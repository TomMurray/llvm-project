# Clang `extern module` Path Explosion Bug (macOS layering_check)

Investigation notes for the `err_undeclared_use_of_module` false-positive that forced
us to patch out `features = ["layering_check"]` on `@llvm_project_overlay//clang` and
`@llvm_project_overlay//lld` in `third_party/patches/llvm/01-disable-layering-check.patch`.

## Summary

Clang's `ModuleMap` loader accumulates un-normalised `../../../../../../` segments
across chained `extern module` loads. With Bazel-generated `.cppmap` files, the
accumulated path for the transitive root (e.g. `llvm:Support`) eventually exceeds
Darwin's `PATH_MAX = 1024` bytes when a `textual header` inside it is resolved.
`stat()` returns `ENAMETOOLONG` (errno 63). The header fails to register. Later,
when user code does `#include "llvm/Support/Compiler.h"`, `findKnownHeader` misses
and `-fmodules-strict-decluse` fires `err_undeclared_use_of_module`.

**This is a Clang bug, not a Bazel / toolchains_llvm misconfiguration.** Fix is
one line in `clang/lib/Lex/ModuleMap.cpp`.

Related upstream ticket: <https://github.com/llvm/llvm-project/issues/147220>
(same class, different reporter, not yet root-caused upstream).

## Reproducer

### Minimal (requires Bazel execroot)

The trigger requires enough cppmaps on disk that extern chains go 5+ levels deep.
Fully synthetic repros in `/tmp/` don't fire because path depths stay short.

Exact steps against our monorepo on macOS:

```bash
# 1. Unpatch llvm layering_check (keeping our patch = Band-Aid)
sed -i '' 's|#"//third_party/patches:llvm/01-disable-layering-check.patch"|"//third_party/patches:llvm/01-disable-layering-check.patch"|' MODULE.bazel

# 2. Run the failing compile to prime the bazel-out tree
bazel build --verbose_failures //build_tools/toolchains/friscv/... 2>&1 | tail -30
# → error: module ...lld:ELF does not depend on a module exporting 'llvm/Support/Compiler.h'
```

### Reduced standalone repro (still needs the real cppmaps on disk)

```bash
BASE=$(bazel info execution_root)
LLD=$BASE/bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/lld

cat > "$LLD/MINREPRO.cppmap" <<'EOF'
module "+llvm_project_overlay+llvm-project//lld:ELF" {
  use "+llvm_project_overlay+llvm-project//llvm:Support"
  use "+llvm_project_overlay+llvm-project//lld:Common"
}
extern module "+llvm_project_overlay+llvm-project//lld:Common" "../../../../../../bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/lld/Common.cppmap"
EOF

cd "$BASE" && <llvm_toolchain>/bin/clang++ \
  -xc++ -fsyntax-only \
  -isystem external/+llvm_project_overlay+llvm-project/llvm/include \
  -Xclang "-fmodule-name=+llvm_project_overlay+llvm-project//lld:ELF" \
  -Xclang -fmodule-map-file=$LLD/MINREPRO.cppmap \
  -Xclang -fmodule-map-file=bazel-out/darwin_arm64-opt-exec-ST-7983c0098c7c/bin/external/+llvm_project_overlay+llvm-project/llvm/Support.cppmap \
  -fmodules-strict-decluse \
  -x c++ - <<<'#include "llvm/Support/Compiler.h"'
```

### Triggering conditions empirically confirmed

| Condition                                                                        | Effect                     |
| -------------------------------------------------------------------------------- | -------------------------- |
| ELF extern Common, Common extern Support, Support+ELF on cmdline                 | **fail**                   |
| Only ELF extern Support directly (1-level chain)                                 | pass                       |
| Support.cppmap first on cmdline (loads via short path), then ELF                 | pass                       |
| Absolute paths in `extern module`                                                | pass                       |
| Remove all `extern module` lines from ELF.cppmap                                 | pass                       |
| Execroot substring `/private/var/tmp/_bazel_tom/<hash>/execroot/_main` shortened | pass                       |
| Full `A*.cppmap + BinaryFormat + CodeGen + Support` on disk, rest absent         | fail only with all present |

Last row: the bug depends on an extern-chain depth threshold — remove enough cppmaps
from disk and the chained load can't descend far enough to inflate paths past 1024 chars.

## Root cause

`clang/lib/Lex/ModuleMap.cpp::ModuleMapLoader::handleExternModuleDecl` (line 1895
on `c3e7f9899750`):

```cpp
void ModuleMapLoader::handleExternModuleDecl(
    const modulemap::ExternModuleDecl &EMD) {
  StringRef FileNameRef = EMD.Path;
  SmallString<128> ModuleMapFileName;
  if (llvm::sys::path::is_relative(FileNameRef)) {
    ModuleMapFileName += Directory.getName();
    llvm::sys::path::append(ModuleMapFileName, EMD.Path);
    // BUG: no remove_dots() here — `..` segments accumulate forever
    FileNameRef = ModuleMapFileName;
  }
  if (auto File = SourceMgr.getFileManager().getOptionalFileRef(FileNameRef))
    Map.parseAndLoadModuleMapFile(
        *File, ..., File->getDir(), ...);
}
```

Chain of events that produces a 1106-char path:

1. Bazel writes cppmaps under `bazel-out/<cfg>/bin/external/<repo>/<pkg>/*.cppmap`.
   Every `extern module "X" "PATH"` Bazel emits uses a relative path of form
   `../../../../../../bazel-out/<cfg>/bin/external/<repo>/<pkg>/X.cppmap`
   (six `..` to climb from the cppmap's dir up to the execroot).
2. `ELF.cppmap` is loaded via cmdline `-fmodule-map-file=`. `Directory.getName()` = short.
3. Its `extern module "lld:Common"` triggers. Joined path = `ELF_dir + "../../../../../../..."`.
   `llvm::sys::path::append` concatenates literally — **no dot-dot collapsing**.
4. `getOptionalFileRef(Joined)` stats. Stat follows `..` at kernel level, file found.
   A new `FileEntry` is cached. Its `Dir` is `parent_path(Joined)` = still un-normalised.
5. `Common.cppmap` is loaded with `Dir` = that un-normalised path (e.g. 2 dot-segments).
6. Common's `extern module "llvm:Support"` fires. New joined path = Common's un-normalised
   dir + `../../../../../../bazel-out/...`. Three dot-segments now.
7. Repeat for Common's ~10 other externs, each referencing already-loaded dependencies
   via their own chain paths. Recursion unwinds, but each new FileEntry gets its `Dir`
   stored with however many `..` segments accumulated at first visit.
8. By the time `llvm:Support`'s `textual header "../../../../../../external/.../Compiler.h"`
   is resolved, `M->Directory.getName()` is **1007 chars** (five lld/llvm dot-segment
   bounces). `findHeader` appends textual header's own six `..` → **1106 chars**.
9. macOS `stat()` returns ENAMETOOLONG. `getFileRef` returns `nullopt`.
10. `resolveHeader` falls to the `else { Mod->MissingHeaders.push_back(Header); }`
    branch. `Compiler.h` never enters `Headers[FileEntryRef]`.
11. During compile of the TU, `#include "llvm/Support/Compiler.h"` resolves via
    short `-isystem` path. `FileManager` dedups by UniqueID → same `FileEntry`.
    `findKnownHeader(File)` → `Headers.find(File)` → **miss** (never registered).
12. `diagnoseHeaderInclusion` falls through to the strict-decluse branch:
    `err_undeclared_use_of_module`.

### Trace evidence (instrumented clang)

Build instrumented clang:

```bash
cd ~/Development/llvm-project && mkdir -p build && cd build
cmake -G Ninja ../llvm \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS='clang' \
  -DLLVM_TARGETS_TO_BUILD='AArch64' \
  -DLLVM_ENABLE_ASSERTIONS=ON
ninja clang  # takes ~20 min first time
```

Instrumentation points added to `clang/lib/Lex/ModuleMap.cpp`:

- `findKnownHeader`: log File pointer + name + MISS/HIT
- `addHeader`: log Mod + FileEntry + name
- `resolveHeader`: log `:add` (success) or `:FAIL` (findHeader returned null)
- `findHeader`: log `M->Directory.getName()`, `Header.FileName`, `FullPathName`, length, GetFile result
- `handleExternModuleDecl`: log CurDir_len, Joined_len, EMD.Path, resolved FileEntry
- `diagnoseHeaderInclusion` strict-fire: log Requesting, Filename, File ptr

(All gated on `.contains("Compiler.h")` or `.contains("Support")` to cut noise.)

Filter the pre-fix run:

```
[TRACE findHeader] Mod='+llvm_project_overlay+llvm-project//llvm:Support'
  Directory='.../lld/../../../../../../.../lld/../../../../../../.../llvm/.../...' (len=1007)
  Header.FileName='../../../../../../external/.../Compiler.h'
  FullPathName (len=1106) = '...'
  GetFile result = NULL

[TRACE resolveHeader:FAIL] Mod='...llvm:Support'
  FileName='../../../../../../external/.../Compiler.h' findHeader returned null

[TRACE findKnownHeader] File=0xc4d865738 name='external/.../Compiler.h'
  result=MISS (Headers.size=3454)     ← 6 of these

[TRACE diagnose:STRICT_FIRE] Requesting='...lld:ELF' Filename='llvm/Support/Compiler.h'
  File=0xc4d865738
```

Also confirmed:

- `addHeader` fires **0 times** for Compiler.h (never registered in any module).
- `handleExternModuleDecl` for Support.cppmap fires **48 times** across the build,
  all with same `FileEntry=0x80130b4d0` — dedup works at FileEntry level; what
  matters is the path used at **first** access.
- `CurDir_len` values: 888, 769 → Joined_len 1022, 903. Max Joined sits just under
  the kernel's 1024 limit, but when appended with another relative textual-header
  path inside, the combined result blows past 1024.

## Fix

One-line change in `clang/lib/Lex/ModuleMap.cpp`, inside `ModuleMapLoader::handleExternModuleDecl`:

```diff
   StringRef FileNameRef = EMD.Path;
   SmallString<128> ModuleMapFileName;
   if (llvm::sys::path::is_relative(FileNameRef)) {
     ModuleMapFileName += Directory.getName();
     llvm::sys::path::append(ModuleMapFileName, EMD.Path);
+    llvm::sys::path::remove_dots(ModuleMapFileName, /*remove_dot_dot=*/true);
     FileNameRef = ModuleMapFileName;
   }
```

Collapsing `..` before the stat prevents the joined path from carrying forward
the chain-accumulator into the `FileEntry`'s cached `Dir`, so subsequent nested
extern loads (and eventual textual-header resolution inside the loaded module)
stay short.

### Verification

With fix applied to `~/Development/llvm-project`, rebuilt `bin/clang`, reran the
reduced repro:

```
FullPathName (len=275) = '.../llvm/../../../../../../external/.../Compiler.h'
GetFile result = OK
```

Both minimal ELF.cppmap and real `@llvm_project_overlay//lld:ELF` cppmap now
compile cleanly with `-fmodules-strict-decluse`.

### Known safety considerations

- `llvm::sys::path::remove_dots` with `remove_dot_dot=true` is purely lexical;
  it does not consult the filesystem, so it cannot produce a file that the
  original `..`-full path couldn't (on Unix where `..` is defined lexically).
- Should not change behaviour for absolute paths (they bypass this branch).
- Could consider applying the same normalisation in `ModuleMap::findHeader`
  after its own `append` (line ~228) for defence in depth, but the one spot
  above is sufficient for this bug.
- LLVM's own test suite should be run before upstreaming
  (`clang/test/Modules`, in particular `strict-decluse.cpp`,
  `header-attribs.cpp`, `incomplete-module.m`).

## Files touched during investigation

- `~/Development/llvm-project/build/` — instrumented clang build (10-core, ~20 min
  initial; ~45 s per incremental rebuild of `clangLex` + link).
- `~/Development/llvm-project/clang/lib/Lex/ModuleMap.cpp` — fix is one line;
  instrumentation was all stripped. `git diff` should show only the `remove_dots`
  addition.
- `/tmp/trace.log` — sample instrumented run output.
- `/tmp/rr/`, `/tmp/mr[2-7]/` — scratch repros while bisecting.

Also verified as state: `/Users/tom/Development/monorepo/new-toolchain/MODULE.bazel`
has `"//third_party/patches:llvm/01-disable-layering-check.patch"` **commented out**
(restoring upstream layering_check on clang/lld). That's what surfaced the bug.

## Next steps

1. **Upstream PR** to `llvm/llvm-project`:

   - Commit the one-line fix.
   - Add a regression test under `clang/test/Modules/`: cppmap chain that, with a
     sufficiently long execroot/cwd, would blow past PATH_MAX on macOS. Probably
     easiest to shape as a `lit` test with long synthetic path segments.
   - Reference issue #147220 in the commit message.
   - CC reviewers from `clang/modules` ownership.

2. **Short-term monorepo rollout**:

   - Option A: **Keep the Band-Aid**. Uncomment the existing patch line in
     `MODULE.bazel`; wait for upstream fix to land and propagate to our
     `@llvm_project` version. Zero risk, zero engineering cost.
   - Option B: **Apply the clang fix as our own llvm patch**. Add
     `third_party/patches/llvm/02-remove-dots-in-extern-module.patch` containing
     the one-line diff against `clang/lib/Lex/ModuleMap.cpp`. Then remove
     `01-disable-layering-check.patch`. Re-enables layering_check for clang/lld.
     Slight risk of bitrot if llvm bumps.
   - Option C: drop `extern module` emission in Bazel's `CppModuleMapAction`
     (all cppmaps already come via `-fmodule-map-file=` on cmdline). Upstream
     Bazel change. Higher risk / blast radius. Not recommended.

   Recommended: **B** once the clang fix is verified to not break other layering
   tests on Linux (where PATH_MAX is 4096 and this bug wouldn't fire). Fall back
   to **A** if impatient for CI green.

3. **Regression test in our repo**: once layering_check is re-enabled, add a
   Bazel test that builds `@llvm_project_overlay//clang:serialization` in an
   exec configuration on macOS — that's the shortest failing path from our
   original bug report (`bazel test //build_tools/toolchains/friscv/...`).

## Followup actions (pick up from here)

These are the outstanding pieces of work to get this bug fixed upstream.

### 1. Build a standalone reproducer

Goal: a self-contained test case, checked in under `.investigation/repro/`,
that anyone can run without needing the Fractile monorepo's `bazel-out` tree.

Concrete artefacts to produce:

- `.investigation/repro/cppmaps/` — a minimal set of `.cppmap` files.
  Options:
  - (a) Copy + scrub the actual failing cppmaps
    (`@llvm_project_overlay//lld:ELF`, `//lld:Common`, `//llvm:Support`,
    `//llvm:CodeGen`, `//llvm:BinaryFormat`, `//llvm:BinaryFormatELF`, the
    ~15 `A*.cppmap` files — see bisection log below) and any headers they
    reference (subset of `llvm/include/llvm/Support/*.h` etc.).
  - (b) Synthesise cppmaps from scratch: a chain of ~10 modules `M0..M10`
    each with `extern module Mi+1 "../../../../../../path/Mi+1.cppmap"`,
    and a terminal module with many `textual header "../../../../../..."` decls.
    Less realistic but easier to own/bitrot-proof.
  - (c) Minimal script that simulates the Bazel cppmap emitter — writes a
    generated tree and then invokes clang. Probably best long-term form.
- `.investigation/repro/run.sh` — driver script: takes `$CLANG` and runs the
  failing invocation. Exits non-zero on repro success (so CI can gate).
- `.investigation/repro/README.md` — explains expected output pre-fix
  (`error: module ...lld:ELF does not depend on...`) vs post-fix (silent).

Important: the trigger is **cwd path length + cppmap tree depth** combined,
so the repro must either (i) run from a cwd >=50 chars like
`/private/var/tmp/.../execroot/_main`, or (ii) artificially pad cppmap
dir names so the chain-accumulator reaches >1024 chars even under `/tmp/`.
Purely-synthetic repros under `/tmp/` during this investigation did **not**
fire the bug — chain depth stayed too shallow. Would need to either (a)
extend chain depth with more intermediate modules, or (b) pad directory
names with `aaaaaa.../` segments to artificially inflate the accumulator.

### 2. Verify bug reproduces on llvm main

Known-repros on `c3e7f9899750` (the commit `~/Development/llvm-project` was
on during investigation — late 2024 pull). Need to confirm it still
reproduces on the current fork checkout (`9435160a040b` as of branching,
close to head-of-main).

Steps:

1. Build plain clang from this fork:
   ```bash
   cd ~/Development/llvm-project-fork && mkdir -p build && cd build
   cmake -G Ninja ../llvm \
     -DCMAKE_BUILD_TYPE=Release \
     -DLLVM_ENABLE_PROJECTS='clang' \
     -DLLVM_TARGETS_TO_BUILD='AArch64' \
     -DLLVM_ENABLE_ASSERTIONS=ON
   ninja clang
   ```
2. Run the standalone repro (from step 1) against `build/bin/clang`.
3. If it reproduces, proceed to step 3. If it doesn't, bisect between
   `c3e7f9899750` and current head to find the accidental fix, then decide
   whether upstream-PR is still needed (for older-version users) or moot.

### 3. Iterate on the fix + upstream

Primary fix, already proven on `c3e7f9899750`:

```diff
--- a/clang/lib/Lex/ModuleMap.cpp
+++ b/clang/lib/Lex/ModuleMap.cpp
@@ -1895,6 +1895,7 @@ void ModuleMapLoader::handleExternModuleDecl(
   if (llvm::sys::path::is_relative(FileNameRef)) {
     ModuleMapFileName += Directory.getName();
     llvm::sys::path::append(ModuleMapFileName, EMD.Path);
+    llvm::sys::path::remove_dots(ModuleMapFileName, /*remove_dot_dot=*/true);
     FileNameRef = ModuleMapFileName;
   }
```

Todo before PR:

- [ ] Rebase the fix on top of the current fork head. The surrounding code
  moved in late 2024 when the ModuleMap parser was split into a separate
  `modulemap::` namespace (hence `EMD.Path` in `handleExternModuleDecl`).
  Minor risk of the line numbers drifting.
- [ ] Think about whether the same normalisation belongs in
  `ModuleMap::findHeader` (line ~228) for defence-in-depth. Only adds value
  if some other code path constructs long `..`-laden paths — probably not,
  given this one fix alone cleared the repro. Leave out of initial PR
  unless tests motivate it.
- [ ] Write a regression test under `clang/test/Modules/`. Shape:
  - lit test with a controlled cppmap tree whose chain-accumulator would
    exceed PATH_MAX on macOS when cwd is sufficiently long.
  - Pre-fix: `expected-error {{does not depend on a module exporting}}`
    only appears on macOS (where PATH_MAX=1024). Linux has PATH_MAX=4096
    so bug doesn't fire there with realistic paths — may need
    `REQUIRES: darwin` or similar.
  - Alternative: drive the test off `fake-filesystem` machinery clang
    tests use, so it's platform-independent. Unclear whether clang's
    existing VFS-fakery enforces real PATH_MAX limits though.
- [ ] Run full `clang/test/Modules/` suite. In particular:
  - `strict-decluse.cpp` / `strict-decluse-headers.cpp`
  - `header-attribs.cpp`
  - `incomplete-module.m`
  - Anything involving `extern module` directives.
- [ ] Decide commit message: reference upstream issue **#147220** (same
  class of report, never root-caused — link back to this investigation
  note in the PR description).
- [ ] CC `clang/modules` maintainers. `git log --follow clang/lib/Lex/ModuleMap.cpp`
  should surface a reasonable reviewer list.

### 4. (Optional) Chase Bazel-side mitigation

Even with the clang fix, there's a cleanup opportunity on the Bazel side:
`CppModuleMapAction` emits `extern module` declarations that are redundant
given `-fmodule-map-file=` on the cmdline covers every dep already. Dropping
them would eliminate the entire chain-accumulation pressure and avoid
needing the clang fix for this specific pattern. Not strictly needed if
the clang fix lands, but worth noting as a robustness lever.

Tracking: `src/main/java/com/google/devtools/build/lib/rules/cpp/CppModuleMapAction.java`
in bazelbuild/bazel. Empirically verified: stripping all `extern module`
lines from `ELF.cppmap` while passing all cppmaps via cmdline
`-fmodule-map-file=` compiles successfully.

## Appendix — bisection log

Presence/absence of individual `llvm/*.cppmap` files on disk under
`bazel-out/.../llvm/` (with minimal ELF + cmdline Support):

- Only `Support.cppmap` + `CodeGen.cppmap` + `BinaryFormatELF.cppmap`: pass
- Add `A*.cppmap` (AArch64*, ABI, AggressiveInstCombine, AllTargets*, Analysis, AsmParser):
  still pass
- Add `BinaryFormat.cppmap`: **fail**

The trigger isn't any single cppmap — it's the cumulative chain depth
the loader reaches while walking externs. More cppmaps on disk = more successful
extern resolutions = more nested loads = longer accumulated `..`-prefixed paths.

Single-FileEntry trace (48 handleExternModuleDecl fires for Support.cppmap, all
same `FileEntry=0x80130b4d0`) proves that FileEntry dedup is working — the bug
is in how the _name_ stored on that FileEntry's DirectoryEntry was first minted.
