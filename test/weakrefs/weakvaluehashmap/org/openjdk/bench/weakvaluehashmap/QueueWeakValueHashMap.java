package org.openjdk.bench.weakvaluehashmap;

import java.lang.ref.ReferenceQueue;
import java.lang.ref.WeakReference;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;

public final class QueueWeakValueHashMap<K, V> implements ManagedWeakValueMap<K, V> {
    private final HashMap<K, Entry<K, V>> entries = new HashMap<>();
    private final ReferenceQueue<V> queue = new ReferenceQueue<>();

    @Override
    public V get(K key) {
        expungeQueuedEntries();
        Entry<K, V> entry = entries.get(key);
        if (entry == null) {
            return null;
        }

        V value = entry.get();
        if (value == null) {
            entries.remove(key, entry);
        }
        return value;
    }

    @Override
    public V put(K key, V value) {
        expungeQueuedEntries();
        if (value == null) {
            return remove(key);
        }

        Entry<K, V> entry = entries.get(key);
        if (entry == null) {
            entries.put(key, new Entry<>(key, value, queue));
            return null;
        }

        V oldValue = entry.get();
        entry.setValue(value, queue);
        return oldValue;
    }

    @Override
    public V remove(K key) {
        expungeQueuedEntries();
        Entry<K, V> entry = entries.remove(key);
        if (entry == null) {
            return null;
        }

        V oldValue = entry.get();
        entry.clear();
        return oldValue;
    }

    @Override
    public void clear() {
        for (Entry<K, V> entry : entries.values()) {
            entry.clear();
        }
        entries.clear();
        while (queue.poll() != null) {
        }
    }

    @Override
    public int entryCount() {
        return entries.size();
    }

    @Override
    public int staleEntries() {
        int stale = 0;
        for (Entry<K, V> entry : entries.values()) {
            if (entry.isStale()) {
                stale++;
            }
        }
        return stale;
    }

    @Override
    public int cleanupStaleEntries() {
        int removed = expungeQueuedEntries();
        Iterator<Map.Entry<K, Entry<K, V>>> iterator = entries.entrySet().iterator();
        while (iterator.hasNext()) {
            Entry<K, V> entry = iterator.next().getValue();
            if (entry.isStale()) {
                iterator.remove();
                entry.clear();
                removed++;
            }
        }
        return removed;
    }

    private int expungeQueuedEntries() {
        int removed = 0;
        while (true) {
            @SuppressWarnings("unchecked")
            ValueReference<K, V> reference = (ValueReference<K, V>) queue.poll();
            if (reference == null) {
                return removed;
            }

            Entry<K, V> owner = reference.owner();
            Entry<K, V> current = entries.get(owner.key);
            if (current == owner && owner.isCurrent(reference)) {
                entries.remove(owner.key);
                owner.clear();
                removed++;
            }
        }
    }

    private static final class Entry<K, V> {
        private final K key;
        private ValueReference<K, V> valueRef;

        Entry(K key, V value, ReferenceQueue<V> queue) {
            this.key = key;
            this.valueRef = new ValueReference<>(this, value, queue);
        }

        V get() {
            return valueRef.get();
        }

        boolean isStale() {
            return valueRef.get() == null;
        }

        boolean isCurrent(ValueReference<K, V> reference) {
            return valueRef == reference;
        }

        void setValue(V value, ReferenceQueue<V> queue) {
            valueRef.clear();
            valueRef = new ValueReference<>(this, value, queue);
        }

        void clear() {
            valueRef.clear();
        }
    }

    private static final class ValueReference<K, V> extends WeakReference<V> {
        private final Entry<K, V> owner;

        ValueReference(Entry<K, V> owner, V referent, ReferenceQueue<V> queue) {
            super(referent, queue);
            this.owner = owner;
        }

        Entry<K, V> owner() {
            return owner;
        }
    }
}