ARCHS ?= arm64
TARGET ?= iphone:clang:latest:15.0
FINALPACKAGE ?= 1

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FocusFB

FocusFB_FILES = \
	src/Tweak.mm \
	src/FocusFBPrefs.mm \
	src/FocusFBSideloadFix.mm \
	src/FocusFBTabManager.mm \
	src/FocusFBSettingsViewController.mm

FocusFB_CFLAGS = -fobjc-arc -Isrc -Wno-deprecated-declarations -Wno-undeclared-selector
FocusFB_CCFLAGS = -std=c++17
FocusFB_FRAMEWORKS = Foundation UIKit QuartzCore CoreGraphics Security AVFoundation

include $(THEOS_MAKE_PATH)/library.mk
