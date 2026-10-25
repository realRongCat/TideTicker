# Release checklist

## Public source release

- [ ] Version and build number are consistent in `Resources/Info.plist`, README, changelog, and artifact names.
- [ ] The Git tag is a stable semantic version matching `CFBundleShortVersionString`, and the GitHub Release is neither draft nor pre-release.
- [ ] Manual update checking reports the current version; an injected newer fixture shows the floating prompt and persistent menu entry.
- [ ] `swift test` passes from a clean checkout.
- [ ] `bash -n scripts/*.sh` and `plutil -lint Resources/Info.plist` pass.
- [ ] `bash scripts/build-app.sh` succeeds and `codesign --verify --deep --strict` passes.
- [ ] Public Git files contain no build products, preferences, raw evidence, research output, local paths, proxy settings, alert thresholds, credentials, or opaque private archives.
- [ ] Markdown links resolve locally and public documentation describes current behavior.
- [ ] Third-party license and asset notices are present.
- [ ] Kindle display is disabled by default in a clean app UserDefaults domain, and enabling it triggers the macOS local-network permission path.
- [ ] Kindle page, snapshot, health, wrong-token, unsupported-method, `HEAD`, ETag `304`, and LAN-address responses match the documented read-only contract.
- [ ] `npm run kindle:verify` passes the 600 CSS-pixel/DPR-scaled model, the 1072 CSS-pixel/DPR-1 legacy WebKit model, and ignored-iframe-height simulation; one/two/three-card and pending-alert fixtures have zero Companion scroll overflow, a bottom safety margin, equal heights, centered content, unclipped text, and no overlap.
- [x] On Kindle Paperwhite 3 firmware `5.16.2.1.1`, the Companion page stays one card per row, matches the local typography model, fills one screen with three cards and no vertical scrollbar, and hides the browser chrome (verified 2026-10-26).
- [ ] A supported physical Kindle opens the tokenized address and survives a two-hour page reload; record firmware/model and verify that reboot exits the optional always-on Companion kiosk.

## Public ad-hoc test package

Use this section when a GitHub Release includes a downloadable DMG before
Developer ID signing and notarization are available:

- [ ] Build the Universal app and archives from the exact tagged release commit with `bash scripts/build-dmg.sh`.
- [ ] Verify both `arm64` and `x86_64` slices, the ad-hoc code signature, DMG image, extracted ZIP, executable permissions, and SHA-256 files.
- [ ] Install the DMG outside the source tree and exercise launch, quote loading, update checking, and the main settings flow.
- [ ] Name the DMG `TideTicker-<version>-universal.dmg` and upload it together with its `.sha256` file.
- [ ] State prominently in the README and Release notes that the package is ad-hoc signed, not notarized, and may require “Open Anyway”.
- [ ] Do not describe the package as an official signed or notarized macOS build.

## Official binary release

Do not publish a binary as an official TideTicker release until all items below pass for the exact release commit and artifact:

- [ ] Build the Universal app from a clean checkout.
- [ ] Sign with Developer ID Application and hardened runtime.
- [ ] Submit the app or containing archive to Apple notarization and receive acceptance.
- [ ] Staple the notarization ticket to the app and DMG.
- [ ] Verify both `arm64` and `x86_64` slices.
- [ ] Verify `codesign`, `spctl`, DMG mounting, ZIP extraction, executable permissions, and SHA-256 checksums.
- [ ] Install outside the source tree and confirm actual system notification delivery.
- [ ] Complete real sleep/wake, restart, and login-item launch checks.
- [ ] Complete an 8-hour resident run with memory, CPU, reconnect, and alert observations.
- [ ] Exercise OKX, Binance, and Bybit under system-network mode; exercise OKX physical-direct mode. Record access-policy failures without bypassing them.
- [ ] During the 8-hour run, keep a Kindle client connected and verify normal throttled updates, key-state immediate updates, ETag no-change polling, Mac sleep/wake recovery, Wi-Fi interruption recovery, and full-screen ghosting refreshes.
- [ ] Confirm the installed app contains no development paths, private preferences, raw logs, or test fixtures.

GitHub Release assets belong in the release page, not in the source tree.

