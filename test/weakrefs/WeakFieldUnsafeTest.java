import java.lang.ref.Reference;
import java.lang.ref.weak;
import java.lang.reflect.Field;

/**
 * Tests that reading a @weak-annotated field via Unsafe.getReference
 * uses the correct weak-reference barrier (ON_UNKNOWN_OOP_REF resolved
 * to ON_WEAK_OOP_REF by accessBarrierSupport).
 *
 * Phase 1: strong ref alive  -> Unsafe read returns the object.
 * Phase 2: strong ref dropped + GC -> Unsafe read returns null.
 *
 * Run with: java -XX:+UseZGC --add-opens java.base/jdk.internal.misc=ALL-UNNAMED WeakFieldUnsafeTest
 */
public final class WeakFieldUnsafeTest {

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
        // Obtain Unsafe via reflection.
        Field unsafeField = jdk.internal.misc.Unsafe.class.getDeclaredField("theUnsafe");
        unsafeField.setAccessible(true);
        jdk.internal.misc.Unsafe unsafe =
                (jdk.internal.misc.Unsafe) unsafeField.get(null);

        // Compute field offsets.
        long weakOffset  = unsafe.objectFieldOffset(
                Holder.class.getDeclaredField("weakTarget"));
        long strongOffset = unsafe.objectFieldOffset(
                Holder.class.getDeclaredField("strongTarget"));

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

        Object target = new Object();
        Object strong = new Object();
        Holder holder = new Holder(target, strong);

        // ---- Phase 1: both references alive ----
        Object readWeak   = unsafe.getReference(holder, weakOffset);
        Object readStrong = unsafe.getReference(holder, strongOffset);

        if (readWeak != target) {
            throw new RuntimeException("Phase 1 FAIL: Unsafe read of @weak field "
                    + "did not return the referent (got " + readWeak + ")");
        }
        if (readStrong != strong) {
            throw new RuntimeException("Phase 1 FAIL: Unsafe read of strong field "
                    + "did not return the referent");
        }
        System.out.println("Phase 1 PASSED: Unsafe reads return correct objects.");

        // ---- Phase 2: drop strong ref, GC should clear @weak ----
        target = null;
        readWeak = null;

        Reference.reachabilityFence(holder);
        Reference.reachabilityFence(strong);

        System.gc();
        Thread.sleep(500);
        System.gc();
        Thread.sleep(500);

        readWeak   = unsafe.getReference(holder, weakOffset);
        readStrong = unsafe.getReference(holder, strongOffset);

        if (readWeak != null) {
            throw new RuntimeException("Phase 2 FAIL: @weak field was not cleared "
                    + "after GC (got " + readWeak + ")");
        }
        if (readStrong != strong) {
            throw new RuntimeException("Phase 2 FAIL: strong field was unexpectedly "
                    + "cleared after GC");
        }
        System.out.println("Phase 2 PASSED: @weak field cleared, strong field retained.");

        // ---- Phase 3: write via Unsafe, verify round-trip ----
        Object newTarget = new Object();
        unsafe.putReference(holder, weakOffset, newTarget);

        Object readBack = unsafe.getReference(holder, weakOffset);
        if (readBack != newTarget) {
            throw new RuntimeException("Phase 3 FAIL: Unsafe write + read of "
                    + "@weak field did not round-trip");
        }
        System.out.println("Phase 3 PASSED: Unsafe write + read round-trips.");

        Reference.reachabilityFence(holder);
        Reference.reachabilityFence(strong);
        Reference.reachabilityFence(newTarget);

        System.out.println("ALL PASSED");
    }
}
