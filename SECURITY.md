# Security Policy

FileNest processes local files and can connect to user-configured AI services,
so reports that may affect confidentiality, integrity, or safe file handling
are taken seriously.

## Supported versions

Security fixes are provided for the latest release and the current `main`
branch. Older releases may be asked to upgrade before a fix is backported.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting flow from the repository
**Security** tab. If that option is not available, contact a repository
maintainer privately through the contact method on their GitHub profile.

Include, when possible:

- the affected version, commit, and platform;
- a concise impact statement;
- reproduction steps or a minimal proof of concept;
- relevant logs with credentials and personal data removed;
- any suggested mitigation.

Please allow maintainers a reasonable period to investigate and coordinate a
fix before public disclosure. The project will acknowledge a usable report,
keep the reporter informed of material progress, and credit the reporter when
requested and appropriate.

## Security boundaries

- FileNest runs with the current operating-system user's file permissions.
- Local mode is designed to keep document content on the device.
- Content leaves the device only through AI services explicitly configured by
  the user for the relevant operation.
- API credentials, signing materials, private documents, local databases, and
  generated logs must never be attached to public issues.

For implementation details, see
[API and integration map](docs/06-api-and-integration-map.md) and
[technical architecture](docs/03-technical-architecture.md).
