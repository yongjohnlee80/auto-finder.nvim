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
#   AUTO_CORE_REF  WORKTREE_REF  AUTO_RUN_REF  PLENARY_REF  NUI_REF  NVIM_DAP_REF
#
# neo-tree is NOT here: auto-finder ships its own fork under
# lua/auto-finder/neotree. Nor is gitgraph, which is named only in a comment
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

echo "third-party:"
clone_at https://github.com/nvim-lua/plenary.nvim "$lazy/plenary.nvim"  "${PLENARY_REF:-}"
clone_at https://github.com/MunifTanjim/nui.nvim "$lazy/nui.nvim"      "${NUI_REF:-}"
# Real nvim-dap: smoke and smoke-adr0048 drive the actual surface rather than a
# stub, and both prepend it only `if isdirectory` — omitting it would not fail
# the suite, it would quietly test less.
clone_at https://github.com/mfussenegger/nvim-dap "$lazy/nvim-dap"     "${NVIM_DAP_REF:-}"
