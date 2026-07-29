# SnapScan — everything builds through xcodebuild into Xcode's own
# DerivedData (the same product ⌘R makes; no side copies). This Makefile
# just sequences the vendored dependencies in front of it.
#
#   make            build vendored SANE (first time), SANE.xcframework, and
#                   the app (Release); prints the product's path
#   make test       run the unit tests
#   make smoke      build + run the headless scanner smoke test (needs the
#                   scanner free — quit SnapScan first)
#   make clean      xcodebuild clean (keeps vendor/ and the xcframework)
#   make distclean  also remove the built SANE stack and xcframework

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
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme SnapScan \
		-configuration Release build 2>&1 | grep -E "^\*\*|error:"
	@echo "App: $$(xcodebuild -project $(PROJECT) -scheme SnapScan \
		-configuration Release -showBuildSettings 2>/dev/null \
		| awk '/ BUILT_PRODUCTS_DIR =/{print $$3}')/SnapScan.app"

test: SANE.xcframework/Info.plist
	xcodebuild -project $(PROJECT) -scheme SnapScan test

smoke: SANE.xcframework/Info.plist
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme SaneSmokeTest \
		-configuration Release build 2>&1 | grep -E "^\*\*|error:"
	"$$(xcodebuild -project $(PROJECT) -scheme SaneSmokeTest \
		-configuration Release -showBuildSettings 2>/dev/null \
		| awk '/ BUILT_PRODUCTS_DIR =/{print $$3}')/SaneSmokeTest"

clean:
	xcodebuild -project $(PROJECT) -scheme SnapScan clean
	xcodebuild -project $(PROJECT) -scheme SaneSmokeTest clean

distclean: clean
	rm -rf SANE.xcframework
	cd vendor && rm -rf bin etc include lib sbin share var
	cd vendor/src && find . -maxdepth 1 -type d ! -name . -exec rm -rf {} +
