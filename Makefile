.PHONY: build test run app verify package clean

build:
	swift build

test:
	swift test

run:
	swift run HangulFix

app:
	./scripts/create-app-bundle.sh

verify:
	swift test
	swift build -c release
	./scripts/create-app-bundle.sh
	test -x dist/HangulFix.app/Contents/MacOS/HangulFix
	@if command -v codesign >/dev/null 2>&1; then \
		codesign --verify --deep --strict --verbose=2 dist/HangulFix.app; \
	fi

package:
	@test -d dist/HangulFix.app || $(MAKE) app
	rm -f dist/HangulFix-macOS.zip dist/HangulFix-macOS.zip.sha256
	ditto -c -k --sequesterRsrc --keepParent dist/HangulFix.app dist/HangulFix-macOS.zip
	shasum -a 256 dist/HangulFix-macOS.zip > dist/HangulFix-macOS.zip.sha256

clean:
	swift package clean
	rm -rf dist
