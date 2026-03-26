import java.lang.ref.Reference;
import java.lang.ref.weak;

/**
 * Tests that JNI GetObjectField / SetObjectField on a @weak-annotated
 * field uses the correct weak-reference barrier (ON_UNKNOWN_OOP_REF
 * resolved to ON_WEAK_OOP_REF via accessBarrierSupport).
 *
 * Phase 1: strong ref alive  -> JNI read returns the object.
 * Phase 2: strong ref dropped + GC -> JNI read returns null.
 * Phase 3: JNI write + read round-trip.
 *
 * Build native lib:
 *   cc -shared -fPIC -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" \
 *      -o libWeakFieldJniTest.so WeakFieldJniTest.c
 *
 * Run:
 *   java -XX:+UseZGC -Djava.library.path=. WeakFieldJniTest
 */
public final class WeakFieldJniTest {

    static {
        System.loadLibrary("WeakFieldJniTest");
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

    // Native methods implemented in WeakFieldJniTest.c
    private static native Object getField(Object obj, String fieldName);
    private static native void   setField(Object obj, String fieldName, Object value);

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

        Object target = new Object();
        Object strong = new Object();
        Holder holder = new Holder(target, strong);

        // ---- Phase 1: both references alive ----
        Object readWeak   = getField(holder, "weakTarget");
        Object readStrong = getField(holder, "strongTarget");

        if (readWeak != target) {
            throw new RuntimeException("Phase 1 FAIL: JNI read of @weak field "
                    + "did not return the referent (got " + readWeak + ")");
        }
        if (readStrong != strong) {
            throw new RuntimeException("Phase 1 FAIL: JNI read of strong field "
                    + "did not return the referent");
        }
        System.out.println("Phase 1 PASSED: JNI reads return correct objects.");

        // ---- Phase 2: drop strong ref, GC should clear @weak ----
        target = null;
        readWeak = null;

        Reference.reachabilityFence(holder);
        Reference.reachabilityFence(strong);

        System.gc();
        Thread.sleep(500);

        readWeak   = getField(holder, "weakTarget");
        readStrong = getField(holder, "strongTarget");

        if (readWeak != null) {
            throw new RuntimeException("Phase 2 FAIL: @weak field was not cleared "
                    + "after GC (got " + readWeak + ")");
        }
        if (readStrong != strong) {
            throw new RuntimeException("Phase 2 FAIL: strong field was unexpectedly "
                    + "cleared after GC");
        }
        System.out.println("Phase 2 PASSED: @weak field cleared, strong field retained.");

        // ---- Phase 3: JNI write + read round-trip ----
        Object newTarget = new Object();
        setField(holder, "weakTarget", newTarget);

        Object readBack = getField(holder, "weakTarget");
        if (readBack != newTarget) {
            throw new RuntimeException("Phase 3 FAIL: JNI write + read of "
                    + "@weak field did not round-trip");
        }
        System.out.println("Phase 3 PASSED: JNI write + read round-trips.");

        Reference.reachabilityFence(holder);
        Reference.reachabilityFence(strong);
        Reference.reachabilityFence(newTarget);

        System.out.println("ALL PASSED");
    }
}
