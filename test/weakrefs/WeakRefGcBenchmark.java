import java.lang.ref.Reference;
import java.lang.ref.ReferenceQueue;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.concurrent.TimeUnit;

public final class WeakRefGcBenchmark {

    private static final int DEFAULT_OBJECT_COUNT = 2_000_000;
    private static final int DEFAULT_MIN_SIZE = 256;
    private static final int DEFAULT_MAX_SIZE = 4 * 1024;
    private static final int DEFAULT_STRONG_HOLD_MILLIS = 250;
    private static final int DEFAULT_QUEUE_WAIT_MILLIS = 5_000;
    private static final int DEFAULT_WEAK_REF_PADDING_BYTES = 1_024;
    private static final int DEFAULT_ITERATIONS = 10;

    private static final class BigObject {
        final int id;
        final byte[] payload;

        BigObject(int id, int size) {
            this.id = id;
            this.payload = new byte[size];
        }
    }

    public static void main(String[] args) throws InterruptedException {
        int objectCount = DEFAULT_OBJECT_COUNT;
        int minSize = DEFAULT_MIN_SIZE;
        int maxSize = DEFAULT_MAX_SIZE;
        int holdMillis = DEFAULT_STRONG_HOLD_MILLIS;
        int weakRefPaddingBytes = DEFAULT_WEAK_REF_PADDING_BYTES;
        int iterations = DEFAULT_ITERATIONS;

        if (args.length > 0) {
            objectCount = Integer.parseInt(args[0]);
        }
        if (args.length > 1) {
            minSize = Integer.parseInt(args[1]);
        }
        if (args.length > 2) {
            maxSize = Integer.parseInt(args[2]);
        }
        if (args.length > 3) {
            holdMillis = Integer.parseInt(args[3]);
        }
        if (args.length > 4) {
            weakRefPaddingBytes = Integer.parseInt(args[4]);
        }
        if (args.length > 5) {
            iterations = Integer.parseInt(args[5]);
        }

        if (objectCount < 1) {
            objectCount = 1;
        }
        if (minSize < 1) {
            minSize = 1;
        }
        if (maxSize < minSize) {
            maxSize = minSize;
        }
        if (holdMillis < 0) {
            holdMillis = 0;
        }
        if (weakRefPaddingBytes < 0) {
            weakRefPaddingBytes = 0;
        }
        if (iterations < 1) {
            iterations = 1;
        }

        System.out.printf("WeakRefGcBenchmark: objects=%d minSize=%d maxSize=%d holdMillis=%d weakRefPaddingBytes=%d iterations=%d%n",
            objectCount, minSize, maxSize, holdMillis, weakRefPaddingBytes, iterations);

        for (int iter = 0; iter < iterations; iter++) {
            runIteration(iter, objectCount, minSize, maxSize, holdMillis, weakRefPaddingBytes);
        }
    }

    private static void runIteration(int iter, int objectCount, int minSize, int maxSize, 
                                       int holdMillis, int weakRefPaddingBytes) 
            throws InterruptedException {
        System.out.printf("%n=== Iteration %d ===%n", iter + 1);
        List<WeakReference<BigObject>> weakRefs = new ArrayList<>(objectCount);
        BigObject strongRef;
        ReferenceQueue<BigObject> queue = new ReferenceQueue<>();
        List<byte[]> weakRefPadding = weakRefPaddingBytes > 0 ? new ArrayList<>(objectCount) : null;
        int queuedRefTarget = objectCount;
        Random random = new Random(0x5eedcafeL + iter);

        long allocationStart = System.nanoTime();
        long totalAllocatedBytes = 0;
        for (int i = 0; i < objectCount; i++) {
            int size = randomSize(random, minSize, maxSize);
            totalAllocatedBytes += size;
            strongRef = new BigObject(i, size); // Hold a strong reference to the most recently allocated object
            WeakReference<BigObject> ref = (i < queuedRefTarget)
                    ? new WeakReference<>(strongRef, queue)
                    : new WeakReference<>(strongRef);
            weakRefs.add(ref);
            if (weakRefPadding != null) {
                int pad = weakRefPaddingBytes == 1
                        ? 1
                        : Math.max(1, weakRefPaddingBytes + random.nextInt(weakRefPaddingBytes));
                weakRefPadding.add(new byte[pad]);
            }
        }
        long allocationDuration = System.nanoTime() - allocationStart;

        double allocatedMiB = totalAllocatedBytes / (1024.0 * 1024.0);
        System.out.printf("Allocated %.1f MiB in %.3f s%n", allocatedMiB,
                allocationDuration / 1_000_000_000.0);

        for (int i = 0; i < objectCount/10; i++) {
            int size = randomSize(random, minSize, maxSize);
            strongRef = new BigObject(-1, size); // Allocate some additional objects to increase GC pressure
        }

        if (holdMillis > 0) {
            Thread.sleep(holdMillis);
        }
        if (weakRefPadding != null) {
            weakRefPadding.clear();
        }
        System.out.println("Cleared strong references and padding arrays");
        int clearedCount = 0;
        while (queue.poll() != null) {
            clearedCount++;
        }
        System.out.printf("Cleared %d weak references from the queue%n", clearedCount);
        long stillAlive = countAlive(weakRefs);
        System.out.printf("%d / %d objects still alive%n", stillAlive, objectCount);
    }

    private static int randomSize(Random random, int minSize, int maxSize) {
        if (minSize == maxSize) {
            return minSize;
        }
        int bound = maxSize - minSize + 1;
        return minSize + random.nextInt(bound);
    }

    private static long countAlive(List<WeakReference<BigObject>> weakRefs) {
        long alive = 0;
        for (WeakReference<BigObject> ref : weakRefs) {
            if (ref.get() != null) {
                alive++;
            }
        }
        return alive;
    }
}