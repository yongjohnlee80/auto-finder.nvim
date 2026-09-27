#!/usr/bin/env bash
# tests/adr0200-files-mutants.sh — every guarantee tests/adr0200-files.lua claims must be load-bearing.
#
# Copies the worktree, applies ONE mutation, runs tests/adr0200-files.lua against the copy and requires it
# to FAIL. The unmutated copy must pass first: an always-red suite "catches" every mutant. Each mutation must
# match exactly once, or it is reported NOT APPLIED (a no-op mutant would read as killed whenever the suite
# happened to be red for another reason).
#
# The copy keeps the sibling layout the suite resolves auto-core and worktree from
# (<root>/auto-finder.nvim/<name>, <root>/auto-core.nvim/<name>, …): the siblings are symlinked, not copied.
#
# Run on VM43 from the worktree root: bash tests/adr0200-files-mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
NAME="$(basename "$SRC")"
PLUGINS="$(dirname "$(dirname "$SRC")")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

stage() { # stage <dir> → a copy of this worktree at <dir>/auto-finder.nvim/$NAME with symlinked siblings
  mkdir -p "$1/auto-finder.nvim"
  cp -r "$SRC" "$1/auto-finder.nvim/$NAME"
  local sib
  for sib in auto-core.nvim worktree.nvim auto-run.nvim; do
    [ -e "$PLUGINS/$sib" ] && ln -s "$PLUGINS/$sib" "$1/$sib"
  done
}
run_suite() { (cd "$1/auto-finder.nvim/$NAME" && timeout 300 nvim --headless -u NONE -l tests/adr0200-files.lua 2>&1); }
summary_of() { printf '%s\n' "$1" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1; }

stage "$WORK/base"
out="$(run_suite "$WORK/base")"
summary="$(summary_of "$out")"
if [ -z "$summary" ] || [ "${summary##*, }" != "0 failed" ]; then
  echo "BASELINE NOT GREEN: ${summary:-no summary}"; printf '%s\n' "$out" | grep -E '^  FAIL'; exit 1
fi
echo "baseline: $summary"

# One mutant per line of the table: name, file, old, new (python literals, so newlines stay exact).
mapfile -t MUTANTS < <(python3 - <<'PY'
import json
F = "lua/auto-finder/views/files/init.lua"
M = [
  ("hide keeps its directory watches", F,
   '  disarm_all(S.model)\n  require("auto-finder.core.watchers").unwatch_owner(model_mod.WATCH_OWNER)\n  require("auto-finder.core.watchers").unwatch_git_owner',
   '  require("auto-finder.core.watchers").unwatch_git_owner'),
  ("hide keeps its subscriptions", F,
   '  if S.subs then pcall(function() S.subs:dispose_all() end) end\n  if S.augroup then pcall(vim.api.nvim_del_augroup_by_id, S.augroup); S.augroup = nil end\n  stop_timers()\n  pending_reads = {}',
   '  if S.augroup then pcall(vim.api.nvim_del_augroup_by_id, S.augroup); S.augroup = nil end\n  stop_timers()\n  pending_reads = {}'),
  ("hide leaves in-flight reads live (no cancel, token kept)", F,
   '  if S.model and S.model.token then\n    require("auto-core.fs.scan").cancel(S.model.token)\n    S.model.token = nil\n  end\n  if S.search then',
   '  if S.search then'),
  ("re-root leaves in-flight reads live", F,
   '  if S.model and S.model.token then\n    require("auto-core.fs.scan").cancel(S.model.token)\n    S.model.token = nil\n  end\n  disarm_all(S.model)\n  new_model(root)',
   '  disarm_all(S.model)\n  new_model(root)'),
  ("collapse keeps the directory watch", F,
   '      if d.watch and not vim.tbl_contains(model_mod.expanded_dirs(model), d.path) then disarm(d) end',
   '      local _ = d'),
  ("show re-reads every known directory, collapsed ones too", F,
   '  for _, d in ipairs(dirs) do read_then_paint(d, true) end',
   '  for p, n in pairs(S.model.nodes) do if n.type == "directory" then read_then_paint(p, true) end end'),
  ("an event naming a collapsed directory reads it", F,
   '    if dir.expanded and dir.children then\n      schedule_read(payload.dir)',
   '    if dir.children then\n      schedule_read(payload.dir)'),
  ("an event re-reads the root as well as the named directory", F,
   '    if dir.expanded and dir.children then\n      schedule_read(payload.dir)',
   '    if dir.expanded and dir.children then\n      schedule_read(payload.dir); schedule_read(S.model.root)'),
  ("an expanded nested repo never gets its status read", F,
   '      if model == S.model then arm(node); note_repos(model) end',
   '      if model == S.model then arm(node) end'),
  ("a clean file inherits a code that bubbled into its directory", "lua/auto-finder/views/files/git.lua",
   '      if s == "!!" or s == "??" then return M.code(s) end',
   '      if s == "!!" or s == "??" or s == "?" then return M.code(s) end'),
  ("follow re-reads the root", "lua/auto-finder/views/files/model.lua",
   '  if root.children == nil then', '  if true then'),
  ("a dropped key is mapped again", F,
   '  C = "close_node",', '  C = "close_node", P = "refresh",'),
  ("hide keeps its git watches", F,
   '  require("auto-finder.core.watchers").unwatch_git_owner(model_mod.WATCH_OWNER)\n  if S.subs', '  if S.subs'),
  ("the view holds no git watch (an external commit never recolours)", F,
   '    watchers.watch_git(repo, model_mod.WATCH_OWNER)\n', ''),
  ("directory watches inherit fs.watch's default ignore list", "lua/auto-finder/core/watchers.lua",
   '{ recursive = false, self_extend = false, ignore = {} }', '{ recursive = false, self_extend = false }'),
  ("filter prefs never reach the view", "lua/auto-finder/core/init.lua",
   '      require("auto-finder.core.events").publish("auto-finder.core.files:filters", { what = what })\n', ''),
]
for m in M:
    print(json.dumps(m))
PY
)

killed=0; survived=0; broken=0; i=0
for spec in "${MUTANTS[@]}"; do
  i=$((i + 1))
  name="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0])' "$spec")"
  dir="$WORK/m$i"
  stage "$dir"
  if ! python3 - "$dir/auto-finder.nvim/$NAME" "$spec" <<'PY'
import json, sys
root, (name, f, old, new) = sys.argv[1], json.loads(sys.argv[2])
p = root + "/" + f
s = open(p).read()
n = s.count(old)
if n != 1:
    print(f"    mutation matched {n} times"); sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  then
    echo "NOT APPLIED  $name"; broken=$((broken + 1)); continue
  fi
  out="$(run_suite "$dir")"
  summary="$(summary_of "$out")"
  if [ -n "$summary" ] && [ "${summary##*, }" = "0 failed" ]; then
    echo "SURVIVED     $name"; survived=$((survived + 1))
  else
    echo "KILLED       $name  (${summary:-aborted})"
    printf '%s\n' "$out" | grep -E '^  FAIL' | head -3 | sed 's/^/               /'
    killed=$((killed + 1))
  fi
  rm -rf "$dir"
done
echo "killed=$killed survived=$survived not_applied=$broken of ${#MUTANTS[@]}"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
