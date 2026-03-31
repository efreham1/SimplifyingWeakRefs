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

#include "classfile/javaClasses.inline.hpp"
#include "gc/shared/referencePolicy.hpp"
#include "gc/shared/referenceProcessorStats.hpp"
#include "gc/shared/suspendibleThreadSet.hpp"
#include "gc/z/zCollectedHeap.hpp"
#include "gc/z/zDriver.hpp"
#include "gc/z/zHeap.inline.hpp"
#include "gc/z/zReferenceProcessor.hpp"
#include "gc/z/zStat.hpp"
#include "gc/z/zTask.hpp"
#include "gc/z/zTracer.inline.hpp"
#include "gc/z/zValue.inline.hpp"
#include "logging/log.hpp"
#include "memory/universe.hpp"
#include "oops/access.inline.hpp"
#include "runtime/atomicAccess.hpp"
#include "runtime/mutexLocker.hpp"
#include "runtime/os.hpp"
#include "runtime/thread.hpp"
#include "classfile/symbolTable.hpp"
#include "classfile/systemDictionary.hpp"
#include "oops/oopHandle.inline.hpp"
#include "runtime/fieldDescriptor.inline.hpp"

static const ZStatSubPhase ZSubPhaseConcurrentReferencesProcess("Concurrent References Process", ZGenerationId::old);
static const ZStatSubPhase ZSubPhaseConcurrentReferencesEnqueue("Concurrent References Enqueue", ZGenerationId::old);

static ReferenceType reference_type(zaddress reference) {
  return InstanceKlass::cast(to_oop(reference)->klass())->reference_type();
}

static const char* reference_type_name(ReferenceType type) {
  switch (type) {
  case REF_SOFT:
    return "Soft";

  case REF_WEAK:
    return "Weak";

  case REF_FINAL:
    return "Final";

  case REF_PHANTOM:
    return "Phantom";

  default:
    ShouldNotReachHere();
    return "Unknown";
  }
}

static volatile zpointer* reference_referent_addr(zaddress reference) {
  return (volatile zpointer*)java_lang_ref_Reference::referent_addr_raw(to_oop(reference));
}

static zpointer reference_referent(zaddress reference) {
  return ZBarrier::load_atomic(reference_referent_addr(reference));
}

static volatile zpointer* reference_queue_addr(zaddress reference) {
  return (volatile zpointer*)to_oop(reference)->field_addr<zpointer>(java_lang_ref_Reference::queue_offset());
}

static zaddress reference_discovered(zaddress reference) {
  return to_zaddress(java_lang_ref_Reference::discovered(to_oop(reference)));
}

static void reference_set_discovered(zaddress reference, zaddress discovered) {
  java_lang_ref_Reference::set_discovered(to_oop(reference), to_oop(discovered));
}

static zaddress reference_next(zaddress reference) {
  return to_zaddress(java_lang_ref_Reference::next(to_oop(reference)));
}

static void reference_set_next(zaddress reference, zaddress next) {
  java_lang_ref_Reference::set_next(to_oop(reference), to_oop(next));
}

static void soft_reference_update_clock() {
  SuspendibleThreadSetJoiner sts_joiner;
  const jlong now = os::javaTimeNanos() / NANOSECS_PER_MILLISEC;
  java_lang_ref_SoftReference::set_clock(now);
}

static void list_append(zaddress& head, zaddress& tail, zaddress reference) {
  if (is_null(head)) {
    // First append - set up the head
    head = reference;
  } else {
    // Not first append, link tail
    reference_set_discovered(tail, reference);
  }

  // Always set tail
  tail = reference;
}

ZReferenceProcessor::ZReferenceProcessor(ZWorkers* workers)
  : _workers(workers),
    _soft_reference_policy(nullptr),
    _uses_clear_all_soft_reference_policy(false),
    _encountered_count(),
    _discovered_count(),
    _enqueued_count(),
    _encountered_weak_refs_without_queue_count(),
    _discovered_weak_refs_without_queue_count(),
    _cleared_weak_refs_without_queue_count(),
    _discovered_list(zaddress::null),
    _pending_list(zaddress::null),
    _pending_list_tail(zaddress::null),
    _discovered_weak_refs_without_queue_arr(),
    _array_empty(),
    _null_queue_handle() {
  _array_empty.set_all(true);

  log_info(gc, ref)("Reference Processor created, separate lists and dynamic array enabled");
}

void ZReferenceProcessor::set_soft_reference_policy(bool clear_all_soft_references) {
  static AlwaysClearPolicy always_clear_policy;
  static LRUMaxHeapPolicy lru_max_heap_policy;

  _uses_clear_all_soft_reference_policy = clear_all_soft_references;

  if (clear_all_soft_references) {
    _soft_reference_policy = &always_clear_policy;
  } else {
    _soft_reference_policy = &lru_max_heap_policy;
  }

  _soft_reference_policy->setup();
}

bool ZReferenceProcessor::uses_clear_all_soft_reference_policy() const {
  return _uses_clear_all_soft_reference_policy;
}

bool ZReferenceProcessor::is_inactive(zaddress reference, oop referent, ReferenceType type) const {
  if (type == REF_FINAL) {
    // A FinalReference is inactive if its next field is non-null. An application can't
    // call enqueue() or clear() on a FinalReference.
    return !is_null(reference_next(reference));
  } else {
    // Verification
    check_is_valid_zaddress(referent);

    // A non-FinalReference is inactive if the referent is null. The referent can only
    // be null if the application called Reference.enqueue() or Reference.clear().
    return referent == nullptr;
  }
}

bool ZReferenceProcessor::is_strongly_live(oop referent) const {
  const zaddress addr = to_zaddress(referent);
  return ZHeap::heap()->is_young(addr) || ZHeap::heap()->is_object_strongly_live(to_zaddress(referent));
}

bool ZReferenceProcessor::is_softly_live(zaddress reference, ReferenceType type) const {
  if (type != REF_SOFT) {
    // Not a SoftReference
    return false;
  }

  // Ask SoftReference policy
  const jlong clock = java_lang_ref_SoftReference::clock();
  assert(clock != 0, "Clock not initialized");
  assert(_soft_reference_policy != nullptr, "Policy not initialized");
  return !_soft_reference_policy->should_clear_reference(to_oop(reference), clock);
}

bool ZReferenceProcessor::should_discover(zaddress reference, ReferenceType type) const {
  volatile zpointer* const referent_addr = reference_referent_addr(reference);
  const oop referent = to_oop(ZBarrier::load_barrier_on_oop_field(referent_addr));

  if (is_inactive(reference, referent, type)) {
    return false;
  }

  if (is_strongly_live(referent)) {
    return false;
  }

  if (is_softly_live(reference, type)) {
    return false;
  }

  // PhantomReferences with finalizable marked referents should technically not have
  // to be discovered. However, InstanceRefKlass::oop_oop_iterate_ref_processing()
  // does not know about the finalizable mark concept, and will therefore mark
  // referents in non-discovered PhantomReferences as strongly live. To prevent
  // this, we always discover PhantomReferences with finalizable marked referents.
  // They will automatically be dropped during the reference processing phase.
  return true;
}

bool ZReferenceProcessor::try_make_inactive(zaddress reference, ReferenceType type) const {
  const zpointer referent = reference_referent(reference);

  if (is_null_any(referent)) {
    // Reference has already been cleared, by a call to Reference.enqueue()
    // or Reference.clear() from the application, which means it's already
    // inactive and we should drop the reference.
    return false;
  }

  volatile zpointer* const referent_addr = reference_referent_addr(reference);

  // Cleaning the referent will fail if the object it points to is
  // still alive, in which case we should drop the reference.
  if (type == REF_SOFT || type == REF_WEAK) {
    return ZBarrier::clean_barrier_on_weak_oop_field(referent_addr);
  } else if (type == REF_PHANTOM) {
    return ZBarrier::clean_barrier_on_phantom_oop_field(referent_addr);
  } else if (type == REF_FINAL) {
    if (ZBarrier::clean_barrier_on_final_oop_field(referent_addr)) {
      // The referent in a FinalReference will not be cleared, instead it is
      // made inactive by self-looping the next field. An application can't
      // call FinalReference.enqueue(), so there is no race to worry about
      // when setting the next field.
      assert(is_null(reference_next(reference)), "Already inactive");
      reference_set_next(reference, reference);
      return true;
    }
  } else {
    fatal("Invalid referent type %d", type);
  }

  return false;
}

void ZReferenceProcessor::discover(zaddress reference, ReferenceType type) {
  log_trace(gc, ref)("Discovered Reference: " PTR_FORMAT " (%s)", untype(reference), reference_type_name(type));

  assert(ZHeap::heap()->is_old(reference), "Must be old");
  assert(is_null(reference_discovered(reference)), "Already discovered");
  
  // Update statistics
  if (type == REF_WEAK && !has_reference_queue(reference)) {
    _discovered_weak_refs_without_queue_count.get()++;
  }
  else {
    _discovered_count.get()[type]++;
  }

  if (type == REF_WEAK && !has_reference_queue(reference)) {
    // WeakReference with null ReferenceQueue - remember for special processing
    ZWeakRefArray& weak_refs_without_queue = _discovered_weak_refs_without_queue_arr.get();
    ZWeakRefData data = {reference};
    weak_refs_without_queue.append(data);
    _array_empty.set(false);
    reference_set_discovered(reference, reference); // mark as discovered
  } else {
    if (type == REF_FINAL) {
      // Mark referent (and its reachable subgraph) finalizable. This avoids
      // the problem of later having to mark those objects if the referent is
      // still final reachable during processing.
      volatile zpointer* const referent_addr = reference_referent_addr(reference);
      ZBarrier::mark_barrier_on_old_oop_field(referent_addr, true /* finalizable */);
    }

    // Add reference to discovered list
    zaddress* const list = _discovered_list.addr();
    reference_set_discovered(reference, *list);
    *list = reference;
  }
}

bool ZReferenceProcessor::discover_reference(oop reference_obj, ReferenceType type) {
  if (!RegisterReferences) {
    // Reference processing disabled
    return false;
  }

  log_trace(gc, ref)("Encountered Reference: " PTR_FORMAT " (%s)", p2i(reference_obj), reference_type_name(type));

  const zaddress reference = to_zaddress(reference_obj);

  // Update statistics
  if (type == REF_WEAK && !has_reference_queue(reference)) {
    _encountered_weak_refs_without_queue_count.get()++;
  }
  else {
    _encountered_count.get()[type]++;
  }

  if (ZHeap::heap()->is_young(reference)) {
    // Don't discover young references. Young gen reference processing is scary and therefore not supported.
    return false;
  }

  if (!should_discover(reference, type)) {
    // Not discovered
    return false;
  }

  discover(reference, type);

  // Discovered
  return true;
}

void ZReferenceProcessor::process_worker_discovered_list(zaddress discovered_list) {
  zaddress keep_head = zaddress::null;
  zaddress keep_tail = zaddress::null;

  // Iterate over the discovered list and unlink them as we go, potentially
  // appending them to the keep list
  for (zaddress reference = discovered_list; !is_null(reference); ) {
    assert(ZHeap::heap()->is_old(reference), "Must be old");

    const ReferenceType type = reference_type(reference);
    const zaddress next = reference_discovered(reference);
    reference_set_discovered(reference, zaddress::null);

    if (try_make_inactive(reference, type)) {
      // Keep reference
      log_trace(gc, ref)("Enqueued Reference: " PTR_FORMAT " (%s)", untype(reference), reference_type_name(type));

      // Update statistics
      if (type == REF_WEAK && !has_reference_queue(reference)) {
        _cleared_weak_refs_without_queue_count.get()++;
      }
      else {
        _enqueued_count.get()[type]++;

        list_append(keep_head, keep_tail, reference);
      }
    } else {
      // Drop reference
      log_trace(gc, ref)("Dropped Reference: " PTR_FORMAT " (%s)", untype(reference), reference_type_name(type));
    }

    reference = next;
    SuspendibleThreadSet::yield();
  }

  // Prepend discovered references to internal pending list

  // Anything kept on the list?
  if (!is_null(keep_head)) {
    const zaddress old_pending_list = AtomicAccess::xchg(_pending_list.addr(), keep_head);

    // Concatenate the old list
    reference_set_discovered(keep_tail, old_pending_list);

    if (is_null(old_pending_list)) {
      // Old list was empty. First to prepend to list, record tail
      _pending_list_tail = keep_tail;
    } else {
      assert(ZHeap::heap()->is_old(old_pending_list), "Must be old");
    }
  }
}

void ZReferenceProcessor::process_worker_discovered_weak_refs_without_queue(ZWeakRefArray& weak_refs_without_queue) {
  size_t dropped = 0;
  for (size_t i = 0; i < weak_refs_without_queue.length(); i++) {
    const ZWeakRefData& data = weak_refs_without_queue.at(i);    
    zaddress reference = data.reference;
    reference_set_discovered(reference, zaddress::null); // Mark as dropped
    if (try_make_inactive(reference, reference_type(reference))) {
      log_trace(gc, ref)("\"Enqueued\" Weak Reference without Queue");
      // Update statistics
      _cleared_weak_refs_without_queue_count.get()++;
    } else {
      log_trace(gc, ref)("Dropped Weak Reference without Queue");
      dropped++;
    }
    SuspendibleThreadSet::yield();
  }
  weak_refs_without_queue.clear_and_reserve(dropped);
}

void ZReferenceProcessor::work() {
  SuspendibleThreadSetJoiner sts_joiner;

  ZPerWorkerIterator<zaddress> iter(&_discovered_list);
  ZPerWorkerIterator<ZWeakRefArray> iter_weak_refs(&_discovered_weak_refs_without_queue_arr);
  ZPerWorkerIterator<bool> iter_array_empty(&_array_empty);
  
  zaddress* list_addr = nullptr;
  ZWeakRefArray* array_addr = nullptr;
  bool* array_empty = nullptr;
  
  for (; iter.next(&list_addr) && iter_weak_refs.next(&array_addr) && iter_array_empty.next(&array_empty);) {
    const zaddress discovered_list = AtomicAccess::xchg(list_addr, zaddress::null);
    const bool has_array = !AtomicAccess::xchg(array_empty, true);
    const bool has_discovered = discovered_list != zaddress::null;
    
    if (has_discovered) {
      // Process discovered references
      process_worker_discovered_list(discovered_list);
    }
    if (has_array) {
      // Process discovered weak references without queue
      process_worker_discovered_weak_refs_without_queue(*array_addr);
    }
  }
}

void ZReferenceProcessor::verify_empty() const {
#ifdef ASSERT
  ZPerWorkerConstIterator<zaddress> iter(&_discovered_list);
  for (const zaddress* list; iter.next(&list);) {
    assert(is_null(*list), "Discovered list not empty");
  }

  ZPerWorkerConstIterator<ZWeakRefArray> iter_weak_refs(&_discovered_weak_refs_without_queue_arr);
  for (const ZWeakRefArray* array; iter_weak_refs.next(&array);) {
    assert(array->is_empty(), "Discovered weak refs without queue not empty");
  }

  assert(is_null(_pending_list.get()), "Pending list not empty");
#endif
}

void ZReferenceProcessor::reset_statistics() {
  verify_empty();

  // Reset encountered
  ZPerWorkerIterator<Counters> iter_encountered(&_encountered_count);
  for (Counters* counters; iter_encountered.next(&counters);) {
    for (int i = REF_SOFT; i <= REF_PHANTOM; i++) {
      (*counters)[i] = 0;
    }
  }

  // Reset discovered
  ZPerWorkerIterator<Counters> iter_discovered(&_discovered_count);
  for (Counters* counters; iter_discovered.next(&counters);) {
    for (int i = REF_SOFT; i <= REF_PHANTOM; i++) {
      (*counters)[i] = 0;
    }
  }

  // Reset enqueued
  ZPerWorkerIterator<Counters> iter_enqueued(&_enqueued_count);
  for (Counters* counters; iter_enqueued.next(&counters);) {
    for (int i = REF_SOFT; i <= REF_PHANTOM; i++) {
      (*counters)[i] = 0;
    }
  }

  // Reset weak references without queue
  ZPerWorkerIterator<size_t> iter_encountered_weak_no_queue(&_encountered_weak_refs_without_queue_count);
  for (size_t* count; iter_encountered_weak_no_queue.next(&count);) {
    *count = 0;
  }

  ZPerWorkerIterator<size_t> iter_discovered_weak_no_queue(&_discovered_weak_refs_without_queue_count);
  for (size_t* count; iter_discovered_weak_no_queue.next(&count);) {
    *count = 0;
  }

  ZPerWorkerIterator<size_t> iter_cleared_weak_no_queue(&_cleared_weak_refs_without_queue_count);
  for (size_t* count; iter_cleared_weak_no_queue.next(&count);) {
    *count = 0;
  }
}

void ZReferenceProcessor::collect_statistics() {
  Counters encountered = {};
  Counters discovered = {};
  Counters enqueued = {};
  size_t encountered_weak_no_queue = 0;
  size_t discovered_weak_no_queue = 0;
  size_t cleared_weak_no_queue = 0;

  // Sum encountered
  ZPerWorkerConstIterator<Counters> iter_encountered(&_encountered_count);
  for (const Counters* counters; iter_encountered.next(&counters);) {
    for (int i = REF_SOFT; i <= REF_PHANTOM; i++) {
      encountered[i] += (*counters)[i];
    }
  }

  // Sum discovered
  ZPerWorkerConstIterator<Counters> iter_discovered(&_discovered_count);
  for (const Counters* counters; iter_discovered.next(&counters);) {
    for (int i = REF_SOFT; i <= REF_PHANTOM; i++) {
      discovered[i] += (*counters)[i];
    }
  }

  // Sum enqueued
  ZPerWorkerConstIterator<Counters> iter_enqueued(&_enqueued_count);
  for (const Counters* counters; iter_enqueued.next(&counters);) {
    for (int i = REF_SOFT; i <= REF_PHANTOM; i++) {
      enqueued[i] += (*counters)[i];
    }
  }

  // Sum weak references without queue
  ZPerWorkerConstIterator<size_t> iter_encountered_weak_no_queue(&_encountered_weak_refs_without_queue_count);
  for (const size_t* count; iter_encountered_weak_no_queue.next(&count);) {
    encountered_weak_no_queue += *count;
  }

  ZPerWorkerConstIterator<size_t> iter_discovered_weak_no_queue(&_discovered_weak_refs_without_queue_count);
  for (const size_t* count; iter_discovered_weak_no_queue.next(&count);) {
    discovered_weak_no_queue += *count;
  }

  ZPerWorkerConstIterator<size_t> iter_cleared_weak_no_queue(&_cleared_weak_refs_without_queue_count);
  for (const size_t* count; iter_cleared_weak_no_queue.next(&count);) {
    cleared_weak_no_queue += *count;
  }

  // Update statistics
  ZStatReferences::set_soft(encountered[REF_SOFT], discovered[REF_SOFT], enqueued[REF_SOFT]);
  ZStatReferences::set_weak(encountered[REF_WEAK], discovered[REF_WEAK], enqueued[REF_WEAK]);
  ZStatReferences::set_weak_no_queue(encountered_weak_no_queue, discovered_weak_no_queue, cleared_weak_no_queue);
  ZStatReferences::set_final(encountered[REF_FINAL], discovered[REF_FINAL], enqueued[REF_FINAL]);
  ZStatReferences::set_phantom(encountered[REF_PHANTOM], discovered[REF_PHANTOM], enqueued[REF_PHANTOM]);

  // Trace statistics
  const ReferenceProcessorStats stats(discovered[REF_SOFT],
                                      discovered[REF_WEAK],
                                      discovered[REF_FINAL],
                                      discovered[REF_PHANTOM]);
  ZDriver::major()->jfr_tracer()->report_gc_reference_stats(stats);
}

class ZReferenceProcessorTask : public ZTask {
private:
  ZReferenceProcessor* const _reference_processor;

public:
  ZReferenceProcessorTask(ZReferenceProcessor* reference_processor)
    : ZTask("ZReferenceProcessorTask"),
      _reference_processor(reference_processor) {}

  virtual void work() {
    _reference_processor->work();
  }
};

void ZReferenceProcessor::process_references() {
  ZStatTimerOld timer(ZSubPhaseConcurrentReferencesProcess);

  if (_uses_clear_all_soft_reference_policy) {
    log_info(gc, ref)("Clearing All SoftReferences");
  }
  
  // Process discovered lists
  ZReferenceProcessorTask task(this);
  _workers->run(&task);

  // Update SoftReference clock
  soft_reference_update_clock();

  // Collect, log and trace statistics
  collect_statistics();
}

void ZReferenceProcessor::verify_pending_references() {
#ifdef ASSERT
  SuspendibleThreadSetJoiner sts_joiner;

  assert(!is_null(_pending_list.get()), "Should not contain colored null");

  for (zaddress current = _pending_list.get();
       !is_null(current);
       current = reference_discovered(current))
  {
    volatile zpointer* const referent_addr = reference_referent_addr(current);
    const oop referent = to_oop(ZBarrier::load_barrier_on_oop_field(referent_addr));
    const ReferenceType type = reference_type(current);
    assert(ZReferenceProcessor::is_inactive(current, referent, type), "invariant");
    if (type == REF_FINAL) {
      assert(ZPointer::is_marked_any_old(ZBarrier::load_atomic(referent_addr)), "invariant");
    }

    SuspendibleThreadSet::yield();
  }
#endif
}

zaddress ZReferenceProcessor::swap_pending_list(zaddress pending_list) {
  const oop pending_list_oop = to_oop(pending_list);
  const oop prev = Universe::swap_reference_pending_list(pending_list_oop);
  return to_zaddress(prev);
}

void ZReferenceProcessor::enqueue_references() {
  ZStatTimerOld timer(ZSubPhaseConcurrentReferencesEnqueue);

  if (is_null(_pending_list.get())) {
    // Nothing to enqueue
    return;
  }

  // Verify references on internal pending list
  verify_pending_references();

  {
    // Heap_lock protects external pending list
    MonitorLocker ml(Heap_lock);
    SuspendibleThreadSetJoiner sts_joiner;

    const zaddress prev_list = swap_pending_list(_pending_list.get());

    // Link together new and old list
    reference_set_discovered(_pending_list_tail, prev_list);

    // Notify ReferenceHandler thread
    ml.notify_all();
  }

  // Reset internal pending list
  _pending_list.set(zaddress::null);
  _pending_list_tail = zaddress::null;
}

inline bool ZReferenceProcessor::has_reference_queue(zaddress reference) {
  if (_null_queue_handle.is_empty()) {
    // If NULL_QUEUE is not available yet, conservatively treat all references
    // as having a queue and avoid the weak-without-queue fast path.
    log_debug(gc, ref)("ReferenceQueue.NULL_QUEUE not available, treating a reference as having a queue");
    return true;
  }

  const zaddress ref_queue_addr_value = ZBarrier::load_barrier_on_oop_field(reference_queue_addr(reference));
  const oop ref_queue = to_oop(ref_queue_addr_value);
  bool result = ref_queue != _null_queue_handle.resolve();
  return result;
}

void ZReferenceProcessor::initialize_null_queue_handle() {
  EXCEPTION_MARK;
  TempNewSymbol class_name = SymbolTable::new_symbol("java/lang/ref/ReferenceQueue");
  Klass* k = SystemDictionary::resolve_or_fail(class_name, true, CHECK);
  InstanceKlass* ik = InstanceKlass::cast(k);
  ik->initialize(CHECK);
  fieldDescriptor fd;
  bool found = ik->find_local_field(SymbolTable::new_symbol("NULL_QUEUE"),
                                    vmSymbols::referencequeue_signature(), &fd);
  assert(found && fd.is_static(), "ReferenceQueue.NULL_QUEUE missing");
  oop null_q = ik->java_mirror()->obj_field(fd.offset());
  _null_queue_handle = OopHandle(Universe::vm_global(), null_q);
}

void ZReferenceProcessor::initializeResources() {
  Thread* const current = Thread::current();
  guarantee(current->is_Java_thread(), "Must be called by a JavaThread");
  guarantee(!current->is_ConcurrentGC_thread(), "Must not be called by a GC thread");

  initialize_null_queue_handle();
}
