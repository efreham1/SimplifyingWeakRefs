# JDK Weak Reference Optimization Project

## Project Overview

This is a research fork of OpenJDK focused on optimizing weak reference processing in JVM garbage collectors (G1GC and ZGC). The work is part of a thesis project at Uppsala University investigating performance improvements by:

1. Skipping enqueue operations for WeakReferences without ReferenceQueues
2. Replacing linked-list structures with dynamic arrays
3. Eliminating unnecessary compare-and-swap operations
4. Sequential processing optimizations

## Critical Architecture

### Reference Processing Flow
- **Discovery**: GC marks objects, discovers Reference objects via `ReferenceProcessor::discover_reference()`
- **Processing**: In STW pause or concurrent phase, refs are processed by type (Soft → Weak → Final → Phantom)
- **Enqueue**: Cleared references added to their ReferenceQueue (if present)

Key insight: Many WeakReferences have null queues and can skip enqueueing entirely, reducing overhead.

### Core Components
- `src/hotspot/share/gc/shared/referenceProcessor.*` - GC-agnostic reference processing logic
- `src/hotspot/share/gc/z/zReferenceProcessor.*` - ZGC-specific implementation with generational support
- `src/hotspot/share/gc/g1/g1*` - G1 garbage collector implementation
- `src/java.base/share/classes/java/lang/ref/Reference.java` - Java-level Reference API

Development is currently focused on zgc.

### Important Concepts
- **SATB (Snapshot-At-The-Beginning)**: G1's marking algorithm; referents stay live during marking
- **Discovered lists**: Per-GC-thread lists of discovered Reference objects, linked via hidden `discovered` field
- **Young-to-old references**: Cross-generational references requiring special handling (see `considerations.txt`)

## Build & Test Workflow

### Building
Use the scripts available in the directory /scripts for building and testing.


### Standard JDK Tests
```bash
make test-tier1           # Quick smoke tests
make test TEST=tier2      # More comprehensive
```

## Project-Specific Conventions

### Hotspot C++ Style
- Use `oop` for Java object pointers, `zaddress` for ZGC addresses
- Macros like `NOT_DEBUG_RETURN` compile to nothing in product builds
- GC code uses phases tracked by `GCTraceTime` for performance analysis
- Prefer `log_trace(gc, ref)` over printf for debugging; controlled by `-Xlog:gc+ref=trace`

### Reference Processing Changes
When modifying reference processing:
1. Check both `referenceProcessor.cpp` (shared) and GC-specific implementations (e.g., `zReferenceProcessor.cpp`). Since zgc is the focus, if zgc has a specific implementation (e.g., `zReferenceProcessor.cpp`), changes should be made there and the shared code can remain unchanged if possible.
3. Verify cross-generational reference handling (young referent + old Reference object)

### Files Modified for Null-Queue Optimization
- Check `has_reference_queue()` / `has_queue` before enqueueing
- Track separately: `_encountered_weak_refs_without_queue_count` vs `_encountered_count[REF_WEAK]`
- Look for patterns like: `if (type == REF_WEAK && !has_queue) { /* fast path */ }`

## Key Command-Line Flags

```bash
-XX:+UseZGC                          # Use ZGC (generational by default)
-XX:+UseG1GC                         # Use G1GC (usually default)
-Xlog:gc+stats                       # Print GC statistics
-Xlog:gc+ref=trace                   # Detailed reference processing logs, gives an extreme amount of output, use with care
-XX:+UnlockDiagnosticVMOptions       # Enable diagnostic flags
-XX:InitialTenuringThreshold=1       # Young→old promotion (for testing)
```

## Research Context

See `I_do_this.txt` for current task list and `considerations.txt` for critical constraints (e.g., young referents with old References must stay reachable).

**Thesis**: Located in `Report/Thesis.tex`. Compile with `xelatex` or `pdflatex`.

## Common Pitfalls

2. **Generation barriers**: ZGC has young/old generations; barriers ensure cross-generation refs work correctly
3. **Concurrent vs STW**: Some reference processing is concurrent; use appropriate synchronization
4. **Performance testing requires isolation**: Use `run_benchmark_iterations.sh` with proper CPU pinning, not ad-hoc runs
5. **OpenJDK merge conflicts**: Regularly merge from `openjdk:master`; reference processing code changes frequently

## Useful Searches

- Weak reference processing: `grep -r "REF_WEAK" src/hotspot/share/gc/`
- Enqueue operations: `grep -r "enqueue" src/hotspot/share/gc/shared/referenceProcessor.cpp`
- ZGC without-queue handling: `grep -r "without_queue" src/hotspot/share/gc/z/`


## Rules for writing code
- Do not suggest code that has been deleted in recent edits.
- Do not suggest code that has been moved in recent edits.

## Rules for writing text
- Do not use M-dashes (---)
- Use British English spelling (e.g., "optimisation" instead of "optimization")