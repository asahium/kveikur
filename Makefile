.PHONY: build app run debug test clean icon ios ios-sim

IOS_SIM ?= iPhone 17 Pro

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

icon:
	swift scripts/make-icon.swift /tmp/kveikur-icon.png
	rm -rf /tmp/AppIcon.iconset && mkdir /tmp/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s /tmp/kveikur-icon.png --out /tmp/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) /tmp/kveikur-icon.png --out /tmp/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
