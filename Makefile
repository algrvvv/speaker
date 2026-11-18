APP := build/Speaker.app
CONTENTS := $(APP)/Contents
EXECUTABLE := $(CONTENTS)/MacOS/Speaker
PLIST := $(CONTENTS)/Info.plist
ICON := $(CONTENTS)/Resources/Speaker.icns
ICONSET := build/Speaker.iconset
SIGNATURE := $(CONTENTS)/_CodeSignature/CodeResources
SOURCES := $(wildcard Sources/*.swift)
ARCH := $(shell uname -m)
MIN_MACOS := 15.0

.DELETE_ON_ERROR:
.PHONY: all run check clean

all: $(SIGNATURE)

$(EXECUTABLE): $(SOURCES) Makefile
	mkdir -p "$(@D)"
	xcrun --sdk macosx swiftc -swift-version 6 -warnings-as-errors -O -target $(ARCH)-apple-macosx$(MIN_MACOS) -module-cache-path build/ModuleCache $(SOURCES) -o "$@"

$(PLIST): Info.plist
	mkdir -p "$(@D)"
	cp "$<" "$@"

$(ICON): Assets/Speaker.png Makefile
	mkdir -p "$(ICONSET)" "$(@D)"
	@set -e; for size in 16 32 128 256 512; do \
		retina=$$((size * 2)); \
		sips -z $$size $$size "$<" --out "$(ICONSET)/icon_$${size}x$${size}.png" >/dev/null; \
		sips -z $$retina $$retina "$<" --out "$(ICONSET)/icon_$${size}x$${size}@2x.png" >/dev/null; \
	done
	iconutil -c icns "$(ICONSET)" -o "$@"

$(SIGNATURE): $(EXECUTABLE) $(PLIST) $(ICON)
	codesign --force --sign - "$(APP)"

run: all
	open "$(APP)"

check: all
	plutil -lint "$(PLIST)"
	codesign --verify --strict "$(APP)"

clean:
	rm -rf build
