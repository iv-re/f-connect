# Usage: make help
APP_NAME   := F-Connect
SCHEME     := FConnect
BUILD_DIR  := build
APP        := $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app
INSTALLED  := /Applications/$(APP_NAME).app
XCODEBUILD := xcodebuild -scheme $(SCHEME) -derivedDataPath $(BUILD_DIR)

.PHONY: help generate build test install uninstall dmg clean

help:
	@echo "make build      build a Release app into $(BUILD_DIR)/"
	@echo "make test       run the unit tests (no hardware needed)"
	@echo "make install    build, then replace $(INSTALLED) and launch it"
	@echo "make uninstall  quit the app and remove it from /Applications"
	@echo "make dmg        build and package $(APP_NAME).dmg"
	@echo "make clean      remove build output"

# Needs xcodegen (brew install xcodegen). Regenerates the Xcode project from project.yml.
generate:
	xcodegen generate

build:
	$(XCODEBUILD) -configuration Release CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build

test:
	$(XCODEBUILD) -destination 'platform=macOS' test

install: build
	-pkill -x $(APP_NAME)
	@sleep 1
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" "$(INSTALLED)"
	open "$(INSTALLED)"

uninstall:
	-pkill -x $(APP_NAME)
	rm -rf "$(INSTALLED)"

dmg: build
	@version=$$(plutil -extract CFBundleShortVersionString raw "$(APP)/Contents/Info.plist"); \
	stage=$$(mktemp -d); \
	cp -R "$(APP)" "$$stage/"; \
	ln -s /Applications "$$stage/Applications"; \
	rm -f "$(BUILD_DIR)/$(APP_NAME)-$$version.dmg"; \
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$$stage" -ov -format UDZO "$(BUILD_DIR)/$(APP_NAME)-$$version.dmg"; \
	rm -rf "$$stage"; \
	echo "Created $(BUILD_DIR)/$(APP_NAME)-$$version.dmg"

clean:
	rm -rf $(BUILD_DIR)
