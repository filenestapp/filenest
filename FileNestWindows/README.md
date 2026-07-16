# FileNest for Windows

Windows 11 desktop implementation of FileNest. It keeps the macOS product model and data flow while using Windows-native integration for Explorer, Recycle Bin, startup, system tray, installers and secure credential storage.

## Run locally

Requirements: Node.js 20.19+ or 22.12+ (an active LTS release is recommended).

```powershell
npm ci
npm run dev
```

## Verify and package

```powershell
npm run typecheck
npm test
npm run build
npm run package:win
```

`package:win` creates NSIS installers and portable executables for x64 and ARM64 under `release/`. Production distribution should sign the executables with an Authenticode certificate. Configure the HTTPS update directory in FileNest settings after publishing `latest.yml` and the signed installer.

## Local data

- App database: `%APPDATA%\FileNest\filenest-windows.sqlite`
- Logs: `%APPDATA%\FileNest\logs`
- Managed Docling environment: `%APPDATA%\FileNest\services\docling`
- Default organized files: `%USERPROFILE%\Documents\FileNest Organized`
- API keys are encrypted with Windows DPAPI through Electron `safeStorage` before being persisted.

The approved Windows UI reference is in [`design/windows-approved-ui.png`](design/windows-approved-ui.png). The implementation combines the full navigation sidebar with the right-side file inspector.

See [`PARITY.md`](PARITY.md) for the macOS-to-Windows capability mapping.
