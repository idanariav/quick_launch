APP_NAME := QuickLaunch
DERIVED  := build
PKG      := Packages/QuickLaunchKit
APP      := $(DERIVED)/Build/Products/Debug/$(APP_NAME).app
XCB      := xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) \
            -configuration Debug -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64'

.PHONY: gen build run test test-pkg test-app lint clean install-cli streamdeck dmg

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

# The Stream Deck plugin (decision 0019): build it and link it into Stream Deck.
SD := integrations/streamdeck
streamdeck:
	cd $(SD) && npm ci --ignore-scripts && npm run typecheck && npm run build
	cd $(SD) && npx streamdeck validate com.idanariav.quicklaunch.sdPlugin && npx streamdeck link com.idanariav.quicklaunch.sdPlugin
	cd $(SD) && npx streamdeck restart com.idanariav.quicklaunch

# A notarized DMG for installing on other Macs (decision 0032). Universal Release
# build, signed with Developer ID. Notarizing needs stored credentials, once:
#   xcrun notarytool store-credentials quicklaunch-notary --apple-id <id> --team-id RLUV35UZ26
NOTARY_PROFILE ?= quicklaunch-notary
REL_APP := $(DERIVED)/Build/Products/Release/$(APP_NAME).app
STAGE   := $(DERIVED)/dmg
dmg: gen
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Release \
	  -derivedDataPath $(DERIVED) -destination 'generic/platform=macOS' -quiet build
	codesign --verify --strict $(REL_APP)
	@version=$$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $(REL_APP)/Contents/Info.plist); \
	dmg=$(DERIVED)/$(APP_NAME)-$$version.dmg; \
	rm -rf $(STAGE) $$dmg && mkdir -p $(STAGE) && \
	cp -R $(REL_APP) $(STAGE)/ && ln -s /Applications $(STAGE)/Applications && \
	hdiutil create -quiet -volname $(APP_NAME) -srcfolder $(STAGE) -format UDZO $$dmg && \
	codesign --sign "Developer ID Application" --timestamp --keychain $(HOME)/Library/Keychains/login.keychain-db $$dmg && \
	xcrun notarytool submit $$dmg --keychain-profile $(NOTARY_PROFILE) --wait && \
	xcrun stapler staple $$dmg && \
	spctl --assess --type open --context context:primary-signature -v $$dmg && \
	echo "Built $$dmg"

clean:
	rm -rf $(DERIVED) $(APP_NAME).xcodeproj $(PKG)/.build
