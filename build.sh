#!/bin/zsh
# Builds SimpleWhispr and installs it to ~/Applications/SimpleWhispr.app.
# Build products live in ~/Library/Developer/SimpleWhispr, outside the repo.
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
set -euo pipefail
here=${0:A:h}
name="SimpleWhispr"
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

# Sign with your Apple Development certificate when you have one (Xcode >
# Settings > Accounts). Otherwise sign ad hoc, which is fine for your own Mac.
# NOTE: permissions (Accessibility, Microphone) are tied to the signature and
# path, so install to the same path and use the same signature every time.
identity="${SIGN_IDENTITY:-}"
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
# swift build can report success while an edited file failed to compile. Catch that.
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" 2>/dev/null | head -1)
if [[ -n "$stale" ]]; then
	echo "build failed: binary is older than $stale"
	swift build -c "$config" --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error:" | head -20
	exit 1
fi

app="$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" >"$app/Contents/Info.plist"
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
codesign --force --deep --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
echo "installed $app (signed: ${identity})"

if [[ " $* " == *" --open "* ]]; then
	osascript -e 'tell application "System Events" to set frontApp to name of first process whose frontmost is true' >/dev/null 2>&1 || true
	pkill -x "$name" 2>/dev/null || true
	sleep 0.5
	open "$app"
	# return focus to whatever was frontmost before we launched, so the menu bar
	# item does not steal the user's window
fi
