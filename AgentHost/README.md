# FileNest OMP Adapter

This small Bun-based adapter starts the official OMP runtime for FileNest and
exposes its RPC v2 protocol over standard input and output. FileNest bundles the
adapter; the official OMP executable is downloaded and versioned separately.

The P1 policy is intentionally narrow:

- OMP built-in tools, MCP, LSP, extensions, skills, rules, and ambient context discovery are disabled.
- Only tools registered by the FileNest host are available to the model.
- The workspace, agent data, and session directories must be supplied explicitly by FileNest.
- Standard output is reserved for RPC frames; diagnostics are written to standard error.
- Attached-file chat receives only bounded text snapshots prepared by FileNest. The Agent Host does not receive the attachment path, and it runs from a separate application-support workspace.
- The selected FileNest global provider, model, endpoint, API key, and Thinking
  level are passed only through the isolated child-process environment.

## Build

Install Bun 1.3.14 or newer, then run:

```sh
./script/build_agent_host.sh
```

Release builds can set `FILENEST_AGENT_HOST_TARGET` to `bun-darwin-arm64` or
`bun-darwin-x64`, and can set `FILENEST_AGENT_HOST_OUTPUT` to choose the
output executable path.

The executable, a `version.txt` sidecar, and a `.sha256` checksum file are written to `AgentHost/dist`. For a developer launch, set:

```sh
FILENEST_OMP_AGENT_ENABLED=1
FILENEST_AGENT_HOST_EXECUTABLE="$PWD/AgentHost/dist/filenest-agent-host"
FILENEST_OMP_RUNTIME_EXECUTABLE="/path/to/official/omp"
```

FileNest supplies the global provider, model, endpoint, and Thinking state at
launch time. The host uses an app-owned generated model registry instead of a
separate OMP model setting. A Cloud API key is supplied only through the
isolated child-process environment for the request lifetime; it is not written
to the generated registry file or project workspace.

When both variables are present, attached-file chat shows a `Classic` / `OMP Preview` selector. Classic remains the default. If OMP cannot start before emitting content, FileNest falls back to the configured classic provider; a partial OMP response is never mixed with a second provider.

## Official OMP Runtime

FileNest uses the official [oh-my-pi GitHub Releases](https://github.com/can1357/oh-my-pi/releases).
It selects the matching macOS runtime, verifies the SHA-256 digest supplied by
GitHub, validates the downloaded executable, and stores each version under
FileNest's application-support directory. The current runtime pointer switches
atomically and retains the prior version for rollback.

The app exposes installation, update checks, and rollback from Settings and
from the onboarding wizard when OMP Preview is selected.
