# Release Process

FileNest uses `.github/workflows/release.yml` to build macOS and Windows
packages on native GitHub-hosted runners. Installers are uploaded as workflow
artifacts or GitHub Release assets and are never committed to the source tree.

## Build validation artifacts

Run a cross-platform build without publishing a GitHub Release:

```bash
gh workflow run release.yml \
  --repo filenestapp/filenest \
  --ref main \
  -f release_tag=v0.2.4 \
  -f publish_release=false \
  -f prerelease=true
```

The Windows job produces the Universal installer and x64/ARM64 portable
executables. Without Apple distribution secrets, the macOS job produces
clearly named `unsigned` ZIP and DMG artifacts for build validation only.
Unsigned artifacts are not distribution-ready.

## Configure macOS distribution

The following repository Actions secrets are required for signed and notarized
macOS releases:

- `MACOS_CERTIFICATE_P12_BASE64`: base64-encoded Developer ID Application
  certificate and private key in PKCS#12 format.
- `MACOS_CERTIFICATE_PASSWORD`: password used to export the PKCS#12 file.
- `MACOS_TEAM_ID`: Apple Developer Team ID for the Developer ID certificate.
- `MACOS_NOTARY_KEY_ID`: App Store Connect API key ID.
- `MACOS_NOTARY_ISSUER_ID`: App Store Connect API issuer ID.
- `MACOS_NOTARY_PRIVATE_KEY_BASE64`: base64-encoded App Store Connect `.p8`
  private key.

Optional Windows code-signing secrets:

- `WINDOWS_CSC_LINK`
- `WINDOWS_CSC_KEY_PASSWORD`

Never commit these credentials. Set them through GitHub CLI or the repository
Actions settings.

## Publish a release

After all required distribution secrets are configured:

```bash
gh workflow run release.yml \
  --repo filenestapp/filenest \
  --ref main \
  -f release_tag=v0.2.4 \
  -f publish_release=true \
  -f prerelease=true
```

The publish job refuses to create a GitHub Release unless the macOS app was
signed with Developer ID, notarized, stapled, and validated. It uses the
workflow-scoped GitHub token and GitHub CLI to create the release and upload
all platform assets.

## Monitor the build

```bash
gh run list --repo filenestapp/filenest --workflow release.yml
gh run watch RUN_ID --repo filenestapp/filenest --exit-status
```
