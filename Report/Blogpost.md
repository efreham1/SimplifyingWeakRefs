# Simplifying Weak Reference Processing in ZGC

My name is Fredrik, and I recently completed my master's degree in Computer and Information Engineering at Uppsala University. For my thesis I worked with the GC team at Oracle's Stockholm office, investigating the overhead of weak reference processing in generational ZGC and whether it could be reduced with targeted modifications to the pipeline — or avoided altogether through a different representation of weak semantics.

## The Problem

Java's `WeakReference` provides a way to hold a reference to an object without preventing it from being collected. When the GC determines that an object is only weakly reachable, it clears the referent field and, if the reference was registered with a `ReferenceQueue`, enqueues the reference so the application can react to the collection event. This notification mechanism is optional: the `WeakReference` constructor accepts a `null` queue argument, and many uses, e.g. caches, interning maps, listener registrations, never register a queue.

Despite this distinction, ZGC's reference-processing pipeline treats all weak references uniformly. Every discovered reference is linked into an intrusive per-thread linked list via the hidden `discovered` field, transferred to the `ReferenceHandler` thread via the pending list, and iterated by that thread regardless of whether it will actually be enqueued. This mismatch between the optional nature of the callback mechanism and the unconditional work performed for it has been noted in the OpenJDK issue tracker (JDK-8029205) but has not yet been addressed in the JDK.

The per-reference processing cost scales linearly with the number of weak references, making it a bottleneck in workloads that allocate many of them. This thesis investigates whether that cost can be reduced through three orthogonal pipeline modifications, and whether it can be avoided more fundamentally by replacing `WeakReference` objects with an annotated-field mechanism.

## Four Mechanisms

### 1. Skip-Enqueue Separation (`sep`)

The simplest modification routes queue-less weak references to a separate per-worker discovered list during the mark phase. References on this list are processed and cleared by GC threads directly, without ever being added to the pending list or handed to the `ReferenceHandler` thread. The key change in `ZReferenceProcessor` is a queue check at discovery time:

```cpp
if (type == REF_WEAK && !has_reference_queue(ref)) {
    weak_no_queue_list_per_worker.append(ref);  // bypasses pending list entirely
} else {
    discovered_list_per_worker.append(ref);     // normal enqueue pipeline
}
```

The two lists are processed by specialised functions, keeping the no-enqueue path free of per-reference queue checks.

### 2. Dynamic Array (`dyn`)

The intrusive linked list traversed during reference processing exhibits poor cache locality: each element is a `WeakReference` object scattered across the heap, and following the `discovered` chain requires loading a new cache line per reference. The `dyn` mechanism replaces this list with a contiguous `ZWeakRefArray` allocated on the C heap. References are appended during discovery in O(1) amortised time; during processing the array is iterated sequentially with index-based access, keeping references in L1/L2 cache. The array retains capacity between cycles to avoid reallocations when the reference population is stable.

A secondary benefit is that field data can be pre-loaded during discovery and stored inline in each array entry, enabling the clear path optimisation described next.

### 3. Optimised Clear Path (`clear_path`)

The standard ZGC path for clearing a referent performs three operations: a load barrier to read the referent, a virtual call to determine the reference type, and a CAS via a ZGC barrier to atomically set the field to a coloured null. For queue-less weak references, all three can be simplified:

1. **Load barrier eliminated.** When combined with `dyn`, the referent address and value are pre-loaded at discovery time and stored in the array entry. No additional heap loads are needed at processing time.
2. **Virtual call eliminated.** The reference type is statically known at the call site.
3. **CAS replaced with a plain store.** The only concurrent application-level operations on a referent field are clearing or enqueueing it (both set it to null), so an atomic CAS can be replaced with a direct store without correctness risk.

These three simplifications interact constructively: individually they reduce non-strong processing time by 7% (`clear_path_only`) and 36% (`dyn_only`), but together in `clear_path_dyn` they achieve an 81% reduction — far larger than the sum of their individual contributions. The superadditivity arises because the dynamic array removes the pointer-chasing bottleneck that would otherwise persist when the CAS is eliminated, and the pre-loaded data lets the clear logic run without any barrier overhead.

### 4. Weak Fields (`weak_fields`)

The three pipeline optimisations accelerate the processing of `WeakReference`'s , but the `WeakReference` objects themselves remain on the heap and must be marked, promoted, and relocated across every GC cycle. The `weak_fields` mechanism takes a different approach: rather than wrapping a weak pointer in a separate object, weak semantics is expressed directly as a field annotation.

```java
// Instead of:
public class Cache {
    private final WeakReference<Value> entry;
}

// With the @weak annotation:
public class Cache {
    private @weak Value entry;
}
```

The `@weak` annotation is recognised by the class-file parser and stored in `fieldInfo` metadata. At GC time, ZGC's marking closure checks each reference field against its `fieldInfo` entry and, if the field is annotated `@weak`, diverts it to a per-worker `ZWeakFieldArray` rather than treating it as a strong reference. After marking, weak fields whose referents are unreachable are nulled via a CAS.

## Benchmark Design

Two custom microbenchmarks target the reference-processing pipeline under ZGC:

- **Single-object benchmark.** 20 million holder objects each contain either a `WeakReference` or an `@weak` field pointing to a single shared target. After a randomised setup (Fisher-Yates shuffle), the strong reference to the target is released and `System.gc()` is called, concentrating the entire weak-reference load into one GC cycle and maximising non-strong processing time.

- **Multi-object benchmark.** 2 million objects with variable-size byte-array payloads are paired with holder objects. Strong references are released in five 20%-rounds with a `System.gc()` after each round, spreading reference processing across multiple cycles.

Both benchmarks use `-XX:+UseZGC`, a 100 GB heap, and `-XX:InitialTenuringThreshold=1` to promote objects quickly to the old generation where ZGC discovers and processes references. Each variant ran 250 measurement iterations on an exclusive AMD EPYC 9454P node (48 cores, 768 GiB RAM) on the UPPMAX Pelle supercomputer cluster, with four parallel instances pinned via `taskset` to isolated CPU sets to avoid inter-instance interference.

## Results

### Non-Strong Reference Processing Time

The metric most directly targeted by the optimisations is `Concurrent Process Non-Strong`, the wall-clock duration of ZGC's concurrent reference-processing phase.

| Variant | Single-object median | vs. baseline | Multi-object median | vs. baseline |
|---|---|---|---|---|
| `none` (baseline) | 996.9 ms | — | 44.1 ms | — |
| `sep_only` | 943.8 ms | −5 % | 44.1 ms | 0 % |
| `dyn_only` | 639.1 ms | −36 % | 27.5 ms | −38 % |
| `clear_path_only` | 923.7 ms | −7 % | 41.5 ms | −6 % |
| `clear_path_dyn` | 187.9 ms | **−81 %** | 18.8 ms | **−57 %** |
| `all` | 184.4 ms | **−81 %** | 18.7 ms | **−57 %** |
| `weak_fields` | 484.6 ms | −51 % | 35.8 ms | −19 % |

The `clear_path_dyn` and `all` variants are the clear leaders. The `sep_only` variant shows that the enqueueing stage itself is not the dominant bottleneck: routing queue-less references away from the `ReferenceHandler` thread has negligible effect on processing time in these queue-less benchmarks. However, it should reduce pending-list traversal in the `ReferenceHandler` thread and might improve branch prediction in the processing step for workloads with a mix of queue-less and queue-registered references.

### Total GC Collection Time

The 81% reduction in the targeted phase translates to a more modest improvement in total major collection time, because non-strong processing accounts for only 14.7% of baseline major-collection time in the single-object benchmark and 4.5% in the multi-object benchmark. Furthermore, these improvements should be taken with a grain of salt as the distributions of total collection time overlap substantially across variants, only the `weak_fields` variant shows a clear separation from the baseline.

| Variant | Single-object median | vs. baseline | Multi-object median | vs. baseline |
|---|---|---|---|---|
| `none` | 6 958 ms | — | 982 ms | — |
| `all` | 6 377 ms | −8 % | 967 ms | −2 % |
| `weak_fields` | 4 136 ms | **−41 %** | 708 ms | **−28 %** |

`weak_fields` reduces major collection time by 41% and old-generation time by 37% in the single-object benchmark (28% and 31% in the multi-object benchmark). This improvement spans every phase - concurrent mark, relocate, young generation - because eliminating millions of `WeakReference` objects from the heap reduces the GC workload across the board, not only in the reference-processing phase.

### Memory Usage

The dynamic array incurs a meaningful auxiliary GCr memory cost in the single-object benchmark, where 20 million entries are live simultaneously:

| Variant | Auxiliary GCr memory (single-object, median max) |
|---|---|
| `none` | 120 MB |
| `dyn_only` | 308 MB (+157%) |
| `clear_path_dyn` | 1 268 MB (+957%) |
| `all` | 884 MB (+637%) |
| `weak_fields` | 446 MB (+272%) |

In the multi-object benchmark the absolute numbers are smaller (292 MB baseline) and the relative overheads contract sharply, because the reference population is smaller.

`all` saves ~30% of auxiliary GCr memory over `clear_path_dyn` by not needing to store the reference address in each array entry (the skip-enqueue separation routes queue-less references to a separate list, so the address field is not needed there) making it the more attractive pipeline variant overall.

Java heap occupancy is essentially identical across all `WeakReference` variants (~1 720 MB in the single-object benchmark). `weak_fields` reduces this to 806 MB (−53%), directly reflecting the absence of the `WeakReference` objects.

## Key Takeaways

The results suggest that weak-reference overhead behaves more like a _representation_ problem than a _pipeline_ problem. Reducing it meaningfully appears to require reconsidering how weak semantics is encoded in the language, not merely how the resulting objects are processed once they have been allocated.

The `clear_path_dyn` and `all` combinations demonstrate that a carefully designed interaction between cache-friendly data structures and simplified per-reference logic can achieve large reductions in the targeted phase. Yet even an 81% reduction only an 8% reduction in collection time under conditions engineered to maximise it. The `@weak` field annotation, by contrast, eliminates the objects responsible for that overhead from every phase of every cycle, delivering 41% major-collection-time savings and 53% heap savings in the single-object benchmark.

This finding is consistent with how weak semantics is implemented across the broader language ecosystem. Go's `weak.Pointer`, C++'s `std::weak_ptr`, and .NET's `WeakReference<T>` all treat weak reachability and cleanup notification as separate concerns. The `@weak` annotation brings Java's callback-less weak-reference cost closer to that model.

The `weak_fields` implementation currently touches 27 files (compared to at most 10 for the most complex pipeline variant) and remains a prototype. Several paths forward are described in the thesis, including integration of one or more pipeline variants into the OpenJDK project.

---

The [thesis](http://urn.kb.se/resolve?urn=urn:nbn:se:uu:diva-588851) is available at Uppsala University's DiVA portal. The full [codebase](https://github.com/efreham1/SimplifyingWeakRefs) is a fork of OpenJDK with all four mechanisms implemented as source-file overlays under `patches/`, together with build and benchmarking scripts. The complete [measurement dataset](https://doi.org/10.5281/zenodo.20445473) is published on Zenodo.

I would like to extend my sincere thanks to Stefan Johansson and Tobias Wrigstad for their guidance throughout the project, and to everyone at the Oracle Stockholm office for their support and generosity in sharing their expertise.
