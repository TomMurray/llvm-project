#!/usr/bin/env bash
# Standalone reproducer for clang `ModuleMap` extern-path accumulation bug.
#
# See ../README.md for the full investigation. TL;DR: chained `extern module`
# loads in cppmaps accumulate `../../..` segments unboundedly; on macOS the
# path given to `stat()` for a textual header inside a transitive dep exceeds
# PATH_MAX=1024, the header fails to register in the Module's Headers map,
# and -fmodules-strict-decluse later fires a false err_undeclared_use_of_module.
#
# Usage:
#   ./run.sh               # uses `clang++` from PATH
#   ./run.sh /path/to/clang++
#
# Expected:
#   Pre-fix:  exit 1, prints
#             error: module ...lld:ELF does not depend on a module exporting
#                    'llvm/Support/Compiler.h'
#   Post-fix: exit 0, no output.
#
# Requirements:
#   - macOS (PATH_MAX=1024). Linux has PATH_MAX=4096; this exact fixture does
#     not exceed that, so the bug won't trigger. To reproduce on Linux, inflate
#     the fixture dirname prefix (e.g. deepen `bazel-out/<longname>/bin/...`).
#   - cwd path <= ~90 chars. If the fixture is checked out into a cwd that
#     pushes the accumulated path well beyond 1024, this still reproduces;
#     if cwd is much shorter than ~60 chars the bug may *not* trigger.
#     Script sanity-checks by computing the failing path length up-front.

set -e

CLANG="${1:-clang++}"
if ! command -v "$CLANG" >/dev/null 2>&1; then
  echo "clang not found: $CLANG" >&2
  echo "Pass the path to clang++ as the first argument." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/fixture"

if [[ ! -d "$FIXTURE" ]]; then
  echo "missing fixture dir: $FIXTURE" >&2
  exit 2
fi

LLD_REL="bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/lld"
LLVM_REL="bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/llvm"

cd "$FIXTURE"

"$CLANG" -xc++ -fsyntax-only \
  -isystem external/+llvm_project_overlay+llvm-project/llvm/include \
  -Xclang "-fmodule-name=+llvm_project_overlay+llvm-project//lld:ELF" \
  -Xclang -fmodule-map-file="$LLD_REL/ELF.cppmap" \
  -Xclang -fmodule-map-file="$LLVM_REL/Support.cppmap" \
  -fmodules-strict-decluse \
  -x c++ - <<<'#include "llvm/Support/Compiler.h"'

rc=$?
if [[ "$rc" -eq 0 ]]; then
  echo "[repro] clang exited 0 — bug NOT reproduced (fix in place, or path under PATH_MAX)."
else
  echo "[repro] clang exited $rc — bug reproduced."
fi
exit "$rc"
