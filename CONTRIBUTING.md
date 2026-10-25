# Contributing

TideTicker is a Swift Package Manager project for macOS 13 and later. Contributions should preserve the user-facing quote and alert semantics documented by the project rather than redefining them inside implementation code.

For installation and product usage, see the [user guide](./docs/USER_GUIDE.md).

## Before you start

- Read [CONTEXT.md](./CONTEXT.md) before changing contract identity, quote fields, timestamps, or product copy.
- Read [DESIGN.md](./DESIGN.md) before changing scheduling, source switching, preferences, alerts, or release updates.
- Read the relevant records in [docs/adr](./docs/adr) before changing transport, proxy, DNS, physical-interface, or main-quote behavior.
- Read [AGENTS.md](./AGENTS.md) when using a coding agent in this repository.

## Build and test

The project requires an Xcode or Command Line Tools installation with Swift 6 support.

```sh
swift test
bash scripts/build-app.sh
open dist/TideTicker.app
```

`build-app.sh` creates an ad-hoc signed application for the current machine architecture at `dist/TideTicker.app`. It does not install, launch, notarize, or upload the application. To build both Apple Silicon and Intel slices locally, run:

```sh
bash scripts/build-app.sh --universal
```

Run `swift test` for Swift behavior changes. Cross-module, product-name, resource, or packaging changes must also pass `bash scripts/build-app.sh`. Release work must follow [docs/RELEASE_CHECKLIST.md](./docs/RELEASE_CHECKLIST.md).

## Live quote probe

The command-line probe checks the public exchange endpoints without launching the application:

```sh
swift run TideTickerProbe --rounds 3
swift run TideTickerProbe --rounds 1 --all-markets
```

These commands use the external network. Record current failures as current observations; do not treat an earlier successful probe as evidence that an endpoint is still reachable.

## UI acceptance

Use an isolated preferences file for UI checks so development data does not replace the regular watchlist or alerts:

```sh
dist/TideTicker.app/Contents/MacOS/TideTicker \
  --preferences-file /tmp/tideticker-ui.json \
  --show-settings \
  --ui-snapshot /tmp/tideticker-ui-snapshot.json \
  --disable-update-checks
```

Use a unique `/tmp` name for each run. `--preferences-file` also isolates the adjacent source-profile file and skips login-item registration. The coin-icon preference still uses the real `UserDefaults`, and notification authorization remains system-wide.

To exercise the update prompt without querying GitHub, replace `--disable-update-checks` with an injected newer version:

```sh
--update-fixture-version 9.9.9
```

Restore normal application preferences after any acceptance check that intentionally used the regular configuration.

## Repository layout

```text
Sources/MarkBarCore/       Domain models, providers, transport, quote sessions, and alerts
Sources/MarkBarApp/        Menu bar, main window, notifications, updates, and lifecycle
Sources/MarkBarProbe/      Public-market command-line probe
Tests/MarkBarCoreTests/    Behavior, parsing, migration, and concurrency regression tests
Resources/                 Info.plist, product logo, and author asset
scripts/                   Local app, icon, and release-package build scripts
docs/adr/                  Current architecture decisions
```

Build products, personal preferences, raw validation evidence, research output, temporary screenshots, and release archives must stay out of commits. Product screenshots intentionally used by public documentation belong in `docs/images/`.

## Implementation expectations

Keep changes focused and add tests for behavior that can regress across providers, timestamps, lifecycle transitions, or persisted preferences. Use `Decimal` for prices and thresholds. Preserve complete `Contract.id` values, including numeric unit prefixes. The canonical definitions and concurrency rules live in [CONTEXT.md](./CONTEXT.md), [DESIGN.md](./DESIGN.md), and [AGENTS.md](./AGENTS.md); link to them instead of copying those rules into new documentation.

## Pull requests

Describe the user-visible behavior, affected quote or alert semantics, and checks run. Do not attach unredacted logs or screenshots. Public test fixtures must not contain real local paths, live proxy configuration, personal alert thresholds, routable personal IP addresses, or account data. Clearly synthetic values and IANA-reserved addresses are allowed when a security or redaction test requires them.

Contributions are licensed under the repository's [MIT License](./LICENSE).
