package org.openjdk.bench.weakvaluehashmap;

import java.util.ArrayList;
import java.util.Random;
import org.openjdk.jmh.annotations.Level;
import org.openjdk.jmh.annotations.Param;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.TearDown;
import org.openjdk.jmh.infra.Blackhole;

public abstract class WeakValueHashMapBenchmarkSupport {
    static final class Key {
        final int id;
        final byte[] payload;
        private final int hash;

        Key(int id, int payloadSize) {
            this.id = id;
            this.payload = new byte[payloadSize];
            this.hash = 31 * id + 0x9e3779b9;
        }

        @Override
        public boolean equals(Object other) {
            return other instanceof Key key && key.id == id;
        }

        @Override
        public int hashCode() {
            return hash;
        }
    }

    static final class Value {
        final int ownerId;
        final int version;
        final byte[] payload;

        Value(int ownerId, int version, int payloadSize) {
            this.ownerId = ownerId;
            this.version = version;
            this.payload = new byte[payloadSize];
        }
    }

    private static final class Slot {
        final int id;
        final Key key;
        private int version;
        private Value value;

        Slot(int id, int keyPayloadSize, int valuePayloadSize) {
            this.id = id;
            this.key = new Key(id, keyPayloadSize);
            this.value = new Value(id, version, valuePayloadSize);
        }

        Value currentValue() {
            return value;
        }

        void retireValue() {
            value = null;
        }

        Value replaceValue(int valuePayloadSize) {
            value = new Value(id, ++version, valuePayloadSize);
            return value;
        }
    }

    @State(Scope.Thread)
    public abstract static class BaseState {
        @Param({"4096"})
        public int liveSet;

        @Param({"64"})
        public int keyPayloadSize;

        @Param({"256"})
        public int valuePayloadSize;

        @Param({"32"})
        public int lookupsPerInvocation;

        @Param({"8"})
        public int replacementsPerInvocation;

        @Param({"16"})
        public int retirementsPerInvocation;

        private final ArrayList<Slot> slots = new ArrayList<>();
        private final ArrayList<Slot> retiredSlots = new ArrayList<>();
        private final Random random = new Random(0x5eedc0deL);
        private ManagedWeakValueMap<Key, Value> map;
        private int nextId;

        protected abstract ManagedWeakValueMap<Key, Value> createMap();

        @Setup(Level.Trial)
        public void setupTrial() {
            map = createMap();
            slots.clear();
            retiredSlots.clear();
            nextId = 0;

            for (int index = 0; index < liveSet; index++) {
                Slot slot = new Slot(nextId++, keyPayloadSize, valuePayloadSize);
                slots.add(slot);
                map.put(slot.key, slot.currentValue());
            }
        }

        @TearDown(Level.Iteration)
        public void verifyIteration() {
            map.cleanupStaleEntries();
            if (map.staleEntries() != 0) {
                throw new AssertionError("Unexpected stale entry count: " + map.staleEntries());
            }
            if (map.entryCount() != slots.size()) {
                throw new AssertionError("Unexpected map size: " + map.entryCount() + ", expected " + slots.size());
            }
            for (Slot slot : slots) {
                Value expected = slot.currentValue();
                if (expected == null) {
                    throw new AssertionError("Slot should have been repopulated before verification");
                }
                Value actual = map.get(slot.key);
                if (actual != expected) {
                    throw new AssertionError("Value mismatch for key id " + slot.id);
                }
            }
        }

        public int lookupMany(Blackhole blackhole) {
            int checksum = 0;
            for (int index = 0; index < lookupsPerInvocation; index++) {
                Slot slot = randomLiveSlot();
                Value expected = slot.currentValue();
                Value actual = map.get(slot.key);
                if (actual != expected) {
                    throw new AssertionError("Missing live value for key id " + slot.id);
                }
                checksum += actual.ownerId ^ actual.version;
                blackhole.consume(actual);
            }
            return checksum;
        }

        public int replaceMany() {
            int checksum = 0;
            for (int index = 0; index < replacementsPerInvocation; index++) {
                Slot slot = randomLiveSlot();
                Value value = slot.replaceValue(valuePayloadSize);
                map.put(slot.key, value);
                checksum += value.version;
            }
            return checksum;
        }

        protected void prepareCleanupBatch() throws Exception {
            retiredSlots.clear();
            retireValues(retirementsPerInvocation);
            awaitStaleValues(retiredSlots.size());
        }

        public int cleanupStaleEntriesOnly() {
            return map.cleanupStaleEntries();
        }

        protected int repopulateRetiredValues() {
            int checksum = 0;
            for (Slot slot : retiredSlots) {
                Value value = slot.replaceValue(valuePayloadSize);
                map.put(slot.key, value);
                checksum ^= value.ownerId + value.version;
            }
            retiredSlots.clear();
            return checksum;
        }

        public int cleanupRetiredValues() {
            int checksum = cleanupStaleEntriesOnly();
            checksum ^= repopulateRetiredValues();
            return checksum;
        }

        protected void prepareMixedRound(boolean forceGc) {
            retiredSlots.clear();
            retireValues(retirementsPerInvocation);
            createAllocationPressure();
            if (forceGc) {
                System.gc();
            }
        }

        private void retireValues(int count) {
            int attempts = 0;
            while (retiredSlots.size() < count && attempts < slots.size() * 8) {
                Slot slot = slots.get(random.nextInt(slots.size()));
                if (slot.currentValue() == null) {
                    attempts++;
                    continue;
                }
                slot.retireValue();
                retiredSlots.add(slot);
                attempts++;
            }
            if (retiredSlots.size() != count) {
                throw new IllegalStateException("Unable to retire the requested number of values");
            }
        }

        private void awaitStaleValues(int expected) throws Exception {
            for (int attempt = 0; attempt < 64; attempt++) {
                if (map.staleEntries() >= expected) {
                    return;
                }
                createAllocationPressure();
                System.gc();
                Thread.sleep(10L);
            }
            throw new AssertionError("Timed out waiting for stale values");
        }

        private Slot randomLiveSlot() {
            for (int attempt = 0; attempt < slots.size() * 8; attempt++) {
                Slot slot = slots.get(random.nextInt(slots.size()));
                if (slot.currentValue() != null) {
                    return slot;
                }
            }
            throw new IllegalStateException("Unable to find a live slot");
        }

        private void createAllocationPressure() {
            int blockSize = Math.max(keyPayloadSize + valuePayloadSize, 256) * 8;
            byte[][] pressure = new byte[32][];
            for (int index = 0; index < pressure.length; index++) {
                pressure[index] = new byte[blockSize];
                pressure[index][0] = (byte) index;
            }
        }
    }

    @State(Scope.Thread)
    public abstract static class CleanupState extends BaseState {
        @Setup(Level.Invocation)
        public void setupInvocation() throws Exception {
            prepareCleanupBatch();
        }

        @TearDown(Level.Invocation)
        public void tearDownInvocation() {
            repopulateRetiredValues();
        }
    }

    @State(Scope.Thread)
    public abstract static class MixedState extends BaseState {
        @Param({"8"})
        public int gcEveryMixedRounds;

        private int mixedRounds;

        @Setup(Level.Iteration)
        public void setupIteration() {
            mixedRounds = 0;
        }

        public int mixedRound(Blackhole blackhole) {
            int checksum = lookupMany(blackhole);
            checksum ^= replaceMany();
            boolean forceGc = gcEveryMixedRounds > 0 && (++mixedRounds % gcEveryMixedRounds) == 0;
            prepareMixedRound(forceGc);
            checksum ^= cleanupRetiredValues();
            checksum ^= lookupMany(blackhole);
            return checksum;
        }
    }
}