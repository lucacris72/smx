#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"

local_image="smx-test-env:local"
remote_image="ghcr.io/lucacris72/smx:latest"

if [[ -n "${SMX_DOCKER_IMAGE:-}" ]]; then
  image="${SMX_DOCKER_IMAGE}"
elif docker image inspect "${local_image}" >/dev/null 2>&1; then
  image="${local_image}"
else
  image="${remote_image}"
fi

if [[ $# -eq 0 ]]; then
  cmd=(bash)
else
  cmd=("$@")
fi

docker_flags=(--rm)

if [[ -t 0 && -t 1 ]]; then
  docker_flags+=(-it)
fi

exec docker run \
  "${docker_flags[@]}" \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e RISCV=/opt/riscv \
  -v "${repo_root}:/workspace" \
  -w /workspace \
  "${image}" \
  "${cmd[@]}"
