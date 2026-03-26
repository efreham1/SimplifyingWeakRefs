import java.lang.ref.Reference;
import java.lang.ref.weak;
import java.lang.reflect.Field;

/**
 * Tests that reading a @weak-annotated field via reflection (Field.get)
 * uses the correct weak-reference barrier.
 *
 * Phase 1: strong ref alive  -> reflection read returns the object.
 * Phase 2: strong ref dropped + GC -> reflection read returns null.
 *
 * Run with: java -XX:+UseZGC WeakFieldReflectionTest
 */
public final class WeakFieldReflectionTest {

    static final class Holder {
        @weak
        Object weakTarget;

        Object strongTarget;

        Holder(Object w, Object s) {
            this.weakTarget = w;
            this.strongTarget = s;
        }
    }

    public static void main(String[] args) throws Exception {
        Field weakField  = Holder.class.getDeclaredField("weakTarget");
        Field strongField = Holder.class.getDeclaredField("strongTarget");
        weakField.setAccessible(true);
        strongField.setAccessible(true);

        Object target = new Object();
        Object strong = new Object();
        Holder holder = new Holder(target, strong);

        // ---- Phase 0: verify @weak annotation metadata ----
        if (!weakField.isAnnotationPresent(weak.class)) {
            throw new RuntimeException("Phase 0 FAIL: @weak annotation not found on weakTarget");
        }
        if (strongField.isAnnotationPresent(weak.class)) {
            throw new RuntimeException("Phase 0 FAIL: @weak annotation unexpectedly found on strongTarget");
        }
        System.out.println("Phase 0 PASSED: @weak annotation present on weakTarget, absent on strongTarget.");

        // ---- Phase 1: both references alive ----
        Object readWeak   = weakField.get(holder);
        Object readStrong = strongField.get(holder);

        if (readWeak != target) {
            throw new RuntimeException("Phase 1 FAIL: reflection read of @weak field "
                    + "did not return the referent (got " + readWeak + ")");
        }
        if (readStrong != strong) {
            throw new RuntimeException("Phase 1 FAIL: reflection read of strong field "
                    + "did not return the referent");
        }
        System.out.println("Phase 1 PASSED: reflection reads return correct objects.");

        // ---- Phase 2: drop strong ref to target, GC should clear @weak ----
        target = null;
        readWeak = null;

        Reference.reachabilityFence(holder);
        Reference.reachabilityFence(strong);

        System.gc();
        Thread.sleep(500);
        System.gc();
        Thread.sleep(500);

        readWeak   = weakField.get(holder);
        readStrong = strongField.get(holder);

        if (readWeak != null) {
            throw new RuntimeException("Phase 2 FAIL: @weak field was not cleared "
                    + "after GC (got " + readWeak + ")");
        }
        if (readStrong != strong) {
            throw new RuntimeException("Phase 2 FAIL: strong field was unexpectedly "
                    + "cleared after GC");
        }
        System.out.println("Phase 2 PASSED: @weak field cleared, strong field retained.");

        // ---- Phase 3: write via reflection, verify round-trip ----
        Object newTarget = new Object();
        weakField.set(holder, newTarget);

        Object readBack = weakField.get(holder);
        if (readBack != newTarget) {
            throw new RuntimeException("Phase 3 FAIL: reflection write + read of "
                    + "@weak field did not round-trip");
        }
        System.out.println("Phase 3 PASSED: reflection write + read round-trips.");

        Reference.reachabilityFence(holder);
        Reference.reachabilityFence(strong);
        Reference.reachabilityFence(newTarget);

        System.out.println("ALL PASSED");
    }
}
