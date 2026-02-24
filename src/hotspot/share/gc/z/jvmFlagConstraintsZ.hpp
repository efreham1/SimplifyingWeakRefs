/*
 * ZGC-specific JVM flag constraint declarations.
 */
#ifndef SHARE_GC_Z_JVMFLAGCONSTRAINTSZ_HPP
#define SHARE_GC_Z_JVMFLAGCONSTRAINTSZ_HPP

#include "runtime/flags/jvmFlag.hpp"
#include "utilities/globalDefinitions.hpp"

// ZGC-specific constraints
#define Z_GC_CONSTRAINTS(f)                                   \
  f(bool, ZUseGrowableArrayDiscoveredListConstraintFunc)

Z_GC_CONSTRAINTS(DECLARE_CONSTRAINT)

#endif // SHARE_GC_Z_JVMFLAGCONSTRAINTSZ_HPP
