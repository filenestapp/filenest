#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
agent_host_directory="${repository_root}/AgentHost"
agent_host_target="${FILENEST_AGENT_HOST_TARGET:-}"
agent_host_output="${FILENEST_AGENT_HOST_OUTPUT:-${agent_host_directory}/dist/filenest-agent-host}"

if ! command -v bun >/dev/null 2>&1; then
  echo "Bun 1.3.14 or newer is required to build the FileNest Agent Host." >&2
  exit 1
fi

cd "${agent_host_directory}"
bun install --frozen-lockfile
bun run check
mkdir -p "$(dirname "${agent_host_output}")"
build_args=(
  build
  src/main.ts
  --compile
  --external
  omp-legacy-pi-modules
  --outfile
  "${agent_host_output}"
)
if [[ -n "${agent_host_target}" ]]; then
  build_args+=(--target "${agent_host_target}")
fi
bun "${build_args[@]}"

host_version="$(bun -e 'const packageJSON = await Bun.file("package.json").json(); process.stdout.write(packageJSON.version)')"
printf '%s\n' "${host_version}" > "$(dirname "${agent_host_output}")/version.txt"
shasum -a 256 "${agent_host_output}" \
  > "${agent_host_output}.sha256"

echo "Built ${agent_host_output} (${host_version})"
