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

#include <string.h>
#include "jvmti.h"
#include "jvmti_common.hpp"

extern "C" {

static jvmtiEnv* jvmti = nullptr;

// Tag of the object we are looking for during the heap walk.
static jlong search_tag = 0;
// Count of field references that point to the searched-for object.
static int  found_count = 0;

// FollowReferences heap_reference_callback:
// Invoked for every object reference discovered during the walk.
static jint JNICALL
heapReferenceCallback(jvmtiHeapReferenceKind  reference_kind,
                      const jvmtiHeapReferenceInfo* reference_info,
                      jlong  class_tag,
                      jlong  referrer_class_tag,
                      jlong  size,
                      jlong* tag_ptr,
                      jlong* referrer_tag_ptr,
                      jint   length,
                      void*  user_data)
{
    // We only care about instance field references from our tagged holder.
    if (reference_kind == JVMTI_HEAP_REFERENCE_FIELD && referrer_tag_ptr != nullptr) {
        jlong referrer_tag = *referrer_tag_ptr;
        jlong referee_tag  = *tag_ptr;
        // The holder is tagged 1; check if this field points to our target.
        if (referrer_tag != 0 && referee_tag == search_tag) {
            found_count++;
        }
    }
    return JVMTI_VISIT_OBJECTS;
}


// ---- Agent_OnLoad: acquire can_tag_objects capability ----

JNIEXPORT jint JNICALL
Agent_OnLoad(JavaVM* jvm, char* options, void* reserved)
{
    jint res = jvm->GetEnv((void**)&jvmti, JVMTI_VERSION_1_1);
    if (res != JNI_OK || jvmti == nullptr) {
        LOG("ERROR: GetEnv failed\n");
        return JNI_ERR;
    }

    jvmtiCapabilities caps;
    memset(&caps, 0, sizeof(caps));
    caps.can_tag_objects = 1;

    jvmtiError err = jvmti->AddCapabilities(&caps);
    if (err != JVMTI_ERROR_NONE) {
        LOG("ERROR: AddCapabilities failed: %s (%d)\n", TranslateError(err), err);
        return JNI_ERR;
    }
    return JNI_OK;
}


// ---- JNI methods called from WeakFieldRefsTest.java ----

JNIEXPORT void JNICALL
Java_WeakFieldRefsTest_init(JNIEnv* env, jclass cls)
{
    // Nothing extra needed; Agent_OnLoad already set up jvmti.
    LOG("WeakFieldRefsTest agent initialised\n");
}

JNIEXPORT void JNICALL
Java_WeakFieldRefsTest_tagObject(JNIEnv* env, jclass cls, jobject obj, jlong tag)
{
    check_jvmti_status(env,
        jvmti->SetTag(obj, tag),
        "SetTag failed");
}

JNIEXPORT jint JNICALL
Java_WeakFieldRefsTest_walkAndCountField(JNIEnv* env, jclass cls,
                                         jobject root, jlong targetTag)
{
    search_tag  = targetTag;
    found_count = 0;

    jvmtiHeapCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.heap_reference_callback = heapReferenceCallback;

    check_jvmti_status(env,
        jvmti->FollowReferences(0,         // no filter
                                nullptr,   // no class filter
                                root,      // start from root object
                                &callbacks,
                                nullptr),  // no user_data
        "FollowReferences failed");

    return found_count;
}

// Check, from native JNI, whether a field has the @weak annotation.
// This exercises a different code path than Java-side reflection.
JNIEXPORT jboolean JNICALL
Java_WeakFieldRefsTest_checkWeakAnnotation(JNIEnv* env, jclass cls,
                                           jclass targetClass, jstring fieldName)
{
    jclass classClass = env->FindClass("java/lang/Class");
    jmethodID getDeclaredField = env->GetMethodID(classClass,
        "getDeclaredField", "(Ljava/lang/String;)Ljava/lang/reflect/Field;");
    if (getDeclaredField == nullptr) {
        LOG("ERROR: failed to find getDeclaredField\n");
        return JNI_FALSE;
    }

    jobject fieldObj = env->CallObjectMethod(targetClass, getDeclaredField, fieldName);
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        return JNI_FALSE;
    }

    jclass weakAnnotClass = env->FindClass("java/lang/ref/weak");
    if (weakAnnotClass == nullptr) {
        LOG("ERROR: failed to find java.lang.ref.weak\n");
        return JNI_FALSE;
    }

    jclass fieldClass = env->FindClass("java/lang/reflect/Field");
    jmethodID isAnnotPresent = env->GetMethodID(fieldClass,
        "isAnnotationPresent", "(Ljava/lang/Class;)Z");
    if (isAnnotPresent == nullptr) {
        LOG("ERROR: failed to find isAnnotationPresent\n");
        return JNI_FALSE;
    }

    return env->CallBooleanMethod(fieldObj, isAnnotPresent, weakAnnotClass);
}

} // extern "C"
