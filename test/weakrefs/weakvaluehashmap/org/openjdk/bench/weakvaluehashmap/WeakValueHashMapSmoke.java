package org.openjdk.bench.weakvaluehashmap;

public final class WeakValueHashMapSmoke {
    private WeakValueHashMapSmoke() {
    }

    public static void main(String[] args) throws Exception {
        exerciseQueueVariant();
        exerciseNoQueueVariant();
        exerciseWeakFieldVariant();
        System.out.println("WeakValueHashMap smoke test completed");
    }

    private static void exerciseQueueVariant() throws Exception {
        QueueWeakValueHashMap<String, ValueHolder> map = new QueueWeakValueHashMap<>();
        ValueHolder stableValue = new ValueHolder("queue-stable");

        if (map.put("stable", stableValue) != null) {
            throw new AssertionError("queue put returned an unexpected previous value");
        }

        ValueHolder replacement = new ValueHolder("queue-replacement");
        if (map.put("stable", replacement) != stableValue) {
            throw new AssertionError("queue replace returned the wrong previous value");
        }
        if (map.get("stable") != replacement) {
            throw new AssertionError("queue get did not return the replacement value");
        }

        ValueHolder collectedValue = new ValueHolder("queue-collected");
        map.put("collected", collectedValue);
        collectedValue = null;

        awaitAutoCleared(map, "stable", replacement, 1);

        if (map.remove("stable") != replacement) {
            throw new AssertionError("queue remove returned the wrong value");
        }
        if (map.entryCount() != 0) {
            throw new AssertionError("queue map should be empty after removal");
        }
    }

    private static void exerciseNoQueueVariant() throws Exception {
        NoQueueWeakValueHashMap<String, ValueHolder> map = new NoQueueWeakValueHashMap<>();
        exerciseManualVariant("no-queue", map);
    }

    private static void exerciseWeakFieldVariant() throws Exception {
        WeakFieldValueHashMap<String, ValueHolder> map = new WeakFieldValueHashMap<>();
        exerciseManualVariant("weak-field", map);
    }

    private static void exerciseManualVariant(String label, ManagedWeakValueMap<String, ValueHolder> map)
            throws Exception {
        ValueHolder stableValue = new ValueHolder(label + "-stable");
        if (map.put("stable", stableValue) != null) {
            throw new AssertionError(label + " put returned an unexpected previous value");
        }

        ValueHolder replacement = new ValueHolder(label + "-replacement");
        if (map.put("stable", replacement) != stableValue) {
            throw new AssertionError(label + " replace returned the wrong previous value");
        }
        if (map.get("stable") != replacement) {
            throw new AssertionError(label + " get did not return the replacement value");
        }

        ValueHolder collectedValue = new ValueHolder(label + "-collected");
        map.put("collected", collectedValue);
        collectedValue = null;

        awaitStaleEntries(map, 1);

        if (map.entryCount() != 2) {
            throw new AssertionError(label + " should still contain the stale entry before cleanup");
        }
        if (map.cleanupStaleEntries() != 1) {
            throw new AssertionError(label + " cleanup should remove exactly one stale entry");
        }
        if (map.entryCount() != 1) {
            throw new AssertionError(label + " should only contain the stable entry after cleanup");
        }
        if (map.remove("stable") != replacement) {
            throw new AssertionError(label + " remove returned the wrong value");
        }
        if (map.entryCount() != 0) {
            throw new AssertionError(label + " map should be empty after removal");
        }
    }

    private static void awaitAutoCleared(ManagedWeakValueMap<String, ValueHolder> map, String probeKey,
            ValueHolder expectedProbeValue, int expectedEntries) throws Exception {
        for (int attempt = 0; attempt < 100; attempt++) {
            createAllocationPressure();
            System.gc();
            if (map.get(probeKey) == expectedProbeValue && map.entryCount() == expectedEntries) {
                return;
            }
            Thread.sleep(10L);
        }
        throw new AssertionError("Timed out waiting for automatic cleanup");
    }

    private static void awaitStaleEntries(ManagedWeakValueMap<String, ValueHolder> map, int expected)
            throws Exception {
        for (int attempt = 0; attempt < 100; attempt++) {
            createAllocationPressure();
            System.gc();
            if (map.staleEntries() >= expected) {
                return;
            }
            Thread.sleep(10L);
        }
        throw new AssertionError("Timed out waiting for a stale entry");
    }

    private static void createAllocationPressure() {
        byte[][] pressure = new byte[32][];
        for (int index = 0; index < pressure.length; index++) {
            pressure[index] = new byte[64 * 1024];
            pressure[index][0] = (byte) index;
        }
    }

    private static final class ValueHolder {
        private final String name;
        private final byte[] payload = new byte[256];

        ValueHolder(String name) {
            this.name = name;
            payload[0] = (byte) name.length();
        }

        @Override
        public String toString() {
            return name;
        }
    }
}