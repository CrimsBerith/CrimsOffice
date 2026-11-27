#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SKIP_BUILD=false
if [ "${1:-}" = "--skip-build" ]; then
    SKIP_BUILD=true
fi

echo "🔨 Crims Office v4 (macOS Native SwiftUI) derleniyor..."
if [ "$SKIP_BUILD" = false ]; then
    swift build -c release
fi

if [ ! -x ".build/release/ClawOffice" ]; then
    echo "❌ Derlenmiş ikili bulunamadı: .build/release/ClawOffice" >&2
    exit 1
fi

APP_DIR="build/Crims Office.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp ".build/release/ClawOffice" "$APP_DIR/Contents/MacOS/CrimsOffice"

if [ -d ".build/release/ClawOffice_ClawOffice.bundle" ]; then
    cp -R ".build/release/ClawOffice_ClawOffice.bundle" "$APP_DIR/Contents/Resources/"
fi
cp -R "Sources/ClawOffice/Resources/avatars" "$APP_DIR/Contents/Resources/avatars"

if [ -d "Assets/AppIcon.iconset" ] && command -v iconutil >/dev/null 2>&1; then
    echo "🎨 macOS AppIcon.icns (Crims Office) oluşturuluyor..."
    iconutil -c icns "Assets/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CrimsOffice</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.crimsoffice.macos.v4</string>
    <key>CFBundleName</key><string>Crims Office</string>
    <key>CFBundleDisplayName</key><string>Crims Office</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>4.0.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Crims Office harici diskteki proje dosyalarını ve çalışma alanını yönetmek için çıkarılabilir disk erişimine ihtiyaç duyar.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Crims Office belgeler klasöründeki proje ve şablon dosyalarını yönetmek için erişim gerektirir.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Crims Office masaüstündeki proje dosyalarını yönetmek için erişim gerektirir.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Crims Office indirilenler klasöründeki proje dosyalarını yönetmek için erişim gerektirir.</string>
</dict>
</plist>
EOF

mkdir -p "$HOME/.openclaw/workspace/skills"
cp -rn Templates/workspace/skills/* "$HOME/.openclaw/workspace/skills/" 2>/dev/null || true

# Kalıcı TCC izni için geçerli Apple Development kimliği ile imzala
DEV_IDENTITY=$(security find-identity -p codesigning -v | grep "Apple Development" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)

if [ -n "$DEV_IDENTITY" ]; then
    echo "🔏 Kod imzalama: $DEV_IDENTITY ile kalıcı imzalanıyor..."
    codesign --force --deep --sign "$DEV_IDENTITY" "$APP_DIR"
else
    echo "🔏 Kod imzalama: Sabit kural (designated requirement) ile imzalanıyor..."
    codesign --force --deep -s - -r='designated => identifier "com.crimsoffice.macos.v4"' "$APP_DIR"
fi

# /Applications/Crims Office.app dizinine kur ve eski ClawOffice kopyasını temizle
INSTALL_DIR="/Applications/Crims Office.app"
LEGACY_APP="/Applications/ClawOffice.app"
echo "📦 /Applications dizinine kopyalanıyor: $INSTALL_DIR"
osascript -e 'tell application id "com.crimsoffice.macos.v4" to quit' 2>/dev/null || true
osascript -e 'tell application id "com.clawoffice.macos.v4" to quit' 2>/dev/null || true
pkill -TERM -x "CrimsOffice" 2>/dev/null || true
pkill -TERM -x "ClawOffice" 2>/dev/null || true
for _ in $(seq 1 20); do
    if ! pgrep -x "CrimsOffice" >/dev/null 2>&1 && ! pgrep -x "ClawOffice" >/dev/null 2>&1; then
        break
    fi
    sleep 0.15
done
pkill -KILL -x "CrimsOffice" 2>/dev/null || true
pkill -KILL -x "ClawOffice" 2>/dev/null || true
rm -rf "$INSTALL_DIR" "$LEGACY_APP"
ditto "$APP_DIR" "$INSTALL_DIR"
if [ -n "$DEV_IDENTITY" ]; then
    codesign --force --deep --sign "$DEV_IDENTITY" "$INSTALL_DIR"
else
    codesign --force --deep -s - -r='designated => identifier "com.crimsoffice.macos.v4"' "$INSTALL_DIR"
fi

# Refresh macOS LaunchServices icon cache for the new Crims Office bundle
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR" >/dev/null 2>&1 || true

echo "✅ Hazır: $INSTALL_DIR"
open "$INSTALL_DIR"
