# Contributing

TideTicker is a Swift Package Manager project for macOS 13 and later. Read
`CONTEXT.md` before changing contract identity, quote fields, or product copy;
read `DESIGN.md` before changing scheduling, source switching, preferences, or
alerts. Network changes must also follow the ADRs in `docs/adr/`.

## Development

```sh
swift test
bash scripts/build-app.sh
```

The build script creates an ad-hoc signed local application at
`dist/TideTicker.app`. Build output, diagnostics, personal preferences, raw UI
snapshots, research material, and release archives must stay out of commits.

Keep changes focused and add tests for behavior that can regress across quote
sources, timestamps, lifecycle transitions, or persisted preferences. Use
`Decimal` for prices and thresholds. Preserve complete `Contract.id` values,
including numeric unit prefixes.

## Pull requests

Describe the user-visible behavior, the quote or alert semantics affected, and
the checks run. Do not attach unredacted logs or screenshots. Public test
fixtures must not contain real local paths, live proxy configuration, personal
alert thresholds, routable personal IP addresses, or account data. Clearly
synthetic values and IANA-reserved addresses are allowed when a security or
redaction test needs them.

Contributions are licensed under the repository's MIT License.

