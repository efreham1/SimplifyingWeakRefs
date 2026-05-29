# Thesis Defence Script

## Opening

OK, so everyone's feeling ready? Perfect. Then I'll go ahead.

Hello everyone, my name is Fredrik and this is my thesis defence. My thesis is titled Optimising Weak Reference Processing in the JVM Z Garbage Collector, and to some of you that may sound like a load of gibberish. But my hope is that by the end of this presentation it will no longer sound like gibberish, and you'll also understand what my thesis has been about and the results I've actually gotten. So without further ado, I think we can just jump right into it.

[change slide]

## Agenda

We'll go through background, motivation, design and implementation, then evaluation and results, and finally conclusions. Please hold any questions until the end.

[change slide]

## Background

Alright then, let's jump into the background to understand all this gibberish. It's actually not as bad as it sounds.

[change slide]

### Java and the JVM

To start off, we have the programming language Java. Most of you should at least have heard of it before - if not, that's also fine. Java is an object-oriented language that is extremely popular. It's one of the most used languages in the world. One big selling point of Java is that it can run on any machine, completely regardless of the architecture. So you write once, compile once, and the code can just run anywhere, which is very neat indeed.

How this is achieved is through something called a JVM, or Java Virtual Machine. A JVM is, in its most basic form, just a virtual machine that can run Java - hence Java Virtual Machine. The most popular implementation of a JVM is the HotSpot JVM, developed by Oracle in the OpenJDK project, and due to its popularity it is the JVM I did my implementation in.

[change slide]

### Garbage Collection

Another neat thing about Java is that you don't actually have to manage memory like in languages such as C or C++, which some of you might be familiar with. Instead, it's an automatically managed memory system. How this is achieved in HotSpot is that it has a garbage collector.

This garbage collector goes through and finds what memory the application is no longer using, and then returns that memory to the operating system. One thing to note here is that HotSpot actually has several implementations of garbage collectors and that the user can choose which one to use when executing a Java program. One of these garbage collectors is called ZGC, which is the one I did my implementation in, and the one I will be talking about for the rest of this presentation.

ZGC is a concurrent relocating garbage collector. So what does that mean? It means that it runs concurrently with the application - that is, it doesn't stop the application while it's doing garbage collection, and it also means that it relocates alive objects in memory and lets the rest of the memory be reused, in other words the memory containing the dead objects.

[change slide]

So how does this work? To understand that, we can take a look at this illustration here. This big box represents the heap of the JVM on a computer. In this memory, the objects that the Java application uses are spread out in different parts. So we have object A here, object B here, and object C here. And then off to the left we have something called the root set, which contains everything that is known to be alive - things we should never garbage collect. All these objects and the root set interact in various ways.

[change slide]

For example, object A might contain a reference to object B. And the stack - which is in the root set - might have a reference to object C. When we garbage collect, we find everything alive -- meaning reachable from the root set.

[change slide]

So in this case we can quite clearly see that C is reachable, but A and B are not reachable from the root set. So that means we mark C as alive and mark A and B as dead.

[change slide]

Once this is done, we get to the relocating phase, which is basically that we take C and move it to a new piece of memory over here. And when that is done, we mark the old memory region as reusable, meaning it can eventually be overwritten by new objects. So yeah, that is basically how ZGC works.

In reality, of course, garbage collection and ZGC is much more complicated than this, but in the interest of time and focusing on what I've done for this thesis, I won't go any further into it.

[change slide]

### Weak References

But there is a slight problem with having references be the thing that keeps objects alive. Because if we find ourselves in a situation while programming where we want to be able to read, for example, object B as long as it is reachable from the root set - but as soon as B is no longer reachable from the root set, we no longer want to be able to read it - with what I've talked about so far, this is impossible. Because if we can read it, that means we have a reference to it, which means it won't become unreachable from the root set even if there are no other references to it. As you can see in the diagram here, C holds a strong reference to B -- which means B can never be collected as long as C is alive.

So how this problem is solved is through something called a weak reference. A weak reference is a reference in the sense that we can read the object through it, but it's weak in the sense that it won't actually keep the object alive.

[change slide]

So if we go back to our graph, and change the strong reference between C and B to a weak one. Then, in this case, where B is not reachable from the root set via any strong reference, we can't use the reference going from C to B, because it's a weak reference, and this weak reference will also not keep B alive.

[change slide]

So when we do garbage collection, B will be collected and the weak reference will be cleared.

[change slide]

But let's change up this graph a bit. Let's add a strong reference from the root set to A, so it now looks like this. And in this case, we can use the reference that goes from C to B, since B is reachable through A.

So this is what a weak reference does - it allows us to conditionally reach an object based on whether it is reachable from the root set or not.

Looking at weak references in a graph is fine - it's clear whether something is reachable or not. But actually getting this to work in a garbage collector is quite a bit more difficult. To understand the implementation I've done, and the results and conclusions I've come to, we need to understand a little bit of how Java implements weak references and how ZGC processes them. So let's take a look at that.

[change slide]

#### The WeakReference wrapper object

In Java, weak references are implemented as separate objects. The graph I showed earlier was actually a simplification - this is how it really looks. As we can see, there is a new object in the graph. That is the `WeakReference` object. C has a strong reference to it, and the `WeakReference` object itself holds the actual weak reference pointing to B.

This might seem counterintuitive - why do we need this extra object? But there is a good reason. When programming with weak references, there are often scenarios where you want to know when a weak reference becomes inactive, meaning the object it pointed to has been garbage collected. How this works in Java is that, as you can see in the code here, when you create a `WeakReference` you can optionally pass in a `ReferenceQueue`. When a weak reference is cleared by the garbage collector, that `WeakReference` object gets added to this queue so the application can react -- for example, to clean up a cache.

You can also create a `WeakReference` without a `ReferenceQueue` if you just want the conditional reachability we discussed earlier - also known as weak semantics. So that's how weak references implemented, now let's look at how ZGC actually processes them.

[change slide]

#### Reference processing pipeline

When ZGC does a GC cycle - going through all the objects and deciding what to relocate and what to not - it also searches for weak references. It can't decide during the marking phase whether a weak reference should be cleared, because it hasn't seen the entire object graph yet. So instead, each discovered weak reference is added to a discovered list. We continue marking through the graph, adding each newly found weak reference to this list as we go.

Once we've marked the entire object graph, we take this discovered list and start processing it. For each `WeakReference` in the list, we check whether its referent - the object it points to - is alive. If it is, we leave it alone. But if the referent is dead, we need to act. First, we null out the field holding the address of the referent, so it no longer points to the dead object - because that would be a dangling pointer, which is of course bad. Then we add the `WeakReference` object to a pending list, to be enqueued later. We do this for every entry in the discovered list.

Once the discovered list is empty, the pending list is handed to the reference handler thread in HotSpot, which is responsible for placing each reference into its correct `ReferenceQueue` - since there might be multiple queues in a single application. Once that is done, it's up to the application to poll its queues.

And that is the entire pipeline: discovery, to processing, and finally to enqueueing.

[change slide]

## Motivation

Alright, with that background out of the way, the thesis title should hopefully make some sense now: "Optimising Weak Reference Processing in the JVM Z Garbage Collector". But just because it makes sense doesn't mean it's obvious why it matters. So let's talk about the motivation.

[change slide]

Since Java is a garbage-collected language, the performance of the garbage collector directly impacts the performance of the program. This is one of the reasons Oracle developed ZGC - to minimise the stop-the-world pauses that previous collectors had and make garbage collection concurrent. This was a big success, and ZGC is a very well-functioning and widely used garbage collector.

However, as one bug report has pointed out, the way ZGC - along with other garbage collectors - handles reference processing, especially for weak references without a `ReferenceQueue`, is suboptimal. Specifically, when a weak reference without a `ReferenceQueue` gets processed, it still gets handed to the reference handler thread, even though there is no queue to actually add it to. So we're doing unnecessary work in the garbage collector and giving unnecessary work to the reference handler thread. This isn't idle, especially not in ZGC, which is designed for low latency and high throughput - every bit of unnecessary work adds up.

This is why this thesis investigates whether optimisations to reference processing in ZGC can make the garbage collector perform better and faster. That general mission was then concretised into two research questions.

[change slide]

RQ1 asks how specific pipeline modifications to ZGC's processing of queue-less `WeakReference` objects affect four key metrics: reference-processing time, total GC cycle time, GC memory footprint, and Java heap usage.

RQ2 asks how expressing weak semantics through annotated object fields affects those same metrics compared to the optimised `WeakReference` approach -- so a completely different representation, not just an optimised pipeline.

[change slide]

## Design and Implementation

Okay, now that we know what the thesis is about and why it matters, let's talk about the specific optimisations I actually implemented.

[change slide]

### Optimisation 1: Skip Enqueue Path

The first optimisation addresses exactly what was pointed out in the bug report. Currently, every weak reference goes through the full pipeline - including the enqueue step - even if there is no queue to add it to.

[change slide]

The fix is to split the discovered list into two separate lists during the discovery phase: one for `WeakReference` objects that have a `ReferenceQueue`, and one for those that don't. When we then go to process them, we run two separate processing pipelines. The no-queue pipeline just checks whether the referent is alive and clears it if not - and then stops. The with-queue pipeline does the same, but also performs the enqueueing step we discussed earlier.

The reason for splitting into two lists rather than simply branching on a condition inside a single pipeline is that the branch condition requires a memory load, and even with modern processors with good branch prediction and speculative execution, this adds meaningful overhead.

[change slide]

### Optimisation 2: Dynamic Array Discovered List

The second optimisation addresses the discovered list data structure itself. Currently it's a linked list, and iterating through a linked list is terrible for performance. It seems fine at first, but once you look at what happens in the CPU cache, it becomes clear why it isn't. When you load a node from memory, the CPU loads the entire cache line around it - but the next node's pointer points somewhere else entirely in memory, so that next node isn't in the cache. Which means we then have to wait for another memory load before we can even start loading the one after that. We can't prefetch or speculate ahead. This is very bad for modern processors.

The fix is to replace the linked list with an array, as shown in the illustration. When we load one entry from an array, the CPU loads the surrounding cache line, which then contains many consecutive entries - so we effectively get the next several entries for free.

The problem with a plain array is that it's fixed-size, and we don't know up front how many references we'll discover. So what we actually use is a dynamic array that automatically allocates a larger array when it fills up. That is the second optimisation - replacing the linked list with a dynamic array to give us much better cache locality and therefore much better performance.

[change slide]

### Optimisation 3: Optimised Clear Path

The third optimisation is about the clearing step - that is, writing null to the referent field to mark the weak reference as inactive. Currently this is done using a compare-and-swap, or CAS. A CAS is an atomic operation: when the CPU executes it, it guarantees that the read-check-write sequence happens atomically, with no other thread able to interleave, as shown in this pseudo-code. The reason a CAS is used here is that an application thread could also write to the referent field concurrently, and if both the GC and the application thread write at the same time without synchronisation, that is a data race, which is bad.

[change slide]

However, there is one key observation: the only thing an application thread can do to the referent field of a `WeakReference` is call `WeakReference.clear()`, which writes null. So if a race occurs, both sides are writing null - the result is the same regardless of the order. That means we can safely replace the CAS with a plain write, removing a costly atomic operation.

Those are the three optimisations for Research Question 1.

[change slide]

### Research Question 2: Weak Fields

For Research Question 2, we take a step back and ask a more fundamental question. Recall that weak references in Java are implemented as separate wrapper objects. The only reason that wrapper object exists is to support the `ReferenceQueue` callback mechanism. But for weak references without a `ReferenceQueue`, there is no callback - so why do we need the wrapper at all? The answer is: we don't.

The idea behind Research Question 2 is to allow one object to hold a weak reference to another directly, via an annotated field, as shown in the diagram. Writing `@weak` before a field declaration tells ZGC to treat that field as a weak reference, without any wrapper object, as shown in the code example.

This opens up quite a few implementation challenges. How do we discover these fields? or How do we clear them in a thread-safe way? What I did in this thesis was a proof-of-concept implementation - I got it working with my benchmarks, but it is not production-ready.

Discovery mirrors the normal pipeline: annotated fields found during marking go into a dynamic array, which is then processed after marking completes.

One important difference from weak references however: we cannot use the optimised clear path here. For a `WeakReference`, the only thing an application thread can write to the referent field is null, via `WeakReference.clear()`. But an `@weak`-annotated field is a regular object field - an application thread can write anything to it at any time. So we must keep the CAS to avoid a data race.

Once the field is cleared, we are done - there is no `ReferenceQueue` and therefore no enqueueing step.

There is a lot more compiler- and interpreter-specific work involved in making this all function correctly, but in the interest of time I won't go into it here.

[change slide]

## Evaluation

So now we know what my thesis is about, why it matters, and what I actually built. The next question is: does any of it actually work? Are these optimisations faster, or are they just pointless? To find out just that, I developed two benchmarks.

[change slide]

### Benchmark Design

The single-object benchmark is straightforward. As you can see in the illustration, there is one shared payload object, and a large number of weak references or weak fields all pointing to it - 20 million, to be precise. This payload object also has a single strong reference pointing to it and right before a GC cycle this reference is removed. This results in all of those weak references - or weak fields - being discovered and processed in that single GC cycle. This maximises the per-cycle reference-processing load and isolates the cost of the processing pipeline itself.

The multi-object benchmark is a slightly more realistic workload. As you can see in the illustration, we still have the array, holder objects, and weak references - but instead of a single shared payload, each of the 2 million holders has its own individual payload object. And unlike in the single-object benchmark, we don't release all strong references at once. Instead, the benchmark proceeds through five rounds: in each round, 20% of the strong references are released, making those objects eligible for collection, and then a GC cycle is triggered. This gradual release means that weak references or weak fields are processed across multiple GC cycles rather than in a single burst which introduces more variability in GC behaviour.

In both benchmarks, none of the weak references are backed by a `ReferenceQueue`. And the weak-fields counterpart works in exactly the same way, just without the `WeakReference` wrapper objects.

[change slide]

### Variants and Execution

In total, I benchmarked nine variants. As we can see in this table, this covers all eight combinations of the three optimisations - the baseline with none of them, each individually, each pair, and all three together - plus the `weak_fields` variant. This allows me to isolate the individual and combined effects of each optimisation.

The benchmarks were executed on UPPMAX's supercomputer cluster Pelle, on a single node with 48 cores and 768 GiB of RAM. Each variant was run 250 times, split across four parallel instances, each pinned to 10 JVM cores and 2 auxiliary cores to prevent interference. Each instance used a 100 GB heap.

[change slide]

## Results

The results are presented as composite plots: a violin plot showing the full distribution, and a median percentage-difference histogram comparing all variants to the unmodified baseline. Let's start with the most directly targeted metric.

[change slide]

### Non-Strong Processing Time

The "Concurrent Process Non-Strong" metric - the wall-clock time ZGC spends on its reference-processing phase. This is the phase all three optimisations directly target, and the results here are the clearest.

As you can see, the combination of the optimised clear path and the dynamic array reduces median non-strong processing time by about 81% in the single-object benchmark - from roughly 1000 ms down to around 187 ms. Adding the skip-enqueue separation on top gives essentially the same result: 184 ms. So in the single-object benchmark, the variant with all three optimisations is basically tied with just optimisations 2 and 3.

An interesting thing to notice is that this is actually super-additive. If you look at the optimised clear path alone, it only achieves a 7% reduction. The dynamic array alone achieves 36%. But together they achieve 81% - far more than their sum. The reason is that they remove different bottlenecks in sequence: when you have only the dynamic array, the CAS operation in the clear step becomes the bottleneck. And when you have only the optimised clear path, the linked-list traversal is still the bottleneck. But when you have both, you remove both bottlenecks at the same time.

The skip-enqueue separation on its own, however, shows almost no effect on this metric - just 5% in the single-object benchmark and nothing measurable in the multi-object benchmark. This is expected, because this metric only captures GC-internal work. The reference handler thread's load is not measured here, so the benefit of routing queue-less references away from it doesn't show up.

For weak fields, the picture is also interesting. It achieves a 51% reduction - clearly better than the baseline, but not as good as clear_path_dyn or all. And its performance is closely comparable to the `sep_dyn` variant - which makes sense, because weak fields can only use those two pipeline optimisations for the reasons we discussed earlier.

[change slide]

In the multi-object benchmark the same pattern holds -- -57% for the best variants. Weak fields sit at 19%, again comparable to `sep_dyn`.

[change slide]

### Major Collection Time

Now let's look at what actually matters to end users: the total major collection time.

Here the story is very different. For all the `WeakReference` variants, the distributions are broad and heavily overlapping. The best variants, `clear_path_dyn` and `all`, sit about 8% below the baseline in the single-object benchmark - but with distributions that still overlap substantially with each other and with the baseline. In the multi-object benchmark, the differences essentially disappear into the noise entirely.

For `weak_fields`, however, the picture is clear and unambiguous. In the single-object benchmark it reduces median major collection time by about 41% relative to the baseline, and in the multi-object benchmark by about 28%. Its distribution is also much tighter, with significantly less variability than any `WeakReference` variant.

[change slide]

### Memory Usage

Finally, let's look at memory.

All variants that use the dynamic array incur noticeably higher auxiliary GC memory. The `clear_path_dyn` variant is the worst, at about 10 times the baseline auxiliary memory in the single-object benchmark. Adding the skip-enqueue separation - which is what `all` does on top of `clear_path_dyn` - reduces this by about 30%, because the separation eliminates the need to store the reference address in each array entry. Even so, `all` still uses about 7 times the baseline auxiliary memory in the single-object benchmark. In the multi-object benchmark the overhead is much smaller in relative terms.

For Java heap usage, all `WeakReference` variants are identical - the optimisations don't change what objects are allocated on the heap. But `weak_fields` reduces heap usage by 53% in the single-object benchmark and 5% in the multi-object benchmark, simply because it eliminates the `WeakReference` wrapper objects entirely.

[change slide]

## Conclusions

Alright, so what do all of these results actually tell us? Let me answer the research questions.

[change slide]

For Research Question 1: the pipeline optimisations achieve an 81% reduction in non-strong processing time, which is significant. But this translates to only an 8% reduction in total major collection time, even in a benchmark specifically constructed to maximise the fraction of GC time spent on reference processing. That fraction, by the way, is 14.3% of major collection time in the single-object baseline - and only 4.5% in the multi-object baseline. So even if you could eliminate reference processing entirely, the best you could hope for is a 14% improvement in a benchmark that only does reference processing. In a realistic application, the gain would be far smaller.

For Research Question 2: weak fields achieve a 41% and 28% reduction in major collection time, far exceeding the 8% from the pipeline variants. They also reduce Java heap usage by 53% in the single-object benchmark and 5% in the multi-object benchmark. And this advantage doesn't come from faster processing - in fact, weak fields' non-strong processing time isn't even the best of any variant. It comes from something much more fundamental: by eliminating the `WeakReference` wrapper objects entirely, weak fields reduce the amount of work the GC has to do across every phase of every collection cycle - marking, relocating, everything.

[change slide]

So the key takeaway is this: optimising the reference processing pipeline is valuable, but it faces a hard ceiling set by the fraction of time spent on reference processing - namely that 14.3%. Weak fields, on the other hand, achieve a 41% reduction in major collection time and a 53% reduction in Java heap usage, thanks to the removal of the `WeakReference` wrapper objects from the GC-load. The real bottleneck isn't the pipeline. It's the representation. And the way to unlock meaningful improvement is to change how weak semantics is represented in the language, not just how the resulting objects are processed once they've been allocated.

[change slide]

Thank you for listening!
