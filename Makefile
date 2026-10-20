APP_NAME := QuickLaunch
DERIVED  := build
PKG      := Packages/QuickLaunchKit
APP      := $(DERIVED)/Build/Products/Debug/$(APP_NAME).app
XCB      := xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) \
            -configuration Debug -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64'

.PHONY: gen build run test test-pkg test-app lint clean

gen:
	xcodegen generate --quiet

build: gen
	$(XCB) -quiet build

# Waits for the old instance to exit; relaunching too early fails with error -600.
run: build
	@pkill -x $(APP_NAME); while pgrep -qx $(APP_NAME); do sleep 0.1; done
	open $(APP)

# Each test step prints failures (✘) and a summary; full logs in build/*.log.
test: lint test-pkg test-app

test-pkg:
	@mkdir -p $(DERIVED)
	set -o pipefail; swift test --package-path $(PKG) 2>&1 | tee $(DERIVED)/test-pkg.log | grep -E '✘|✔ Test run|error:'

test-app: gen
	@mkdir -p $(DERIVED)
	set -o pipefail; $(XCB) test 2>&1 | tee $(DERIVED)/test-app.log | grep -E '✘|✔ Test run|error:|\*\* TEST'

lint:
	@scripts/lint-layers.sh

clean:
	rm -rf $(DERIVED) $(APP_NAME).xcodeproj $(PKG)/.build
