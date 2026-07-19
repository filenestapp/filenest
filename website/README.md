# FileNest Website

The official FileNest product website is a dependency-free static site with English as the default language and optional Simplified Chinese localization.

## Preview

Run a local server from this directory:

```bash
python3 -m http.server 4173
```

Then open `http://localhost:4173`.

## Structure

- `index.html` contains the semantic page structure and English fallback copy.
- `styles.css` contains the responsive visual system and motion behavior.
- `script.js` manages localization, the mobile menu, platform tabs, the hero interaction, and five replayable product demos.
- `locales/` contains user-facing translations.
- `assets/` contains product artwork and screenshots captured from the current FileNest build using its privacy-safe showcase mode.

The interactive demos use a fictional Northstar Studio workspace. They cover local indexing, direct search, Smart Search, chat-based file discovery, and grounded chat with a selected file. Autoplay pauses when the demo leaves the viewport, and reduced-motion preferences disable the sequence animations.

The release call to action intentionally avoids a download link until production artifacts and hosting are configured.
