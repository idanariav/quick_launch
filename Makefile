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

test: gen
	$(XCB) -quiet test

clean:
	rm -rf $(DERIVED) $(APP_NAME).xcodeproj
