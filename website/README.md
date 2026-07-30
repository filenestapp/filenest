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
- `download.html` is the public download page for the current signed and notarized macOS release.
- `downloads/FileNest-0.2.0-macOS.dmg` is the current public macOS release artifact.
- `styles.css` contains the responsive visual system and motion behavior.
- `script.js` manages localization, the mobile menu, platform tabs, the hero interaction, and five replayable product demos.
- `media/filenest-homepage-loop.mp4` is the silent, 32-second product film embedded on the homepage; `media/filenest-homepage-poster.jpg` is its poster image.
- `locales/` contains user-facing translations.
- `assets/` contains product artwork, the social-sharing card, and screenshots captured from the current FileNest build using its privacy-safe showcase mode.
- `robots.txt` and `sitemap.xml` use `https://filenestapp.com` as the canonical public origin.

The interactive demos use a fictional Northstar Studio workspace. They cover local indexing, direct search, Smart Search, chat-based file discovery, and grounded chat with a selected file. Autoplay pauses when the demo leaves the viewport, and reduced-motion preferences disable the sequence animations.

The homepage and download page link directly to the current macOS DMG. Update both the release asset and checksum together for each future release.
