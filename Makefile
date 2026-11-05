.PHONY: build test app run install clean

build:
	swift build

test:
	swift test

app:
	scripts/bundle.sh

run: app
	open "dist/Vibe Cleaner.app"

install: app
	rm -rf "/Applications/Vibe Cleaner.app"
	cp -R "dist/Vibe Cleaner.app" /Applications/

clean:
	rm -rf .build dist
