# JDK Weak Reference Optimisation Project

## Project Overview

This is a research fork of OpenJDK focused on optimising weak reference processing in the ZGC garbage collector. The work is part of a Master's thesis at Uppsala University investigating four mechanisms:

1. **Skip enqueue path** (`sep`): skip enqueueing for WeakReferences without a ReferenceQueue
2. **Dynamic array** (`dyn`): replace per-thread linked-list discovered lists with dynamic arrays
3. **Optimised clear path** (`clear_path`): eliminate unnecessary CAS operations when clearing referents
4. **Weak fields** (`weak_fields`): a `java.lang.ref.weak` field annotation that lets ordinary object fields act as weak references, processed directly by ZGC without the `WeakReference` wrapper overhead

Development is focused exclusively on ZGC (Generational ZGC). G1GC work was explored earlier but is not the focus.

## Critical Architecture

### Reference Processing Flow
- **Discovery**: GC marks objects, discovers Reference objects via `ReferenceProcessor::discover_reference()`
- **Processing**: In STW pause or concurrent phase, refs are processed by type (Soft → Weak → Final → Phantom)
- **Enqueue**: Cleared references added to their ReferenceQueue (if present)

Key insight: Many WeakReferences have null queues and can skip enqueueing entirely.

### Core Components
- `src/hotspot/share/gc/shared/referenceProcessor.*` - GC-agnostic reference processing logic (do not modify unless necessary; ZGC has its own implementation)
- `src/hotspot/share/gc/z/zReferenceProcessor.*` - ZGC-specific implementation with generational support; primary target for changes
- `src/java.base/share/classes/java/lang/ref/Reference.java` - Java-level Reference API
- `src/java.base/share/classes/java/lang/ref/weak.java` - the weak-field annotation class

### Weak Fields Mechanism
- Annotation `java.lang.ref.weak` applied to object fields
- `classFileParser.cpp` recognises the annotation and marks affected `fieldInfo` entries; only active when ZGC is enabled
- At GC time, `zMark.cpp` discovers weak fields and stores them in per-worker `ZWeakFieldArray` (defined in `patches/weak_fields/src/hotspot/share/gc/z/zWeakFieldArray.hpp`)
- ZGC processes them in `zReferenceProcessor.cpp` and reports via `Weak Fields` in `-Xlog:gc+ref` logs
- Patches span many subsystems: `c1_LIRGenerator`, `opto/parse3`, `opto/library_call`, `oops/resolvedFieldEntry`, `oops/fieldInfo`, `prims/jvmtiTagMap`, `gc/z/*`, `classfile/*`, `cpu/x86/templateTable_x86`

### Important Concepts
- **Discovered lists**: per-GC-thread lists of discovered Reference objects, linked via hidden `discovered` field; `dyn_only` replaces these with arrays (`zWeakRefArray.hpp`)
- **Young-to-old references**: cross-generational references require special handling (see `considerations.txt`)
- **SATB (Snapshot-At-The-Beginning)**: ZGC's marking algorithm; referents stay live during marking

## Variant System

Variants are stored as source-file overlays under `patches/`. Each directory contains only the files that differ from baseline.

| Variant | Patches applied | Abbreviations |
|---------|----------------|---------------|
| `none` | baseline (no optimisations) | - |
| `sep_only` | skip enqueue path only | sep |
| `dyn_only` | dynamic array only | dyn |
| `clear_path_only` | optimised clear path only | clear_path |
| `clear_path_sep` | clear_path + sep | |
| `sep_dyn` | sep + dyn | |
| `clear_path_dyn` | clear_path + dyn | |
| `all` | clear_path + sep + dyn | all three WeakRef optimisations |
| `weak_fields` | weak-field annotation mechanism (dedicated build) | |

`patches/base/` contains measurement and statistics infrastructure applied to all variants (ZGC stat tracking, `zStat.cpp/.hpp`, `zCollectedHeap`, thread exit hooks).

## Build Workflow

All build and benchmark scripts are in `scripts/`. Use these; do not run `make` commands manually for variant builds.

### Step 1 – Create configured build directories
```bash
./scripts/create_configs.sh
```
Downloads boot JDK 26 if needed (from `build/boot-jdks/`), configures shared and dedicated build trees, writes `scripts/variants.conf`.

### Step 2 – Build all variants
```bash
./scripts/build_configs.sh --debug-level release
./scripts/build_configs.sh --debug-level fastdebug
```
Ref-proc variants (`none`…`all`) share one configured build per debug level; each variant's HotSpot artefact cache is stored under `build/variant-build-state/` and runnable images under `build/variant-images/`. `weak_fields` keeps a dedicated configured build.
Note that `build_configs.sh` removes the other debug level's build directory to save space, so only one debug level can be built at a time.

### Swap source without rebuilding
```bash
./scripts/swap_config.sh copy <variant>   # apply variant patches to src/
./scripts/swap_config.sh restore          # restore src/ from backup
./scripts/swap_config.sh save <patch>     # copy modified src/ back into patches/<patch>/
```

### Standard JDK Tests
```bash
make test-tier1           # quick smoke tests
make test TEST=tier2      # more comprehensive
```

## Benchmark & Measurement Workflow

### Benchmarks
Two custom micro-benchmarks (no JMH):
- **Single-object**: 20 million WeakReferences all pointing to one shared target object; measures non-strong processing overhead in isolation
- **Multi-object**: 2 million objects, 5 collection rounds; measures overall major-collection time

Both benchmarks use `-XX:+UseZGC` with 100 GB heap (UPPMAX nodes have large memory).

### Running on UPPMAX (SLURM)
Submit `scripts/run_regular_benchmarks.sbatch` via `sbatch`. Key parameters baked in:
- `OUTER_ITERATIONS=250`, `WARMUP_ITERATIONS=1`, `PARALLEL_INSTANCES=4`
- `BENCHMARK_JVM_CORE_COUNT=10`, `BENCHMARK_AUX_CORE_COUNT=2`
- 4 parallel instances pinned via `taskset` to isolated CPU sets
- Exclusive node (`--exclusive`), no hyperthreading, 48 CPUs, 72-hour time limit
- Account: `uppmax2026-1-109`

Raw output is written to `output/` (or `FINAL_OUTPUT_ROOT`).

### Parsing results
```bash
python3 scripts/parse_gc_stats.py [options]
```
Reads CSVs from `results/`, writes:
- Violin + median-diff plots to `images/`
- LaTeX table fragments to `tables/`
`weak_fields` is recognised as a separate variant and included automatically.

## Report (Thesis)

### Location and compilation
- Main file: `Report/Thesis.tex`
- **Compile with xelatex** (not pdflatex). The `.vscode/settings.json` has the recipe `xelatex -> bibtex -> xelatex*2` configured for the LaTeX Workshop extension.
- xelatex handles `UU_logo_sv_42.eps` natively; no Ghostscript pre-conversion needed.
- Manual compile sequence:
  ```bash
  cd Report
  rm -f Thesis.aux Thesis.toc Thesis.lof Thesis.lot
  xelatex -interaction=nonstopmode Thesis.tex
  bibtex Thesis
  xelatex -interaction=nonstopmode Thesis.tex
  xelatex -interaction=nonstopmode Thesis.tex
  xelatex -interaction=nonstopmode Thesis.tex   # fourth pass for longtable stability
  ```

### Chapter structure (in order)
1. Introduction (`Introduction.tex`)
2. Background (`Background.tex`)
3. Design and Implementation (`DesignAndImplementation.tex`)
4. Evaluation (`Evaluation.tex`) — contains §4.1 Optimisation Variants, §4.2 Performance Evaluation, §4.3 Presentation of Results (all 12 figures inline). **No separate Results.tex file exists.**
5. Analysis of Results (`AnalysisOfResults.tex`)
6. Discussion (`Discussion.tex`)
7. Related Work (`RelatedWork.tex`)
8. Conclusion (`Conclusion.tex`)
9. Appendices (`Appendices.tex`)

### Key report files
- `Report/References.bib` — bibliography (style: `ieeetr`)
- `tables/` — LaTeX table fragments generated by `parse_gc_stats.py`, included via `\input{../tables/...}`
- `images/` — plots generated by `parse_gc_stats.py`, included via `\graphicspath{{../images/}}`
- `cleveref` is used for all cross-references (`\cref`, `\Cref`)
- `listings` package with `listing` float for Java/C++ code snippets

## Key Command-Line Flags

```bash
-XX:+UseZGC                          # Use ZGC (generational by default)
-Xlog:gc+stats                       # Print GC statistics
-Xlog:gc+ref=trace                   # Detailed reference processing logs (very verbose; use with care)
-XX:+UnlockDiagnosticVMOptions       # Enable diagnostic flags
-XX:InitialTenuringThreshold=1       # Young→old promotion (for testing)
```

## Research Context

See `I_do_this.txt` for current task list and `considerations.txt` for critical constraints (e.g., young referents with old Reference objects must stay reachable).

## Common Pitfalls

- **Generation barriers**: ZGC has young/old generations; barriers ensure cross-generation refs work correctly
- **Concurrent vs STW**: some reference processing is concurrent; use appropriate synchronisation
- **Performance testing requires isolation**: use `run_benchmark_iterations.sh` with proper CPU pinning, not ad-hoc local runs
- **OpenJDK merge conflicts**: regularly merge from `openjdk:master`; reference processing code changes frequently
- **weak_fields is a dedicated build**: it patches files outside HotSpot (classfile, oops, c1, opto, prims), so it cannot share the configured build directory with the ref-proc variants

## Useful Searches

```bash
grep -r "REF_WEAK" src/hotspot/share/gc/
grep -r "without_queue\|has_queue\|has_reference_queue" src/hotspot/share/gc/z/
grep -r "ZWeakFieldArray\|ZWeakRefArray" src/hotspot/share/gc/z/
```

## Rules for writing code
- Do not suggest code that has been deleted in recent edits.
- Do not suggest code that has been moved in recent edits.

## Rules for writing text
- Do not use em-dashes (---)
- Use British English spelling (e.g., "optimisation" instead of "optimization")