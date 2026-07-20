# macOS to Windows parity

The detailed, source-backed parity specification is maintained in:

- [`../docs/02-feature-map.md`](../docs/02-feature-map.md)
- [`../docs/08-windows-parity.md`](../docs/08-windows-parity.md)
- [`../docs/09-verification.md`](../docs/09-verification.md)

The Windows source now implements the macOS capability map at the code and local-integration level. The current Windows gates pass 37 Vitest cases, strict TypeScript checking, and the Electron production build. The complete evidence record, including the current macOS XCTest count, is maintained in [`../docs/09-verification.md`](../docs/09-verification.md).

Release packaging produces one `FileNest-Setup-<version>.exe` Universal NSIS installer containing x64 and ARM64 payloads, plus architecture-specific x64 and ARM64 Portable executables. Tagged releases are rebuilt on a native Windows GitHub Actions runner and published as prereleases until signing and Windows-native acceptance gates are complete.

This is not yet a release claim of 100% parity. Windows-native acceptance remains required for installers, Explorer, Recycle Bin, startup, tray behavior, NTFS/cross-volume operations, packaged DPAPI, managed local services, x64/ARM64, signing, and production updates.
