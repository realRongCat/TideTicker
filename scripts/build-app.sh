#!/bin/bash
set -euo pipefail
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--universal" ] && [ "$1" != "--help" ]; }; then
  printf 'Usage: bash %s [--universal]\n' "$0" >&2
  exit 64
fi
if [ "${1:-}" = "--help" ]; then
  printf 'Usage: bash %s [--universal]\n' "$0"
  exit 0
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
mkdir -p "$task_root/dist"
task_tmp="$(mktemp -d "$task_root/dist/.tideticker-build.XXXXXX")"
task_output="$task_root/dist/TideTicker.app"
cleanup() {
  # A signal between the two publication moves must not discard the old app.
  if [ -e "$task_tmp/previous.app" ] && [ ! -e "$task_output" ]; then
    if ! mv "$task_tmp/previous.app" "$task_output"; then
      printf 'Previous app retained for recovery: %s\n' "$task_tmp/previous.app" >&2
      return 1
    fi
  fi
  rm -rf "$task_tmp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
task_app="$task_tmp/TideTicker.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
if [ "${1:-}" = "--universal" ]; then
  task_min_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$task_root/Resources/Info.plist")"
  task_binaries=()
  for task_arch in arm64 x86_64; do
    task_triple="${task_arch}-apple-macosx${task_min_os}"
    task_scratch="$task_root/.build/distribution-$task_arch"
    xcrun swift build -c release --product TideTicker --triple "$task_triple" --scratch-path "$task_scratch"
    task_bin="$(xcrun swift build -c release --show-bin-path --triple "$task_triple" --scratch-path "$task_scratch")"
    task_binaries+=("$task_bin/TideTicker")
  done
  xcrun lipo -create "${task_binaries[@]}" -output "$task_app/Contents/MacOS/TideTicker"
  # Some Xcode lipo versions misparse multiple architectures in -verify_arch.
  for task_arch in arm64 x86_64; do
    xcrun lipo "$task_app/Contents/MacOS/TideTicker" -verify_arch "$task_arch"
  done
else
  xcrun swift build -c release --product TideTicker
  task_bin="$(xcrun swift build -c release --show-bin-path)"
  cp "$task_bin/TideTicker" "$task_app/Contents/MacOS/TideTicker"
fi
# SwiftPM may add a build-machine toolchain search path. Distribution uses
# macOS system Swift libraries, so remove that redundant development path.
while IFS= read -r task_rpath; do
  case "$task_rpath" in
    *.xctoolchain/*|*/CommandLineTools/*)
      xcrun install_name_tool -delete_rpath "$task_rpath" "$task_app/Contents/MacOS/TideTicker"
      ;;
  esac
done < <(xcrun otool -l "$task_app/Contents/MacOS/TideTicker" | awk '
  $1 == "cmd" && $2 == "LC_RPATH" { wanted = 1; next }
  wanted && $1 == "path" { sub(/^.*path /, ""); sub(/ \(offset.*$/, ""); print; wanted = 0 }
' | sort -u)
if /usr/bin/strings "$task_app/Contents/MacOS/TideTicker" | /usr/bin/grep -F "$task_root" >/dev/null; then
  printf 'Build contains a development checkout path; remove source-path literals before packaging.\n' >&2
  exit 1
fi
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
bash "$task_root/scripts/build-icon.sh" "$task_app/Contents/Resources/AppIcon.icns" >/dev/null
cp "$task_root/Resources/rongcat-avatar.jpg" "$task_app/Contents/Resources/CreatorAvatar.jpg"
cp -R "$task_root/Sources/MarkBarApp/Resources/CoinIcons" "$task_app/Contents/Resources/CoinIcons"
cp -R "$task_root/Sources/MarkBarApp/Resources/ExchangeIcons" "$task_app/Contents/Resources/ExchangeIcons"
cp -R "$task_root/Sources/MarkBarApp/Resources/Kindle" "$task_app/Contents/Resources/Kindle"
codesign --force --sign - "$task_app"
codesign --verify --all-architectures --deep --strict "$task_app"
# Replacing nested files leaves the bundle directory's old mtime intact.
# Refresh it so installation copies do not preserve stale Spotlight metadata.
touch "$task_app"
if [ -e "$task_output" ]; then mv "$task_output" "$task_tmp/previous.app"; fi
if ! mv "$task_app" "$task_output"; then
  if [ -d "$task_tmp/previous.app" ]; then mv "$task_tmp/previous.app" "$task_output"; fi
  exit 1
fi
printf '%s\n' "$task_output"
