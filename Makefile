APP_NAME = Kea
# The Swift target keeps its original name.
TARGET = Launcher
BUNDLE_ID = directory.kea.launcher
BUILD = .build/release/$(TARGET)
APP_DIR = dist/$(APP_NAME).app
INSTALL_DIR = /Applications
# A stable signing identity keeps macOS privacy grants (Documents, Full Disk Access)
# across rebuilds. Ad-hoc signing ("-") changes every build and re-prompts each time.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | head -1 | awk '{print $$2}')
# Without one, a self-signed identity from scripts/make-signing-cert.sh also keeps the grants.
ifeq ($(SIGN_IDENTITY),)
SIGN_IDENTITY = $(shell security find-identity -v -p codesigning 2>/dev/null | grep 'Kea Local Signing' | head -1 | awk '{print $$2}')
endif
ifeq ($(SIGN_IDENTITY),)
SIGN_IDENTITY = -
endif

.PHONY: build test run bundle install reload install-commands uninstall clean

build:
	swift build -c release

test:
	swift test

run:
	swift run $(TARGET)

bundle: build
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	cp $(BUILD) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	cp Resources/AppIcon.icns $(APP_DIR)/Contents/Resources/AppIcon.icns
	cp Resources/emoji.tsv $(APP_DIR)/Contents/Resources/emoji.tsv
	sed -e 's/__APP_NAME__/$(APP_NAME)/g' -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/g' Info.plist.template > $(APP_DIR)/Contents/Info.plist
	codesign --force --sign $(SIGN_IDENTITY) $(APP_DIR)
	@echo "Signed with: $(SIGN_IDENTITY)"

install: bundle
	mkdir -p $(INSTALL_DIR)
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R $(APP_DIR) "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Open it with: open \"$(INSTALL_DIR)/$(APP_NAME).app\""

# Restarts the installed app under its LaunchAgent. `kickstart -k` alone only
# replaces the launchd-owned copy; a copy opened from the Dock or Finder would
# survive, and the new copy would then exit on the single-instance check.
reload:
	-pkill -x $(APP_NAME)
	sleep 1
	launchctl kickstart gui/$$(id -u)/directory.kea.launcher.agent || open "$(INSTALL_DIR)/$(APP_NAME).app"
	@sleep 2; pgrep -lx $(APP_NAME)

# Copies the example commands into ~/.launcher/commands without overwriting edits.
install-commands:
	mkdir -p $(HOME)/.launcher/commands
	for d in examples/commands/*/; do n=$$(basename $$d); [ -e "$(HOME)/.launcher/commands/$$n" ] || cp -R "$$d" "$(HOME)/.launcher/commands/$$n"; done
	@ls $(HOME)/.launcher/commands

uninstall:
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

clean:
	rm -rf .build dist
