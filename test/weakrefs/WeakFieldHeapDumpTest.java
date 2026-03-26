import com.sun.management.HotSpotDiagnosticMXBean;
import java.io.File;
import java.lang.management.ManagementFactory;
import java.lang.ref.Reference;
import java.lang.ref.weak;
import java.util.Enumeration;
import java.util.List;

import jdk.test.lib.hprof.model.*;
import jdk.test.lib.hprof.parser.Reader;

/**
 * Tests that hprof heap dumps correctly record @weak-annotated field values.
 *
 * Phase 1: Dump while referent is alive  -> field shows the object.
 * Phase 2: Drop strong ref, GC, dump    -> field shows null.
 *
 * Run with:
 *   javac -cp $TEST_LIB WeakFieldHeapDumpTest.java
 *   java  -cp .:$TEST_LIB -XX:+UseZGC WeakFieldHeapDumpTest
 *
 * where TEST_LIB points to the compiled test/lib classes (jdk.test.lib.hprof).
 */
public final class WeakFieldHeapDumpTest {

    // A unique marker class so we can find it in the heap dump.
    static final class Target {
        final int marker = 0xCAFE;
    }

    static final class Holder {
        @weak
        Object weakTarget;

        Object strongTarget;

        Holder(Object w, Object s) {
            this.weakTarget = w;
            this.strongTarget = s;
        }
    }

    // Keep a static reference so the holder survives across dumps.
    static Holder holder;

    public static void main(String[] args) throws Exception {
        // ---- Phase 0: verify @weak annotation metadata ----
        java.lang.reflect.Field weakReflect  = Holder.class.getDeclaredField("weakTarget");
        java.lang.reflect.Field strongReflect = Holder.class.getDeclaredField("strongTarget");
        if (!weakReflect.isAnnotationPresent(weak.class)) {
            throw new RuntimeException("Phase 0 FAIL: @weak annotation not found on weakTarget");
        }
        if (strongReflect.isAnnotationPresent(weak.class)) {
            throw new RuntimeException("Phase 0 FAIL: @weak annotation unexpectedly found on strongTarget");
        }
        System.out.println("Phase 0 PASSED: @weak annotation present on weakTarget, absent on strongTarget.");

        Target target = new Target();
        Object strong = new Object();
        holder = new Holder(target, strong);

        // ---- Phase 1: dump while referent is alive ----
        File dump1 = new File("weakfield_phase1.hprof");
        if (dump1.exists()) dump1.delete();

        dumpHeap(dump1);
        verifyDump(dump1, /*expectWeakAlive=*/ true);
        dump1.delete();
        System.out.println("Phase 1 PASSED: @weak field present in heap dump.");

        // ---- Phase 2: drop the strong ref, GC, dump again ----
        target = null;

        Reference.reachabilityFence(holder);
        Reference.reachabilityFence(strong);

        System.gc();
        Thread.sleep(500);
        System.gc();
        Thread.sleep(500);

        File dump2 = new File("weakfield_phase2.hprof");
        if (dump2.exists()) dump2.delete();

        dumpHeap(dump2);
        verifyDump(dump2, /*expectWeakAlive=*/ false);
        dump2.delete();
        System.out.println("Phase 2 PASSED: @weak field null in heap dump after GC.");

        Reference.reachabilityFence(holder);
        Reference.reachabilityFence(strong);

        System.out.println("ALL PASSED");
    }

    private static void dumpHeap(File file) throws Exception {
        List<HotSpotDiagnosticMXBean> list =
                ManagementFactory.getPlatformMXBeans(HotSpotDiagnosticMXBean.class);
        list.get(0).dumpHeap(file.getAbsolutePath(), /* live= */ true);
    }

    private static void verifyDump(File file, boolean expectWeakAlive) throws Exception {
        try (Snapshot snapshot = Reader.readFile(file.getPath(), true, 0)) {
            snapshot.resolve(true);

            // Find the Holder instance.
            String holderClassName = Holder.class.getName().replace('.', '/');
            // The hprof parser uses '.' separators:
            holderClassName = Holder.class.getName();
            JavaClass holderClass = snapshot.findClass(holderClassName);
            if (holderClass == null) {
                throw new RuntimeException("Could not find class " + holderClassName
                        + " in heap dump");
            }

            Enumeration<?> instances = holderClass.getInstances(/*includeSubclasses=*/ false);
            if (!instances.hasMoreElements()) {
                throw new RuntimeException("No instances of " + holderClassName + " found");
            }

            JavaObject holderObj = (JavaObject) instances.nextElement();

            // Check the weakTarget field.
            JavaThing weakVal = holderObj.getField("weakTarget");
            // Check the strongTarget field.
            JavaThing strongVal = holderObj.getField("strongTarget");

            boolean weakIsNull = (weakVal == null || weakVal == snapshot.getNullThing());
            boolean strongIsNull = (strongVal == null || strongVal == snapshot.getNullThing());

            System.out.println("  weakTarget=" + weakVal + " (null=" + weakIsNull + ")");
            System.out.println("  strongTarget=" + strongVal + " (null=" + strongIsNull + ")");

            if (strongIsNull) {
                throw new RuntimeException("strongTarget should never be null in the dump");
            }

            if (expectWeakAlive && weakIsNull) {
                throw new RuntimeException("Expected weakTarget to be alive, but it is null");
            }
            if (!expectWeakAlive && !weakIsNull) {
                throw new RuntimeException("Expected weakTarget to be null after GC, "
                        + "but got " + weakVal);
            }
        }
    }
}
