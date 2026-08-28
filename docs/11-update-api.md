# Version Update API

FileNest uses the independent Go service in [`update-server`](../update-server) as its release metadata control plane.

## Update flow

1. CI builds, signs, notarizes, and archives FileNest.
2. CI calculates the archive SHA-256 digest.
3. Sparkle's `sign_update` command creates the EdDSA signature.
4. The archive is uploaded to immutable HTTPS storage.
5. CI posts the metadata to `POST /v1/admin/releases`.
6. FileNest reads `/appcast/{channel}.xml` through Sparkle.
7. FileNest checks once at startup and continues on Sparkle's background
   schedule.
8. When automatic installation is enabled, Sparkle downloads and verifies the
   archive, FileNest drains its managed services, then the updater installs
   the release and relaunches the application.
9. Other clients and operations tools can use `/v1/updates/check`.

The OMP Agent Host uses a separate manifest because its Bun runtime is an
architecture-specific executable rather than a Sparkle application archive:

1. CI builds the pinned `@oh-my-pi/pi-coding-agent` host for `arm64` and
   `x86_64` with `script/build_agent_host.sh`.
2. CI uploads both immutable executables to `downloads.filenestapp.com` and
   records their SHA-256 digests.
3. CI atomically replaces the file configured by
   `FILENEST_OMP_MANIFEST_FILE` with the new `version` and `artifacts` JSON.
4. FileNest checks `GET /omp-agent/stable.json`, verifies the manifest and
   artifact digest, then stages and atomically replaces the managed host.

If the production API still returns `404` while a release is being rolled out,
FileNest retries discovery against the latest GitHub Release and accepts only
the two architecture-specific `filenest-agent-host-*` assets when GitHub
provides a SHA-256 digest. This is a migration fallback for an older API
deployment; the configured manifest remains the primary update source.

The API never receives or stores Apple signing certificates, notarization credentials, or the Sparkle private key.

Release builds receive the appcast URL and EdDSA public key through the
`FILENEST_UPDATE_FEED_URL` and `FILENEST_SPARKLE_PUBLIC_KEY` Xcode build
settings. The private key is used only by the release signer.

Production endpoints:

- Appcast and update API: `https://updates.filenestapp.com`
- Immutable macOS update archives: `https://downloads.filenestapp.com`
- OMP Agent Host manifest: `https://updates.filenestapp.com/omp-agent/stable.json`

## JSON update check

```http
GET /v1/updates/check?platform=macos&arch=arm64&channel=stable&version=0.2.0&build=2
```

```json
{
  "update_available": true,
  "latest": {
    "id": "macos-arm64-stable-0.3.0-3",
    "version": "0.3.0",
    "build": 3,
    "platform": "macos",
    "architecture": "arm64",
    "channel": "stable",
    "published_at": "2026-07-29T10:00:00Z",
    "download_url": "https://downloads.filenestapp.com/FileNest-0.3.0-macOS.zip",
    "file_size": 12345678,
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "sparkle_ed_signature": "public-signature",
    "minimum_os_version": "13.0",
    "release_notes_url": "https://updates.example.com/releases/0.3.0",
    "critical": false
  },
  "checked_at": "2026-07-29T12:00:00Z"
}
```

When no matching release exists, `latest` is omitted and `update_available` is `false`. Public responses include an ETag and a five-minute cache policy.

## Release selection

- Build number is compared before the marketing version.
- A requested architecture matches an exact architecture, `universal`, or `any`.
- Stable and prerelease channels are isolated.
- The appcast includes at most the latest 20 matching releases.
- macOS releases without a Sparkle EdDSA signature are rejected.

## Operational security

- Admin endpoints are disabled until `FILENEST_UPDATE_ADMIN_TOKEN` is configured.
- Admin authentication uses a constant-time Bearer token comparison.
- Request bodies are limited to 1 MiB and reject unknown JSON fields.
- Release metadata is written through a temporary file and atomic rename.
- Production download and release-note URLs must use HTTPS.
- CORS is disabled unless explicit browser origins are configured.
- `updates.filenestapp.com` is reverse-proxied to the loopback-only Go API.
- `downloads.filenestapp.com` serves release archives directly from Nginx and
  does not expose the admin API.

See [`update-server/README.md`](../update-server/README.md) for local execution, Docker, release publishing, and FileNest integration.
