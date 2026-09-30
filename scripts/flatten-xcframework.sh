#!/usr/bin/env bash
# Turns gomobile's versioned framework bundles into the shallow ones iOS wants.
#
# `gomobile bind -target ios` emits a macOS-style bundle: a Versions/A directory
# with symlinks at the root. Xcode refuses to embed that in an iOS app, with
# "expected Info.plist at the root level since the platform uses shallow
# bundles", and the framework links fine right up until that point, so the
# failure lands at the very end of a long build.
#
# Idempotent: a slice that is already shallow is left alone.
set -euo pipefail

xcframework="${1:?usage: flatten-xcframework.sh <path/to/Foo.xcframework>}"
name="$(basename "$xcframework" .xcframework)"

for slice in "$xcframework"/*/; do
  framework="$slice$name.framework"
  [ -d "$framework/Versions/A" ] || continue

  flat="$slice.$name.flat"
  rm -rf "$flat"
  mkdir -p "$flat"
  cp "$framework/Versions/A/$name" "$flat/$name"
  cp -R "$framework/Versions/A/Headers" "$flat/Headers"
  cp -R "$framework/Versions/A/Modules" "$flat/Modules"
  cp "$framework/Versions/A/Resources/Info.plist" "$flat/Info.plist"

  # gomobile writes an empty dict there, which Xcode rejects on embed with
  # "Info.plist of framework ... was empty". A framework bundle needs at least
  # an executable name, an identifier and the platform it was built for.
  if ! /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$flat/Info.plist" >/dev/null 2>&1; then
    case "$slice" in
      *simulator*) platform=iPhoneSimulator ;;
      *) platform=iPhoneOS ;;
    esac
    cat > "$flat/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>land.gno.$(echo "$name" | tr '[:upper:]' '[:lower:]')</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>MinimumOSVersion</key><string>13.4</string>
</dict>
</plist>
PLIST
    echo "wrote a usable Info.plist for $platform"
  fi

  rm -rf "$framework"
  mv "$flat" "$framework"
  echo "flattened $framework"
done

# The xcframework's own manifest still points into Versions/A.
plist="$xcframework/Info.plist"
if grep -q "$name.framework/Versions/A/$name" "$plist"; then
  sed -i '' "s|$name.framework/Versions/A/$name|$name.framework/$name|g" "$plist"
  echo "rewrote BinaryPath in $plist"
fi
