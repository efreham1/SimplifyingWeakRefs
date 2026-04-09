package org.openjdk.bench.weakvaluehashmap;

interface ManagedWeakValueMap<K, V> {
    V get(K key);

    V put(K key, V value);

    V remove(K key);

    void clear();

    int entryCount();

    int staleEntries();

    int cleanupStaleEntries();
}