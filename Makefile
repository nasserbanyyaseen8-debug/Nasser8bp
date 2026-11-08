ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = 8BallPool

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NSR8BP
NSR8BP_FILES = Tweak.xm \
	$(wildcard vendor/imgui/*.cpp) \
	vendor/imgui/backends/imgui_impl_metal.mm
NSR8BP_CFLAGS = -fobjc-arc -std=c++17 -Ivendor/imgui -Ivendor/imgui/backends -Wno-deprecated-declarations
NSR8BP_CCFLAGS = -std=c++17 -Ivendor/imgui -Ivendor/imgui/backends
NSR8BP_FRAMEWORKS = UIKit Foundation Metal MetalKit QuartzCore CoreGraphics
NSR8BP_LIBRARIES = c++

include $(THEOS)/makefiles/tweak.mk