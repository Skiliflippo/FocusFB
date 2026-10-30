# FocusFB

An open-source iOS tweak for Facebook focused on removing distractions, cleaning up the feed, saving media, and keeping Marketplace fast and usable without endless scrolling traps.

Works on non-jailbroken devices (SideStore, Feather, AltStore, LiveContainer) and jailbroken setups (`.deb`). Zero dependency on CydiaSubstrate or ElleKit.

## Features

- **Custom Tabs & Smooth Full-Screen Marketplace**: Hide Home, Reels, Friends, Groups, or Notifications. Defaults to Marketplace-only and removes the bottom bar completely when a single tab is kept, with native 120Hz scrolling.
- **Ad Blocker & Feed De-cluttering**: Blocks sponsored and boosted listings in Marketplace (Home, search, categories, PDP, and blended GraphQL feeds) and removes sponsored ads, "People You May Know" boxes, the Reels carousel, suggested posts, and optionally the top Stories bar from the Feed.
- **Native Reels Downloader**: Adds a matching Facebook-style outline download icon right above the Like button in Reels to save HD videos (including split-audio DASH and HLS `.m3u8` streams) directly to the iOS Camera Roll.
- **Stories Incognito Mode**: View Stories anonymously without sending seen receipts.
- **Physical Key Lock for Feed & Reels (Foqos-style)**:
  - Pair any physical QR code, product barcode, or NFC tag.
  - Applies strictly to Feed, Reels, Stories, and social tabs — **Marketplace always remains unlocked**.
  - Includes up to 3 emergency unlocks per month when you are away from your physical key.
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
  2. Go to **Actions -> Build FocusFB -> Run workflow**.
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
