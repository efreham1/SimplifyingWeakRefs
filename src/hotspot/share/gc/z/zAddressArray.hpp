/*
 * Copyright (c) 2025, Oracle and/or its affiliates. All rights reserved.
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

#ifndef SHARE_GC_Z_ZADDRESSARRAY_HPP
#define SHARE_GC_Z_ZADDRESSARRAY_HPP

#include "gc/z/zAddress.hpp"
#include "memory/allocation.hpp"
#include "utilities/debug.hpp"
#include <string.h>

// High-performance growable array specifically for storing discovered weak references.
// Uses struct-of-arrays (SoA) layout for better cache locality and SIMD potential.
// Stores three parallel arrays:
// - referent_field_addrs: pointers to zpointer fields (the referent fields in Reference objects)
// - discovered_field_addrs: pointers to zaddress fields (the discovered fields in Reference objects)
// - referent_addrs: zaddress values of the referent objects
//
// Performance optimizations:
// - Uses memcpy for bulk copying instead of element-by-element loops
// - Does not zero newly allocated memory (caller responsible for initialization)
// - Single clear_and_reserve operation to avoid separate clear/reserve calls
// - Struct-of-arrays layout improves cache efficiency during sequential access
class ZAddressArray : public AnyObj {
private:
  zpointer** _referent_field_addrs;
  zaddress** _discovered_field_addrs;
  zaddress* _referent_addrs;
  int       _length;
  int       _capacity;

  void expand_to(int new_capacity) {
    assert(new_capacity > _capacity, "expected growth but %d <= %d", new_capacity, _capacity);
    
    zpointer** new_referent_field_addrs = (zpointer**)AllocateHeap(new_capacity * sizeof(zpointer*), mtGC);
    zaddress** new_discovered_field_addrs = (zaddress**)AllocateHeap(new_capacity * sizeof(zaddress*), mtGC);
    zaddress* new_referent_addrs = (zaddress*)AllocateHeap(new_capacity * sizeof(zaddress), mtGC);
    
    if (_length > 0) {
      // Use memcpy for trivially copyable types - much faster than element-by-element copy
      memcpy(new_referent_field_addrs, _referent_field_addrs, _length * sizeof(zpointer*));
      memcpy(new_discovered_field_addrs, _discovered_field_addrs, _length * sizeof(zaddress*));
      memcpy(new_referent_addrs, _referent_addrs, _length * sizeof(zaddress));
    }
    
    if (_referent_field_addrs != nullptr) {
      FreeHeap(_referent_field_addrs);
      FreeHeap(_discovered_field_addrs);
      FreeHeap(_referent_addrs);
    }
    
    _referent_field_addrs = new_referent_field_addrs;
    _discovered_field_addrs = new_discovered_field_addrs;
    _referent_addrs = new_referent_addrs;
    _capacity = new_capacity;
  }

  void grow(int min_capacity) {
    int new_capacity = MAX2(8, next_power_of_2(min_capacity - 1));
    expand_to(new_capacity);
  } 

public:
  ZAddressArray() : _referent_field_addrs(nullptr), _discovered_field_addrs(nullptr), _referent_addrs(nullptr), _length(0), _capacity(0) {}

  ~ZAddressArray() {
    if (_referent_field_addrs != nullptr) {
      FreeHeap(_referent_field_addrs);
      FreeHeap(_discovered_field_addrs);
      FreeHeap(_referent_addrs);
      _referent_field_addrs = nullptr;
      _discovered_field_addrs = nullptr;
      _referent_addrs = nullptr;
    }
  }

  // Append a new entry
  void append(zpointer* referent_field_addr, zaddress* discovered_field_addr, zaddress referent_addr) {
    if (_length >= _capacity) {
      grow(_length + 1);
    }
    _referent_field_addrs[_length] = referent_field_addr;
    _discovered_field_addrs[_length] = discovered_field_addr;
    _referent_addrs[_length] = referent_addr;
    _length++;
  }

  // Get referent field address at index
  zpointer* referent_field_addr_at(int index) const {
    assert(index >= 0 && index < _length, "index out of bounds: %d (length: %d)", index, _length);
    return _referent_field_addrs[index];
  }

  // Get discovered field address at index
  zaddress* discovered_field_addr_at(int index) const {
    assert(index >= 0 && index < _length, "index out of bounds: %d (length: %d)", index, _length);
    return _discovered_field_addrs[index];
  }

  // Get referent address at index
  zaddress referent_addr_at(int index) const {
    assert(index >= 0 && index < _length, "index out of bounds: %d (length: %d)", index, _length);
    return _referent_addrs[index];
  }

  // Current length
  int length() const {
    return _length;
  }

  // Current capacity
  int capacity() const {
    return _capacity;
  }

  void clear_and_reserve(int new_capacity) {
    _length = 0;
    if (_referent_field_addrs != nullptr) {
        FreeHeap(_referent_field_addrs);
        FreeHeap(_discovered_field_addrs);
        FreeHeap(_referent_addrs);
    }
    _capacity = MAX2(8, next_power_of_2(new_capacity - 1));
    _referent_field_addrs = (zpointer**)AllocateHeap(_capacity * sizeof(zpointer*), mtGC);
    _discovered_field_addrs = (zaddress**)AllocateHeap(_capacity * sizeof(zaddress*), mtGC);
    _referent_addrs = (zaddress*)AllocateHeap(_capacity * sizeof(zaddress), mtGC);
  }

  // Clear without deallocating
  void clear() {
    _length = 0;
  }

  // Reserve capacity without clearing
  void reserve(int new_capacity) {
    if (new_capacity > _capacity) {
      grow(new_capacity);
    }
  }
};

#endif // SHARE_GC_Z_ZADDRESSARRAY_HPP
