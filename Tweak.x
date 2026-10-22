// MirrorFront — save front-camera photos/videos mirrored (as the preview shows them).
//
// Works at the AVFoundation level instead of hooking PLCameraController, so the
// same code covers Camera.app and the lock-screen camera (which on iOS 6 runs
// inside SpringBoard — that's the process the old tweak missed).
//
// Only output connections (still image + movie file) are touched; the preview
// layer is left alone because iOS already mirrors it for the front camera.

#import <AVFoundation/AVFoundation.h>

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

static BOOL MFIsFrontOutputConnection(AVCaptureConnection *c) {
    AVCaptureOutput *out = [c output];
    if (!out) return NO; // preview-layer connection
    if (![out isKindOfClass:[AVCaptureStillImageOutput class]] &&
        ![out isKindOfClass:[AVCaptureMovieFileOutput class]]) return NO;
    for (AVCaptureInputPort *port in [c inputPorts]) {
        AVCaptureInput *in = [port input];
        if ([in isKindOfClass:[AVCaptureDeviceInput class]] &&
            [[(AVCaptureDeviceInput *)in device] position] == AVCaptureDevicePositionFront)
            return YES;
    }
    return NO;
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

// Last line of defence: right before the shutter fires.
%hook AVCaptureStillImageOutput

- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection completionHandler:(void (^)(CMSampleBufferRef, NSError *))handler
{
    MFApply(connection, @"capture");
    %orig;
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
