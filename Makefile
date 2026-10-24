TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MirrorFront
MirrorFront_FILES = Tweak.x
MirrorFront_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreGraphics ImageIO
MirrorFront_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 Camera; killall -9 SpringBoard"
