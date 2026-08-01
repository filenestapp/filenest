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
  -f release_tag=v0.2.5 \
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
- `FILENEST_SPARKLE_PRIVATE_KEY`: private EdDSA key exported by Sparkle's
  `generate_keys` tool. It is used only by the macOS packaging job.
- `FILENEST_UPDATE_ADMIN_TOKEN`: bearer token used to publish signed release
  metadata to the production update API.
- `FILENEST_DEPLOY_SSH_KEY`: dedicated restricted SSH key used only to upload
  the signed macOS update archive.

The following repository Actions variables are also required:

- `FILENEST_UPDATE_FEED_URL`: production HTTPS Sparkle appcast URL, for example
  `https://updates.example.com/appcast/stable.xml?arch=universal`.
- `FILENEST_SPARKLE_PUBLIC_KEY`: EdDSA public key produced by Sparkle's
  `generate_keys` tool. It must match the private key used by `sign_update`.
- `FILENEST_DOWNLOAD_BASE_URL`: immutable archive origin. Production uses
  `https://downloads.filenestapp.com`.
- `FILENEST_UPDATE_ADMIN_URL`: update control-plane origin. Production uses
  `https://updates.filenestapp.com`.
- `FILENEST_DEPLOY_HOST` and `FILENEST_DEPLOY_USER`: production archive upload
  target.

The release workflow injects these values into the final application
`Info.plist`. A macOS build is treated as a validation-only artifact when
either value is missing, preventing publication of a signed package that
cannot securely discover and verify updates.

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
  -f release_tag=v0.2.5 \
  -f publish_release=true \
  -f prerelease=false
```

The publish job refuses to create a GitHub Release unless the macOS app was
signed with Developer ID, notarized, stapled, and validated. The workflow then:

1. recreates the ZIP from the stapled application;
2. signs the final ZIP with the matching Sparkle private key;
3. publishes the GitHub Release assets;
4. uploads the signed ZIP to `downloads.filenestapp.com`;
5. verifies the public download URL;
6. publishes the signed metadata to the update API.

Each DMG includes `FileNest.app` and an `Applications` Finder alias. This is
the standard drag-to-install layout: open the DMG, then drag FileNest onto the
Applications alias before launching it.

The application checks the appcast at startup and on Sparkle's normal
background schedule. When automatic installation is enabled, FileNest
downloads the signed archive, safely stops its managed services, installs the
update, and relaunches.

FileNest 0.2.4 and older builds do not contain the production automatic-update
configuration. Users on those versions must install 0.2.5 once through the DMG;
subsequent releases can update automatically.

## Monitor the build

```bash
gh run list --repo filenestapp/filenest --workflow release.yml
gh run watch RUN_ID --repo filenestapp/filenest --exit-status
```
