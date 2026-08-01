# FileNest Website

The official FileNest product website for `filenestapp.com` is a dependency-free static site with English as the default language and optional Simplified Chinese localization.

## Preview

Run a local server from this directory:

```bash
python3 -m http.server 4173
```

Then open `http://localhost:4173`.

## Structure

- `index.html` contains the main marketing site, semantic page structure, and English fallback copy.
- `download.html` links to the signed macOS and Windows packages published with the current GitHub Release.
- `styles.css` contains the responsive visual system and motion behavior.
- `script.js` manages localization, the mobile menu, platform tabs, the hero interaction, and five replayable product demos.
- `media/filenest-homepage-loop.mp4` is the silent, 32-second product film embedded on the homepage; `media/filenest-homepage-poster.jpg` is its poster image.
- `locales/` contains user-facing translations.
- `assets/` contains product artwork, the social-sharing card, and screenshots captured from the current FileNest build using its privacy-safe showcase mode.
- `robots.txt` and `sitemap.xml` use `https://filenestapp.com` as the canonical public origin.

The interactive demos use a fictional Northstar Studio workspace. They cover local indexing, direct search, Smart Search, chat-based file discovery, and grounded chat with a selected file. Autoplay pauses when the demo leaves the viewport, and reduced-motion preferences disable the sequence animations.

The homepage presents the public GitHub repository, MIT license, contribution guide, issue tracker, and release assets. Installer packages are hosted in GitHub Releases and are not committed to the source repository. The homepage and download page ask the GitHub Releases API for the latest stable release at runtime, with a versioned fallback for offline or rate-limited requests. They identify macOS or Windows locally in the browser and link the primary download action to the matching installer; unsupported systems are directed to the complete download list.

## Publish a release

Use the repository script after updating both platform versions and committing the release changes:

```bash
scripts/publish-release.sh 0.2.7
```

It validates version parity and creates or checks the matching tag. A newly
pushed tag starts the release workflow automatically; an existing tag at `HEAD`
is dispatched manually. GitHub Actions then builds, signs, notarizes, uploads
the release assets, and publishes the Sparkle update metadata.
