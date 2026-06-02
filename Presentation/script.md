# Thesis Defence Script

## Opening

Hello everyone, my name is **Fredrik** and this is my **thesis defence**. My thesis is titled **Optimising Weak Reference Processing in the JVM Z Garbage Collector**, and to some of you that may not make much sense at all. But my hope is that by the end of this presentation that title will **make sense**, and you'll also understand what my thesis has been about, the **results** I've gotten, and the **conclusions** I've come to. So without further ado, I think we can just jump right into it.

[change slide] (~0:38)

## Agenda

The agenda for my presentation looks like this. We'll start off by looking at the **background** and **motivation** of my thesis, then move on to the **design and implementation** of the optimisations I built, followed by the **evaluation method** I used to measure them, then the **results** I got, and finally the **conclusions** I drew from all of it. And please hold any questions until the end.

[change slide] (~1:07)

## Background

Let's get going with the background, to understand all the **necessary theory**.

[change slide] (~1:13)

### Java and the JVM

To start off, we have the programming language **Java**. Most of you should have heard of it before - but if not, here is a brief introduction. Java is an **object-oriented** language that is very **popular** - it's one of the most used languages in the world. One big selling point of Java is that it can run on **any machine**, completely regardless of the **architecture**. So you **write once**, **compile once**, and the code can just run anywhere, which is very neat indeed.

How this is achieved is through something called a **JVM**, or Java Virtual Machine. A JVM is, in its most basic form, just a virtual machine that can run Java - hence Java Virtual Machine. The most popular implementation of a JVM is the **HotSpot** JVM which is maintained by **Oracle** and available in the **OpenJDK** project. Due to HotSpot's popularity it is the JVM I did my implementation in.

[change slide] (~2:20)

### Garbage Collection

Another neat thing about Java is that you don't actually have to **manage memory** like you do in languages such as C or C++. Instead, it's an **automatically managed** memory system. How this is achieved in HotSpot is through something called a **garbage collector**, or a GC.

The garbage collector goes through and finds what memory the application is **no longer using**, and then **returns** that memory to the operating system. One thing to note here is that HotSpot actually has **several implementations** of garbage collectors and that the user can **choose** which one to use when executing a Java program. One of these garbage collectors is called **ZGC**, which is the one I did my implementation in, and the one I will be talking about for the rest of this presentation.

ZGC is a **concurrent relocating** garbage collector. So what does that mean? It means that it runs **concurrently** with the application - resulting in very short application pauses or **stop-the-world** pauses as they're more commonly referred to. It also means that it **relocates alive objects** to new memory, and therefore compacting - or de-fragmenting - the memory and then lets that **old memory be reused**.

[change slide] (~3:46)

So how does that work? To understand that, we can take a look at this illustration here. This big box represents the **heap** of the JVM on a computer. In this memory, the objects that the Java application uses are spread out in different parts. So we have **object A** here, **object B** here, and **object C** here. And then off to the left we have something called the **root set**, which contains everything that is **known to be alive** - things we should never garbage collect. All these objects and the root set interact in various ways.

[change slide] (~4:29)

For example, **object A** might contain a **reference** to **object B**. And the **stack** - which is in the root set - might have a reference to **object C**. When we garbage collect, we find everything that's **alive** -- meaning everything that's **reachable from the root set**.

[change slide] (~4:50)

So in this case we can quite clearly see that **C is reachable**, but **A and B are not reachable**. So that means we **mark C as alive** and **mark A and B as dead**.

[change slide] (~5:05)

Once this is done, we get to the **relocating phase**, which is basically that we take C and **move it to a new piece of memory** over here that now is compact and not fragmented. And when that is done, we **mark the old memory region as reusable**, meaning it can eventually be overwritten by new objects. So that's your crash course in how garbage collection works.

[change slide] (~5:34)

### Weak References

But there is a slight **problem** with having references be the thing that keeps objects alive. Because if we find ourselves in a situation while programming where we want to be able to **read** object B as long as it is **reachable from the root set** - but as soon as B is **no longer reachable**, we no longer want to be able to read it - with what I've talked about so far, this is **impossible**. Because if we can read it, that means we have a **reference** to it, which means it won't become unreachable even if there are no other references to it. You can see this in the diagram here, C holds a **strong reference** to B -- which means B can **never be collected** as long as C is alive.

So how this problem is solved is through something called a **weak reference**. A weak reference is a reference in the sense that we can read the object through it, but it's weak in the sense that it **won't actually keep the object alive**.

[change slide] (~6:53)

So if we change the **strong reference** between C and B to a **weak one**. Then, in this case, where B is not reachable from the root set via any strong reference, we **can't use** the reference going from C to B, because it's a weak reference, and this weak reference will also **not keep B alive**.

[change slide] (~7:18)

So when we do garbage collection, B will be **collected** and the weak reference will be **cleared**.

[change slide] (~7:25)

But let's change up this graph a bit. Let's add a **strong reference from the root set to A**, so it now looks like this. And in this case, we **can use** the reference that goes from C to B, since B is **reachable**.

So this is what a weak reference does - it allows us to **conditionally reach** an object based on whether it is **reachable from the root set** or not.

This is the general concept of weak references but to understand the implementation I've done, and the results and conclusions I've come to, we need to understand a little bit of how Java **implements** weak references and how **ZGC processes** them. So let's take a look at that.

[change slide] (~8:18)

#### The WeakReference object

In Java, weak references are implemented as **separate objects**, this is how that looks. As we can see, there is a new object in the graph. That is the `WeakReference` object. C has a **strong reference** to it, and the `WeakReference` object itself holds the actual **weak reference** pointing to B.

This might seem counterintuitive - why do we need this extra object? But there is a **good reason**. When programming with weak references, there are often scenarios where you want to know when a weak reference becomes **inactive**, meaning the object it pointed to has been **garbage collected**. How this works in Java is that, as you can see in the code here, when you create a `WeakReference` you can optionally pass in a **`ReferenceQueue`**. When a weak reference is cleared by the garbage collector, that `WeakReference` object gets **added to this queue** so the application can **react** -- for example, to **clean up a cache**.

You can also create a `WeakReference` **without a `ReferenceQueue`** if you just want the **conditional reachability** we discussed earlier - also known as **weak semantics**. So that's how Java implements weak references, now let's look at how ZGC processes them.

[change slide] (~9:44)

#### Reference processing pipeline

ZGC's reference processing pipeline consists of **three distinct phases**: **discovery**, **processing**, and finally **enqueueing**.

In **discovery**, when ZGC is **marking** the object graph - i.e. going through all the objects and deciding what to relocate and what to not - it also searches for **weak references**. And since it finds weak references before knowing which objects are dead and which are alive it can't yet decide what to do with the weak references. So instead, it adds each discovered weak reference to a **discovered list**.

Once the entire object graph has been marked, we take this discovered list and start **processing** it. For each `WeakReference` in the list, we check whether its **referent** - the object it points to - is **alive**. If it is, we **leave it alone**. But if the referent is **dead**, we **null out the field** in the `WeakReference` holding the address of the referent and then add the `WeakReference` object to a **pending list**, to handle enqueuing in the next phase.

And once the entire discovered list is processed, the pending list is handed to the **reference handler thread** in HotSpot, which is responsible for placing each reference into its correct `ReferenceQueue` - since there might be multiple queues in a single application. Once that is done, it's left to the application to **poll** those queues.

So there we have it, ZGC's reference processing pipeline. And with that we should also have all the background we need to understand the rest of the presentation. Let's try it out on the thesis title "Optimising Weak Reference Processing in the JVM Z Garbage Collector", does that make some more sense now? I hope so at least, but just because it makes sense doesn't mean it's obvious why it matters. So let's talk about

[change slide] (~11:54)

the motivation.

## Motivation

[change slide] (~11:55)

Since Java is a garbage-collected language, the **performance of the garbage collector directly impacts** the performance of the program. This is one of the reasons ZGC was developed - to minimise the long **stop-the-world pauses** that previous collectors had by making garbage collection more **concurrent**. This was a success, and ZGC is now a very well-functioning and widely used garbage collector.

However, as one **OpenJDK bug report** has pointed out, the way ZGC - along with other garbage collectors - handles reference processing, especially for **weak references without a `ReferenceQueue`**, is **suboptimal**. Specifically, when a weak reference without a `ReferenceQueue` gets processed, it still gets **handed to the reference handler thread**, even though there is **no queue** to actually add it to. So we're doing **unnecessary work** in the garbage collector and giving **unnecessary work** to the reference handler thread. This isn't idle, especially not in ZGC, which is designed for **low latency** and **high throughput**.

This is why this thesis investigates whether optimisations to reference processing in ZGC can make the garbage collector **perform better and faster**. That general mission was then concretised into **two research questions**.

[change slide] (~13:17)

Research question **1** asks how do specific modifications to ZGC's processing of `WeakReference` objects **without a `ReferenceQueue`** affect **reference-processing time**, **total GC cycle time**, **GC memory footprint**, and **Java heap usage**?

Research question **2** asks how does expressing weak semantics through **annotated object fields** affect reference processing time, GC cycle time, GC memory footprint, and Java heap usage compared to the optimised `WeakReference`-based approach of RQ1? -- so a completely **different representation**, not just an optimised pipeline.

[change slide] (~13:51)

## Design and Implementation

Okay, now that we know what the thesis is about and why it matters, let's talk about the specific **optimisations** I actually implemented.

[change slide] (~14:01)

### Optimisation 1: Separate Skip-Enqueue Pipeline

The **first optimisation** addresses exactly what was pointed out in the bug report. Currently, **every weak reference** goes through the **full pipeline** - including the **enqueue step** - even if there is **no queue** to add it to.

[change slide] (~14:17)

My optimisation **splits** the discovered list into **two separate lists** during the **discovery phase**: one for `WeakReference` objects **with** a `ReferenceQueue`, and one for those **without**. When we then go to process them, we run **two separate processing pipelines**. The **no-queue pipeline** just checks whether the referent is alive and clears the field if it's not - and then **stops**. The **with-queue pipeline** does the same, but also performs the **enqueueing** step we discussed earlier.

The reason for **splitting into two lists** rather than simply **branching** on a condition inside a single pipeline is that, that branch condition would require a **memory load**, and even with modern processors with good branch prediction and speculative execution, this adds **meaningful overhead**.

[change slide] (~15:10)

### Optimisation 2: Dynamic Array Discovered List

The **second optimisation** addresses the **data structure** of the discovered list. Currently it's a **linked list**, and iterating through a linked list is **terrible for performance**. When you load a node from memory, the CPU loads the entire **cache line** around it - but the node's **next-pointer** likely points **somewhere else** in memory, so that next node **isn't in the cache**. Which means we then have to **wait for another memory load** before we can even start loading the one after that.

My optimisation replaces the linked list with a **dynamic array**. As shown in the illustration, when we load one entry from the array, the CPU loads the surrounding cache line, which then contains many **consecutive entries** - so we effectively get the next several entries **for free**. The reason for using a **dynamic** array rather than a **static** array is that we **don't know up front** how many weak references we'll discover during marking, so we can't just allocate a big enough array at the start.

This optimisation does, sadly comes with a **trade-off**. The dynamic array needs **additional memory** compared to the linked list. This will be apparent in the results later on.

[change slide] (~16:35)

### Optimisation 3: Optimised Clear Path

The **third optimisation** is about the **clearing step** - that is, **writing null** to the referent field to mark the weak reference as **inactive**. Currently this is done using a **compare-and-swap**, or **CAS**. A CAS is an **atomic operation**: when the CPU executes it, it guarantees that the **read-check-write** sequence happens **atomically**, with no other thread able to interleave, this is shown in this pseudo-code. The reason a CAS is used here is that an application thread could write to the referent field **concurrently** with the GC, and without any synchronisation, that would result in a **data race**, which of course is bad.

[change slide] (~17:20)

Or is it? There is one **key observation**: the only thing an application thread can do to the referent field of a `WeakReference` is call `WeakReference.clear()`, which **writes null**. So if a data race does occur, **both sides are writing null**, meaning the result is the **same regardless of the order**. Which leads us to my 3rd and final optimisation, replacing the **CAS** with a **plain write**, removing a **costly atomic operation**.

So that's the three optimisations I implemented for Research Question 1. Now let's look at Research Question 2, which isn't about **optimising the pipeline**, but about **changing Java's representation** of weak semantics.

[change slide] (~18:06)

### Research Question 2: Weak Fields

Recall that weak references in Java are implemented as **separate objects**. The main reason that these object exists is to support the **`ReferenceQueue` callback mechanism**. But for weak references **without a `ReferenceQueue`**, there is **no callback** - so why do we need the additional object at all? The answer is: **we don't**.

The idea behind Research Question 2 is to allow one object to hold a weak reference to another **directly**, just as shown in the diagram. This is achieved through **field annotation**, so by writing **`@weak`** before a field declaration - as shown in the code example - HotSpot and ZGC will treat that field as a **weak reference**, without any `WeakReference` object.

This opens up quite a few implementation challenges. For example: How do we **discover** these fields? and How do we **clear** them in a **thread-safe** way?

Both of those challenges are thankfully quite easy to solve. **Discovery** can mirror the optimised pipeline: annotated fields found during marking go into a **dynamic array**.

And processing can also mirror the optimised pipeline just with one important difference: we **cannot use the optimised clear path**. Since an `@weak`-annotated field is a **regular object field** - an application thread can write **anything** to it at any time. So a data race here is in fact **bad** so we therefore need to keep the **CAS** in the clearing step for weak fields.

There was a lot more work involved in making this all function correctly, but in the interest of time I won't go into it here.

[change slide] (~19:58)

## Evaluation

So now we know what my thesis is about, why it matters, and what I actually built. The next question is: does any of it actually **work**? Are these optimisations **faster**, or are they just **pointless**? To find out just that, I developed two benchmarks - a **single-object** benchmark and a **multi-object** benchmark.

[change slide] (~20:21)

### Benchmark Design

The **single-object benchmark** is straightforward. As you can see in the illustration, there is one **shared target object**, and a large number of weak references or weak fields all pointing to it - **20 million**, to be precise. This target object also has a **single strong reference** pointing to it and right before a GC cycle this reference is **removed**. This results in all of those weak references - or weak fields - being **discovered and processed in that single GC cycle**. This maximises the **per-cycle reference-processing load** and therefore also maximises the **impact of the processing pipeline on the total GC duration**.

[change slide] (~21:06)

The **multi-object benchmark** is a slightly more **realistic** workload. As you can see in the illustration, we still have the array, holder objects, and weak references - but instead of a single shared target, each of the **2 million holders** has its own **individual target object**. And unlike in the single-object benchmark, we don't release all strong references at once. Instead, the benchmark proceeds through **five rounds**: in each round, **20%** of the strong references are released, making the corresponding weak references - or weak fields - eligible for processing when a GC cycle is triggered. This **gradual release** means that weak references - or weak fields - are processed across **multiple GC cycles** rather than in a single burst.

In both benchmarks, none of the weak references are backed by a `ReferenceQueue` in order to mirror the weak-fields counterpart as well as possible.

[change slide] (~22:09)

### Variants and Execution

These benchmarks were run with **nine variants** of ZGC. As we can see in this table, this covers all **eight combinations** of the three optimisations - the baseline with none of them, each individually, each pair, and all three together - plus the `weak_fields` variant. This allows me to **isolate the individual and combined effects** of each optimisation.

The benchmarks were executed on **UPPMAX's supercomputer cluster Pelle**, on a single node with **48 cores** and **768 GiB** of RAM. **Four benchmark instances** was run in parallel, each pinned to **10 JVM cores** and **2 auxiliary cores** to prevent any interference. And each JVM used a **100 GB heap**.

Each variant was run for **1 warmup iteration** and **250 measured iterations**. These 250 measurements are presented as composite plots: a **violin plot** showing the full distribution of them, and a **histogram** of median percentage-difference of all variants compared to the unmodified baseline.

[change slide] (~23:15)

## Results

Let's start by looking at results for the most **directly targeted metric**.

[change slide] (~23:21)

### Non-Strong Processing Time

The **"Concurrent Process Non-Strong"** metric which is the wall-clock time ZGC spends on its reference-processing pipeline. This is the metric all three pipeline optimisations directly target, and the results here are the **clearest**.

As you can see, the combination of the **optimised clear path** and the **dynamic array** reduces median non-strong processing time by about **81%** in the single-object benchmark - from roughly **1000 ms** down to around **190 ms**. Adding the separating skip-enqueue on top gives essentially the **same result**. So in the single-object benchmark, the variant with all three optimisations is basically **tied** with the variant with just optimisations 2 and 3.

An interesting thing to notice is that this is actually **super-additive**. If you look at the optimised clear path alone, it only achieves a **7%** reduction. And the dynamic array alone achieves a **36%** reduction. But together they achieve **81%** - far more than their sum. The reason is that they remove **different bottlenecks** of differing sizes. The **linked list is the biggest bottleneck**, but when we remove it, the **CAS becomes the biggest bottleneck** - so removing that on top of the linked list gives a much bigger improvement than removing it alone.

Another noteworthy observation is that the **separating skip-enqueue** optimisation shows almost **no effect** on this metric - just **5%** in the single-object benchmark. This is however, somewhat expected since this metric only captures **GC-internal work**. The **reference handler thread's load is not measured here**, so the benefit of routing queue-less references away from it doesn't show up.

For weak fields, the picture is also interesting. It achieves a **51%** reduction - clearly better than the baseline, but not as good as clear_path_dyn or all. And its performance is closely comparable to the **`sep_dyn`** variant - which makes sense, because weak fields only uses **those two pipeline optimisations** for the reasons we discussed earlier.

[change slide] (~25:37)

In the multi-object benchmark the same pattern holds -- **-57%** for the best variants. Weak fields sit at **19%**, again comparable to `sep_dyn`.

[change slide] (~25:47)

### Major Collection Time

Now let's look at what actually matters to **end users**: the **total major collection time**.

Here the story is **very different**. For all the `WeakReference` variants, the distributions are **broad and heavily overlapping**. The best variants, **`clear_path_dyn`** and **`all`**, sit about **8%** below the baseline in the single-object benchmark - but with distributions that **still overlap** substantially with each other and with the baseline. In the multi-object benchmark, the differences essentially **disappear into the noise** entirely.

For **`weak_fields`**, however, the picture is **clear and unambiguous**. In the single-object benchmark it reduces median major collection time by about **41%** relative to the baseline, and in the multi-object benchmark by about **28%**. Its distribution is also much **tighter**, with significantly less variability than any of the `WeakReference` variants.

[change slide] (~26:42)

### Memory Usage

Finally, let's take a look at memory usage.

All variants that use the **dynamic array** incur noticeably higher **auxiliary GC memory**. The **`clear_path_dyn`** variant is the worst, at about **10 times** the baseline auxiliary memory in the single-object benchmark. Adding the **separating skip-enqueue** - which is what `all` does on top of `clear_path_dyn` - reduces this by about **30%**, because the separation eliminates the need to **store the reference address** in each array entry. Even so, `all` still uses about **7 times** the baseline auxiliary memory in the single-object benchmark.

For **Java heap usage**, all `WeakReference` variants are **identical** since the optimisations don't change what objects are allocated on the heap. But `weak_fields` reduces heap usage by **53%** in the single-object benchmark and **5%** in the multi-object benchmark, simply because it **eliminates** those `WeakReference` objects.

[change slide] (~27:41)

## Conclusions

Alright, so what do all of these results actually tell us? First of all let me answer the **research questions**.

[change slide] (~27:50)

For **Research Question 1**: the best pipeline optimisations achieve an **81% reduction** in non-strong processing time, which is significant. But this translates to only an **8% reduction** in total major collection time, even in a benchmark specifically constructed to **maximise the fraction of GC time** spent on reference processing. That fraction, by the way, is **14%** of major collection time in the single-object baseline - and only **5%** in the multi-object baseline. So even if you could **eliminate reference processing entirely**, the best you could hope for is a **14% improvement** in a benchmark that only does reference processing. In any realistic application, the gain would be **far smaller**.

[change slide] (~28:38)

For **Research Question 2**: weak fields achieve a **41%** and **28%** reduction in major collection time, **far exceeding the 8%** from the pipeline variants. It also reduces Java heap usage by **53%** in the single-object benchmark and **5%** in the multi-object benchmark. These improvements **doesn't come from faster reference processing** - in fact, weak fields' non-strong processing time is **worse** than the best `WeakReference` variants. It instead comes from something much more **fundamental**: by **eliminating the `WeakReference` objects**, the weak fields variant reduces the amount of work the GC has to do across **every phase of every collection cycle** - marking, relocating, everything.

[change slide] (~29:23)

So the **key takeaway** is this: optimising the reference processing pipeline is **valuable**, but it faces a **hard ceiling** set by the fraction of time spent on reference processing. Weak fields, on the other hand, **breaks through this ceiling** thanks to the **removal of the `WeakReference` objects** from the GC-load. Which means, the **real bottleneck is the representation** not the processing pipeline. So in order to unlock meaningful improvement, the **way weak semantics are represented in Java needs to change**.

[change slide] (~29:58)

Thank you for listening!
