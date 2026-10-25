# Release checklist

## Public source release

- [ ] Version and build number are consistent in `Resources/Info.plist`, README, changelog, and artifact names.
- [ ] `swift test` passes from a clean checkout.
- [ ] `bash -n scripts/*.sh` and `plutil -lint Resources/Info.plist` pass.
- [ ] `bash scripts/build-app.sh` succeeds and `codesign --verify --deep --strict` passes.
- [ ] Public Git files contain no build products, preferences, raw evidence, research output, local paths, proxy settings, alert thresholds, credentials, or opaque private archives.
- [ ] Markdown links resolve locally and public documentation describes current behavior.
- [ ] Third-party license and asset notices are present.

## Public binary release

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
- [ ] Confirm the installed app contains no development paths, private preferences, raw logs, or test fixtures.

GitHub Release assets belong in the release page, not in the source tree.

