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
        int queueWaitMillis = DEFAULT_QUEUE_WAIT_MILLIS;
        int weakRefPaddingBytes = DEFAULT_WEAK_REF_PADDING_BYTES;

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
            queueWaitMillis = Integer.parseInt(args[5]);
        }
        if (args.length > 5) {
            weakRefPaddingBytes = Integer.parseInt(args[6]);
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
        if (queueWaitMillis < 0) {
            queueWaitMillis = 0;
        }
        if (weakRefPaddingBytes < 0) {
            weakRefPaddingBytes = 0;
        }

        System.out.printf("WeakRefGcBenchmark: objects=%d minSize=%d maxSize=%d holdMillis=%d queueWaitMillis=%d weakRefPaddingBytes=%d%n",
            objectCount, minSize, maxSize, holdMillis, queueWaitMillis, weakRefPaddingBytes);
        List<WeakReference<BigObject>> weakRefs = new ArrayList<>(objectCount);
        List<BigObject> strongRefs = new ArrayList<>(objectCount);
        ReferenceQueue<BigObject> queue = new ReferenceQueue<>();
        List<byte[]> weakRefPadding = weakRefPaddingBytes > 0 ? new ArrayList<>(objectCount) : null;
        int queuedRefTarget = Math.min(3, objectCount);
        Random random = new Random(0x5eedcafeL);

        long allocationStart = System.nanoTime();
        long totalAllocatedBytes = 0;
        for (int i = 0; i < objectCount; i++) {
            int size = randomSize(random, minSize, maxSize);
            BigObject obj = new BigObject(i, size);
            totalAllocatedBytes += size;
            strongRefs.add(obj);
            WeakReference<BigObject> ref = (i < queuedRefTarget)
                    ? new WeakReference<>(obj, queue)
                    : new WeakReference<>(obj);
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

        if (holdMillis > 0) {
            Thread.sleep(holdMillis);
        }
        for (int i = 0; i < 3; i++) {
            System.gc();
        }
        strongRefs.clear();
        if (weakRefPadding != null) {
            weakRefPadding.clear();
        }
        System.out.println("Cleared strong references and padding arrays");
        long gcStart = System.nanoTime();
        System.gc();
        long gcDuration = System.nanoTime() - gcStart;
        System.out.printf("System.gc() took %.3f ms%n",
            gcDuration / 1_000_000.0);

        int enqueued = awaitQueue(queue, queuedRefTarget, queueWaitMillis);
        System.out.printf("Queued references collected=%d/%d%n",
            enqueued, queuedRefTarget);

        long stillAlive = countAlive(weakRefs);
        System.out.printf("After GC: %d / %d objects still alive%n", stillAlive, objectCount);
    }

    private static int randomSize(Random random, int minSize, int maxSize) {
        if (minSize == maxSize) {
            return minSize;
        }
        int bound = maxSize - minSize + 1;
        return minSize + random.nextInt(bound);
    }


    private static int awaitQueue(ReferenceQueue<BigObject> queue, int expected, int timeoutMillis)
            throws InterruptedException {
        int enqueued = 0;
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis);
        while (enqueued < expected) {
            long now = System.nanoTime();
            long remaining = deadline - now;
            if (remaining <= 0) {
                break;
            }
            Reference<? extends BigObject> ref = queue.remove(TimeUnit.NANOSECONDS.toMillis(remaining));
            if (ref != null) {
                enqueued++;
            }
        }
        Reference<? extends BigObject> ref;
        while ((ref = queue.poll()) != null) {
            enqueued++;
        }
        return enqueued;
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
