# FileNest Update API

This service publishes signed FileNest releases through both a Sparkle 2 appcast and a reusable JSON API. It stores release metadata in one atomically updated JSON file and has no third-party Go dependencies.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/healthz` | Process health |
| `GET` | `/appcast.xml` | Sparkle 2 appcast |
| `GET` | `/appcast/{channel}.xml` | Channel-specific Sparkle appcast |
| `GET` | `/v1/updates/check` | JSON update check |
| `GET` | `/v1/releases/latest` | Latest matching release metadata |
| `POST` | `/v1/admin/releases` | Create or replace release metadata |
| `DELETE` | `/v1/admin/releases/{id}` | Delete release metadata |

Public release endpoints accept:

- `platform`: defaults to `macos`
- `arch`: `arm64`, `x86_64`, `universal`, or `any`; defaults to `universal`
- `channel`: defaults to `stable`

The update check also accepts the installed `version` and integer `build`. The build number is the primary ordering key because that matches Sparkle's update semantics.

## Run locally

```bash
cd update-server
export FILENEST_UPDATE_ADMIN_TOKEN="$(openssl rand -hex 32)"
export FILENEST_UPDATE_DATA_FILE="$PWD/data/releases.json"
go run ./cmd/server
```

The default listener is `127.0.0.1:8080`.

```bash
curl http://127.0.0.1:8080/healthz
curl "http://127.0.0.1:8080/v1/updates/check?platform=macos&arch=arm64&channel=stable&version=0.2.0&build=2"
curl "http://127.0.0.1:8080/appcast/stable.xml?arch=arm64"
```

## Publish a release

Generate the update archive, SHA-256 digest, and Sparkle EdDSA signature in the release pipeline. Keep the Sparkle private key out of this service.

```bash
shasum -a 256 FileNest-0.3.0.zip
/path/to/Sparkle/bin/sign_update FileNest-0.3.0.zip
```

Submit only the public signature and release metadata:

```bash
curl -X POST http://127.0.0.1:8080/v1/admin/releases \
  -H "Authorization: Bearer $FILENEST_UPDATE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @release.json
```

A macOS release is rejected unless it has:

- a positive build number and file size
- an HTTPS download URL
- a 64-character SHA-256 digest
- a Sparkle EdDSA signature

HTTP URLs are accepted only for `localhost` and loopback addresses to support local testing.

Example release metadata is available at [`data/release.example.json`](data/release.example.json).

## Connect FileNest

Deploy the API behind HTTPS and set FileNest's update feed URL to:

```text
https://updates.example.com/appcast/stable.xml?arch=arm64
```

For a universal package, use `arch=universal`. The app already rejects non-HTTPS update feeds.

## Configuration

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `FILENEST_UPDATE_ADDR` | `127.0.0.1:8080` | Listener address |
| `FILENEST_UPDATE_DATA_FILE` | `data/releases.json` | Persistent metadata file |
| `FILENEST_UPDATE_ADMIN_TOKEN` | empty | Bearer token; empty disables all admin endpoints |
| `FILENEST_UPDATE_ALLOWED_ORIGINS` | empty | Comma-separated browser origins allowed by CORS |

## Production notes

- Terminate TLS at a trusted reverse proxy or load balancer.
- Store release archives in immutable object storage or a release CDN.
- Mount the metadata file on persistent storage.
- Use a long random admin token from a secret manager.
- Do not expose the Sparkle private key to the API process.
- Back up the metadata file and release artifacts together.

## Docker

```bash
docker build -t filenest-update-api ./update-server
docker run --rm \
  -p 8080:8080 \
  -e FILENEST_UPDATE_ADMIN_TOKEN="$FILENEST_UPDATE_ADMIN_TOKEN" \
  -v "$PWD/update-data:/data" \
  filenest-update-api
```
