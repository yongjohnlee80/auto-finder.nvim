#!/usr/bin/env bash
# tests/bench/run.sh — the files slot before (the retired fork) and after (ADR-0200), one driver, one fixture.
#
#   tests/bench/run.sh <work-dir>
#
# Run on VM43 from the worktree root. Clones the BEFORE tree (auto-finder at $BEFORE_REF with auto-core at
# $BEFORE_CORE_REF, the fork's CI pin) into <work-dir>, uses THIS worktree plus its auto-core sibling as the
# AFTER tree, builds a fresh identical fixture for each run, runs tests/bench/files-panel.lua under both, and
# writes <work-dir>/RESULTS.md (the table checked in as tests/bench/RESULTS.md).
set -euo pipefail
cd "$(dirname "$0")/../.."
AFTER="$PWD"
W="${1:?usage: tests/bench/run.sh <work-dir>}"
BEFORE_REF="${BEFORE_REF:-b6f2b11}"
BEFORE_CORE_REF="${BEFORE_CORE_REF:-5bba92e0bbcf46dc9f486373958f06dd7803627c}"
AFTER_CORE="${AFTER_CORE:-$(dirname "$(dirname "$AFTER")")/auto-core.nvim/$(basename "$AFTER")}"
RUNS="${RUNS:-3}"
mkdir -p "$W"

clone_at() { # clone_at <url> <dest> <ref>
  [ -d "$2" ] || git clone -q "$1" "$2"
  git -C "$2" fetch -q origin
  git -C "$2" checkout -q "$3"
}
clone_at https://github.com/yongjohnlee80/auto-finder.nvim "$W/before/auto-finder" "$BEFORE_REF"
clone_at https://github.com/yongjohnlee80/auto-core.nvim "$W/before/auto-core" "$BEFORE_CORE_REF"
[ -d "$AFTER_CORE/lua/auto-core/fs" ] || { echo "no auto-core at $AFTER_CORE"; exit 1; }

# Fixture: 4 git repos, each 10 × 10 × 10 directories (1,111 per repo) with 8 files per leaf and 2 per inner
# directory (~33k files, ~4.4k directories), a 2,000-file node_modules and a 500-file build/ in repo1.
make_tree() {
  rm -rf "$1"
  python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]
def touch(p):
    with open(p, "w") as f: f.write(os.path.basename(p) + "\n")
for r in range(1, 5):
    repo = f"{root}/repo{r}"
    for i in range(1, 11):
        for j in range(0, 11):
            for k in range(0, 11):
                if j == 0 and k > 0: continue
                d = f"{repo}/d{i}" + (f"/d{i}_{j}" if j else "") + (f"/d{i}_{j}_{k}" if k else "")
                os.makedirs(d, exist_ok=True)
                for n in range(1, (9 if k else 3)):
                    touch(f"{d}/f{n}.txt")
    touch(f"{repo}/README.md")
os.makedirs(f"{root}/repo1/node_modules/pkg", exist_ok=True)
for n in range(2000): touch(f"{root}/repo1/node_modules/pkg/m{n}.js")
os.makedirs(f"{root}/repo1/build", exist_ok=True)
for n in range(500): touch(f"{root}/repo1/build/o{n}.o")
with open(f"{root}/repo1/.gitignore", "w") as f: f.write("node_modules/\nbuild/\n")
PY
  local r
  for r in 1 2 3 4; do
    git -C "$1/repo$r" init -q -b main
    git -C "$1/repo$r" -c user.email=b@example.invalid -c user.name=bench add -A
    git -C "$1/repo$r" -c user.email=b@example.invalid -c user.name=bench commit -qm fixture
  done
  git -C "$1" init -q -b main   # the workspace itself is a repo too, as a project parent often is
}

for run in $(seq 1 "$RUNS"); do
  for mode in before after; do
    tree="$W/tree"
    make_tree "$tree"
    if [ "$mode" = before ]; then plugin="$W/before/auto-finder"; core="$W/before/auto-core"
    else plugin="$AFTER"; core="$AFTER_CORE"; fi
    echo "── run $run: $mode ($(git -C "$plugin" rev-parse --short HEAD 2>/dev/null || echo staged), auto-core $(git -C "$core" rev-parse --short HEAD 2>/dev/null || echo staged))"
    AF_BENCH_PLUGIN="$plugin" AF_BENCH_AUTO_CORE="$core" AF_BENCH_MODE="$mode" AF_BENCH_TREE="$tree" \
      AF_BENCH_OUT="$W/$mode-$run.json" timeout 600 nvim --headless -u NONE -l "$AFTER/tests/bench/files-panel.lua"
  done
done

python3 - "$W" "$RUNS" <<'PY' > "$W/RESULTS.md"
import json, sys, statistics
w, runs = sys.argv[1], int(sys.argv[2])
data = {m: [json.load(open(f"{w}/{m}-{i}.json")) for i in range(1, runs + 1)] for m in ("before", "after")}
names = [s["name"] for s in data["before"][0]["scenarios"]]
def med(mode, name, key):
    vals = []
    for r in data[mode]:
        for s in r["scenarios"]:
            if s["name"] == name: vals.append(s["r"][key])
    return int(statistics.median(vals))
print(f"Medians of {runs} runs. Each row is one scenario; each cell is before → after.\n")
print("| scenario | dir reads | entries examined | git subprocesses | live watches | ms |")
print("|---|---|---|---|---|---|")
for n in names:
    cells = [f"{med('before', n, k):,} → {med('after', n, k):,}" for k in ("dir_opens", "entries", "git", "watches", "ms")]
    print(f"| {n} | " + " | ".join(cells) + " |")
errs = [(m, s["name"], s["r"]["error"]) for m in data for r in data[m] for s in r["scenarios"] if s["r"].get("error")]
if errs:
    print("\nErrors:\n")
    for m, n, e in errs: print(f"- {m} / {n}: `{e}`")
PY
cat "$W/RESULTS.md"
