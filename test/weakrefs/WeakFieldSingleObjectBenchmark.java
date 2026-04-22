import java.lang.ref.Reference;
import java.lang.ref.weak;
import java.util.Random;

/**
 * Benchmark that allocates many annotated weak holders all pointing to a single
 * object, then removes the strong reference to that object and observes GC
 * behaviour.
 */
public final class WeakFieldSingleObjectBenchmark {

    private static final int DEFAULT_OBJECT_COUNT = 10000000;
    private static final int DEFAULT_STRONG_HOLD_MILLIS = 500;

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
        int weakRefCount = DEFAULT_OBJECT_COUNT;
        int sleepMillis = DEFAULT_STRONG_HOLD_MILLIS;

        if (args.length > 0) {
            weakRefCount = Integer.parseInt(args[0]);
        }
        if (args.length > 1) {
            sleepMillis = Integer.parseInt(args[1]);
        }

        if (weakRefCount < 1) {
            weakRefCount = 1;
        }
        if (sleepMillis < 0) {
            sleepMillis = 0;
        }

        System.out.printf("WeakFieldSingleObjectBenchmark: weakRefCount=%d sleepMillis=%d%n",
            weakRefCount, sleepMillis);

        @SuppressWarnings("unchecked")
        WeakRefHolder<BigObject>[] weakRefHolders = new WeakRefHolder[weakRefCount];
        Random random = new Random(0x5eedcafeL);

        System.out.println("Phase 1: Allocating the single target object...");
        BigObject target = new BigObject(0, 1024);

        System.out.printf("Phase 2: Allocating %d weak holders in random order...%n", weakRefCount);
        long allocationStart = System.nanoTime();

        int[] storeOrder = shuffledIndices(weakRefCount, random);
        for (int i = 0; i < weakRefCount; i++) {
            weakRefHolders[storeOrder[i]] = new WeakRefHolder<>(target);
        }

        long allocDuration = System.nanoTime() - allocationStart;
        System.out.printf("Allocated %d weak holders in %.2f seconds%n",
            weakRefCount, allocDuration / 1_000_000_000.0);

        System.out.printf("Phase 3: Sleeping for %d ms (strong ref still held)...%n", sleepMillis);
        if (sleepMillis > 0) {
            Thread.sleep(sleepMillis);
        }

        System.out.println("Phase 4: Releasing the strong reference to the target object...");
        Reference.reachabilityFence(target);
        target = null;

        System.out.println("Phase 5: Triggering GC...");
        System.gc();

        System.out.println("Phase 6: Checking results...");
        int aliveCount = countAlive(weakRefHolders);
        System.out.printf("Alive weak holders after GC: %d / %d%n", aliveCount, weakRefCount);

        Thread.sleep(2000); // Give GC some time to collect stats
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
        int alive = 0;
        for (WeakRefHolder<BigObject> ref : weakRefHolders) {
            if (ref.get() != null) {
                alive++;
            }
        }
        return alive;
    }
}