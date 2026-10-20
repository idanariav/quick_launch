APP_NAME := QuickLaunch
DERIVED  := build
APP      := $(DERIVED)/Build/Products/Debug/$(APP_NAME).app
XCB      := xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) \
            -configuration Debug -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64'

.PHONY: gen build run test clean

gen:
	xcodegen generate --quiet

build: gen
	$(XCB) -quiet build

run: build
	-pkill -x $(APP_NAME)
	open $(APP)

# Prints failures (✘) and the run summary; full log in build/test.log.
test: gen
	set -o pipefail; $(XCB) test 2>&1 | tee $(DERIVED)/test.log | grep -E '✘|✔ Test run|error:|\*\* TEST'

clean:
	rm -rf $(DERIVED) $(APP_NAME).xcodeproj
