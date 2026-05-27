# Thesis Defence Script

## Opening

OK, so everyone's feeling ready? Perfect. Then I'll go ahead.

Hello everyone, my name is Fredrik and this is my thesis defence. My thesis is titled Optimising Weak References in ZGC, and to some of you that likely sounds like a load of gibberish. But my hope is that by the end of this presentation it will no longer sound like gibberish, and you'll also understand what my thesis has been about and the results I've actually gotten. So without further ado, I think we can just jump right into it.

## Agenda

As we can see in the agenda, we'll start off with some important background information -- this is hopefully where the gibberish title of this thesis actually starts making sense to everyone. After that, we will go into the motivation, establishing why the work I've done actually matters -- kind of important. Then we will go into the design and implementation of my actual solution and the code I've written. After that, we will look at the results from the benchmarking and testing I did, as well as the analysis and discussion of those results. And finally, to round it all out, we will look at the conclusions I've come to during my thesis and how they tie into the broader field. And after that, there will of course be time for some questions, which is why I ask you to hold onto your questions until the end.

## Background

Alright then, let's jump into the background to understand all this gibberish. It's actually not as bad as it sounds.

### Java and the JVM

To start off, we have the programming language Java. Most of you should at least have heard of it before -- if not, that's also fine. Java is an object-oriented language that is extremely popular. It's one of the most used languages in the world. One big selling point of Java is that it can run on any machine, completely regardless of the architecture. So you write once, compile once, and the code can just run anywhere, which is very neat indeed.

How this is achieved is through something called a JVM, or Java Virtual Machine. A JVM is, in its most basic form, just a virtual machine that can run Java -- hence Java Virtual Machine. The most popular implementation of a JVM is the HotSpot JVM, developed by Oracle, which is also the company where I did my master's thesis, and therefore the JVM I did my implementation in.

### Garbage Collection

In Java, you don't actually have to manage memory like in languages such as C or C++, which some of you might be familiar with. Instead, it's an automatically managed memory system. How this is achieved is that HotSpot has a garbage collector. This garbage collector goes through and finds what memory the application is no longer using, and then returns that memory to the operating system. One thing to note here is that Hotspot actually has several implementations of garbage collectors and that the user can choose which one to use when executing a Java program. One of these garbage collectors is called ZGC, which is the one I did my implementation in, and the one I will be talking about for the rest of this presentation.

ZGC is fundamentally a concurrent relocating garbage collector. So what does that mean? It means that it runs concurrently with the application -- that is, it doesn't stop the application while it's doing garbage collection, and it also means that it relocates alive objects in memory and lets the rest of the memory be reused, in other words the memory containing the dead objects.

So how does this work? To understand that, we can take a look at this illustration here. You can think of this big box as the memory allotted to this specific process on the computer. In this memory, the objects that the Java program uses are spread out in different parts. So we have object A here, object B here, and object C here. And then off to the left we have something called the root set, which contains everything that is known to be alive -- things we should never garbage collect.

All these objects and the root set interact in various ways. For example, object A might contain a reference to object B. And the stack might have a reference to object C.

When we actually start garbage collecting we have to find everything that is alive, and alive in this case means, reachable from the root set -- because if it's reachable from the root set, that means the application can reach it, which means the application can use it. So in this case we can quite clearly see that C is reachable, but A and B, even though A has an edge to B, is not actually reachable from the root set. So that means we mark C as alive and keep A and B as dead.

Once this is done, we get to the relocating phase, which is basically that we take C and move it to a new piece of memory over here. And when that is done, we mark the old memory region as reusable, meaning it can eventually be overwritten by new objects. So yeah, that is basically how ZGC works.

In reality, of course, garbage collection and ZGC is much more complicated than this, but in the interest of time and focusing on what I've done for this thesis, I won't go any further into it.

### Weak References

So that's ZGC! But there is a slight problem with having references be the thing that keeps objects alive. Because if we find ourselves in a situation while programming where we want to be able to read, for example, object A as long as it is reachable from the root set -- but as soon as A is no longer reachable from the root set, we no longer want to be able to read it -- with what I've talked about so far, this is impossible. Because if we can read it, that means we have a reference to it, which means it won't become unreachable from the root set even if there are no other references to it.

How this problem is solved is something called a weak reference. A weak reference is a reference in the sense that we can read the object through it, but it's weak in the sense that it won't actually keep the object alive.

So if we go back to our graph, let's say for example that C has a weak reference to B, and we represent this by a dotted edge. In this case, where B is not reachable from the root set via any strong reference, we can't use the reference going from C to B, because it's a weak reference, and this weak reference will also not keep B alive. So when we do the relocation, we will just relocate C.

But let's change up this graph a bit. Let's add a strong reference from the root set to A, so it now looks like this. And in this case, we Can use the reference that goes from C to B, since B is reachable through A. So this is what a weak reference does -- it allows us to conditionally reach an object based on whether it is reachable from the root set or not.

Looking at weak references in a graph is fine -- it's clear whether something is reachable or not. But actually getting this to work in code is quite a bit more difficult. To understand the implementation I've done, and the results and conclusions I've come to, we need to understand a little bit of how Java implements weak references and how ZGC processes them. So let's take a look at that.

#### The WeakReference wrapper object

In Java, weak references are implemented as separate objects. The graph I showed earlier was actually a simplification -- let's look at how it really looks. As we can see, there is a new object in the graph. That is the `WeakReference` object. C has a strong reference to it, and the `WeakReference` object itself holds the actual weak reference pointing to B.

This might seem counterintuitive -- why do we need this extra object? But there is a good reason. When programming with weak references, there are often scenarios where you want to know when a weak reference becomes inactive, meaning the object it pointed to has been garbage collected. How this works in Java is that when you create a `WeakReference` like this [show code], you can optionally pass in a `ReferenceQueue`. You can then poll that queue to ask "have any new references been added?" Once a weak reference is cleared by the garbage collector, the `WeakReference` object gets added to this queue. You can then retrieve it and, for example, clean up a cache or do whatever is appropriate.

You can also create a `WeakReference` without a `ReferenceQueue` if you just want the conditional reachability we discussed earlier -- also known as weak semantics. So yeah, that is why we have this extra object in our graph, and that is how weak references are implemented in Java.

#### Reference processing pipeline

Now let me talk about how ZGC actually processes these weak references. When ZGC does a GC cycle -- going through all the objects and deciding what to relocate and what to delete -- it also searches for weak references. It can't decide during the marking walk whether a weak reference should be cleared, because it hasn't seen the entire object graph yet. So instead, each discovered weak reference is added to a discovered list. We continue marking through the graph, adding each newly found weak reference to this list as we go.

Once we've marked the entire object graph, we take this discovered list and start processing it. For each `WeakReference` in the list, we check whether its referent -- the object it points to -- is alive. If it is, we leave it alone. But if the referent is dead, we need to act. First, we null out the field holding the address of the referent, so it no longer points to the dead object -- because that would be a dangling pointer, which is of course bad. Then we add the `WeakReference` object to a pending list, to be enqueued later. We do this for every entry in the discovered list.

Once the discovered list is empty, the pending list is handed to the reference handler thread in HotSpot, which is responsible for placing each reference into its correct `ReferenceQueue` -- since there might be multiple threads with different queues, or a single thread with multiple queues. Once that is done, it's up to the application to poll its queues.

And that is the entire pipeline: discovery, processing, and finally enqueueing.




