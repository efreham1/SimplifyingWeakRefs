/*
 * ZGC-specific JVM flag constraint implementations.
 */

#include "runtime/flags/jvmFlag.hpp"
#include "runtime/flags/jvmFlagLimit.hpp"
#include "gc/z/jvmFlagConstraintsZ.hpp"
#include "gc/z/zGlobals.hpp"

JVMFlag::Error ZUseGrowableArrayDiscoveredListConstraintFunc(bool value, bool verbose) {
  if (value) {
    if (!ZUseSeperateDiscoveredLists) {
      JVMFlag::printError(verbose,
                          "ZUseGrowableArrayDiscoveredList requires ZUseSeperateDiscoveredLists to be true\n");
      return JVMFlag::VIOLATES_CONSTRAINT;
    }
  }
  return JVMFlag::SUCCESS;
}
