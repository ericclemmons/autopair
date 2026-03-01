.PHONY: run build

run: build
	pkill -x AutoPair 2>/dev/null || true
	codesign --force --options runtime --entitlements AutoPair.entitlements --sign - AutoPair.app
	open AutoPair.app

build:
	bash build-app.sh debug
