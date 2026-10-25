# TideTicker Kindle Companion

TideTicker Kindle Companion is an optional full-screen launcher for jailbroken Kindle devices. It opens the read-only LAN display already served by the macOS app; market data, alert state, contract identity, and refresh policy remain owned by TideTicker on the Mac.

The first acceptance target is Kindle Paperwhite 3 (7th generation, Wi-Fi) on firmware `5.16.2.1.1`. Full-screen launch, live Wi-Fi data without USB, a three-card page without vertical scrolling, and reboot recovery to the Kindle library have been exercised on that device. The two-hour reload and eight-hour resident check remain release gates in [`docs/RELEASE_CHECKLIST.md`](../docs/RELEASE_CHECKLIST.md); other models and firmware versions are not claimed as supported.

## Local display simulation

Install the development-only browser driver once, then run the automated Kindle layout check before copying files to a device:

```sh
npm install
npm run kindle:verify
```

The check renders one-card, two-card, three-card, and pending-alert fixtures. Each fixture runs through the viewport behaviors seen on Kindle: a 600 CSS-pixel layout with a Paperwhite-density scale, a legacy WebKit shell that exposes the 1072-pixel physical width with `devicePixelRatio` near 1, and a shell that ignores the requested iframe height and reports 1448 CSS pixels. The Companion must normalize these behaviors to the same 600 x 800 CSS-pixel dashboard. The check rejects horizontal or vertical overflow, unequal cards, off-center card content, text outside its card, element overlap, repeated transport/timezone labels, and a Companion-only fullscreen button. Paperwhite-sized screenshots are written to the ignored `outputs/kindle-preview/` directory.

For interactive review, use:

```sh
npm run kindle:preview
npm run kindle:preview -- --cards=2 --alert
npm run kindle:preview -- --model=css
```

The preview requires Google Chrome or Chromium; set `CHROME_PATH` when it is not installed in a standard location. It reproduces viewport scaling and layout constraints, but it cannot reproduce the device's exact Mesquite font rasterizer or e-ink refresh behavior. A final physical-device visual check is still required after the local check passes.

## Install from macOS

1. Enable **Kindle Display** in TideTicker and keep the Mac and Kindle on the same trusted Wi-Fi.
2. Connect the jailbroken Kindle by USB and wait for `/Volumes/Kindle` to mount.
3. Run `bash scripts/deploy-kindle-companion.sh` from the repository root.
4. Safely eject the Kindle and open **TideTicker** from the Kindle library.

The deployment script reads the pairing token from the installed TideTicker preferences, verifies the local service, and writes the private URL directly to the Kindle. It also embeds a dashboard revision so Mesquite does not reuse stale HTML after a redeploy. It does not create a token-bearing file in the repository or print the URL.

## Device controls

- **TideTicker** registers and opens the WAF, hides Kindle chrome, enables Wi-Fi, and prevents automatic sleep. Companion mode is an always-on kiosk: the normal short power-button sleep action is intentionally unavailable while it is running.
- **TideTicker Exit** is a recovery helper for cases where the Kindle library is already reachable; it stops the WAF and restores normal sleep. It is not an in-kiosk exit control.
- **TideTicker Uninstall** removes the WAF registration and restores normal sleep. The files remain on the USB-visible partition so they can be inspected or installed again.

To leave kiosk mode when the Kindle UI is not reachable, hold the physical power button until the device restarts. TideTicker does not launch automatically after a reboot. A wall charger can power the display continuously; a USB data connection to the Mac is only needed for installation or recovery and may put the Kindle into USB drive mode.

The launcher backs up `/var/local/appreg.db` before its first registry change. If the display cannot open, run **TideTicker Exit** before troubleshooting. The companion requires the Mac app to remain running and reachable on the same LAN.
