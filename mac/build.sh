#!/bin/zsh
# AIエージェント.app をビルドする
#   ./build.sh            → build/AIエージェント.app を作成
#   ./build.sh --install  → /Applications にインストールして起動
set -e
cd "$(dirname "$0")"
APP_NAME="AIエージェント"
APP="build/$APP_NAME.app"

swift build -c release
[ -f Resources/AppIcon.icns ] || swift scripts/make_icon.swift Resources

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AIAgent "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Apple Development 証明書があれば使う（再ビルドしてもマイク許可やキーチェーン許可が保たれる）。なければ ad-hoc 署名
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
xattr -cr "$APP"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "✅ $APP (署名: ${IDENTITY:-ad-hoc})"

if [ "$1" = "--install" ]; then
  pkill -x AIAgent 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "✅ /Applications/$APP_NAME.app にインストールしました"
fi
