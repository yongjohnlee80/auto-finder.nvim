#!/usr/bin/env bash
# .github/install-parsers.sh — build the tree-sitter parsers this suite needs.
#
# A GitHub runner's Neovim ships parsers for c, lua, vim, vimdoc, markdown and
# query only. Everything else is something a developer installed once and then
# stopped seeing. That is exactly how this dependency stayed invisible: the
# suite was green on every machine that had a Go parser lying around, and the
# first runner without one failed FIVE rendering cells while reporting the
# scan as "complete" — it completed, having found nothing.
#
# Built from source with cc rather than pulled from nvim-treesitter, so the
# grammar is pinned by commit like every other dependency here and no plugin
# manager has to run. Parsers with a scanner.c get it compiled in; omitting it
# yields a parser that loads and then mis-parses.
#
# LANGS is set by the workflow. Enumerate it from the ADAPTERS, not from the
# fixtures the tests happen to build: a language the code can dispatch to is a
# language CI has to be able to parse.
set -euo pipefail

: "${LANGS:?LANGS must be set (space-separated tree-sitter languages)}"
# Ask NEOVIM where its data dir is rather than assuming $HOME/.local/share.
# A runner has XDG_DATA_HOME unset so the two coincide there, but they do not
# on a machine that sets it — and installing a parser somewhere nvim does not
# look produces exactly the failure this script exists to prevent, with a
# green-looking install step in front of it. (install-deps.sh hardcodes the
# lazy path on purpose: the SUITES hardcode that literal, so matching them is
# the correct behaviour there. Different question, different answer.)
dest="$(nvim --headless -u NONE -c 'lua io.write(vim.fn.stdpath("data"))' -c q)/site/parser"
mkdir -p "$dest"
echo "parser dir: $dest"
src_root="${RUNNER_TEMP:-/tmp}/ts-grammars"
mkdir -p "$src_root"

# repo + ref + subdir per language. Pinned by commit for the same
# reproducibility reason as everything else in this workflow.
grammar_repo() {
  case "$1" in
    go)         echo "tree-sitter/tree-sitter-go|2346a3ab1bb3857b48b29d779a1ef9799a248cd7|." ;;
    javascript) echo "tree-sitter/tree-sitter-javascript|58404d8cf191d69f2674a8fd507bd5776f46cb11|." ;;
    typescript) echo "tree-sitter/tree-sitter-typescript|75b3874edb2dc714fb1fd77a32013d0f8699989f|typescript" ;;
    tsx)        echo "tree-sitter/tree-sitter-typescript|75b3874edb2dc714fb1fd77a32013d0f8699989f|tsx" ;;
    *) echo "unknown grammar: $1" >&2; exit 1 ;;
  esac
}

for lang in $LANGS; do
  IFS='|' read -r repo ref subdir <<< "$(grammar_repo "$lang")"
  clone="$src_root/$(basename "$repo")"
  if [ ! -d "$clone" ]; then
    git clone --filter=blob:none "https://github.com/$repo" "$clone"
    git -C "$clone" checkout "$ref"
  fi
  src="$clone/$subdir/src"
  files="$src/parser.c"
  [ -f "$src/scanner.c" ] && files="$files $src/scanner.c"
  cc -O2 -o "$dest/$lang.so" -shared -fPIC -I"$src" $files
  printf '  built %-11s %s bytes\n' "$lang.so" "$(stat -c%s "$dest/$lang.so")"
done

# Positive control. `test -f` would pass on a parser that cannot load — an ABI
# mismatch, a missing scanner — and a parser that fails to load produces the
# same empty tree as no parser at all, which is the failure this step exists to
# stop. So each one must actually PARSE.
echo "verifying each parser loads and parses:"
LANGS="$LANGS" nvim --headless -u NONE -c 'lua
local bad = {}
for lang in vim.gsplit(vim.env.LANGS, " ", { trimempty = true }) do
  local ok, p = pcall(vim.treesitter.get_string_parser, "", lang)
  local root = ok and p:parse()[1]:root()
  if not root then bad[#bad+1] = lang .. ": " .. tostring(p)
  else print(string.format("  %-11s -> %s", lang, root:type())) end
end
if #bad > 0 then
  io.stderr:write("FATAL: parsers did not load: " .. table.concat(bad, "; ") .. "\n")
  vim.cmd("cquit 1")
end
' -c q
