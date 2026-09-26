#!/bin/zsh
# Build a Finder-launchable app bundle for this checkout.
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Thongpari Virtual Fly Lab"
SOURCE_IMAGE="$ROOT/assets/ThongpariFlyIconSource.png"
OUTPUT="$ROOT/dist/$APP_NAME.app"
mkdir -p "$ROOT/dist"
STAGE_ROOT="$(mktemp -d "$ROOT/dist/.package-XXXXXXXX")"
# Keep the staging directory's name extension-free so Finder does not attach
# bundle FinderInfo until after codesign has sealed the contents.
APP="$STAGE_ROOT/$APP_NAME.bundle-stage"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET="$STAGE_ROOT/Thongpari.iconset"

cleanup() { rm -rf -- "$STAGE_ROOT"; }
trap cleanup EXIT

if [[ ! -f "$SOURCE_IMAGE" ]]; then
  print -u2 "App icon source is missing: $SOURCE_IMAGE"
  exit 1
fi

mkdir -p "$MACOS" "$RESOURCES" "$ICONSET"
if [[ ! -x "$ROOT/ThongpariFlyNeuronSim" ]] || \
   find "$ROOT" -maxdepth 1 \( -name '*.swift' -o -name '*.metal' -o -name 'build.sh' \) \
     -newer "$ROOT/ThongpariFlyNeuronSim" -print -quit | grep -q .; then
  "$ROOT/build.sh"
else
  print "Using current ./ThongpariFlyNeuronSim build"
fi
cp "$ROOT/ThongpariFlyNeuronSim" "$MACOS/ThongpariFlyNeuronSim"
cp "$ROOT/LIF.metal" "$RESOURCES/LIF.metal"
ditto --norsrc --noextattr "$ROOT/data" "$RESOURCES/data"

SOURCE_WIDTH="$(sips -g pixelWidth "$SOURCE_IMAGE" | awk '/pixelWidth/ {print $2}')"
SOURCE_HEIGHT="$(sips -g pixelHeight "$SOURCE_IMAGE" | awk '/pixelHeight/ {print $2}')"
if (( SOURCE_WIDTH >= SOURCE_HEIGHT )); then
  CROP_SIZE="$SOURCE_HEIGHT"
  CROP_X="$(((SOURCE_WIDTH - SOURCE_HEIGHT) / 2))"
  CROP_Y=0
else
  CROP_SIZE="$SOURCE_WIDTH"
  CROP_X=0
  CROP_Y="$(((SOURCE_HEIGHT - SOURCE_WIDTH) / 2))"
fi
SQUARE_IMAGE="$STAGE_ROOT/icon-source-square.png"
sips -c "$CROP_SIZE" "$CROP_SIZE" "$SOURCE_IMAGE" \
  --cropOffset "$CROP_Y" "$CROP_X" --out "$SQUARE_IMAGE" >/dev/null
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SQUARE_IMAGE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SQUARE_IMAGE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" --output "$RESOURCES/ThongpariFlyNeuronSim.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleExecutable</key><string>ThongpariFlyNeuronSim</string>
  <key>CFBundleIconFile</key><string>ThongpariFlyNeuronSim</string>
  <key>CFBundleIdentifier</key><string>org.thongpari.VirtualFlyLab</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Thongpari Virtual Fly Lab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :ThongpariProjectRoot string $ROOT" "$CONTENTS/Info.plist"
printf '%s\n' "$ROOT" > "$RESOURCES/.thongpari-generated-bundle"
chmod +x "$MACOS/ThongpariFlyNeuronSim"
xattr -cr "$APP"
report_bundle_metadata() {
  print -u2 "Unsignable bundle details:"
  xattr -lr "$APP" 2>&1 | head -80 >&2 || true
  find "$APP" \( -name '._*' -o -name '.DS_Store' \) -print >&2
  find "$APP" -type l -print >&2
}
if ! codesign --force --deep --sign - "$APP"; then
  report_bundle_metadata
  exit 1
fi
if ! codesign --verify --deep --strict "$APP"; then
  report_bundle_metadata
  exit 1
fi

if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
  MARKER="$OUTPUT/Contents/Resources/.thongpari-generated-bundle"
  # Compare through the filesystem: Hangul path components may be stored in a
  # different Unicode normalization than `pwd` reports.
  if [[ ! -f "$MARKER" ]] || [[ "$(cd "$(<"$MARKER")" 2>/dev/null && pwd -P)" != "$(cd "$ROOT" && pwd -P)" ]]; then
    print -u2 "Refusing to replace an app bundle that was not generated here: $OUTPUT"
    exit 1
  fi
  rm -rf -- "$OUTPUT"
fi
mv "$APP" "$OUTPUT"
print "Built $OUTPUT"
