#!/bin/bash
set -euo pipefail

if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
    printf 'Usage: bash scripts/build-dmg.sh\nBuild a universal TideTicker app with verified DMG and ZIP archives in dist/.\n'
    exit 0
  fi
  printf 'Usage: bash scripts/build-dmg.sh\nNo build-skipping or custom input options are supported.\n' >&2
  exit 2
fi

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_app="$task_root/dist/TideTicker.app"
task_guide="$task_root/docs/install-guide.txt"
[[ -f "$task_guide" ]] || { printf 'Missing installation guide: %s\n' "$task_guide" >&2; exit 1; }

bash "$task_root/scripts/build-app.sh" --universal

task_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$task_app/Contents/Info.plist")"
if [[ ! "$task_version" =~ ^[0-9][A-Za-z0-9._-]*$ ]]; then
  printf 'Invalid version for a DMG filename: %s\n' "$task_version" >&2
  exit 1
fi
for task_arch in arm64 x86_64; do
  /usr/bin/lipo "$task_app/Contents/MacOS/TideTicker" -verify_arch "$task_arch"
done
/usr/bin/codesign --verify --deep --strict "$task_app"

task_dmg_name="TideTicker-${task_version}-universal.dmg"
task_checksum_name="${task_dmg_name}.sha256"
task_zip_name="TideTicker-${task_version}-universal.zip"
task_zip_checksum_name="${task_zip_name}.sha256"
task_artifacts=("$task_dmg_name" "$task_checksum_name" "$task_zip_name" "$task_zip_checksum_name")
task_work="$(mktemp -d "$task_root/dist/.dmg-build.XXXXXX")"
task_publishing=false
task_published=false
cleanup() {
  if [[ "$task_publishing" == true && "$task_published" != true ]]; then
    for task_name in "${task_artifacts[@]}"; do
      if [[ -f "$task_work/previous-$task_name" ]]; then
        if ! mv -f "$task_work/previous-$task_name" "$task_root/dist/$task_name"; then
          printf 'Previous distribution retained for recovery: %s\n' "$task_work" >&2
          return 1
        fi
      else
        rm -f "$task_root/dist/$task_name"
      fi
    done
  fi
  rm -rf "$task_work"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$task_work/volume"
/usr/bin/ditto --norsrc "$task_app" "$task_work/volume/TideTicker.app"
ln -s /Applications "$task_work/volume/Applications"
cp "$task_guide" "$task_work/volume/安装说明.txt"
# Validate the staged copy too; stripping resource forks must not break its seal.
/usr/bin/codesign --verify --deep --strict "$task_work/volume/TideTicker.app"
for task_arch in arm64 x86_64; do
  /usr/bin/lipo "$task_work/volume/TideTicker.app/Contents/MacOS/TideTicker" -verify_arch "$task_arch"
done

/usr/bin/hdiutil create \
  -srcfolder "$task_work/volume" \
  -volname 'TideTicker' \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov "$task_work/$task_dmg_name"
/usr/bin/hdiutil verify "$task_work/$task_dmg_name"
# ZIP is an alternative for systems where opening disk images is restricted.
# It contains the same signed app; it does not bypass macOS app security checks.
(
  cd "$task_work/volume"
  /usr/bin/zip -q -r -y "$task_work/$task_zip_name" TideTicker.app
)
/usr/bin/unzip -tq "$task_work/$task_zip_name"
mkdir "$task_work/zip-check"
/usr/bin/ditto -x -k "$task_work/$task_zip_name" "$task_work/zip-check"
/usr/bin/codesign --verify --all-architectures --deep --strict "$task_work/zip-check/TideTicker.app"
/usr/bin/diff -qr "$task_work/volume/TideTicker.app" "$task_work/zip-check/TideTicker.app"
test -x "$task_work/zip-check/TideTicker.app/Contents/MacOS/TideTicker"
(
  cd "$task_work"
  /usr/bin/shasum -a 256 "$task_dmg_name" > "$task_checksum_name"
  /usr/bin/shasum -a 256 "$task_zip_name" > "$task_zip_checksum_name"
)
for task_name in "${task_artifacts[@]}"; do chmod 644 "$task_work/$task_name"; done
# Leave any previous distribution intact until all build and integrity checks pass.
for task_name in "${task_artifacts[@]}"; do
  if [[ -f "$task_root/dist/$task_name" ]]; then
    cp -p "$task_root/dist/$task_name" "$task_work/previous-$task_name"
  fi
done
task_publishing=true
for task_name in "${task_artifacts[@]}"; do
  mv -f "$task_work/$task_name" "$task_root/dist/$task_name"
done
task_published=true
for task_name in "${task_artifacts[@]}"; do printf '%s\n' "$task_root/dist/$task_name"; done
