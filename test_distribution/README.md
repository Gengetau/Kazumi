# Kazumi SyncPlay temporary test distribution

This directory describes the temporary packaging layer for
`test/syncplay-chat-room-build`. It is deliberately kept separate from the
`feat/syncplay-chat-room` feature branch, and it must not be merged back into
that branch.

The test layer provides:

- procedural, attribution-safe branding for the Android and Windows test
  packages;
- an isolated Android application ID and Windows executable/mutex identity;
- compile-time source and build identifiers shown in the About page and logs;
- a GitHub Actions workflow that publishes short-lived artifacts only (no
  GitHub Release is created).

## Recreate the branding

From the repository root, run:

```bash
python3 tool/generate_syncplay_test_branding.py
dart run flutter_launcher_icons -f test_distribution/flutter_launcher_icons.yaml
python3 tool/verify_syncplay_test_assets.py
```

The generator uses only geometric drawing instructions and Pillow at
development time. Pillow is not an application or runtime dependency. The
SVG source and generated PNG/ICO files are committed so the test branch can be
built without inventing a different visual identity.

The original logo and the previous static avatar are intentionally absent from
the packaged `assets/images` tree. Network-fetched Bangumi covers are runtime
content and are outside this static bundle audit.

## Build identity

The workflow passes these Dart defines to both desktop and mobile builds:

```text
SYNCPLAY_TEST_BUILD=true
SYNCPLAY_FEATURE_SHA=<feature branch HEAD>
SYNCPLAY_TEST_SHA=<test branch HEAD>
SYNCPLAY_BUILD_ID=<GitHub run number>
```

The About page identifies the package as an unofficial SyncPlay test build and
shows all three traceability values. The same values are included in
`SOURCE_INFO.txt` beside each artifact.

## Android coexistence and signing

The test package ID is
`io.github.gengetau.kazumi.syncplaytest`, so its application data directory is
separate from the official `com.predidit.kazumi` application. Release builds
use stable test signing when all four `SYNCPLAY_TEST_*` keystore secrets are
present. Without them, the workflow emits a visible warning and uses
short-lived debug signing; installing a later stable-signed build then requires
uninstalling the debug-signed test app.

The workflow never stores a keystore, password, or private key in Git.

## Windows coexistence

The portable package contains `kazumi_syncplay_test.exe`. Its native window
title and single-instance mutex are distinct from the official application, so
both applications can run at the same time.

## Feedback

Copy `BUG_REPORT_TEMPLATE.md` from the artifact and include the exact package
filename, Feature SHA, Test SHA, Build ID, and logs when reporting a SyncPlay
test result.
