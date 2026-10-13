init:
	@echo You probably want to run "zig build" instead.
.PHONY: init

# ghostty-fork: one-step production build of Burrow.app. The core library has
# to be built optimized first: the app links whatever GhosttyKit.xcframework
# holds, and a plain `zig build` leaves a Debug core there.
ZIG ?= /opt/homebrew/opt/zig@0.16/bin/zig
APP := macos/build/ReleaseLocal/Burrow.app

release:
	$(ZIG) build -Doptimize=ReleaseFast -Demit-macos-app=false
	cd macos && xcodebuild -project Ghostty.xcodeproj -scheme Ghostty \
		-configuration ReleaseLocal SYMROOT=$$PWD/build build
.PHONY: release

# Copies the release build into /Applications. Quit Burrow first.
install: release
	@if pgrep -xq Burrow; then echo "Quit Burrow before installing."; exit 1; fi
	ditto $(APP) /Applications/Burrow.app
.PHONY: install

# glad updates the GLAD loader. To use this, place the generated glad.zip
# in this directory next to the Makefile, remove vendor/glad and run this target.
#
# Generator: https://gen.glad.sh/
glad: vendor/glad
.PHONY: glad

vendor/glad: vendor/glad/include/glad/gl.h vendor/glad/include/glad/glad.h

vendor/glad/include/glad/gl.h: glad.zip
	rm -rf vendor/glad
	mkdir -p vendor/glad
	unzip glad.zip -dvendor/glad
	find vendor/glad -type f -exec touch '{}' +

vendor/glad/include/glad/glad.h: vendor/glad/include/glad/gl.h
	@echo "#include <glad/gl.h>" > $@

clean:
	rm -rf \
		zig-out .zig-cache \
		macos/build \
		macos/GhosttyKit.xcframework
.PHONY: clean
