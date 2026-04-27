import java.lang.ref.Reference;
import java.lang.ref.weak;
import java.util.Random;

public final class WeakFieldMultiObjectBenchmark {

    private static final int DEFAULT_OBJECT_COUNT = 7340009;
    private static final int DEFAULT_MIN_SIZE = 509;
    private static final int DEFAULT_MAX_SIZE = 1097;
    private static final int DEFAULT_STRONG_HOLD_MILLIS = 3000;

    private static final class BigObject {
        final int id;
        final byte[] payload;

        BigObject(int id, int size) {
            this.id = id;
            this.payload = new byte[size];
        }
    }

    private static final class WeakRefHolder<T> {
        @weak
        private T referent;

        WeakRefHolder(T referent) {
            this.referent = referent;
        }

        T get() {
            return referent;
        }
    }

    public static void main(String[] args) throws InterruptedException {
        int objectCount = DEFAULT_OBJECT_COUNT;
        int minSize = DEFAULT_MIN_SIZE;
        int maxSize = DEFAULT_MAX_SIZE;
        int sleepMillis = DEFAULT_STRONG_HOLD_MILLIS;

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

        System.out.printf("WeakFieldMultiObjectBenchmark: objects=%d minSize=%d maxSize=%d sleepMillis=%d%n",
            objectCount, minSize, maxSize, sleepMillis);

        runBenchmark(objectCount, minSize, maxSize, sleepMillis);
    }

    @SuppressWarnings("unchecked")
    private static void runBenchmark(int objectCount, int minSize, int maxSize, int sleepMillis)
            throws InterruptedException {
        BigObject[] strongRefs = new BigObject[objectCount];
        WeakRefHolder<BigObject>[] weakRefHolders = new WeakRefHolder[objectCount];
        Random random = new Random(0x5eedcafeL);

        System.out.println("Phase 1: Allocating references and objects...");
        long allocationStart = System.nanoTime();

        int[] strongOrder = shuffledIndices(objectCount, random);
        int[] weakOrder = shuffledIndices(objectCount, random);

        for (int i = 0; i < objectCount; i++) {
            int strongIdx = strongOrder[i];
            int size = randomSize(random, minSize, maxSize);
            BigObject obj = new BigObject(strongIdx, size);
            strongRefs[strongIdx] = obj;

            int weakIdx = weakOrder[i];
            weakRefHolders[weakIdx] = new WeakRefHolder<>(obj);
        }

        long allocDuration = System.nanoTime() - allocationStart;
        System.out.printf("Allocated %d objects in %.2f seconds%n", objectCount, allocDuration / 1_000_000_000.0);

        System.out.printf("Phase 2: Sleeping for %d ms...%n", sleepMillis);
        if (sleepMillis > 0) {
            Thread.sleep(sleepMillis);
        }

        int subPhase = 1;
        int remainingRefs = objectCount;
        int[] clearOrder = shuffledIndices(objectCount, random);
        int i = 0;
        for (int j = 0; j < 5; j++) {
            System.out.printf("Phase 3.%d: Clearing strong references...%n", subPhase++);
            int toClear = objectCount / 5 + 1;
            int clearedThisRound = 0;
            for (; i < objectCount && clearedThisRound < toClear; i++) {
                int idx = clearOrder[i];
                if (strongRefs[idx] != null) {
                    strongRefs[idx] = null;
                    clearedThisRound++;
                }
            }

            remainingRefs -= clearedThisRound;
            System.out.printf("Cleared %d strong references, %d remaining%n", clearedThisRound, remainingRefs);

            System.out.println("Triggering GC manually...");
            System.gc();
        }

        Reference.reachabilityFence(strongRefs);

        System.out.printf("Phase 4: Final annotated field checks...%n");

        int aliveWeakRefHolders = countAlive(weakRefHolders);
        System.out.printf("Final count of alive annotated fields: %d%n", aliveWeakRefHolders);

        for (i = 0; i < objectCount; i++) {
            if (strongRefs[i] != null) {
                System.out.printf("Error: strongRefs[%d] is not cleared!%n", i);
            }
        }
        
        Thread.sleep(2000);
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
        for (int i = count - 1; i > 0; i--) {
            int j = random.nextInt(i + 1);
            int temp = indices[i];
            indices[i] = indices[j];
            indices[j] = temp;
        }
        return indices;
    }

    private static int countAlive(WeakRefHolder<BigObject>[] weakRefHolders) {
        int aliveCount = 0;
        for (WeakRefHolder<BigObject> ref : weakRefHolders) {
            if (ref.get() != null) {
                aliveCount++;
            }
        }
        return aliveCount;
    }
}