# Standalone reproducer

Self-contained fixture that triggers the `ModuleMap` extern-path accumulation
bug described in `../README.md`.

## Quick start

```bash
./run.sh /path/to/clang++
```

Pre-fix clang: exits `1`, prints
```
<stdin>:1:10: error: module ELF does not depend on a module exporting
  'llvm/Support/Compiler.h'
```
Post-fix clang: exits `0`, silent.

## Minimal fixture (8 cppmaps, 33 lines total)

Linear chain of `extern module` loads — each cppmap in the chain is ~4 lines
(module decl + `export *` + one extern to the next link):

```
ELF → Common → CodeGen → AggressiveInstCombine →
  Analysis → BinaryFormat → BinaryFormatELF → Support
```

- `ELF.cppmap` is the target (`-fmodule-name=ELF`); declares `use "Support"`
  so post-fix compile succeeds.
- `Support.cppmap` is the chain terminal; declares the single `textual header`
  for `Compiler.h` that *should* be registered but fails to register pre-fix.
- Intermediate modules `Common`/`CodeGen`/etc. have nothing but an `export *`
  plus a single `extern module` pointing to the next link. Their sole purpose
  is to inflate the path accumulator one more hop.

```
fixture/
├─ bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/
│  ├─ lld/{ELF,Common}.cppmap
│  └─ llvm/{CodeGen,AggressiveInstCombine,Analysis,
│            BinaryFormat,BinaryFormatELF,Support}.cppmap
└─ external/+llvm_project_overlay+llvm-project/llvm/include/llvm/Support/
   └─ Compiler.h       # empty stub
```

The directory layout — specifically the length of
`bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/<pkg>/`
— preserves the per-hop path-growth from real Bazel output (~130 chars per
extern-chain step). **Do not shorten it**; doing so drops the accumulator
below `PATH_MAX=1024` and the bug stops reproducing.

## Chain mechanics (why 7 hops are needed)

Clang's `ModuleMap::handleExternModuleDecl` concatenates
`Directory.getName() + EMD.Path` without `llvm::sys::path::remove_dots`.
Each nested cppmap load therefore stores a `FileEntry->Dir` with one more
unresolved `../../../../../../` segment than the previous level.

Per-hop path growth in this fixture:
```
hop 0 (ELF)           Dir ≈ 169 chars   (cwd + bazel-out/…/lld)
hop 1 (Common)        Dir ≈ 287        +118
hop 2 (CodeGen)           ≈ 405
hop 3 (AggressiveIC)      ≈ 523
hop 4 (Analysis)          ≈ 641
hop 5 (BinaryFormat)      ≈ 759
hop 6 (BinaryFormatELF)   ≈ 877
hop 7 (Support)           ≈ 995
+ textual header path     ≈ +100 chars
                           = ≈ 1095 chars  >  PATH_MAX (1024)
```

At this point, `findHeader`'s `getFileRef` calls `stat()` on a 1095-char
path; Darwin returns `ENAMETOOLONG` (errno 63). The textual header
`Compiler.h` never registers in `Support` module's `Headers` map. Later,
when the TU does `#include "llvm/Support/Compiler.h"` via the short
`-isystem` path, `findKnownHeader` misses and `-fmodules-strict-decluse`
fires `err_undeclared_use_of_module`.

## Reproduction constraints

- **macOS-only.** Linux's `PATH_MAX=4096`; the 1095-char path doesn't hit
  `ENAMETOOLONG` there, so the bug does not trigger. To reproduce on Linux,
  extend the chain to ~25 hops, or inflate dir names by ~300 chars.
- **Cwd length sensitive.** Verified to reproduce from
  `~/Development/llvm-project-fork/.investigation/repro/fixture` (69 chars).
  A much shorter cwd (e.g. `/a/`) may fall below the 1024 threshold even
  at 7 hops. Symlink-pad if needed:
  ```bash
  ln -s $PWD/fixture /tmp/padding_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/fixture
  cd /tmp/padding_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/fixture
  ```

## Minimal failing clang invocation

```bash
cd fixture/
LLD=bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/lld
LLVM=bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/llvm

clang++ -xc++ -fsyntax-only \
  -isystem external/+llvm_project_overlay+llvm-project/llvm/include \
  -Xclang -fmodule-name=ELF \
  -Xclang -fmodule-map-file=$LLD/ELF.cppmap \
  -Xclang -fmodule-map-file=$LLVM/Support.cppmap \
  -fmodules-strict-decluse \
  -x c++ - <<<'#include "llvm/Support/Compiler.h"'
```

Only `ELF.cppmap` and `Support.cppmap` are on the command line; the other
six cppmaps are loaded via the chained `extern module` declarations starting
inside `ELF.cppmap`.

## What a successful repro proves

Pre-fix behavior trace (requires instrumented clang — see `../README.md`):
```
[TRACE findHeader] Mod='Support'
  Directory='.../lld/../../.../lld/../../.../llvm/.../...' (len ≈ 995)
  Header.FileName='../../../../../../external/.../Compiler.h'
  FullPathName (len ≈ 1095) = '...'
  GetFile result = NULL      ← stat ENAMETOOLONG
[TRACE diagnose:STRICT_FIRE] Requesting='ELF' Filename='llvm/Support/Compiler.h'
```

Post-fix: `FullPathName` collapses to ~275 chars via `remove_dots` inside
`handleExternModuleDecl`, `GetFile` succeeds, `addHeader` registers Compiler.h
in Support, `findKnownHeader` hits, diagnostic doesn't fire.
