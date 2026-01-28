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

struct ZWeakRefData {
  zpointer* referent_field_addr;
  zaddress* discovered_field_addr;
  zaddress referent_addr;
  zpointer referent_field_value;
};

// High-performance growable array specifically for storing discovered weak references.
// Uses array-of-structs (AoS) layout for better cache locality when processing sequentially.
// Each element is a ZWeakRefData struct containing:
// - referent_field_addr: pointer to zpointer field (the referent field in Reference object)
// - discovered_field_addr: pointer to zaddress field (the discovered field in Reference object)
// - referent_addr: zaddress value of the referent object
//
// Performance optimizations:
// - Uses memcpy for bulk copying instead of element-by-element loops
// - Does not zero newly allocated memory (caller responsible for initialization)
// - Single clear_and_reserve operation to avoid separate clear/reserve calls
// - Array-of-structs layout improves cache efficiency for sequential processing
class ZAddressArray : public AnyObj {
private:
  ZWeakRefData* _data;
  int           _length;
  int           _capacity;

  void expand_to(int new_capacity) {
    assert(new_capacity > _capacity, "expected growth but %d <= %d", new_capacity, _capacity);
    
    ZWeakRefData* new_data = (ZWeakRefData*)AllocateHeap(new_capacity * sizeof(ZWeakRefData), mtGC);
    
    if (_length > 0) {
      // Use memcpy for trivially copyable types - much faster than element-by-element copy
      memcpy(new_data, _data, _length * sizeof(ZWeakRefData));
    }
    
    if (_data != nullptr) {
      FreeHeap(_data);
    }
    
    _data = new_data;
    _capacity = new_capacity;
  }

  void grow(int min_capacity) {
    int new_capacity = MAX2(8, next_power_of_2(min_capacity - 1));
    expand_to(new_capacity);
  } 

public:
  ZAddressArray() : _data(nullptr), _length(0), _capacity(0) {}

  ~ZAddressArray() {
    if (_data != nullptr) {
      FreeHeap(_data);
      _data = nullptr;
    }
  }

  // Append a new entry
  void append(zpointer* referent_field_addr, zaddress* discovered_field_addr, zaddress referent_addr, zpointer referent_field_value) {
    if (_length >= _capacity) {
      grow(_length + 1);
    }
    _data[_length].referent_field_addr = referent_field_addr;
    _data[_length].discovered_field_addr = discovered_field_addr;
    _data[_length].referent_addr = referent_addr;
    _data[_length].referent_field_value = referent_field_value;
    _length++;
  }

  // Get entry at index
  const ZWeakRefData& at(int index) const {
    assert(index >= 0 && index < _length, "index out of bounds: %d (length: %d)", index, _length);
    return _data[index];
  }

  // Get referent field address at index
  zpointer* referent_field_addr_at(int index) const {
    assert(index >= 0 && index < _length, "index out of bounds: %d (length: %d)", index, _length);
    return _data[index].referent_field_addr;
  }

  // Get discovered field address at index
  zaddress* discovered_field_addr_at(int index) const {
    assert(index >= 0 && index < _length, "index out of bounds: %d (length: %d)", index, _length);
    return _data[index].discovered_field_addr;
  }

  // Get referent address at index
  zaddress referent_addr_at(int index) const {
    assert(index >= 0 && index < _length, "index out of bounds: %d (length: %d)", index, _length);
    return _data[index].referent_addr;
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
    if (_data != nullptr) {
      FreeHeap(_data);
    }
    _capacity = MAX2(8, next_power_of_2(new_capacity - 1));
    _data = (ZWeakRefData*)AllocateHeap(_capacity * sizeof(ZWeakRefData), mtGC);
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
