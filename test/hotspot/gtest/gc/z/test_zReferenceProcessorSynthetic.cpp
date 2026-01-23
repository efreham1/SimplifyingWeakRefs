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

#include "classfile/javaClasses.inline.hpp"
#include "classfile/symbolTable.hpp"
#include "classfile/systemDictionary.hpp"
#include "gc/z/zArguments.hpp"
#include "gc/z/zGlobals.hpp"
#include "gc/z/zReferenceProcessor.hpp"
#include "gc/z/zGeneration.inline.hpp"
#include "memory/oopFactory.hpp"
#include "memory/resourceArea.hpp"
#include "oops/instanceKlass.inline.hpp"
#include "oops/oopHandle.inline.hpp"
#include "oops/oop.inline.hpp"
#include "oops/typeArrayOop.inline.hpp"
#include "runtime/fieldDescriptor.inline.hpp"
#include "runtime/handles.inline.hpp"
#include "runtime/interfaceSupport.inline.hpp"
#include "runtime/os.hpp"
#include "runtime/thread.hpp"
#include "runtime/vmThread.hpp"
#include "unittest.hpp"
#include "zunittest.hpp"
#include "utilities/ticks.hpp"

static oop fetch_null_queue(JavaThread* THREAD) {
  // Mirrors ZReferenceProcessor::initialize_null_queue_handle(), kept local to avoid touching private members.
  TempNewSymbol class_name = SymbolTable::new_symbol("java/lang/ref/ReferenceQueue");
  Klass* k = SystemDictionary::resolve_or_fail(class_name, true, THREAD);
  if (HAS_PENDING_EXCEPTION) {
    CLEAR_PENDING_EXCEPTION;
    return nullptr;
  }

  InstanceKlass* ik = InstanceKlass::cast(k);
  ik->initialize(THREAD);
  if (HAS_PENDING_EXCEPTION) {
    CLEAR_PENDING_EXCEPTION;
    return nullptr;
  }

  fieldDescriptor fd;
  const bool found = ik->find_local_field(SymbolTable::new_symbol("NULL_QUEUE"),
                                          vmSymbols::referencequeue_signature(), &fd);
  assert(found && fd.is_static(), "ReferenceQueue.NULL_QUEUE missing");
  return ik->java_mirror()->obj_field(fd.offset());
}

class VM_ZRefProcessorSynthetic : public VM_GTestExecuteAtSafepoint {
public:
  virtual void doit();
};

void VM_ZRefProcessorSynthetic::doit() {
  JavaThread* THREAD = JavaThread::current();
  HandleMark hm(THREAD);

  // Check if references will land on old pages (non-generational mode required)
  oop test_obj = oopFactory::new_byteArray(64, THREAD);
  if (HAS_PENDING_EXCEPTION || !ZHeap::heap()->is_old(to_zaddress(test_obj))) {
    if (HAS_PENDING_EXCEPTION) CLEAR_PENDING_EXCEPTION;
    tty->print_cr("ZReferenceProcessor synthetic benchmark: SKIPPED (generational mode or allocation failure)");
    return;
  }

  ZReferenceProcessor* rp = static_cast<ZReferenceProcessor*>(ZGeneration::old()->reference_discoverer());
  rp->prepare();
  rp->reset_statistics();
  rp->set_soft_reference_policy(false);

  oop null_queue = fetch_null_queue(THREAD);
  ASSERT_NE(null_queue, (oop)nullptr);

  InstanceKlass* weak_ik = InstanceKlass::cast(vmClasses::WeakReference_klass());
  weak_ik->initialize(THREAD);
  ASSERT_FALSE(HAS_PENDING_EXCEPTION);

  const int total_refs = 50000; // Large enough to get measurable work without exhausting the test VM
  const int padding_per_ref = 4;
  ResourceMark rm(THREAD);

  GrowableArray<zaddress> ref_addresses(total_refs);

  // Phase 1: Allocate references with scattered referents (allocation + setup phase)
  const Ticks alloc_start = Ticks::now();
  for (int i = 0; i < total_refs; i++) {
    const int payload_size = 256 + (os::random() & 1023);
    oop referent_obj = oopFactory::new_byteArray(payload_size, THREAD);
    if (HAS_PENDING_EXCEPTION) {
      CLEAR_PENDING_EXCEPTION;
      continue;
    }
    Handle referent(THREAD, referent_obj);

    oop ref_obj = weak_ik->allocate_instance(THREAD);
    if (HAS_PENDING_EXCEPTION) {
      CLEAR_PENDING_EXCEPTION;
      break;
    }
    Handle ref(THREAD, ref_obj);

    ref()->obj_field_put(java_lang_ref_Reference::referent_offset(), referent());
    ref()->obj_field_put(java_lang_ref_Reference::queue_offset(), null_queue);
    java_lang_ref_Reference::set_next_raw(ref(), nullptr);
    java_lang_ref_Reference::set_discovered_raw(ref(), nullptr);

    ref_addresses.append(to_zaddress(ref()));

    // Padding allocations to ensure references land far apart in memory.
    for (int p = 0; p < padding_per_ref; p++) {
      const int pad_size = 128 + (os::random() & 2047);
      (void)oopFactory::new_byteArray(pad_size, THREAD);
      if (HAS_PENDING_EXCEPTION) {
        CLEAR_PENDING_EXCEPTION;
        break;
      }
    }
  }
  const uint64_t alloc_ns = (Ticks::now() - alloc_start).nanoseconds();

  // Phase 2: Discovery phase (measure separately)
  const Ticks discover_start = Ticks::now();
  for (int i = 0; i < ref_addresses.length(); i++) {
    rp->discover(ref_addresses.at(i), REF_WEAK);
  }
  const uint64_t discover_ns = (Ticks::now() - discover_start).nanoseconds();

  // Phase 3: Processing phase
  const Ticks process_start = Ticks::now();
  rp->process_references();
  rp->enqueue_references();
  const uint64_t process_ns = (Ticks::now() - process_start).nanoseconds();

  tty->print_cr("ZReferenceProcessor synthetic benchmark: refs=%d padding=%d alloc_us=" UINT64_FORMAT " discover_us=" UINT64_FORMAT " process_us=" UINT64_FORMAT,
                ref_addresses.length(), padding_per_ref, alloc_ns / 1000, discover_ns / 1000, process_ns / 1000);
}

TEST_VM(ZReferenceProcessor, synthetic_benchmark) {
  if (!UseZGC) {
    return;
  }

  VM_ZRefProcessorSynthetic op;
  ThreadInVMfromNative invm(JavaThread::current());
  VMThread::execute(&op);
}
