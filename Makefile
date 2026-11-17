.PHONY: build app run debug test clean icon

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

icon:
	swift scripts/make-icon.swift /tmp/kveikur-icon.png
	rm -rf /tmp/AppIcon.iconset && mkdir /tmp/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s /tmp/kveikur-icon.png --out /tmp/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) /tmp/kveikur-icon.png --out /tmp/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
