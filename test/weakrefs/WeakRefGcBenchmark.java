import java.lang.ref.ReferenceQueue;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.concurrent.TimeUnit;

public final class WeakRefGcBenchmark {

    private static final int DEFAULT_OBJECT_COUNT = 7340009;
    private static final int DEFAULT_MIN_SIZE = 509;
    private static final int DEFAULT_MAX_SIZE = 1097;
    private static final int DEFAULT_STRONG_HOLD_MILLIS = 3000;
    private static final int DEFAULT_ITERATIONS = 3;    

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
        int sleepMillis = DEFAULT_STRONG_HOLD_MILLIS;
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
            sleepMillis = Integer.parseInt(args[3]);
        }
        if (args.length > 4) {
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
        if (sleepMillis < 0) {
            sleepMillis = 0;
        }
        if (iterations < 1) {
            iterations = 1;
        }

        System.out.printf("WeakRefGcBenchmark: objects=%d minSize=%d maxSize=%d sleepMillis=%d iterations=%d%n",
            objectCount, minSize, maxSize, sleepMillis, iterations);

        for (int iter = 0; iter < iterations; iter++) {
            runIteration(iter, objectCount, minSize, maxSize, sleepMillis);
            
            System.out.println("Cooling down for 5 seconds...");
            Thread.sleep(TimeUnit.SECONDS.toMillis(5));
        }
    }

    @SuppressWarnings("unchecked")
    private static void runIteration(int iter, int objectCount, int minSize, int maxSize, 
                                       int sleepMillis) 
            throws InterruptedException {
        System.out.printf("%n=== Iteration %d ===%n", iter + 1);
        
        // Arrays to hold strong and weak references
        BigObject[] strongRefs = new BigObject[objectCount];
        WeakReference<BigObject>[] weakRefs = new WeakReference[objectCount];
        ReferenceQueue<BigObject> queue = new ReferenceQueue<>();
        Random random = new Random(0x5eedcafeL + iter);

        // Phase 1: Allocate strong refs to BigObjects in random order with padding
        System.out.println("Phase 1: Allocating references and objects...");
        long allocationStart = System.nanoTime();
        
        int[] strongOrder = shuffledIndices(objectCount, random);
        int[] weakOrder = shuffledIndices(objectCount, random);
        int queuedRefCount = objectCount / 20; // 5% of weak refs get a queue

        
        for (int i = 0; i < objectCount; i++) {
            int strongIdx = strongOrder[i];
            int size = randomSize(random, minSize, maxSize);
            BigObject obj = new BigObject(strongIdx, size);
            strongRefs[strongIdx] = obj;
            int weakIdx = weakOrder[i];
            if (i <= queuedRefCount) {
                weakRefs[weakIdx] = new WeakReference<>(obj, queue);
            } else {
                weakRefs[weakIdx] = new WeakReference<>(obj);
            }
        }
            

        long allocDuration = System.nanoTime() - allocationStart;
        System.out.printf("Allocated %d objects in %.2f seconds%n", objectCount, allocDuration / 1_000_000_000.0);
        

        // Phase 3: Hold everything still for a couple of seconds
        System.out.printf("Phase 2: Sleeping for %d ms...%n", sleepMillis);
        if (sleepMillis > 0) {
            Thread.sleep(sleepMillis);
        }

        // Phase 4-*: Repeatedly clear half of remaining strong refs until all are gone
        int subPhase = 1;
        int remainingRefs = objectCount;

        // Phase 3: Dummy write to ensure all objects are touched
        System.out.println("Phase 3: Touching all strong references...");
        for (int i = 0; i < objectCount; i++) {
            strongRefs[i].payload[0] = (byte) (strongRefs[i].id & 0xFF);
        }

        int [] clearOrder = shuffledIndices(objectCount, random);
        
        for (int j = 0 ; j < 5; j++) {
            // Count and clear half of remaining strong refs
            System.out.printf("Phase 4-%d: Clearing half of remaining strong references...%n", subPhase++);
            int toClear = (int)Math.ceil(objectCount/5);
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
                if (strongRefs[idx] != null) {
                    strongRefs[idx].payload[0] = (byte) (strongRefs[idx].id & 0xFF);
                }
            }
            
            remainingRefs -= clearedThisRound;
            System.out.printf("Cleared %d strong references, %d remaining%n", clearedThisRound, remainingRefs);
            
            // Wait
            System.out.printf("Waiting %d ms...%n", sleepMillis);
            if (sleepMillis > 0) {
                Thread.sleep(sleepMillis);
            }
        }

        System.out.printf("Phase 5: Final GC and weak reference check...%n");
        
        int aliveWeakRefs = AliveWeakRefs(weakRefs);
        System.out.printf("Final count of alive weak references: %d%n", aliveWeakRefs);

        // Empty the reference queue to see how many were enqueued
        int queuedCount = 0;
        while (queue.poll() != null) {
            queuedCount++;
        }
        System.out.printf("References enqueued in ReferenceQueue: %d%n", queuedCount);
        for (int i = 0; i < objectCount; i++) {
            if (strongRefs[i] != null) {
                System.out.printf("Error: strongRefs[%d] is not cleared!%n", i);
            }
        }
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