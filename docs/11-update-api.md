# Version Update API

FileNest uses the independent Go service in [`update-server`](../update-server) as its release metadata control plane.

## Update flow

1. CI builds, signs, notarizes, and archives FileNest.
2. CI calculates the archive SHA-256 digest.
3. Sparkle's `sign_update` command creates the EdDSA signature.
4. The archive is uploaded to immutable HTTPS storage.
5. CI posts the metadata to `POST /v1/admin/releases`.
6. FileNest reads `/appcast/{channel}.xml` through Sparkle.
7. Other clients and operations tools can use `/v1/updates/check`.

The API never receives or stores Apple signing certificates, notarization credentials, or the Sparkle private key.

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
    "download_url": "https://updates.example.com/FileNest-0.3.0.zip",
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

See [`update-server/README.md`](../update-server/README.md) for local execution, Docker, release publishing, and FileNest integration.
