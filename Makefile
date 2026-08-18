.PHONY: build test run app clean

build:
	swift build

test:
	swift test

run:
	swift run HangulFix

app:
	./scripts/create-app-bundle.sh

clean:
	swift package clean
	rm -rf dist
