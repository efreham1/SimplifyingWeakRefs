#!/bin/bash
# Runs the @weak field correctness tests against the built JDK.
# Usage: ./run_weak_field_tests.sh [path-to-jdk]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAVA_HOME="${1:-$SCRIPT_DIR/build/all-linux-x86_64-server-release/jdk}"
BUILD_DIR="${JAVA_HOME%/jdk}"
JAVA="$JAVA_HOME/bin/java"
JAVAC="$JAVA_HOME/bin/javac"
TEST_DIR="$SCRIPT_DIR/test/weakrefs"
JVMTI_SRC="$SCRIPT_DIR/test/hotspot/jtreg/serviceability/jvmti/FollowReferences/WeakFieldRefs"
JVMTI_COMMON="$SCRIPT_DIR/test/lib/jdk/test/lib/jvmti"
HPROF_LIB="$SCRIPT_DIR/test/lib"
TMPDIR="${TMPDIR:-/tmp}/weak_field_tests.$$"

if [ ! -x "$JAVA" ]; then
    echo "ERROR: $JAVA not found. Pass JDK path as first argument or build first."
    exit 1
fi

echo "Using JDK: $JAVA_HOME"
echo "========================================"

PASS=0
FAIL=0

run_test() {
    local name="$1"
    shift
    echo ""
    echo "---- $name ----"
    if "$@"; then
        echo "  => PASSED"
        PASS=$((PASS + 1))
    else
        echo "  => FAILED (exit $?)"
        FAIL=$((FAIL + 1))
    fi
}

cd "$TEST_DIR"

# 1) Reflection test
$JAVAC WeakFieldReflectionTest.java
run_test "Reflection" $JAVA -XX:+UseZGC WeakFieldReflectionTest

# 2) Unsafe test
$JAVAC --add-exports java.base/jdk.internal.misc=ALL-UNNAMED WeakFieldUnsafeTest.java
run_test "Unsafe" $JAVA -XX:+UseZGC --add-opens java.base/jdk.internal.misc=ALL-UNNAMED WeakFieldUnsafeTest

# 3) JNI test
$JAVAC WeakFieldJniTest.java
cc -shared -fPIC -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" \
   -o libWeakFieldJniTest.so WeakFieldJniTest.c
run_test "JNI" $JAVA -XX:+UseZGC --enable-native-access=ALL-UNNAMED -Djava.library.path=. WeakFieldJniTest

# Clean up
python3 -c "import glob,os; [os.unlink(f) for f in glob.glob('*.class')]; [os.unlink(f) for f in glob.glob('*.so')]"

# 4) JVMTI FollowReferences test
mkdir -p "$TMPDIR"
$JAVAC -d "$TMPDIR" "$JVMTI_SRC/WeakFieldRefsTest.java"
g++ -shared -fPIC \
    -I"$BUILD_DIR/support/modules_include/java.base" \
    -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" \
    -I"$JVMTI_COMMON" \
    -o "$TMPDIR/libWeakFieldRefsTest.so" "$JVMTI_SRC/libWeakFieldRefsTest.cpp"
run_test "JVMTI FollowReferences" \
    $JAVA -XX:+UseZGC --enable-native-access=ALL-UNNAMED \
    -agentpath:"$TMPDIR/libWeakFieldRefsTest.so" \
    -Djava.library.path="$TMPDIR" \
    -cp "$TMPDIR" WeakFieldRefsTest
python3 -c "import shutil; shutil.rmtree('$TMPDIR', ignore_errors=True)"

# 5) Heap dump test (tests heapDumper.cpp @weak handling)
mkdir -p "$TMPDIR"
$JAVAC -d "$TMPDIR" -sourcepath "$HPROF_LIB" \
    "$HPROF_LIB/jdk/test/lib/hprof/parser/Reader.java" \
    "$HPROF_LIB/jdk/test/lib/hprof/model/Snapshot.java" \
    "$HPROF_LIB/jdk/test/lib/hprof/model/JavaObject.java" \
    "$HPROF_LIB/jdk/test/lib/hprof/HprofParser.java"
$JAVAC -d "$TMPDIR" -cp "$TMPDIR" "$TEST_DIR/WeakFieldHeapDumpTest.java"
run_test "Heap dump" \
    $JAVA -XX:+UseZGC -cp "$TMPDIR" WeakFieldHeapDumpTest
python3 -c "import shutil; shutil.rmtree('$TMPDIR', ignore_errors=True)"

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
