# WeakRefPressureAgent

Java agent that creates continuous weak reference pressure during benchmarks to simulate realistic garbage collection scenarios.

## Purpose

This agent creates weak references **without** using `ReferenceQueue`, causing them to be:
1. Immediately eligible for garbage collection (no strong references kept)
2. Processed through ZGC's reference processing mechanism
3. Adding realistic GC pressure to benchmark scenarios

## Configuration

The agent accepts comma-separated parameters:

```
-javaagent:weakref-agent.jar=threads=2,refs=1000,delay=10
```

### Parameters

- **threads** (default: 2) - Number of background threads creating weak references
- **refs** (default: 1000) - Number of weak references created per batch
- **delay** (default: 10) - Delay in milliseconds between batches

## Usage

### Build
```bash
./build.sh
```

### Run with JVM
```bash
java -javaagent:weakref-agent.jar=threads=2,refs=1000,delay=10 YourApplication
```

### With JMH Benchmarks
The agent is automatically integrated into the benchmark suite via the 5th configuration.

## Statistics

The agent prints statistics every 30 seconds:
```
[WeakRefAgent] Stats: created=60,000 (2,000/s), cleared=58,500 (1,950/s), alive=1,500
```

## Implementation Details

- Creates short-lived objects (128 byte arrays)
- Wraps them in `WeakReference` without keeping strong references
- No `ReferenceQueue` used - references are orphaned immediately
- Periodically checks how many references have been cleared by GC
- Daemon threads automatically shut down with the JVM
