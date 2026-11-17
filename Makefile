.PHONY: build app run debug test clean icon ios ios-sim ios-device dmg

IOS_SIM ?= iPhone 17 Pro
# Team of the first "Apple Development" certificate (Xcode → Settings → Accounts creates one, a free Apple ID works).
TEAM ?= $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && !/simulated/ {for (i=1;i<=NF;i++) if ($$i ~ /^[0-9A-F]{8}-/) {print $$i; exit}}')

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
	cd iOS && xcodegen generate && xcodebuild -project KveikurMobile.xcodeproj -scheme KveikurMobile \
		-destination 'generic/platform=iOS' -derivedDataPath ../.build/ios-device -allowProvisioningUpdates \
		DEVELOPMENT_TEAM=$(TEAM) build
	xcrun devicectl device install app --device $(DEVICE) .build/ios-device/Build/Products/Debug-iphoneos/Kveikur.app
	xcrun devicectl device process launch --device $(DEVICE) dev.kveikur.mobile

icon:
	swift scripts/make-icon.swift /tmp/kveikur-icon.png
	rm -rf /tmp/AppIcon.iconset && mkdir /tmp/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s /tmp/kveikur-icon.png --out /tmp/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) /tmp/kveikur-icon.png --out /tmp/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
