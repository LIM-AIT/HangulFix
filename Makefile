.PHONY: build test run icon app install verify package dmg notarize e2e-create e2e-check clean

E2E_DIR ?= $(HOME)/Desktop/HangulFix-E2E-Test

build:
	swift build

test:
	swift test

run:
	swift run HangulFix

icon:
	./scripts/create-app-icon.sh dist/HangulFix.icns

app:
	./scripts/create-app-bundle.sh

install: app
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/HangulFix.app"
	ditto dist/HangulFix.app "$(HOME)/Applications/HangulFix.app"
	open "$(HOME)/Applications/HangulFix.app"

verify:
	swift test
	swift build -c release
	./scripts/create-app-bundle.sh
	test -x dist/HangulFix.app/Contents/MacOS/HangulFix
	test -f dist/HangulFix.app/Contents/Resources/HangulFix.icns
	@test "$$(( $$(stat -f%z dist/HangulFix.app/Contents/Resources/HangulFix.icns) ))" -gt 1000
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/HangulFix.app/Contents/Info.plist)" = "0.8.0"
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' dist/HangulFix.app/Contents/Info.plist)" = "HangulFix"
	@if command -v codesign >/dev/null 2>&1; then \
		codesign --verify --deep --strict --verbose=2 dist/HangulFix.app; \
	fi

package: app
	rm -f dist/HangulFix-macOS.zip dist/HangulFix-macOS.zip.sha256
	ditto -c -k --sequesterRsrc --keepParent dist/HangulFix.app dist/HangulFix-macOS.zip
	shasum -a 256 dist/HangulFix-macOS.zip > dist/HangulFix-macOS.zip.sha256
	./scripts/create-dmg.sh

dmg: app
	./scripts/create-dmg.sh

notarize:
	./scripts/notarize-release.sh

e2e-create:
	python3 scripts/e2e_fixture.py create "$(E2E_DIR)"

e2e-check:
	python3 scripts/e2e_fixture.py check "$(E2E_DIR)"

clean:
	swift package clean
	rm -rf dist
