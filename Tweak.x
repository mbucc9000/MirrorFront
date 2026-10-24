// MirrorFront — save front-camera photos/videos mirrored (as the preview shows them).
//
// Works at the AVFoundation level instead of hooking PLCameraController, so the
// same code covers Camera.app and the lock-screen camera (which on iOS 6 runs
// inside SpringBoard — that's the process the old tweak missed).
//
// Photos: the JPEG's pixels are flipped in the capture completion handler.
// (1.0 used connection mirroring, which iOS 6 only applies as a mirrored EXIF
// orientation: Photos honors it, Messages strips it when sending.)
// Videos: movie-output connection mirroring.
// The preview layer is left alone; iOS already mirrors it for the front camera.

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>

static BOOL gApplying = NO;
static int gLogLines = 0;

static void MFLog(NSString *fmt, ...) {
    if (gLogLines++ > 40) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
        [NSDate date], [[NSProcessInfo processInfo] processName], msg];
    FILE *f = fopen("/var/mobile/MirrorFront.log", "a");
    if (f) {
        fputs([line UTF8String], f);
        fclose(f);
    }
}

static BOOL MFIsFront(AVCaptureConnection *c) {
    for (AVCaptureInputPort *port in [c inputPorts]) {
        AVCaptureInput *in = [port input];
        if ([in isKindOfClass:[AVCaptureDeviceInput class]] &&
            [[(AVCaptureDeviceInput *)in device] position] == AVCaptureDevicePositionFront)
            return YES;
    }
    return NO;
}

// Connections whose mirroring we force on (videos only).
static BOOL MFIsFrontOutputConnection(AVCaptureConnection *c) {
    return [[c output] isKindOfClass:[AVCaptureMovieFileOutput class]] && MFIsFront(c);
}

static BOOL MFIsFrontStill(AVCaptureConnection *c) {
    return [[c output] isKindOfClass:[AVCaptureStillImageOutput class]] && MFIsFront(c);
}

// Make sure the still connection isn't EXIF-mirrored as well (1.0's setting can
// linger on a live session), or it would cancel out the pixel flip.
static void MFUnmirrorStill(AVCaptureConnection *c) {
    if (![c isVideoMirroringSupported]) return;
    gApplying = YES;
    @try {
        [c setAutomaticallyAdjustsVideoMirroring:NO];
        [c setVideoMirrored:NO];
    } @catch (NSException *e) {
        MFLog(@"unmirror: exception %@", e);
    }
    gApplying = NO;
}

// Returns a new +1 sample buffer holding the mirrored JPEG, or NULL.
static CMSampleBufferRef MFCreateFlippedBuffer(CMSampleBufferRef sb) {
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (!fd || CMFormatDescriptionGetMediaSubType(fd) != kCMVideoCodecType_JPEG) {
        MFLog(@"flip: not a JPEG buffer");
        return NULL;
    }
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (!bb) return NULL;
    size_t len = CMBlockBufferGetDataLength(bb);
    NSMutableData *jpeg = [NSMutableData dataWithLength:len];
    if (CMBlockBufferCopyDataBytes(bb, 0, len, [jpeg mutableBytes]) != kCMBlockBufferNoErr) return NULL;

    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    CFRelease(src);
    if (!img) return NULL;

    // Mirror along the axis that ends up horizontal once the orientation is
    // applied. For 5-8 (sideways: the usual portrait shot) that's the raw
    // buffer's vertical axis.
    int orient = 1;
    CFTypeRef att = CMGetAttachment(sb, kCGImagePropertyOrientation, NULL);
    if (att && CFGetTypeID(att) == CFNumberGetTypeID())
        orient = [(__bridge NSNumber *)att intValue];
    else if (props[(__bridge NSString *)kCGImagePropertyOrientation])
        orient = [props[(__bridge NSString *)kCGImagePropertyOrientation] intValue];
    BOOL sideways = (orient >= 5 && orient <= 8);

    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        CGImageRelease(img);
        return NULL;
    }
    if (sideways) {
        CGContextTranslateCTM(ctx, 0, h);
        CGContextScaleCTM(ctx, 1, -1);
    } else {
        CGContextTranslateCTM(ctx, w, 0);
        CGContextScaleCTM(ctx, -1, 1);
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGImageRelease(img);
    CGImageRef flipped = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!flipped) return NULL;

    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
    NSMutableDictionary *outProps = [props mutableCopy] ?: [NSMutableDictionary dictionary];
    outProps[(__bridge NSString *)kCGImageDestinationLossyCompressionQuality] = @0.93;
    BOOL ok = NO;
    if (dst) {
        CGImageDestinationAddImage(dst, flipped, (__bridge CFDictionaryRef)outProps);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(flipped);
    if (!ok) return NULL;

    CMBlockBufferRef nbb = NULL;
    size_t nlen = [out length];
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, nlen, kCFAllocatorDefault, NULL, 0, nlen,
            kCMBlockBufferAssureMemoryNowFlag, &nbb) != kCMBlockBufferNoErr) return NULL;
    CMBlockBufferReplaceDataBytes([out bytes], nbb, 0, nlen);

    CMSampleTimingInfo timing = kCMTimingInfoInvalid;
    CMSampleBufferGetSampleTimingInfo(sb, 0, &timing);
    CMSampleBufferRef nsb = NULL;
    OSStatus st = CMSampleBufferCreate(kCFAllocatorDefault, nbb, true, NULL, NULL, fd, 1, 1, &timing, 1, &nlen, &nsb);
    CFRelease(nbb);
    if (st != noErr || !nsb) {
        MFLog(@"flip: CMSampleBufferCreate failed %d", (int)st);
        return NULL;
    }
    // EXIF, orientation etc. live in the attachments; carry them all over.
    CFDictionaryRef a1 = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sb, kCMAttachmentMode_ShouldPropagate);
    if (a1) {
        CMSetAttachments(nsb, a1, kCMAttachmentMode_ShouldPropagate);
        CFRelease(a1);
    }
    CFDictionaryRef a2 = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sb, kCMAttachmentMode_ShouldNotPropagate);
    if (a2) {
        CMSetAttachments(nsb, a2, kCMAttachmentMode_ShouldNotPropagate);
        CFRelease(a2);
    }
    MFLog(@"flip: %zux%zu orient %d -> %zu bytes", w, h, orient, nlen);
    return nsb;
}

static void MFApply(AVCaptureConnection *c, NSString *why) {
    if (!MFIsFrontOutputConnection(c)) return;
    if (![c isVideoMirroringSupported]) {
        MFLog(@"%@: mirroring not supported on %@", why, NSStringFromClass([[c output] class]));
        return;
    }
    if ([c isVideoMirrored] && ![c automaticallyAdjustsVideoMirroring]) return;
    gApplying = YES;
    @try {
        [c setAutomaticallyAdjustsVideoMirroring:NO];
        [c setVideoMirrored:YES];
        MFLog(@"%@: mirrored %@", why, NSStringFromClass([[c output] class]));
    } @catch (NSException *e) {
        MFLog(@"%@: exception %@", why, e);
    }
    gApplying = NO;
}

static void MFApplySession(AVCaptureSession *s, NSString *why) {
    for (AVCaptureOutput *out in [s outputs]) {
        for (AVCaptureConnection *c in [out connections]) {
            MFApply(c, why);
        }
    }
}

%hook AVCaptureSession

- (void)commitConfiguration
{
    %orig;
    MFApplySession(self, @"commit");
}

- (void)startRunning
{
    MFApplySession(self, @"start");
    %orig;
}

- (void)addInput:(AVCaptureInput *)input
{
    %orig;
    MFApplySession(self, @"addInput");
}

- (void)addOutput:(AVCaptureOutput *)output
{
    %orig;
    MFApplySession(self, @"addOutput");
}

%end

// Stop PhotoLibrary from switching it back.
%hook AVCaptureConnection

- (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)value
{
    if (!gApplying && value && MFIsFrontOutputConnection(self)) {
        %orig(NO);
        return;
    }
    %orig;
}

- (void)setVideoMirrored:(BOOL)value
{
    if (!gApplying && !value && MFIsFrontOutputConnection(self)) {
        MFApply(self, @"setVideoMirrored");
        return;
    }
    %orig;
}

%end

%hook AVCaptureStillImageOutput

- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection completionHandler:(void (^)(CMSampleBufferRef, NSError *))handler
{
    if (!handler || !MFIsFrontStill(connection)) {
        %orig;
        return;
    }
    MFUnmirrorStill(connection);
    void (^orig)(CMSampleBufferRef, NSError *) = [handler copy];
    %orig(connection, ^(CMSampleBufferRef sb, NSError *err) {
        CMSampleBufferRef flipped = NULL;
        if (sb && !err) {
            @try {
                flipped = MFCreateFlippedBuffer(sb);
            } @catch (NSException *e) {
                MFLog(@"flip: exception %@", e);
            }
        }
        orig(flipped ?: sb, err);
        if (flipped) CFRelease(flipped);
    });
}

%end

%hook AVCaptureMovieFileOutput

- (void)startRecordingToOutputFileURL:(NSURL *)url recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate
{
    for (AVCaptureConnection *c in [self connections]) {
        MFApply(c, @"record");
    }
    %orig;
}

%end

%ctor {
    MFLog(@"loaded");
    %init;
}
