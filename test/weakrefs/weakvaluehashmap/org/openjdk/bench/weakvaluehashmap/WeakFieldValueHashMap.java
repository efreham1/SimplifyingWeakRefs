package org.openjdk.bench.weakvaluehashmap;

import java.lang.ref.weak;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;

public final class WeakFieldValueHashMap<K, V> implements ManagedWeakValueMap<K, V> {
    private final HashMap<K, Entry<K, V>> entries = new HashMap<>();

    @Override
    public V get(K key) {
        Entry<K, V> entry = entries.get(key);
        return entry == null ? null : entry.get();
    }

    @Override
    public V put(K key, V value) {
        if (value == null) {
            return remove(key);
        }

        Entry<K, V> entry = entries.get(key);
        if (entry == null) {
            entries.put(key, new Entry<>(key, value));
            return null;
        }

        V oldValue = entry.get();
        entry.setValue(value);
        return oldValue;
    }

    @Override
    public V remove(K key) {
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
        int removed = 0;
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

    private static final class Entry<K, V> {
        private final K key;
        @weak
        private V value;

        Entry(K key, V value) {
            this.key = key;
            this.value = value;
        }

        V get() {
            return value;
        }

        boolean isStale() {
            return value == null;
        }

        void setValue(V newValue) {
            value = newValue;
        }

        void clear() {
            value = null;
        }
    }
}