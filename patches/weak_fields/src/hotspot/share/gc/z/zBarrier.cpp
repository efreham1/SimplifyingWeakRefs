/*
 * Copyright (c) 2015, 2025, Oracle and/or its affiliates. All rights reserved.
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

#include "classfile/javaClasses.hpp"
#include "gc/z/zAddress.inline.hpp"
#include "gc/z/zBarrier.inline.hpp"
#include "gc/z/zGeneration.inline.hpp"
#include "gc/z/zHeap.inline.hpp"
#include "gc/z/zPage.inline.hpp"
#include "gc/z/zStoreBarrierBuffer.inline.hpp"
#include "memory/iterator.inline.hpp"
#include "oops/instanceKlass.hpp"
#include "oops/oop.inline.hpp"
#include "runtime/fieldDescriptor.inline.hpp"
#include "runtime/safepoint.hpp"
#include "utilities/debug.hpp"

#ifdef ASSERT
static bool during_young_mark() {
  return ZGeneration::young()->is_phase_mark();
}

static bool during_old_mark() {
  return ZGeneration::old()->is_phase_mark();
}

static bool during_any_mark() {
  return during_young_mark() || during_old_mark();
}
#endif

zaddress ZBarrier::relocate_or_remap(zaddress_unsafe addr, ZGeneration* generation) {
  return generation->relocate_or_remap_object(addr);
}

zaddress ZBarrier::remap(zaddress_unsafe addr, ZGeneration* generation) {
  return generation->remap_object(addr);
}

//
// Weak load barrier
//

static void keep_alive_young(zaddress addr) {
  if (ZGeneration::young()->is_phase_mark()) {
    ZBarrier::mark_young<ZMark::Resurrect, ZMark::AnyThread, ZMark::Follow>(addr);
  }
}

zaddress ZBarrier::blocking_keep_alive_on_weak_slow_path(volatile zpointer* p, zaddress addr) {
  if (is_null(addr)) {
    return zaddress::null;
  }

  if (ZHeap::heap()->is_old(addr)) {
    if (!ZHeap::heap()->is_object_strongly_live(addr)) {
      return zaddress::null;
    }
  } else {
    // Young gen objects are never blocked, need to keep alive
    keep_alive_young(addr);
  }

  // Strongly live
  return addr;
}

zaddress ZBarrier::blocking_keep_alive_on_phantom_slow_path(volatile zpointer* p, zaddress addr) {
  if (is_null(addr)) {
    return zaddress::null;
  }

  if (ZHeap::heap()->is_old(addr)) {
    if (!ZHeap::heap()->is_object_live(addr)) {
      return zaddress::null;
    }
  } else {
    // Young gen objects are never blocked, need to keep alive
    keep_alive_young(addr);
  }

  // Strongly live
  return addr;
}

zaddress ZBarrier::blocking_load_barrier_on_weak_slow_path(volatile zpointer* p, zaddress addr) {
  if (is_null(addr)) {
    return zaddress::null;
  }

  if (ZHeap::heap()->is_old(addr)) {
    if (!ZHeap::heap()->is_object_strongly_live(addr)) {
      return zaddress::null;
    }
  } else {
    // Young objects are never considered non-strong
    // Note: Should not need to keep object alive in this operation,
    //       but the barrier colors the pointer mark good, so we need
    //       to mark the object accordingly.
    keep_alive_young(addr);
  }

  return addr;
}

zaddress ZBarrier::blocking_load_barrier_on_phantom_slow_path(volatile zpointer* p, zaddress addr) {
  if (is_null(addr)) {
    return zaddress::null;
  }

  if (ZHeap::heap()->is_old(addr)) {
    if (!ZHeap::heap()->is_object_live(addr)) {
      return zaddress::null;
    }
  } else {
    // Young objects are never considered non-strong
    // Note: Should not need to keep object alive in this operation,
    //       but the barrier colors the pointer mark good, so we need
    //       to mark the object accordingly.
    keep_alive_young(addr);
  }

  return addr;
}

// Mark barrier
//

zaddress ZBarrier::mark_slow_path(zaddress addr) {
  assert(during_any_mark(), "Invalid phase");

  if (is_null(addr)) {
    return addr;
  }

  mark<ZMark::DontResurrect, ZMark::AnyThread, ZMark::Follow, ZMark::Strong>(addr);

  return addr;
}

zaddress ZBarrier::mark_from_young_slow_path(zaddress addr) {
  assert(during_young_mark(), "Invalid phase");

  if (is_null(addr)) {
    return addr;
  }

  if (ZHeap::heap()->is_young(addr)) {
    ZGeneration::young()->mark_object<ZMark::DontResurrect, ZMark::GCThread, ZMark::Follow, ZMark::Strong>(addr);
    return addr;
  }

  if (ZGeneration::young()->type() == ZYoungType::major_full_roots ||
      ZGeneration::young()->type() == ZYoungType::major_partial_roots) {
    // The initial major young collection is responsible for finding roots
    // from the young generation to the old generation.
    ZGeneration::old()->mark_object<ZMark::DontResurrect, ZMark::GCThread, ZMark::Follow, ZMark::Strong>(addr);
    return addr;
  }

  // Don't mark pointers to the old generation for minor during major;
  // the initial young collection pushed the young-to-old pointers that
  // were part of the SATB. All other young-to-old pointers are irrelevant.

  // We still want to heal the pointers so they become store_good, so that
  // after a young collection, all young pointers are store good.
  return addr;
}

zaddress ZBarrier::mark_from_old_slow_path(zaddress addr) {
  assert(during_old_mark(), "Invalid phase");

  if (is_null(addr)) {
    return addr;
  }

  if (ZHeap::heap()->is_old(addr)) {
    ZGeneration::old()->mark_object<ZMark::DontResurrect, ZMark::GCThread, ZMark::Follow, ZMark::Strong>(addr);
    return addr;
  }

  // Don't mark pointers to the young generation; they will be
  // processed by the remembered set scanning.

  // Returning null means this location is not self healed by the caller.
  return zaddress::null;
}

zaddress ZBarrier::mark_young_slow_path(zaddress addr) {
  assert(during_young_mark(), "Invalid phase");

  if (is_null(addr)) {
    return addr;
  }

  mark_if_young<ZMark::DontResurrect, ZMark::GCThread, ZMark::Follow>(addr);

  return addr;
}

zaddress ZBarrier::mark_finalizable_slow_path(zaddress addr) {
  assert(during_any_mark(), "Invalid phase");

  if (is_null(addr)) {
    return addr;
  }

  if (ZHeap::heap()->is_old(addr)) {
    ZGeneration::old()->mark_object<ZMark::DontResurrect, ZMark::GCThread, ZMark::Follow, ZMark::Finalizable>(addr);
    return addr;
  }

  ZGeneration::young()->mark_object_if_active<ZMark::DontResurrect, ZMark::GCThread, ZMark::Follow, ZMark::Strong>(addr);
  return addr;
}

zaddress ZBarrier::mark_finalizable_from_old_slow_path(zaddress addr) {
  assert(during_any_mark(), "Invalid phase");

  if (is_null(addr)) {
    return addr;
  }

  if (ZHeap::heap()->is_old(addr)) {
    ZGeneration::old()->mark_object<ZMark::DontResurrect, ZMark::GCThread, ZMark::Follow, ZMark::Finalizable>(addr);
    return addr;
  }

  // Don't mark pointers to the young generation; they will be
  // processed by the remembered set scanning.

  // Returning null means this location is not self healed by the caller.
  return zaddress::null;
}

zaddress ZBarrier::heap_store_slow_path(volatile zpointer* p, zaddress addr, zpointer prev, bool heal) {
  ZStoreBarrierBuffer* buffer = ZStoreBarrierBuffer::buffer_for_store(heal);

  if (buffer != nullptr) {
    // Buffer store barriers whenever possible
    buffer->add(p, prev);
  } else {
    mark_and_remember(p, addr);
  }

  return addr;
}

zaddress ZBarrier::no_keep_alive_heap_store_slow_path(volatile zpointer* p, zaddress addr) {
  remember(p);

  return addr;
}

zaddress ZBarrier::native_store_slow_path(zaddress addr) {
  if (!is_null(addr)) {
    mark<ZMark::DontResurrect, ZMark::AnyThread, ZMark::Follow, ZMark::Strong>(addr);
  }

  return addr;
}

zaddress ZBarrier::keep_alive_slow_path(zaddress addr) {
  if (!is_null(addr)) {
    mark<ZMark::Resurrect, ZMark::AnyThread, ZMark::Follow, ZMark::Strong>(addr);
  }

  return addr;
}

#ifdef ASSERT

// ON_WEAK barriers should only ever be applied to j.l.r.Reference.referents and @weak-annotated fields
void ZBarrier::verify_on_weak(volatile zpointer* referent_addr) {
  if (referent_addr == nullptr) {
    return;
  }

  // Use ZGC page machinery to find the containing object
  if (!ZHeap::heap()->is_in((uintptr_t)referent_addr)) {
    return;
  }

  ZPage* const page = ZHeap::heap()->page(referent_addr);
  if (page == nullptr) {
    return;
  }

  const zaddress_unsafe base_addr = page->find_base_unsafe(referent_addr);
  if (is_null(base_addr)) {
    // Cannot find base object (e.g. livemap not yet populated); skip verification
    return;
  }

  const oop obj = to_oop(safe(base_addr));
  assert(oopDesc::is_oop(obj), "Verification failed for: ref " PTR_FORMAT " obj: " PTR_FORMAT,
         (uintptr_t)referent_addr, (uintptr_t)base_addr);

  const int offset = (int)((uintptr_t)referent_addr - cast_from_oop<uintptr_t>(obj));

  // Check if it's a Reference.referent field
  if (java_lang_ref_Reference::is_referent_field(obj, offset)) {
    return;
  }

  // Check if it's a @weak-annotated field
  Klass* const k = obj->klass();
  if (k->is_instance_klass()) {
    fieldDescriptor fd;
    if (InstanceKlass::cast(k)->find_field_from_offset(offset, false, &fd)) {
      assert(fd.is_weak(), "ON_WEAK_OOP_REF applied to non-weak, non-referent field %s.%s at offset %d",
             k->external_name(), fd.name()->as_C_string(), offset);
      return;
    }
  }

  assert(false, "ON_WEAK_OOP_REF applied to unknown field at offset %d in %s",
         offset, obj->klass()->external_name());
}

#endif
