#!/usr/bin/env bash
# Runs the plenary.nvim test suite. Clones plenary.nvim and nvim-dap into .deps/ on the
# first run (gitignored, dev-only), unless $PLENARY_PATH / $DAP_PATH point at them.
# Requires: nvim, git; for the debugging tests, gcc and gdb 14 or later (else they are skipped).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

clone() { # env var, repository, folder
  local path="${!1:-$root/.deps/$3}" # (not in tests/: their own specs would run too)
  if [ ! -d "$path" ]; then
    echo "Cloning $3 into $path ..."
    mkdir -p "$(dirname "$path")"
    git clone --depth 1 "$2" "$path"
  fi
  export "$1=$path"
}
clone PLENARY_PATH https://github.com/nvim-lua/plenary.nvim plenary.nvim
clone DAP_PATH https://github.com/mfussenegger/nvim-dap nvim-dap

# what the tests keep (watches, pins, ...) goes to a folder of their own
XDG_DATA_HOME="$(mktemp -d)"
export XDG_DATA_HOME
trap 'rm -rf "$XDG_DATA_HOME"' EXIT

target="${1:-$root/tests}"

nvim --headless --noplugin \
  -u "$root/tests/minimal_init.lua" \
  -c "PlenaryBustedDirectory $target { minimal_init = '$root/tests/minimal_init.lua', sequential = true }"
