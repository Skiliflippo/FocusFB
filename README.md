# FocusFB

An open-source iOS tweak for Facebook focused on removing distractions, blocking ads, and keeping Marketplace usable without the endless feed.

Works on non-jailbroken devices (SideStore, Feather, AltStore, LiveContainer) and jailbroken setups (`.deb`). Zero dependency on CydiaSubstrate.

## Features

- **Custom Tabs & Full-Screen Marketplace**: Hide Home, Reels, Stories, Friends, or Groups. Defaults to Marketplace-only and removes the bottom bar completely when a single tab is kept.
- **Ad Blocker**: Blocks sponsored listings in Marketplace (Home, search, categories) as well as ads and suggested posts in the Feed.
- **Physical Key Lock (Foqos-style)**:
  - Pair any physical QR code, product barcode, or NFC tag.
  - **Dual scope**: keep *Marketplace always open* while limiting the rest of Facebook to a set session/daily timer, or lock the entire app.
  - **Emergency Unlock**: up to 3 emergency unlocks per month if you don't have your physical key with you.
- **Sideload Fixes Included**: Fixes Facebook keychain token refresh (`-34018`) to prevent repeated logouts on sideloaded builds.

## Opening FocusFB Settings

Inside Facebook:
- Hold **2 fingers** anywhere on the screen for 0.6 seconds, or
- Long-press any visible tab on the bottom navigation bar.

## Installation

Grab `FocusFB.dylib` or the `.deb` package from [**Releases**](../../releases).

- **LiveContainer**: Place `FocusFB.dylib` inside your Facebook app container's Tweaks folder and enable tweak injection.
- **Feather / ESign / Sideloadly**: Import your own decrypted Facebook `.ipa`, add `FocusFB.dylib` (or `.deb`) under Tweaks/Dylibs, sign, and install.
- **GitHub Actions (Fork)**:
  1. Fork this repository.
  2. Go to **Actions → Build FocusFB → Run workflow**.
  3. Optionally paste a direct link to your own decrypted `.ipa` in `ipa_url` to generate an injected `.ipa` in your private workflow artifacts.

> **Note on Passkeys when sideloaded**: iOS binds WebAuthn Passkeys to Meta's official Apple Team ID (`associated-domains`). On any sideloaded Facebook build, tap *"Try another way"* during login and confirm with a 2FA code (Authenticator app / SMS) or another logged-in device.

## Building Locally (macOS)

Requires Xcode Command Line Tools / iOS SDK and `ldid` (`brew install ldid`):

```bash
git clone https://github.com/Skiliflippo/FocusFB.git
cd FocusFB
make
```

The compiled binary will be generated at `dist/FocusFB.dylib`.

## Support

If FocusFB saves you time, you can support its development via [PayPal](https://paypal.me/Skiliflippo).

## Disclaimer & License

FocusFB is an independent open-source tweak released under the [MIT License](LICENSE). This project does **not** distribute any proprietary binaries owned by Meta Platforms, Inc., and is not affiliated with, endorsed by, or sponsored by Meta Platforms, Inc. Facebook and Marketplace are trademarks of Meta Platforms, Inc.
