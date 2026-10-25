# Changelog

This project follows semantic versioning from its first public source release.
Dates use the Asia/Shanghai calendar date.

## Unreleased

## 0.3.0 - 2026-10-26

- Add an opt-in, read-only Kindle dashboard served by the Mac on a trusted local network.
- Preserve full spot/perpetual identity, quote freshness, continuity, supplementary data, and pending-alert state on the e-ink display.
- Add configurable e-ink update pacing, ETag-based no-change responses, and a tokenized local address.
- Add an optional jailbroken-Kindle kiosk companion with a local full-screen shell and explicit reboot-to-exit behavior.
- Rebalance Kindle typography, normalize legacy WebKit viewport scaling, show quote timestamps in Beijing time, and keep status, paging, and refresh controls on one compact header row.
- Add repeatable local Paperwhite viewport and device-pixel-ratio simulations with screenshot, overflow, overlap, and legacy-browser checks.
- Group device-specific settings under External Displays and keep failed listeners from exposing unusable addresses.
- Keep the menu compact at a 20-instrument watchlist by showing two pinned quotes at the root and moving the rest and supplemental details into submenus.
- Merge quote viewing and watchlist management into one Watch Market navigation item with Overview and Manage modes.
- Use a compact responsive two-to-four-column grid for live quote cards.

## 0.2.0 - 2026-10-25

- Add automatic and manual GitHub Release checks, a persistent update menu entry, and a non-activating update prompt.
- Add a standard About panel that shows the installed version and build number.

## 0.1.0 - 2026-10-25

- First public source release under the MIT License.
- Use OKX WebSocket quotes in system-network mode with REST fallback.
- Add persistent alert acknowledgement and explicit continuity status.
- Add optional spot and perpetual supplementary market data.
- Increase the watchlist limit to 20 instruments.

Versions used during private development are not public releases. Their raw
validation logs and locally signed packages are intentionally not part of the
public history.

