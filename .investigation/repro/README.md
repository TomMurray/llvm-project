# Standalone reproducer

Self-contained fixture that triggers the `ModuleMap` extern-path accumulation
bug described in `../README.md`.

## Quick start

```bash
./run.sh /path/to/clang++
```

Pre-fix clang: exits `1`, prints
```
<stdin>:1:10: error: module +llvm_project_overlay+llvm-project//lld:ELF does
  not depend on a module exporting 'llvm/Support/Compiler.h'
```
Post-fix clang: exits `0`, silent.

## What's in `fixture/`

Real Bazel-generated cppmaps, copied from a Fractile monorepo build
(`@llvm_project_overlay//lld:ELF`-targeted compile, macOS-arm64 exec config).
Content was not scrubbed — the absolute-looking paths inside are all relative
to `fixture/` and resolve within it.

```
fixture/
├─ bazel-out/darwin_arm64-opt-exec-ST-<hash>/bin/external/+llvm_project_overlay+llvm-project/
│  ├─ lld/
│  │  ├─ ELF.cppmap           # `fmodule-name=` target; use Support + Common
│  │  └─ Common.cppmap        # extern Support + CodeGen + ~10 others
│  └─ llvm/
│     ├─ Support.cppmap       # declares textual header "llvm/Support/Compiler.h"
│     ├─ CodeGen.cppmap        # needed for the chain-depth to reach PATH_MAX
│     ├─ BinaryFormat.cppmap   # ditto
│     ├─ BinaryFormatELF.cppmap
│     └─ A*.cppmap             # AArch64*, ABI, Analysis, AllTargets*, AsmParser
└─ external/+llvm_project_overlay+llvm-project/llvm/include/llvm/Support/
   └─ Compiler.h              # empty stub (#pragma once)
```

The bisection log in `../README.md §Appendix` explains why *all* of those
cppmaps have to be on disk: fewer than this, and the chain of `extern module`
loads doesn't get deep enough to push the accumulated path over PATH_MAX.

Only `Compiler.h` needs real content (empty stub is fine); other textual
headers declared in the real cppmaps do not exist in the fixture — their
individual `resolveHeader` calls fail silently, which doesn't matter.

Headers referenced by our TU (`#include "llvm/Support/Compiler.h"`) resolve
via `-isystem external/+llvm_project_overlay+llvm-project/llvm/include`.

## Reproduction constraints

- **macOS-only.** The trigger is `stat()` failing with `ENAMETOOLONG` once
  the accumulated path exceeds `PATH_MAX=1024`. Linux's `PATH_MAX=4096` is
  not reached by this fixture. To reproduce on Linux, deepen the fixture
  dirname (e.g. add ~1000 chars of padding under `bazel-out/...`).
- **Cwd length sensitive.** Verified to reproduce from
  `/Users/tom/Development/llvm-project-fork/.investigation/repro/fixture`
  (70 chars). If you check this out under a much shorter cwd (e.g. `/a/b/`),
  the bug may *not* trigger — pad via symlink:
  ```bash
  ln -s $(pwd)/fixture /tmp/padding_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/fixture
  cd /tmp/padding_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/fixture
  ```
  (The script does NOT auto-pad, to avoid hiding the real failure mode.)

## Minimal failing clang invocation

For reference, the essential bits:

```bash
cd fixture/
LLD=bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/lld
LLVM=bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/llvm

clang++ -xc++ -fsyntax-only \
  -isystem external/+llvm_project_overlay+llvm-project/llvm/include \
  -Xclang "-fmodule-name=+llvm_project_overlay+llvm-project//lld:ELF" \
  -Xclang -fmodule-map-file=$LLD/ELF.cppmap \
  -Xclang -fmodule-map-file=$LLVM/Support.cppmap \
  -fmodules-strict-decluse \
  -x c++ - <<<'#include "llvm/Support/Compiler.h"'
```

Note: other cppmaps (Common, CodeGen, BinaryFormat\*, A\*) are NOT passed on the
command line — they're picked up via the chained `extern module` declarations
inside `ELF.cppmap` → `Common.cppmap` → ... Their presence on disk is what
expands the accumulator enough to exceed PATH_MAX.

## What a successful repro proves

1. `findHeader` inside `ModuleMap::resolveHeader` returns `std::nullopt` for
   Support's textual header `llvm/Support/Compiler.h` (due to path length).
2. `Compiler.h` therefore never lands in `ModuleMap::Headers[FileEntry]`.
3. During TU compile, `findKnownHeader` misses; `diagnoseHeaderInclusion`
   falls into the strict-decluse branch; error is emitted.

Instrumenting clang with printfs at `findHeader`, `addHeader`,
`findKnownHeader`, and the strict-decluse diagnostic confirms this — see
`../README.md §Trace evidence`.
