APP_NAME := QuickLaunch
DERIVED  := build
PKG      := Packages/QuickLaunchKit
APP      := $(DERIVED)/Build/Products/Debug/$(APP_NAME).app
XCB      := xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) \
            -configuration Debug -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64'

.PHONY: gen build run test test-pkg test-app lint clean install-cli

gen:
	xcodegen generate --quiet

build: gen
	$(XCB) -quiet build

# Waits for the old instance to exit, then retries: LaunchServices can still report
# it as running for a moment, and `open` then fails with error -600.
run: build
	@pkill -x $(APP_NAME); while pgrep -qx $(APP_NAME); do sleep 0.1; done
	@for attempt in 1 2 3 4 5; do open $(APP) 2>/dev/null && exit 0; sleep 0.5; done; open $(APP)

# Each test step prints failures (✘) and a summary; full logs in build/*.log.
test: lint test-pkg test-app

test-pkg:
	@mkdir -p $(DERIVED)
	set -o pipefail; swift test --package-path $(PKG) 2>&1 | tee $(DERIVED)/test-pkg.log | grep -E '✘|✔ Test run with|error:'

test-app: gen
	@mkdir -p $(DERIVED)
	set -o pipefail; $(XCB) test 2>&1 | tee $(DERIVED)/test-app.log | grep -E '✘|✔ Test run with|error:|\*\* TEST'

lint:
	@scripts/lint-layers.sh

# The `quicklaunch` CLI (decision 0016), copied so `make clean` doesn't break it.
BINDIR ?= /opt/homebrew/bin
install-cli:
	swift build --package-path $(PKG) -c release --product quicklaunch
	install -m 755 $(PKG)/.build/release/quicklaunch $(BINDIR)/quicklaunch

clean:
	rm -rf $(DERIVED) $(APP_NAME).xcodeproj $(PKG)/.build
