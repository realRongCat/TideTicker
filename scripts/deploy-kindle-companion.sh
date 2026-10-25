#!/bin/sh
set -eu

task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
volume="${KINDLE_VOLUME:-/Volumes/Kindle}"
bundle_id="com.xlogic.OKXMarkBar"
port="8765"

fail() {
    printf '%s\n' "Kindle Companion deployment failed: $1" >&2
    exit 1
}

[ -d "$volume/documents" ] || fail "Kindle USB volume is not mounted at $volume"

token=$(/usr/bin/defaults read "$bundle_id" tide.kindle.token 2>/dev/null) || fail "TideTicker has no Kindle pairing token"
case "$token" in
    *[!0-9a-f]*|'') fail "TideTicker pairing token is invalid" ;;
esac
[ "${#token}" -eq 64 ] || fail "TideTicker pairing token has an unexpected length"

if [ "${TIDETICKER_HOST:-}" != "" ]; then
    host="$TIDETICKER_HOST"
else
    host=""
    for interface in en0 en1; do
        candidate=$(/usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null || true)
        if [ "$candidate" != "" ] && [ "${candidate#169.254.}" = "$candidate" ]; then
            host="$candidate"
            break
        fi
    done
    [ "$host" != "" ] || fail "could not determine the Mac LAN address"
fi

case "$host" in
    *[!0-9.]*|'') fail "the Mac LAN address is not IPv4" ;;
esac

base_url="http://$host:$port/k/$token/"
/usr/bin/curl --disable --noproxy '*' --fail --silent --show-error --max-time 3 "${base_url}health" >/dev/null || \
    fail "the TideTicker Kindle service is not reachable; enable it before deployment"

destination="$volume/tideticker-companion"
/bin/mkdir -p "$destination/waf" "$destination/state"
/usr/bin/ditto "$task_root/KindleCompanion/waf" "$destination/waf"
/usr/bin/install -m 644 "$task_root/Sources/MarkBarApp/Resources/Kindle/index.html" "$destination/waf/dashboard.html"
/usr/bin/printf "var TIDE_TICKER_URL = '%s';\n" "$base_url" > "$destination/waf/settings.js"
/usr/bin/install -m 755 "$task_root/KindleCompanion/scriptlets/TideTicker.sh" "$volume/documents/TideTicker.sh"
/usr/bin/install -m 755 "$task_root/KindleCompanion/scriptlets/TideTicker-Exit.sh" "$volume/documents/TideTicker-Exit.sh"
/usr/bin/install -m 755 "$task_root/KindleCompanion/scriptlets/TideTicker-Uninstall.sh" "$volume/documents/TideTicker-Uninstall.sh"
/usr/sbin/dot_clean -m "$destination" "$volume/documents"

printf '%s\n' "TideTicker Kindle Companion installed. Safely eject the Kindle, then open TideTicker from its library."
