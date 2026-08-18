.PHONY: build test run app install verify package e2e-create e2e-check clean

E2E_DIR ?= $(HOME)/Desktop/HangulFix-E2E-Test
INSTALL_DIR ?= $(HOME)/Applications

build:
	swift build

test:
	swift test

run:
	swift run HangulFix

app:
	./scripts/create-app-bundle.sh

install: app
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/HangulFix.app"
	ditto dist/HangulFix.app "$(INSTALL_DIR)/HangulFix.app"
	open "$(INSTALL_DIR)/HangulFix.app"

verify:
	swift test
	swift build -c release
	./scripts/create-app-bundle.sh
	test -x dist/HangulFix.app/Contents/MacOS/HangulFix
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSMessage' dist/HangulFix.app/Contents/Info.plist)" = "openInHangulFix"
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSSendFileTypes:0' dist/HangulFix.app/Contents/Info.plist)" = "public.item"
	@if command -v codesign >/dev/null 2>&1; then \
		codesign --verify --deep --strict --verbose=2 dist/HangulFix.app; \
	fi

package:
	@test -d dist/HangulFix.app || $(MAKE) app
	rm -f dist/HangulFix-macOS.zip dist/HangulFix-macOS.zip.sha256
	ditto -c -k --sequesterRsrc --keepParent dist/HangulFix.app dist/HangulFix-macOS.zip
	shasum -a 256 dist/HangulFix-macOS.zip > dist/HangulFix-macOS.zip.sha256

e2e-create:
	python3 scripts/e2e_fixture.py create "$(E2E_DIR)"

e2e-check:
	python3 scripts/e2e_fixture.py check "$(E2E_DIR)"

clean:
	swift package clean
	rm -rf dist
