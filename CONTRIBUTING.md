# Contributing to FileNest

Thank you for helping improve FileNest. Contributions to the macOS app,
Windows app, documentation, tests, and developer tooling are welcome.

## Before you start

- Search existing issues and pull requests before starting duplicate work.
- Open an issue for a substantial feature, architecture change, new external
  service, or behavior that affects user data.
- Keep each pull request focused. Small, reviewable changes are easier to test
  and merge.
- Never commit API keys, signing identities, certificates, private user files,
  model data, or generated release artifacts.

## Development setup

### macOS

Requirements:

- macOS 14 or later for the full XCTest runtime
- Xcode with Swift 5.9 support
- XcodeGen when regenerating the project from `project.yml`

Build and run the release configuration:

```bash
./script/build_and_run.sh --verify
```

Run the macOS tests:

```bash
xcodebuild -project FileNest.xcodeproj -scheme FileNest \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData test
```

### Windows

Requirements:

- Windows 11 for release acceptance
- Node.js 22

Install dependencies and verify the source:

```bash
cd FileNestWindows
npm ci
npm run typecheck
npm test
npm run build
```

## Change guidelines

- Write source identifiers, comments, logs, errors, prompts, and tests in
  English.
- Put user-facing text in the localization resources. Keep English and
  Simplified Chinese coverage aligned.
- Preserve FileNest's local-first privacy boundary. Network access must be
  explicit, user-configured, and documented.
- Add or update tests for behavior changes and regressions.
- Update the relevant README or file under `docs/` when public behavior,
  configuration, architecture, or release steps change.
- Avoid unrelated formatting or generated-file churn.

If AI tools materially assisted the change, say so in the pull request and
describe how the result was reviewed and tested. Contributors remain
responsible for correctness, licensing, and security.

## Pull requests

A pull request should include:

- a concise problem statement and solution summary;
- the platforms and user flows affected;
- verification commands and their results;
- screenshots or recordings for visible UI changes;
- migration, privacy, security, or compatibility notes when applicable.

By submitting a contribution, you agree that it may be distributed under the
[MIT License](LICENSE).

All contributors must follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report
security issues using the process in [SECURITY.md](SECURITY.md).
