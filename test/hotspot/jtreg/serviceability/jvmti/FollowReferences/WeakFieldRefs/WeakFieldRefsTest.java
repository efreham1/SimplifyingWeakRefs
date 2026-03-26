/*
 * Copyright (c) 2026, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

/*
 * @test
 * @summary Verifies that JVMTI FollowReferences correctly reports @weak
 *     annotated fields: the referent must be visible before GC and must be
 *     reported as null after the sole strong reference is dropped and a full
 *     GC clears the weak field.
 * @requires vm.gc.ZGenerational
 * @run main/othervm/native -XX:+UseZGC -agentlib:WeakFieldRefsTest WeakFieldRefsTest
 */

import java.lang.ref.Reference;
import java.lang.ref.weak;

public class WeakFieldRefsTest {

    static {
        System.loadLibrary("WeakFieldRefsTest");
    }

    // ---- native methods implemented by libWeakFieldRefsTest.cpp ----
    private static native void init();
    private static native void tagObject(Object obj, long tag);
    private static native int walkAndCountField(Object root, long targetTag);
    private static native boolean checkWeakAnnotation(Class<?> clazz, String fieldName);

    // Holder with one @weak object field and one strong object field.
    static class Holder {
        @weak
        Object weakTarget;
        Object strongTarget;

        Holder(Object weakTarget, Object strongTarget) {
            this.weakTarget = weakTarget;
            this.strongTarget = strongTarget;
        }
    }

    public static void main(String[] args) throws Exception {
        init();

        // ---- Phase 0: verify @weak annotation via native JNI ----
        boolean weakIsWeak = checkWeakAnnotation(Holder.class, "weakTarget");
        boolean strongIsWeak = checkWeakAnnotation(Holder.class, "strongTarget");
        if (!weakIsWeak) {
            throw new RuntimeException("Phase 0 FAIL: native JNI did not find @weak on weakTarget");
        }
        if (strongIsWeak) {
            throw new RuntimeException("Phase 0 FAIL: native JNI found @weak on strongTarget");
        }
        System.out.println("Phase 0 PASSED: native JNI annotation check correct.");

        // ---- Phase 1: weak field referent is reachable ----
        Object target = new Object();
        Object strong = new Object();
        Holder holder = new Holder(target, strong);

        // Tag the objects so the native agent can recognise them.
        long HOLDER_TAG = 1;
        long WEAK_TAG   = 2;
        long STRONG_TAG = 3;
        tagObject(holder, HOLDER_TAG);
        tagObject(target, WEAK_TAG);
        tagObject(strong, STRONG_TAG);

        // Walk the heap starting from holder - both fields should be reported.
        int weakCount = walkAndCountField(holder, WEAK_TAG);
        int strongCount = walkAndCountField(holder, STRONG_TAG);
        System.out.println("Phase 1: weakCount=" + weakCount + " strongCount=" + strongCount);

        if (weakCount != 1) {
            throw new RuntimeException("Phase 1 FAIL: expected weakCount=1, got " + weakCount);
        }
        if (strongCount != 1) {
            throw new RuntimeException("Phase 1 FAIL: expected strongCount=1, got " + strongCount);
        }
        System.out.println("Phase 1 PASSED: both fields reported.");

        // ---- Phase 2: drop the strong reference, GC should clear @weak ----
        target = null;
        // Keep holder and strong alive.
        Reference.reachabilityFence(holder);
        Reference.reachabilityFence(strong);

        System.gc();
        // Give ZGC time to process the weak references.
        Thread.sleep(500);
        System.gc();
        Thread.sleep(500);

        weakCount = walkAndCountField(holder, WEAK_TAG);
        strongCount = walkAndCountField(holder, STRONG_TAG);
        System.out.println("Phase 2: weakCount=" + weakCount + " strongCount=" + strongCount);

        if (weakCount != 0) {
            throw new RuntimeException("Phase 2 FAIL: expected weakCount=0, got " + weakCount);
        }
        if (strongCount != 1) {
            throw new RuntimeException("Phase 2 FAIL: expected strongCount=1, got " + strongCount);
        }
        System.out.println("Phase 2 PASSED: weak field cleared, strong field retained.");

        // Keep objects alive until the end.
        Reference.reachabilityFence(holder);
        Reference.reachabilityFence(strong);
    }
}
