.PHONY: build app run debug test clean icon ios ios-sim ios-device print-device ios-autosign ios-autosign-off dmg

IOS_SIM ?= iPhone 17 Pro
LAUNCH ?= 1
# Team of the first "Apple Development" certificate (Xcode → Settings → Accounts creates one, a free Apple ID works).
TEAM ?= $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
# The phone build takes over the Mac's Last.fm session (read at build time, never committed).
PREF = defaults read dev.kveikur.player
LASTFM_FROM_MAC = KVEIKUR_LASTFM_KEY="$$($(PREF) lastfmKey 2>/dev/null)" KVEIKUR_LASTFM_SECRET="$$($(PREF) lastfmSecret 2>/dev/null)" \
	KVEIKUR_LASTFM_SESSION="$$($(PREF) lastfmSession 2>/dev/null)" KVEIKUR_LASTFM_USER="$$($(PREF) lastfmUser 2>/dev/null)"
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /(available|connected)/ {for (i=1;i<=NF;i++) if ($$i ~ /^[0-9A-F]{8}-/) {print $$i; exit}}')

build:
	swift build -c release

app:
	./scripts/bundle.sh release

run: app
	open build/Kveikur.app

debug:
	./scripts/bundle.sh debug && open build/Kveikur.app

test:
	swift test

dmg:
	./scripts/dmg.sh

clean:
	rm -rf .build build

ios:
	cd iOS && xcodegen generate && open KveikurMobile.xcodeproj

ios-sim:
	cd iOS && xcodegen generate && xcodebuild -project KveikurMobile.xcodeproj -scheme KveikurMobile \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM)' -derivedDataPath ../.build/ios build
	xcrun simctl boot '$(IOS_SIM)' 2>/dev/null || true
	xcrun simctl install booted .build/ios/Build/Products/Debug-iphonesimulator/Kveikur.app
	xcrun simctl launch booted dev.kveikur.mobile

ios-device:
	@test -n "$(TEAM)" || (echo "No Apple Development certificate: add an Apple ID in Xcode → Settings → Accounts" && exit 1)
	@test -n "$(DEVICE)" || (echo "No paired iPhone found (connect it, unlock, trust this Mac)" && exit 1)
	cd iOS && xcodegen generate && $(LASTFM_FROM_MAC) xcodebuild -project KveikurMobile.xcodeproj -scheme KveikurMobile \
		-destination 'generic/platform=iOS' -derivedDataPath ../.build/ios-device -allowProvisioningUpdates \
		DEVELOPMENT_TEAM=$(TEAM) build
	xcrun devicectl device install app --device $(DEVICE) .build/ios-device/Build/Products/Debug-iphoneos/Kveikur.app
	@if [ "$(LAUNCH)" = 1 ]; then xcrun devicectl device process launch --device $(DEVICE) dev.kveikur.mobile; fi

print-device:
	@echo $(DEVICE)

AGENT = $(HOME)/Library/LaunchAgents/dev.kveikur.ios-resign.plist

# Re-sign the iPhone beta over Wi-Fi before the free 7-day signature runs out.
ios-autosign:
	chmod +x scripts/ios-resign.sh
	@mkdir -p $(HOME)/Library/LaunchAgents
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>Label</key><string>dev.kveikur.ios-resign</string>' \
		'<key>ProgramArguments</key><array><string>$(CURDIR)/scripts/ios-resign.sh</string></array>' \
		'<key>StartInterval</key><integer>10800</integer>' \
		'<key>RunAtLoad</key><true/>' \
		'</dict></plist>' > $(AGENT)
	-launchctl bootout gui/$$(id -u) $(AGENT) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT)
	@echo "Installed. Log: ~/Library/Logs/Kveikur/ios-resign.log"

ios-autosign-off:
	-launchctl bootout gui/$$(id -u) $(AGENT)
	rm -f $(AGENT)

icon:
	swift scripts/make-icon.swift /tmp/kveikur-icon.png
	rm -rf /tmp/AppIcon.iconset && mkdir /tmp/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s /tmp/kveikur-icon.png --out /tmp/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) /tmp/kveikur-icon.png --out /tmp/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
