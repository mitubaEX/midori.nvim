#!/usr/bin/env bash
# midori.nvim test runner — 3-stage: luac syntax / stylua format / nvim behavior.
set -u
cd "$(dirname "$0")/.." || exit 2
REPO="$PWD"
fail=0

echo "== 00-static: luac -p (syntax) =="
while IFS= read -r f; do
  if luac -p "$f"; then
    echo "  ok  - $f"
  else
    echo "  FAIL- $f"
    fail=1
  fi
done < <(find lua plugin tests -name '*.lua' -type f | sort)

echo "== 00-static: stylua --check (format) =="
if command -v stylua >/dev/null 2>&1; then
  if stylua --check .; then
    echo "  ok  - stylua format clean"
  else
    echo "  FAIL- stylua format"
    fail=1
  fi
else
  echo "  skip - stylua not installed"
fi

echo "== behavior: nvim --headless =="
if nvim --headless -u NONE -l tests/behavior.lua; then
  echo "  ok  - behavior suite"
else
  echo "  FAIL- behavior suite"
  fail=1
fi

echo "== result: RUN_EXIT=$fail =="
exit $fail
