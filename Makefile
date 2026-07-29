# SnapScan — everything builds through xcodebuild (the same project, targets,
# signing, and phases as Xcode's Build & Run). This Makefile just sequences
# the dependencies in front of it.
#
#   make            build vendored SANE (first time), SANE.xcframework, and
#                   dist/SnapScan.app (Release)
#   make test       run the unit tests
#   make smoke      build + run the headless scanner smoke test (needs the
#                   scanner free — quit SnapScan first)
#   make clean      remove build products (keeps vendor/ and the xcframework)
#   make distclean  also remove the built SANE stack and xcframework

DERIVED := .build/DerivedData
PROJECT := SnapScan.xcodeproj

.PHONY: all app test smoke clean distclean

all: app

# The vendored SANE stack (libusb + sane-backends), built from the tarballs
# in vendor/src.
vendor/lib/libsane.1.dylib: scripts/build-sane.sh
	scripts/build-sane.sh

# libsane wrapped as a framework with headers + module map for Xcode.
SANE.xcframework/Info.plist: vendor/lib/libsane.1.dylib scripts/make-xcframework.sh
	scripts/make-xcframework.sh

app: SANE.xcframework/Info.plist
	xcodebuild -project $(PROJECT) -scheme SnapScan -configuration Release \
		-derivedDataPath $(DERIVED) build 2>&1 | grep -E "^\*\*|error:"
	rm -rf dist/SnapScan.app
	mkdir -p dist
	cp -R $(DERIVED)/Build/Products/Release/SnapScan.app dist/SnapScan.app
	@echo "Done: dist/SnapScan.app"

test: SANE.xcframework/Info.plist
	xcodebuild -project $(PROJECT) -scheme SnapScan \
		-derivedDataPath $(DERIVED) test

smoke: SANE.xcframework/Info.plist
	xcodebuild -project $(PROJECT) -scheme SaneSmokeTest -configuration Release \
		-derivedDataPath $(DERIVED) build
	$(DERIVED)/Build/Products/Release/SaneSmokeTest

clean:
	rm -rf dist $(DERIVED)

distclean: clean
	rm -rf SANE.xcframework
	cd vendor && rm -rf bin etc include lib sbin share var
	cd vendor/src && find . -maxdepth 1 -type d ! -name . -exec rm -rf {} +
