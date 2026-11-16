#!/bin/zsh
# Builds OkWhispr and installs it to ~/Applications/OkWhispr.app.
# Build products live in ~/Library/Developer/OkWhispr, outside the repo.
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
set -euo pipefail
here=${0:A:h}
name="OkWhispr"
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

# Load signing / notarization credentials from .env.signing when present
# (gitignored via .env*). Provides DEVELOPER_ID_APPLICATION and, for
# NOTARIZE=1, APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD.
if [[ -f "$here/.env.signing" ]]; then
	source "$here/.env.signing"
fi

# Signing identity, resolved in priority order:
#   1. DEVELOPER_ID_APPLICATION from .env.signing   -> Developer ID (default)
#   2. SIGN_IDENTITY environment override
#   3. auto-detected "Apple Development:" identity
#   4. ad hoc ("-") when no certificate is available
# NOTE: permissions (Accessibility, Microphone) are tied to the signature and
# path, so install to the same path and use the same signature every time.
# Switching the identity (e.g. Apple Development -> Developer ID) changes the
# signature and resets TCC, so you must re-grant Microphone + Accessibility.
identity="${DEVELOPER_ID_APPLICATION:-}"
[[ -n "$identity" ]] || identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
	identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

build_log=$(mktemp)
build_ok=1
swift build -c "$config" --package-path "$here" --scratch-path "$scratch" >"$build_log" 2>&1 || build_ok=0
grep -E "error:|warning:|Build complete" "$build_log" | grep -v "^\[" || true
rm -f "$build_log"
[[ "$build_ok" == 1 ]] || {
	echo "build failed"
	exit 1
}
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || {
	echo "build failed: binary not found"
	exit 1
}
# A newer source mtime (e.g. after a git checkout) does not mean the binary is
# stale: swift build tracks content, not mtime, so an up-to-date rebuild reports
# no compile output. Only fail when a re-check actually reports a compile error.
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" 2>/dev/null | head -1)
if [[ -n "$stale" ]]; then
	rebuild_log=$(swift build -c "$config" --package-path "$here" --scratch-path "$scratch" 2>&1)
	if echo "$rebuild_log" | grep -q "error:"; then
		echo "build failed: $stale"
		echo "$rebuild_log" | grep -E "error:" | head -20
		exit 1
	fi
	echo "source mtime newer than binary, but content is up to date; continuing"
fi

# Monotonic build number (incremented on every build) used as CFBundleVersion.
build_number_file="$here/.build_number"
if [[ -f "$build_number_file" ]]; then
	build_number=$(cat "$build_number_file")
else
	build_number=1
fi
build_number=$((build_number + 1))
echo "$build_number" >"$build_number_file"
echo "build number: $build_number"

app="$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
sed -e "s/__BUILD__/$build_number/" "$here/Info.plist.in" >"$app/Contents/Info.plist"
# The icon: render AppIcon.icns (headless CoreGraphics) when the tool exists,
# then bundle it. Skipped if rendering is unavailable, so the build never fails.
if [[ -f "$here/tools/make_icon.sh" ]]; then
	if ! zsh "$here/tools/make_icon.sh" >/dev/null 2>&1; then
		echo "warning: icon generation failed, continuing without a custom icon"
	fi
fi
if [[ -f "$here/tools/AppIcon.icns" ]]; then
	cp "$here/tools/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi
# The MLX Metal library (metallib) must be bundled so MLX can load its GPU
# kernels at runtime. MLX searches, in order, for mlx.metallib next to the
# executable and in Resources/. Copy it to both to be safe.
METALLIB=$(find "$scratch/out/Products" -name "default.metallib" -path "*mlx-swift_Cmlx*" 2>/dev/null | head -1)
if [[ -n "$METALLIB" && -f "$METALLIB" ]]; then
	cp "$METALLIB" "$app/Contents/MacOS/mlx.metallib"
	cp "$METALLIB" "$app/Contents/Resources/mlx.metallib"
	echo "bundled MLX metallib from $METALLIB"
else
	echo "warning: MLX metallib not found; the app may fail to load the GPU model"
fi
xattr -cr "$app"
if [[ "$identity" == "-" ]]; then
	echo "signing ad hoc (no certificate found)"
	codesign --force --deep --sign - "$app" 2>&1 | grep -v "replacing existing signature" || true
else
	# A real signature (Developer ID / Apple Development) uses the hardened
	# runtime plus the app's entitlements. See OkWhispr.entitlements.
	echo "signing with: $identity"
	codesign --force --deep --options runtime \
		--entitlements "$here/OkWhispr.entitlements" \
		--sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
fi
echo "installed $app (signed: $identity)"

# Optional notarization (NOTARIZE=1). Requires a Developer ID certificate and
# APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD from .env.signing.
if [[ "${NOTARIZE:-0}" == "1" ]]; then
	if [[ "$identity" == "-" ]]; then
		echo "error: NOTARIZE=1 requires a signing identity (set DEVELOPER_ID_APPLICATION in .env.signing)"
		exit 1
	fi
	: "${APPLE_ID:?NOTARIZE=1 requires APPLE_ID in .env.signing}"
	: "${APPLE_TEAM_ID:?NOTARIZE=1 requires APPLE_TEAM_ID in .env.signing}"
	: "${APPLE_APP_PASSWORD:?NOTARIZE=1 requires APPLE_APP_PASSWORD in .env.signing}"

	zip_path="$scratch/${name}-notarize.zip"
	echo "creating notarization zip..."
	ditto -c -k --keepParent "$app" "$zip_path"
	echo "submitting for notarization..."
	xcrun notarytool submit "$zip_path" \
		--apple-id "$APPLE_ID" \
		--team-id "$APPLE_TEAM_ID" \
		--password "$APPLE_APP_PASSWORD" \
		--wait
	echo "stapling notarization ticket..."
	xcrun stapler staple "$app"
	rm -f "$zip_path"
	echo "notarization complete"
fi

if [[ " $* " == *" --open "* ]]; then
	osascript -e 'tell application "System Events" to set frontApp to name of first process whose frontmost is true' >/dev/null 2>&1 || true
	pkill -x "$name" 2>/dev/null || true
	sleep 0.5
	open "$app"
	# return focus to whatever was frontmost before we launched, so the menu bar
	# item does not steal the user's window
fi
