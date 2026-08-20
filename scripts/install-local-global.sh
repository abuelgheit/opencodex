#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

export PATH="${HOME}/.bun/bin:${PATH:-}"

if [[ ! -f "${REPO_ROOT}/package.json" ]]; then
  printf 'Error: repository root package.json was not found at %s.\n' "${REPO_ROOT}/package.json" >&2
  exit 1
fi

if ! command -v bun >/dev/null 2>&1; then
  printf 'Error: bun was not found on PATH. Install Bun and try again.\n' >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  printf 'Error: npm was not found on PATH. Install Node.js/npm and try again.\n' >&2
  exit 1
fi

cd -- "${REPO_ROOT}"

printf 'Notice: this installer expects a pre-existing background service; ocx service repair will fail if no service is installed.\n' >&2

printf 'Installing local dependencies...\n'
npm install

printf 'Building the GUI...\n'
npm run build:gui

printf 'Stopping the existing ocx proxy...\n'
ocx stop

printf 'Installing ocx globally from the local repository...\n'
npm install -g .

printf 'Repairing the existing OpenCodex background service...\n'
ocx service repair

printf 'OpenCodex has been refreshed as a background service. Check it with: ocx service status\n'
