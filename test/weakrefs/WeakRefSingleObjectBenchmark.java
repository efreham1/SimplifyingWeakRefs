import java.lang.ref.ReferenceQueue;
import java.lang.ref.WeakReference;
import java.util.Random;
import java.lang.ref.Reference;

/**
 * Benchmark that allocates many WeakReferences all pointing to a single object,
 * then removes the strong reference to that object and observes GC behaviour.
 *
 * The weak references are stored in shuffled (random) order to reflect realistic
 * allocation patterns where refs and other objects are interleaved.
 */
public final class WeakRefSingleObjectBenchmark {

    private static final int DEFAULT_OBJECT_COUNT       = 10000000;
    private static final int DEFAULT_STRONG_HOLD_MILLIS = 500;

    private static final class BigObject {
        final int id;
        final byte[] payload;

        BigObject(int id, int size) {
            this.id = id;
            this.payload = new byte[size];
        }
    }

    public static void main(String[] args) throws InterruptedException {
        int weakRefCount  = DEFAULT_OBJECT_COUNT;
        int sleepMillis   = DEFAULT_STRONG_HOLD_MILLIS;

        if (args.length > 0) weakRefCount = Integer.parseInt(args[0]);
        if (args.length > 1) sleepMillis  = Integer.parseInt(args[1]);

        if (weakRefCount < 1) weakRefCount = 1;
        if (sleepMillis  < 0) sleepMillis  = 0;

        System.out.printf(
            "WeakRefSingleObjectBenchmark: weakRefCount=%d sleepMillis=%d%n",
            weakRefCount, sleepMillis);
            
        System.out.printf("%n=== Iteration 1 ===%n");

        ReferenceQueue<BigObject> queue   = new ReferenceQueue<>();
        @SuppressWarnings("unchecked")
        WeakReference<BigObject>[] weakRefs = new WeakReference[weakRefCount];
        Random random = new Random(0x5eedcafeL);

        // Phase 1: Allocate the single target object
        System.out.println("Phase 1: Allocating the single target object...");
        BigObject target = new BigObject(0, 1024);

        // Phase 2: Allocate all WeakReferences pointing at the single object.
        //          Stored in shuffled order to reflect realistic interleaved allocation.
        System.out.printf("Phase 2: Allocating %d WeakReferences in random order...%n", weakRefCount);
        long allocationStart = System.nanoTime();

        int[] storeOrder   = shuffledIndices(weakRefCount, random);

        for (int i = 0; i < weakRefCount; i++) {
            weakRefs[storeOrder[i]] = new WeakReference<>(target);
        }

        long allocDuration = System.nanoTime() - allocationStart;
        System.out.printf("Allocated %d WeakReferences in %.2f seconds%n",
            weakRefCount, allocDuration / 1_000_000_000.0);

        // Phase 3: Sleep for a couple of seconds
        System.out.printf("Phase 3: Sleeping for %d ms (strong ref still held)...%n", sleepMillis);
        if (sleepMillis > 0) {
            Thread.sleep(sleepMillis);
        }

        // Phase 4: Drop the single strong reference
        System.out.println("Phase 4: Releasing the strong reference to the target object...");
        Reference.reachabilityFence(target);
        target = null;


        // Phase 5: Trigger GC
        System.out.println("Phase 5: Triggering GC...");
        System.gc();
        Thread.sleep(2000); // Give GC some time to collect stats

        // Phase 6: Check results
        System.out.println("Phase 6: Checking results...");
        int aliveCount = countAlive(weakRefs);
        System.out.printf("Alive weak references after GC: %d / %d%n", aliveCount, weakRefCount);

        int queuedCount = 0;
        while (queue.poll() != null) {
            queuedCount++;
        }
        System.out.printf("References enqueued in ReferenceQueue: %d%n", queuedCount);
    }
    private static int[] shuffledIndices(int count, Random random) {
        int[] indices = new int[count];
        for (int i = 0; i < count; i++) {
            indices[i] = i;
        }
        // Fisher-Yates shuffle
        for (int i = count - 1; i > 0; i--) {
            int j = random.nextInt(i + 1);
            int temp = indices[i];
            indices[i] = indices[j];
            indices[j] = temp;
        }
        return indices;
    }

    private static int countAlive(WeakReference<BigObject>[] weakRefs) {
        int alive = 0;
        for (WeakReference<BigObject> ref : weakRefs) {
            if (ref.get() != null) {
                alive++;
            }
        }
        return alive;
    }
}
