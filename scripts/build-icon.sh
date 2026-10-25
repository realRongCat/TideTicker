#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_source="$task_root/Resources/tide-logo-black-white-20261015.png"
task_output="${1:-$task_root/dist/AppIcon.icns}"

if [ "$#" -gt 1 ] || [[ "$task_output" != *.icns ]]; then
  printf 'Usage: bash %s [output.icns]\n' "$0" >&2
  exit 64
fi
if [ ! -f "$task_source" ]; then
  printf 'Logo source not found: %s\n' "$task_source" >&2
  exit 1
fi

task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tideticker-icon.XXXXXX")"
trap 'rm -rf "$task_tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
task_iconset="$task_tmp/AppIcon.iconset"
mkdir -p "$task_iconset"

# Each rendition is resampled directly from the original PNG. Neither the
# source artwork nor its composition is changed, and no generated PNG persists.
for task_points in 16 32 128 256 512; do
  for task_scale in 1 2; do
    task_pixels=$((task_points * task_scale))
    task_suffix=""
    if [ "$task_scale" -eq 2 ]; then task_suffix="@2x"; fi
    /usr/bin/sips --resampleHeightWidth "$task_pixels" "$task_pixels" \
      "$task_source" --out "$task_iconset/icon_${task_points}x${task_points}${task_suffix}.png" >/dev/null
  done
done

/usr/bin/iconutil --convert icns --output "$task_tmp/AppIcon.icns" "$task_iconset"
mkdir -p "$(dirname "$task_output")"
cp "$task_tmp/AppIcon.icns" "$task_output"
printf '%s\n' "$task_output"
