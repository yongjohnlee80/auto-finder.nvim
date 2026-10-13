#!/usr/bin/env bash
# .github/install-deps.sh — materialise the dependencies this test tree
# resolves, in BOTH shapes it resolves them from.
#
# Enumerated from every file under tests/, not from smoke.lua's header: reading
# one file per repo and generalising is exactly what hid a dependency during
# the auto-agents rollout. The suites look for family plugins in two places —
# `$lazy/<plugin>` and `<workspace>/<plugin>/main` — and different suites use
# different ones, so both have to exist for auto-core and worktree. They are
# ONE clone with a symlink rather than two clones, so the two shapes cannot
# resolve to different code.
#
# Refs come from the environment. An EMPTY ref means "whatever the default
# branch is now" — that is the drift job's whole purpose, so it is a supported
# value and not a mistake:
#   AUTO_CORE_REF  WORKTREE_REF  AUTO_RUN_REF  AUTODOC_REF  NVIM_DAP_REF  MINI_ICONS_REF  CATPPUCCIN_REF
#
# The parity gate (tests/parity/compare.lua, ADR-0200) renders with the icon
# provider and colour scheme its goldens were captured with, so those two are
# pinned to the SHAs in tests/fixtures/parity/manifest.json and exposed through
# AF_PARITY_DEPS. gitgraph is not here: it is named only in a comment
# explaining why a path is not driven headless.
set -euo pipefail

lazy="$HOME/.local/share/nvim/lazy"
mkdir -p "$lazy"

# The suites derive their sibling root as fnamemodify(root, ":h:h"), which on a
# runner is dirname(dirname($GITHUB_WORKSPACE)) — the checkout lives at
# /home/runner/work/<repo>/<repo>.
siblings="$(dirname "$(dirname "$GITHUB_WORKSPACE")")"

clone_at() {
  local url="$1" dest="$2" ref="$3"
  git clone --filter=blob:none "$url" "$dest"
  if [ -n "$ref" ]; then
    git -C "$dest" checkout "$ref"
  fi
  printf '  %s -> %s\n' "$dest" "$(git -C "$dest" log --oneline -1)"
}

echo "family plugins (sibling shape, symlinked into the lazy shape):"
for spec in "auto-core.nvim:${AUTO_CORE_REF:-}" \
            "worktree.nvim:${WORKTREE_REF:-}" \
            "auto-run.nvim:${AUTO_RUN_REF:-}"; do
  plugin="${spec%%:*}"; ref="${spec#*:}"
  clone_at "https://github.com/yongjohnlee80/$plugin" \
           "$siblings/$plugin/main" "$ref"
  # auto-run is resolved ONLY as a sibling; auto-core and worktree are looked
  # for in the lazy dir too, by the {file, symbol} candidate pick.
  if [ "$plugin" != "auto-run.nvim" ]; then
    ln -s "$siblings/$plugin/main" "$lazy/$plugin"
  fi
done

# AutoDoc (ADR 1791532020): the todos panel calls AutoDoc's daemon itself,
# through autodoc.nvim's todos client, so the todo cells need autodoc.nvim
# (lua/, in the autodoc repo) and its binary. Sibling shape only: tests/_autodoc.lua looks for
# <plugins>/autodoc/main and its bin/autodoc, and gives each suite a daemon of
# its own. The binary is built here, without cgo, as autodoc's Makefile does.
echo "autodoc:"
clone_at https://github.com/yongjohnlee80/autodoc "$siblings/autodoc/main" "${AUTODOC_REF:-}"
command -v go >/dev/null || { echo "go is required to build autodoc (actions/setup-go)" >&2; exit 1; }
( cd "$siblings/autodoc/main" && GOWORK=off CGO_ENABLED=0 GOFLAGS=-buildvcs=false \
    go build -o bin/autodoc ./cmd/autodoc )
"$siblings/autodoc/main/bin/autodoc" --version

echo "third-party:"
# Real nvim-dap: smoke and smoke-adr0048 drive the actual surface rather than a
# stub, and both prepend it only `if isdirectory` — omitting it would not fail
# the suite, it would quietly test less.
clone_at https://github.com/mfussenegger/nvim-dap "$lazy/nvim-dap"     "${NVIM_DAP_REF:-}"

# Parity-gate dependencies (ADR-0200 §5 cell 1), outside the lazy dir so no suite
# picks them up by accident: only compare.lua reads AF_PARITY_DEPS.
parity="$HOME/af-parity-deps"
mkdir -p "$parity"
clone_at https://github.com/nvim-mini/mini.icons "$parity/mini.icons" "${MINI_ICONS_REF:-}"
clone_at https://github.com/catppuccin/nvim       "$parity/catppuccin" "${CATPPUCCIN_REF:-}"
