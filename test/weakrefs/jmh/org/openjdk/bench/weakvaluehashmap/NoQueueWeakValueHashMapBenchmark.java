package org.openjdk.bench.weakvaluehashmap;

import java.util.concurrent.TimeUnit;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.Warmup;
import org.openjdk.jmh.infra.Blackhole;

@BenchmarkMode(Mode.Throughput)
@OutputTimeUnit(TimeUnit.SECONDS)
@Warmup(iterations = 3, time = 60, timeUnit = TimeUnit.SECONDS)
@Measurement(iterations = 5, time = 60, timeUnit = TimeUnit.SECONDS)
@Fork(1)
public class NoQueueWeakValueHashMapBenchmark extends WeakValueHashMapBenchmarkSupport {
    @State(Scope.Thread)
    public static class BenchmarkState extends BaseState {
        @Override
        protected ManagedWeakValueMap<Key, Value> createMap() {
            return new NoQueueWeakValueHashMap<>();
        }
    }

    @State(Scope.Thread)
    public static class CleanupBenchmarkState extends CleanupState {
        @Override
        protected ManagedWeakValueMap<Key, Value> createMap() {
            return new NoQueueWeakValueHashMap<>();
        }
    }

    @State(Scope.Thread)
    public static class MixedBenchmarkState extends MixedState {
        @Override
        protected ManagedWeakValueMap<Key, Value> createMap() {
            return new NoQueueWeakValueHashMap<>();
        }
    }

    @Benchmark
    public int lookup(BenchmarkState state, Blackhole blackhole) {
        return state.lookupMany(blackhole);
    }

    @Benchmark
    public int replace(BenchmarkState state) {
        return state.replaceMany();
    }

    @Benchmark
    public int cleanup(CleanupBenchmarkState state) {
        return state.cleanupStaleEntriesOnly();
    }

    @Benchmark
    public int mixed(MixedBenchmarkState state, Blackhole blackhole) {
        return state.mixedRound(blackhole);
    }
}