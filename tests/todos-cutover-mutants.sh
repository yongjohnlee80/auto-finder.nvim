#!/usr/bin/env bash
# tests/todos-cutover-mutants.sh — every rule of the todo cutover must be
# load-bearing in its suite (ADR 1791532020 §3 steps 3 and 4): a direct write
# coming back, a daemon verb dropped, the shim used again, the stale guard
# lost, "AutoDoc required" gone or D2's fallback back must turn a cell red.
#
# Copies the tree NEXT TO this checkout (the suites find auto-core, autodoc and
# the other family plugins two directories up), applies ONE mutation, runs the
# suite that owns the rule, and requires it to FAIL. The unmutated copy must be
# green first, and each mutation must match exactly once.
#
# Needs the environment tests/run-all.sh needs (the sibling plugins and AutoDoc,
# .github/install-deps.sh). Run on VM43: bash tests/todos-cutover-mutants.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD"
PARENT="$(dirname "$SRC")"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/af-mutants-XXXXXX")"
export AF_TEST_SANDBOX_ROOT="$SANDBOX"
copies=()
cleanup() {
  pkill -f -- "--config $SANDBOX/" 2>/dev/null || true
  for c in "${copies[@]}"; do rm -rf "$c"; done
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

copy() { local d="$PARENT/mutant-$$-$1"; rm -rf "$d"; cp -r "$SRC" "$d"; copies+=("$d"); echo "$d"; }
run_suite() { # <dir> <suite file>
  (cd "$1" && timeout 900 nvim --headless -u NONE -l "$2" 2>&1)
  pkill -f -- "--config $SANDBOX/" 2>/dev/null || true
}
summary_of() { printf '%s\n' "$1" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1; }
red() { # the run failed: a FAIL line, a non-zero failed count, or no summary
  local s; s="$(summary_of "$1")"
  [ -z "$s" ] || [ "${s##*, }" != "0 failed" ] || printf '%s\n' "$1" | grep -qE '  FAIL  '
}

base="$(copy base)"
for s in tests/todos-cutover.lua tests/smoke.lua tests/adr0083-repos-task-attach.lua; do
  out="$(run_suite "$base" "$s")"
  if red "$out"; then echo "BASELINE NOT GREEN ($s): $(summary_of "$out")"; printf '%s\n' "$out" | grep FAIL; exit 1; fi
  echo "baseline $s: $(summary_of "$out")"
done

V=lua/auto-finder/views/todos/init.lua
D=lua/auto-finder/views/todos/store.lua
T=lua/auto-finder/views/repos/tree.lua
C=tests/todos-cutover.lua
S=tests/smoke.lua
A=tests/adr0083-repos-task-attach.lua
# file|suite|name|old|new — literal strings; old must occur exactly once.
# (No mutant re-adds a require of auto-core.todo: auto-core v0.4.1 removes the
# module, so such a mutant would load nothing and survive there. The cutover
# suite's "never required" cells guard it while the pinned auto-core ships it.)
mutants=(
  "$V|$C|the malformed unlink comes back|    store.remove_malformed(row.relpath, function(ok, err)|    vim.uv.fs_unlink(row.filepath); (function(cb) cb(true) end)(function(ok, err)"
  "$V|$C|remove_malformed is not called|    store.remove_malformed(row.relpath, function(ok, err)|    (function(cb) cb(true) end)(function(ok, err)"
  "$V|$C|the store rename comes back|      store.move_store(new_path, function(moved, err) done(moved ~= nil, err) end)|      done(vim.uv.fs_rename(current, new_path), \"renamed\")"
  "$V|$C|move_store is not called (switch instead)|      store.move_store(new_path, function(moved, err) done(moved ~= nil, err) end)|      store.set_dir(new_path, done)"
  "$V|$C|the parent mkdir comes back|      local parent = fs_path.parent(new_path)\n      if not fs_path.is_dir(parent) then|      local parent = fs_path.parent(new_path)\n      vim.fn.mkdir(parent, \"p\")\n      if not fs_path.is_dir(parent) then"
  "$V|$C|neither exists: the panel makes the directory|    else\n      require(\"auto-finder.log\").error(\"view.todos\",\n        \"migrate: neither \"|    else\n      vim.fn.mkdir(new_path, \"p\"); action = \"switch_only\"\n    end\n    if false then\n      require(\"auto-finder.log\").error(\"view.todos\",\n        \"migrate: neither \""
  "$V|$C|a scaffold write after a status change comes back|      store.follow(row.task, task)|      store.follow(row.task, task)\n      require(\"auto-core.fs.atomic\").write(task.file_path, \"scaffold\\\\n\")"
  "$V|$C|the promote-to-automated hook comes back|\nreturn M\n|\nrequire(\"auto-core.events\").subscribe(\"core.todo.status:changed\", function(p)\n  if p and p.to == \"automated\" then\n    local t = M._by_id and M._by_id[p.id]\n    if t then require(\"auto-core.fs.atomic\").write(t.file_path, \"defaults\\\\n\") end\n  end\nend)\nreturn M\n"
  "$D|$C|the message names the wrong auto-core (v0.3.4)|M.NEEDS_AUTOCORE = \"the todos panel needs auto-core v0.4.0 or later|M.NEEDS_AUTOCORE = \"the todos panel needs auto-core v0.3.4 or later"
  "$V|$C|automated is offered again|local STATUS_CHOICES = { \"open\", \"in-progress\", \"completed\", \"deferred\", \"archived\" }|local STATUS_CHOICES = { \"open\", \"in-progress\", \"automated\", \"completed\", \"deferred\", \"archived\" }"
  "$V|$S|A follows the assignment with its own status call|        local moved = row.task.status == \"open\" and assigned.status == \"in-progress\"|        local moved = row.task.status == \"open\" and assigned.status == \"in-progress\"\n        store.mutate(\"status\", assigned, { \"in-progress\" }, function() end)"
  "$D|$C|a write re-reads the rev (the stale guard is lost)|  local args = { task.id, task.rev }|  if not task._fresh then\n    return M.call(\"get\", { task.id }, function(cur)\n      M.mutate(verb, vim.tbl_extend(\"force\", task, { rev = cur and cur.rev, _fresh = true }), extra, cb)\n    end)\n  end\n  local args = { task.id, task.rev }"
  "$V|$C|AutoDoc missing: no \"AutoDoc required\" screen|    _show_message(bufnr, M.REQUIRED_LINES(why))|    _show_message(bufnr, { \"Loading todos…\" })"
  "$V|$S|D2: the workspace fallback for relative refs comes back|  local kb = _kb_root()|  local ws = require(\"auto-core.todo.where\").root() .. \"/\" .. ref\n  if vim.fn.filereadable(ws) == 1 then return ws end\n  local kb = _kb_root()"
  "$D|$C|open buffers stay on the old path|    pcall(buffers.retarget, from, to)|    local _ = buffers"
  "$D|$C|add re-resolves the project for the scaffold|      return M.call_at(ctx, \"scaffold\", {}, function(_, serr)|      return M.call(\"scaffold\", {}, function(_, serr)"
  "$D|$C|a load re-resolves the project for its months|      M.call_at(snap.ctx, \"list\", { { buckets = { \"archived\" } } }, function(months, merr)|      M.call(\"list\", { { buckets = { \"archived\" } } }, function(months, merr)"
  "$D|$C|set_dir resolves the project root after its wait|    M.context(function(_, cerr) cb(cerr == nil, cerr) end, root)|    M.context(function(_, cerr) cb(cerr == nil, cerr) end)"
  "$T|$A|the review attach writes after a project switch (Lector #68 r0 P2)|      if store.dir() ~= listed then|      if false then"
)

killed=0; survived=0; broken=0; i=0
for m in "${mutants[@]}"; do
  file="${m%%|*}"; rest="${m#*|}"
  suite="${rest%%|*}"; rest="${rest#*|}"
  name="${rest%%|*}"; rest="${rest#*|}"
  old="${rest%%|*}"; new="${rest#*|}"
  i=$((i + 1)); dir="$(copy "m$i")"
  if ! python3 - "$dir/$file" "$old" "$new" <<'PY'
import sys
p = sys.argv[1]
old = sys.argv[2].replace("\\n", "\n")
new = sys.argv[3].replace("\\n", "\n")
s = open(p).read()
n = s.count(old)
if n != 1:
    print(f"    mutation matched {n} times"); sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  then
    echo "NOT APPLIED  $name"; broken=$((broken + 1)); continue
  fi
  out="$(run_suite "$dir" "$suite")"
  if red "$out"; then
    echo "KILLED       $name ($(basename "$suite"): $(summary_of "$out"))"
    printf '%s\n' "$out" | grep -oE '  FAIL  .*' | head -3 | cut -c1-160 | sed 's/^/               /'
    killed=$((killed + 1))
  else
    echo "SURVIVED     $name ($(basename "$suite"))"; survived=$((survived + 1))
  fi
  rm -rf "$dir"
done
echo "mutants: $killed killed, $survived survived, $broken not applied"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
