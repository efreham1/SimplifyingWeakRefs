import java.lang.instrument.Instrumentation;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Java agent that creates continuous weak reference pressure without using ReferenceQueue.
 * Creates short-lived objects with weak references that are immediately eligible for GC.
 */
public class WeakRefPressureAgent {
    
    private static final AtomicLong createdRefs = new AtomicLong(0);
    private static final AtomicLong clearedRefs = new AtomicLong(0);
    private static volatile boolean running = true;
    
    // Volatile field to prevent escape analysis optimizations
    private static volatile Object sink = null;
    
    // Helper class to ensure objects actually escape to heap
    static class Payload {
        final byte[] data;
        final long id;
        
        Payload(int size, long id) {
            this.data = new byte[size];
            this.id = id;
            // Touch the array to ensure allocation
            if (data.length > 0) {
                data[0] = (byte) (id & 0xFF);
                data[data.length - 1] = (byte) ((id >> 8) & 0xFF);
            }
        }
    }
    
    public static void premain(String agentArgs, Instrumentation inst) {
        System.out.println("[WeakRefAgent] Starting weak reference pressure agent");
        
        // Parse configuration from agent args
        int numThreads = 2;
        int refsPerBatch = 1000;
        int batchDelayMs = 10;
        
        if (agentArgs != null && !agentArgs.isEmpty()) {
            // Split by semicolon, comma, or space to handle different scenarios
            String[] args = agentArgs.split("[;,\\s]+");
            for (String arg : args) {
                String[] parts = arg.split("=");
                if (parts.length == 2) {
                    String key = parts[0].trim();
                    String value = parts[1].trim();
                    switch (key) {
                        case "threads":
                            numThreads = Integer.parseInt(value);
                            break;
                        case "refs":
                            refsPerBatch = Integer.parseInt(value);
                            break;
                        case "delay":
                            batchDelayMs = Integer.parseInt(value);
                            break;
                    }
                }
            }
        }
        
        System.out.println("[WeakRefAgent] Config: threads=" + numThreads + 
                         ", refs/batch=" + refsPerBatch + 
                         ", delay=" + batchDelayMs + "ms");
        
        // Start background threads creating weak references
        for (int i = 0; i < numThreads; i++) {
            final int threadId = i;
            final int batchSize = refsPerBatch;
            final int delay = batchDelayMs;
            
            Thread thread = new Thread(() -> {
                runWeakRefGenerator(threadId, batchSize, delay);
            }, "WeakRefPressure-" + i);
            thread.setDaemon(true);
            thread.start();
        }

        // Statistics thread
        Thread statsThread = new Thread(() -> {
            long lastCreated = 0;
            long lastCleared = 0;
            while (running) {
                try {
                    Thread.sleep(30000); // Print stats every 30 seconds
                    long created = createdRefs.get();
                    long cleared = clearedRefs.get();
                    long createdRate = (created - lastCreated) / 30;
                    long clearedRate = (cleared - lastCleared) / 30;
                    System.out.println(String.format(
                        "[WeakRefAgent] Stats: created=%,d (%,d/s), cleared=%,d (%,d/s), alive=%,d",
                        created, createdRate, cleared, clearedRate, (created - cleared)));
                    lastCreated = created;
                    lastCleared = cleared;
                } catch (InterruptedException e) {
                    break;
                }
            }
        }, "WeakRefStats");
        statsThread.setDaemon(true);
        statsThread.start();
        
        // Shutdown hook (may not run in JMH forked processes)
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            running = false;
            System.err.println("[WeakRefAgent] Shutting down. Total refs created: " + 
                             createdRefs.get() + ", cleared: " + clearedRefs.get());
            System.err.flush();
        }));
    }
    
    private static void runWeakRefGenerator(int threadId, int batchSize, int delayMs) {
        List<WeakReference<Payload>> refs = new ArrayList<>(batchSize * 2);
        long objId = threadId * 1_000_000_000L;
        int cycleCount = 0;
        
        while (running) {
            try {
                // Create batch of weak references WITHOUT a ReferenceQueue
                for (int i = 0; i < batchSize; i++) {
                    // Create larger objects to create significant memory pressure
                    // 64KB per object ensures GC must run to reclaim memory
                    Payload payload = new Payload(1024, objId++); 
                    
                    // Force object to escape to heap by briefly storing in volatile field
                    sink = payload;
                    sink = null;
                    
                    // Now create weak reference - payload is only referenced by weak ref
                    WeakReference<Payload> weakRef = new WeakReference<>(payload);
                    refs.add(weakRef);
                    
                    // payload is no longer strongly reachable - eligible for GC
                }
                createdRefs.addAndGet(batchSize);
                cycleCount++;
                
                // More frequently check and clean up cleared references
                int cleared = 0;
                for (int i = refs.size() - 1; i >= 0; i--) {
                    if (refs.get(i).get() == null) {
                        refs.remove(i);
                        cleared++;
                    }
                }
                if (cleared > 0) {
                    clearedRefs.addAndGet(cleared);
                }
                
                
                // Small delay before next batch
                if (delayMs > 0) {
                    Thread.sleep(delayMs);
                }
                
            } catch (InterruptedException e) {
                break;
            } catch (Exception e) {
                System.err.println("[WeakRefAgent] Error in thread " + threadId + ": " + e);
            }
        }
    }
}
