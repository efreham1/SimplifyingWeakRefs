#include <jni.h>
#include <stdio.h>

/*
 * Native companion for WeakFieldJniTest.java.
 *
 * Provides getField / setField that look up a named Object field via
 * JNI GetFieldID + GetObjectField / SetObjectField.  The JNI access
 * goes through HeapAccess<ON_UNKNOWN_OOP_REF> in the VM, which should
 * resolve to ON_WEAK_OOP_REF for @weak annotated fields.
 */

JNIEXPORT jobject JNICALL
Java_WeakFieldJniTest_getField(JNIEnv *env, jclass cls,
                               jobject obj, jstring fieldName)
{
    const char *name = (*env)->GetStringUTFChars(env, fieldName, NULL);
    if (name == NULL) return NULL;

    jclass objClass = (*env)->GetObjectClass(env, obj);
    jfieldID fid = (*env)->GetFieldID(env, objClass, name,
                                      "Ljava/lang/Object;");
    (*env)->ReleaseStringUTFChars(env, fieldName, name);

    if (fid == NULL) {
        fprintf(stderr, "ERROR: GetFieldID failed for '%s'\n", name);
        return NULL;
    }

    return (*env)->GetObjectField(env, obj, fid);
}

JNIEXPORT void JNICALL
Java_WeakFieldJniTest_setField(JNIEnv *env, jclass cls,
                               jobject obj, jstring fieldName, jobject value)
{
    const char *name = (*env)->GetStringUTFChars(env, fieldName, NULL);
    if (name == NULL) return;

    jclass objClass = (*env)->GetObjectClass(env, obj);
    jfieldID fid = (*env)->GetFieldID(env, objClass, name,
                                      "Ljava/lang/Object;");
    (*env)->ReleaseStringUTFChars(env, fieldName, name);

    if (fid == NULL) {
        fprintf(stderr, "ERROR: GetFieldID failed for '%s'\n", name);
        return;
    }

    (*env)->SetObjectField(env, obj, fid, value);
}
