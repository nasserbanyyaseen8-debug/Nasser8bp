ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = 8BallPool

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NSR8BP

# ImGui is vendored by CI into vendor/imgui before make runs.
# Explicit list (no wildcard) so the build is deterministic; demo excluded.
NSR8BP_FILES = Tweak.xm \
	vendor/imgui/imgui.cpp \
	vendor/imgui/imgui_draw.cpp \
	vendor/imgui/imgui_tables.cpp \
	vendor/imgui/imgui_widgets.cpp \
	vendor/imgui/backends/imgui_impl_metal.mm

NSR8BP_CFLAGS = -fobjc-arc -std=c++17 -Ivendor/imgui -Ivendor/imgui/backends -Isrc \
	-Wno-deprecated-declarations -Wno-unused-function
NSR8BP_CCFLAGS = -std=c++17 -Ivendor/imgui -Ivendor/imgui/backends -Isrc \
	-Wno-deprecated-declarations -Wno-unused-function
NSR8BP_FRAMEWORKS = UIKit Foundation Metal MetalKit QuartzCore CoreGraphics
NSR8BP_LIBRARIES = c++

include $(THEOS)/makefiles/tweak.mk