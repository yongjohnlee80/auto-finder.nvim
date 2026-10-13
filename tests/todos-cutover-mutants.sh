#!/usr/bin/env bash
# tests/todos-cutover-mutants.sh — every write the todo cutover replaced
# (ADR 1791532020 §3 step 3) must be load-bearing in its suite: a direct write
# coming back, or an auto-core.todo call dropped, must turn a cell red.
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
for s in tests/todos-cutover.lua tests/smoke.lua; do
  out="$(run_suite "$base" "$s")"
  if red "$out"; then echo "BASELINE NOT GREEN ($s): $(summary_of "$out")"; printf '%s\n' "$out" | grep FAIL; exit 1; fi
  echo "baseline $s: $(summary_of "$out")"
done

V=lua/auto-finder/views/todos/init.lua
C=tests/todos-cutover.lua
S=tests/smoke.lua
# file|suite|name|old|new — literal strings; old must occur exactly once.
mutants=(
  "$V|$C|the malformed unlink comes back|local pcall_ok, removed, err = pcall(todo_m.remove_malformed, row.filepath)|local pcall_ok, removed, err = pcall(vim.uv.fs_unlink, row.filepath)"
  "$V|$C|remove_malformed is not called|local pcall_ok, removed, err = pcall(todo_m.remove_malformed, row.filepath)|local pcall_ok, removed, err = true, true, nil"
  "$V|$C|an older auto-core falls back to the unlink|      require(\"auto-finder.log\").error(\"view.todos\", M.NEEDS_AUTOCORE)\n      return\n    end\n    local choice|      vim.uv.fs_unlink(row.filepath)\n      return\n    end\n    local choice"
  "$V|$C|the store rename comes back|      okm, merr = pcall(todo.move_store, new_path)|      okm, merr = pcall(vim.uv.fs_rename, current, new_path)"
  "$V|$C|move_store is not called (switch instead)|      okm, merr = pcall(todo.move_store, new_path)|      okm, merr = pcall(todo.set_todo_dir, new_path)"
  "$V|$C|the parent mkdir comes back|      local parent = fs_path.parent(new_path)\n      if not fs_path.is_dir(parent) then|      local parent = fs_path.parent(new_path)\n      vim.fn.mkdir(parent, \"p\")\n      if not fs_path.is_dir(parent) then"
  "$V|$C|neither exists: the panel makes the directory|    else\n      require(\"auto-finder.log\").error(\"view.todos\",\n        \"migrate: neither \"|    else\n      vim.fn.mkdir(new_path, \"p\"); action = \"switch_only\"\n    end\n    if false then\n      require(\"auto-finder.log\").error(\"view.todos\",\n        \"migrate: neither \""
  "$V|$C|a scaffold write after a status change comes back|        \"status failed: \" .. tostring(err_str))\n      return\n    end|        \"status failed: \" .. tostring(err_str))\n      return\n    end\n    require(\"auto-core.fs.atomic\").write(task_or_err.file_path, \"scaffold\\\\n\")"
  "$V|$C|the promote-to-automated hook comes back|\nreturn M\n|\nrequire(\"auto-core.events\").subscribe(\"core.todo.status:changed\", function(p)\n  if p and p.to == \"automated\" then\n    local t = require(\"auto-core.todo\").get(p.id)\n    if t then require(\"auto-core.fs.atomic\").write(t.file_path, \"defaults\\\\n\") end\n  end\nend)\nreturn M\n"
  "$V|$C|automated is offered again|local STATUS_CHOICES = { \"open\", \"in-progress\", \"completed\", \"deferred\", \"archived\" }|local STATUS_CHOICES = { \"open\", \"in-progress\", \"automated\", \"completed\", \"deferred\", \"archived\" }"
  "$V|$S|A follows the assignment with its own status call|      local moved = row.task.status == \"open\" and assigned.status == \"in-progress\"|      local moved = row.task.status == \"open\" and assigned.status == \"in-progress\"\n      todo.status(row.task.id, \"in-progress\")"
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
