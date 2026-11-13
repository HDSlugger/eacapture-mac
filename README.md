# EACapture for Mac

An unofficial native macOS app (SwiftUI, macOS 13+, Apple silicon and Intel) that wraps
[Silicondust's EACapture script](https://download.silicondust.com/EACapture/eacapture.php.txt)
for the national EAS test evaluation with an ATSC 3.0 HDHomeRun tuner. It is not made or
endorsed by Silicondust.

The app adds a window and menu-bar status, settings, optional preservation of recordings,
keep-awake, an uninstaller, and an end-of-test reminder. The capture, check-in and upload
logic is Silicondust's, unmodified.

## What's here

| Path | What it is |
|---|---|
| `Sources/main.swift` | The whole app |
| `fetch-script.sh` | Downloads Silicondust's script, verifies its SHA-256, applies the patch |
| `patches/local-changes.patch` | My only changes to their script |
| `vendor/scripts/build-php.sh` | Builds the bundled static PHP from official source |
| `build.sh` / `package.sh` | Build the app / sign, notarize and make the DMG |
| `Icons/` | App icon sources |

## Changes to Silicondust's script (see `patches/local-changes.patch`)

1. `RETRY_SECONDS` 600 -> 60, and the two matching log messages.
2. A new optional `--preserve-dir=DIR` flag that copies each finished recording into DIR
   before upload. Nothing else is touched, including the capture logic.

Verify with: `diff <(curl -s https://download.silicondust.com/EACapture/eacapture.php.txt) src/eacapture.php`

## Bundled PHP

Built from official source by `vendor/scripts/build-php.sh` (curl and sockets only):

| Source | Version | SHA-256 |
|---|---|---|
| PHP | 8.4.27 | `dcf93923b0e38e0d5252b25b796520b5a47761a08b3488b6d0b5d1115764d3f0` |
| OpenSSL | 3.5.9 | `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a` |
| curl | 8.23.0 | `8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5` |

## Building

Needs full Xcode. Put the three source tarballs in `vendor/src/{php-dl,openssl-dl,curl-dl}`
(see the script), then:

```
./fetch-script.sh
vendor/scripts/build-php.sh arm64 && vendor/scripts/build-php.sh x86_64
./build.sh
```

`package.sh` is my release script: it uses my Developer ID and notarytool profile. Change
`IDENTITY` and `PROFILE` to use your own. It is not needed for a local build.

## What the app does on your machine

- Network: discovers tuners on your LAN (UDP 65001), talks to `eastest.silicondust.com`.
- Files: `~/eacapture` (state, captures, optional `Preserved/`). Recordings are deleted after upload.
- Optional login item and sleep prevention, both user-controlled.
