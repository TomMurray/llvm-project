# Standalone reproducer

Self-contained fixture that triggers the `ModuleMap` extern-path accumulation bug.

## How to run

```bash
./run.sh /path/to/clang++
```

Failure produces:
```
<stdin>:1:10: error: module ELF does not depend on a module exporting
  'llvm/Support/Compiler.h'
```

## Reproduction constraints

- **macOS-only.**
- **Cwd length sensitive.** Verified to reproduce from
  `~/Development/llvm-project-fork/.investigation/repro/fixture` (69 chars).
  A much shorter cwd (e.g. `/a/`) may fall below the 1024 threshold even
  at 7 hops. Symlink-pad if needed:
  ```bash
  ln -s $PWD/fixture /tmp/padding_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/fixture
  cd /tmp/padding_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/fixture
  ```
