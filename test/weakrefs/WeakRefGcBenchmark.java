import java.lang.ref.ReferenceQueue;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.concurrent.TimeUnit;

public final class WeakRefGcBenchmark {

    private static final int DEFAULT_OBJECT_COUNT = 2287*2293;
    private static final int DEFAULT_MIN_SIZE = 67;
    private static final int DEFAULT_MAX_SIZE = 509;
    private static final int DEFAULT_STRONG_HOLD_MILLIS = 3000;
    private static final int DEFAULT_WEAK_REF_PADDING_BYTES = 521;
    private static final int DEFAULT_ITERATIONS = 2;    

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
            
            System.out.println("Cooling down for 5 seconds...");
            Thread.sleep(TimeUnit.SECONDS.toMillis(5));
        }
    }

    @SuppressWarnings("unchecked")
    private static void runIteration(int iter, int objectCount, int minSize, int maxSize, 
                                       int holdMillis, int weakRefPaddingBytes) 
            throws InterruptedException {
        System.out.printf("%n=== Iteration %d ===%n", iter + 1);
        
        // Arrays to hold strong and weak references
        BigObject[] strongRefs = new BigObject[objectCount];
        WeakReference<BigObject>[] weakRefs = new WeakReference[objectCount];
        ReferenceQueue<BigObject> queue = new ReferenceQueue<>();
        List<byte[]> strongPadding = new ArrayList<>(objectCount);
        List<byte[]> weakPadding = new ArrayList<>(objectCount);
        Random random = new Random(0x5eedcafeL + iter);

        // Phase 1: Allocate strong refs to BigObjects in random order with padding
        System.out.println("Phase 1: Allocating strong references...");
        long allocationStart = System.nanoTime();
        long totalAllocatedBytes = 0;
        
        int[] strongOrder = shuffledIndices(objectCount, random);
        for (int idx : strongOrder) {
            int size = randomSize(random, minSize, maxSize);
            totalAllocatedBytes += size;
            strongRefs[idx] = new BigObject(idx, size);
            
            // Allocate padding between strong ref allocations
            if (weakRefPaddingBytes > 0) {
                int pad = weakRefPaddingBytes == 1
                        ? 1
                        : Math.max(1, weakRefPaddingBytes + random.nextInt(weakRefPaddingBytes));
                strongPadding.add(new byte[pad]);
            }
        }
        
        long strongAllocDuration = System.nanoTime() - allocationStart;
        double allocatedMiB = totalAllocatedBytes / (1024.0 * 1024.0);
        System.out.printf("Allocated %d strong refs (%.1f MiB) in %.3f s%n", 
                objectCount, allocatedMiB, strongAllocDuration / 1_000_000_000.0);

        for (int i = 0; i < objectCount; i++) {
            strongRefs[i].payload[0] = (byte) (strongRefs[i].id & 0xFF);
        }

        // Phase 2: Allocate weak refs in random order with padding, pointing to unique BigObjects
        System.out.println("Phase 2: Allocating weak references...");
        long weakAllocStart = System.nanoTime();
        
        int[] weakOrder = shuffledIndices(objectCount, random);
        int[] targetMapping = shuffledIndices(objectCount, random); // Map weak refs to unique strong refs
        int queuedRefCount = objectCount / 20; // 5% of weak refs get a queue
        
        for (int i = 0; i < objectCount; i++) {
            int weakIdx = weakOrder[i];
            int targetIdx = targetMapping[i];
            BigObject target = strongRefs[targetIdx];
            
            // 5% of weak refs use the reference queue
            if (i < queuedRefCount) {
                weakRefs[weakIdx] = new WeakReference<>(target, queue);
            } else {
                weakRefs[weakIdx] = new WeakReference<>(target);
            }
            
            // Allocate padding between weak ref allocations
            if (weakRefPaddingBytes > 0) {
                int pad = weakRefPaddingBytes == 1
                        ? 1
                        : Math.max(1, weakRefPaddingBytes + random.nextInt(weakRefPaddingBytes));
                weakPadding.add(new byte[pad]);
            }
        }
        
        long weakAllocDuration = System.nanoTime() - weakAllocStart;
        System.out.printf("Allocated %d weak refs (%d with queue) in %.3f s%n", 
                objectCount, queuedRefCount, weakAllocDuration / 1_000_000_000.0);

        // Phase 3: Hold everything still for a couple of seconds
        System.out.printf("Phase 3: Holding still for %d ms...%n", holdMillis);
        if (holdMillis > 0) {
            Thread.sleep(holdMillis);
        }
        
        System.out.println("Phase 4: Starting to clear strong references in phases...");

        // Phase 4-*: Repeatedly clear half of remaining strong refs until all are gone
        int subPhase = 1;
        int remainingRefs = objectCount;

        int [] clearOrder = shuffledIndices(objectCount, random);
        
        for (int j = 0 ; j < 5; j++) {
            // Count and clear half of remaining strong refs
            System.out.printf("Phase 4-%d: Clearing half of remaining strong references...%n", subPhase++);
            int toClear = (int)Math.ceil(remainingRefs/5);
            int clearedThisRound = 0;
            int i = 0;
            for (; i < objectCount && clearedThisRound < toClear; i++) {
                int idx = clearOrder[i];
                if (strongRefs[idx] != null) {
                    strongRefs[idx] = null;
                    clearedThisRound++;
                }
            }
            for (; i < objectCount; i++) {
                int idx = clearOrder[i];
                strongRefs[idx].payload[0] = (byte) (strongRefs[idx].id & 0xFF);
            }
            
            remainingRefs -= clearedThisRound;
            System.out.printf("Cleared %d strong references, %d remaining%n", clearedThisRound, remainingRefs);
            
            // Wait
            System.out.printf("Waiting %d ms...%n", holdMillis);
            if (holdMillis > 0) {
                Thread.sleep(holdMillis);
            }
        }

        System.out.printf("Phase 5: Final GC and weak reference check...%n");
        
        // Clear padding to allow GC
        strongPadding.clear();
        weakPadding.clear();
        int aliveWeakRefs = AliveWeakRefs(weakRefs);
        System.out.printf("Final count of alive weak references: %d%n", aliveWeakRefs);

        // Empty the reference queue to see how many were enqueued
        int queuedCount = 0;
        while (queue.poll() != null) {
            queuedCount++;
        }
        System.out.printf("References enqueued in ReferenceQueue: %d%n", queuedCount);
    }

    private static int randomSize(Random random, int minSize, int maxSize) {
        if (minSize == maxSize) {
            return minSize;
        }
        int bound = maxSize - minSize + 1;
        return minSize + random.nextInt(bound);
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

    private static int AliveWeakRefs(WeakReference<BigObject>[] weakRefs) {
        int aliveCount = 0;
        for (WeakReference<BigObject> ref : weakRefs) {
            if (ref.get() != null) {
                aliveCount++;
            }
        }
        return aliveCount;
    }
}