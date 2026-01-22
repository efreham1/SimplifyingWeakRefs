import java.lang.ref.ReferenceQueue;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.Random;

public final class WeakRefStress {

    private static final int DEFAULT_ITERATIONS = 20_000_000;
    private static final int DEFAULT_MIN_SIZE = 128;
    private static final int DEFAULT_MAX_SIZE = 1024;
    private static final int DEFAULT_MIN_STRONG = 8 * 1024;
    private static final int DEFAULT_MAX_STRONG = 1024 * 1024;
    private static final int DEFAULT_REPORT_INTERVAL = 100_000;

    static class BigObject {
        final int id;
        final byte[] data;

        BigObject(int id, int size) {
            this.id = id;
            this.data = new byte[size];
        }

        @Override
        public String toString() {
            return "BigObject#" + id + "(" + data.length + "b)";
        }
    }

    public static void main(String[] args) throws Exception {
        int iterations = DEFAULT_ITERATIONS;
        int minSize = DEFAULT_MIN_SIZE;
        int maxSize = DEFAULT_MAX_SIZE;
        int minStrong = DEFAULT_MIN_STRONG;
        int maxStrong = DEFAULT_MAX_STRONG;
        int reportInterval = DEFAULT_REPORT_INTERVAL;
        boolean usingWeakRefs = true;

        if (args.length > 0) {
            iterations = Integer.parseInt(args[0]);
        }
        if (args.length > 1) {
            minSize = Integer.parseInt(args[1]);
        }
        if (args.length > 2) {
            maxSize = Integer.parseInt(args[2]);
        }
        if (args.length > 3) {
            minStrong = Integer.parseInt(args[3]);
        }
        if (args.length > 4) {
            maxStrong = Integer.parseInt(args[3]);
        }
        if (args.length > 5) {
            reportInterval = Integer.parseInt(args[4]);
        }

        if (minSize < 1) {
            minSize = 1;
        }
        if (maxSize < minSize) {
            maxSize = minSize;
        }
        if (maxSize >= Integer.MAX_VALUE) {
            maxSize = Integer.MAX_VALUE - 1;
        }
        if (reportInterval < 1) {
            reportInterval = 1;
        }
        if (minStrong < 0) {
            minStrong = 0;
        }
        if (maxStrong < 0) {
            maxStrong = 0;
        }
        if (maxStrong < minStrong) {
            maxStrong = minStrong;
        }
        System.out.println("WeakRefStress: iterations=" + iterations
                + " minSize=" + minSize
                + " maxSize=" + maxSize
                + " maxStrong=" + maxStrong
                + " reportInterval=" + reportInterval);

        ArrayList<WeakReference<BigObject>> weakRefs = new ArrayList<>();
        ArrayList<BigObject> strongRefs = new ArrayList<>(minStrong);
        Random random = new Random(0x5eed1234L);

        long totalAllocatedBytes = 0;
        int nextId = 0;

        for (int iteration = 1; iteration <= minStrong; iteration++) {
            int size = randomSize(random, minSize, maxSize);
            BigObject obj = new BigObject(nextId++, size);
            totalAllocatedBytes += size;
            strongRefs.add(obj);
            if (usingWeakRefs) {
                int numRefs = 10 + random.nextInt(3);
                for (int i = 0; i < numRefs; i++) {
                    WeakReference<BigObject> weakRef = new WeakReference<>(obj);
                    weakRefs.add(weakRef);
                }
            }
        }

        for (int iteration = 1; iteration <= iterations; iteration++) {
            int size = randomSize(random, minSize, maxSize);
            BigObject obj = new BigObject(nextId++, size);
            totalAllocatedBytes += size;

            if (usingWeakRefs) {
                int numRefs = 10 + random.nextInt(3);
                for (int i = 0; i < numRefs; i++) {
                    WeakReference<BigObject> weakRef = new WeakReference<>(obj);
                    weakRefs.add(weakRef);
                }
            }

            if (strongRefs.size() < maxStrong) {
                strongRefs.add(obj);
            }

            if (!strongRefs.isEmpty() && random.nextInt(4) == 0) {
                dropRandomStrongRefs(random, strongRefs);
            }

            if (random.nextInt(6) == 0) {
                allocateEphemeralNoise(random, minSize, maxSize);
            }

            if (usingWeakRefs && iteration % 5000 == 0) {
                compactWeakRefs(weakRefs);
            }

            if (iteration % reportInterval == 0) {
                long aliveWeak = countAlive(weakRefs);
                double allocatedGb = totalAllocatedBytes / (1024.0 * 1024 * 1024);
                System.out.printf("step=%d allocated=%.2fGB alive_weak=%d strong=%d%n",
                        iteration, allocatedGb, aliveWeak, strongRefs.size());
            }

            if (iteration % 1_000_000 == 0) {
                System.gc();
            }
        }
        compactWeakRefs(weakRefs);
        long alive = countAlive(weakRefs);
        double allocatedGb = totalAllocatedBytes / (1024.0 * 1024 * 1024);
        System.out.printf("done allocated=%.2fGB alive_weak=%d strong=%d%n",
                allocatedGb, alive, strongRefs.size());
    }

    private static int randomSize(Random random, int minSize, int maxSize) {
        if (minSize >= maxSize) {
            return minSize;
        }
        int bound = maxSize - minSize + 1;
        return minSize + random.nextInt(bound);
    }

    private static void dropRandomStrongRefs(Random random, ArrayList<BigObject> strongRefs) {
        int limit = 3 + random.nextInt(3);
        for (int i = 0; i < limit && !strongRefs.isEmpty(); i++) {
            int idx = random.nextInt(strongRefs.size());
            int last = strongRefs.size() - 1;
            strongRefs.set(idx, strongRefs.get(last));
            strongRefs.remove(last);
        }
    }

    private static long countAlive(ArrayList<WeakReference<BigObject>> weakRefs) {
        long alive = 0;
        for (WeakReference<BigObject> ref : weakRefs) {
            if (ref.get() != null) {
                alive++;
            }
        }
        return alive;
    }

    private static void compactWeakRefs(ArrayList<WeakReference<BigObject>> weakRefs) {
        int write = 0;
        for (int read = 0; read < weakRefs.size(); read++) {
            WeakReference<BigObject> ref = weakRefs.get(read);
            if (ref.get() != null) {
                weakRefs.set(write++, ref);
            }
        }
        if (write < weakRefs.size()) {
            weakRefs.subList(write, weakRefs.size()).clear();
        }
    }

    private static void allocateEphemeralNoise(Random random, int minSize, int maxSize) {
        int arrays = 1 + random.nextInt(6);
        byte[][] noise = new byte[arrays][];
        for (int i = 0; i < arrays; i++) {
            int len = randomSize(random, minSize, maxSize);
            noise[i] = new byte[len];
        }
        if (noise.length > 0) {
            noise[0][0] = (byte) random.nextInt(256);
        }
    }
}
