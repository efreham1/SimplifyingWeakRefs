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

#ifndef SHARE_GC_Z_ZREFERENCEARRAY_HPP
#define SHARE_GC_Z_ZREFERENCEARRAY_HPP

#include "gc/z/zAddress.hpp"
#include "memory/allocation.hpp"
#include "utilities/debug.hpp"
#include "utilities/powerOfTwo.hpp"
#include "utilities/globalDefinitions.hpp"
#include <string.h>

struct ZWeakRefData {
  zaddress reference;

};


// High-performance growable array specifically for storing discovered reference data.
// Uses array-of-structs (AoS) layout for better cache locality when processing sequentially.
// The stored entry type is configured by the template parameter.
//
// Performance optimizations:
// - Uses memcpy for bulk copying instead of element-by-element loops
// - Does not zero newly allocated memory (caller responsible for initialization)
// - Single clear_and_reserve operation to avoid separate clear/reserve calls
// - Array-of-structs layout improves cache efficiency for sequential processing
template <typename Entry>
class ZReferenceArray : public AnyObj {
private:
  Entry* _data;
  size_t _length;
  size_t _capacity;

  void expand_to(size_t new_capacity) {
    assert(new_capacity > _capacity, "expected growth but %ld <= %ld", new_capacity, _capacity);
    
    Entry* new_data = (Entry*)AllocateHeap(new_capacity * sizeof(Entry), mtGC);
    
    if (_length > 0) {
      // Use memcpy for trivially copyable types - much faster than element-by-element copy
      memcpy(new_data, _data, _length * sizeof(Entry));
    }
    
    if (_data != nullptr) {
      FreeHeap(_data);
    }
    
    _data = new_data;
    _capacity = new_capacity;
  }

  void grow(size_t min_capacity) {
    size_t new_capacity = MAX2((size_t) 8, next_power_of_2(min_capacity - 1));
    expand_to(new_capacity);
  } 

public:
  ZReferenceArray() : _data(nullptr), _length(0), _capacity(0) {}

  ~ZReferenceArray() {
    if (_data != nullptr) {
      FreeHeap(_data);
      _data = nullptr;
    }
  }

  void append(const Entry& entry) {
    if (_length >= _capacity) {
      grow(_length + 1);
    }
    _data[_length] = entry;
    _length++;
  }

  // Get entry at index
  const Entry& at(size_t index) const {
    assert(index < _length, "index out of bounds: %ld (length: %ld)", index, _length);
    return _data[index];
  }

  // Current length
  size_t length() const {
    return _length;
  }

  // Whether the array is empty
  bool is_empty() const {
    return _length == 0;
  }

  // Current capacity
  size_t capacity() const {
    return _capacity;
  }

  void clear_and_reserve(size_t new_capacity) {
    if (new_capacity == 0) {
      // Special case for clearing to empty - free memory and reset
       if (_data != nullptr) {
         FreeHeap(_data);
         _data = nullptr;
       }
       _length = 0;
       _capacity = 0;
       return;
    }
    _length = 0;
    if (_data != nullptr) {
      FreeHeap(_data);
    }
    _capacity = MAX2((size_t) 8, next_power_of_2(new_capacity - 1));
    _data = (Entry*)AllocateHeap(_capacity * sizeof(Entry), mtGC);
  }

  // Clear without deallocating
  void clear() {
    _length = 0;
  }

  // Reserve capacity without clearing
  void reserve(size_t new_capacity) {
    if (new_capacity > _capacity) {
      grow(new_capacity);
    }
  }
};

typedef ZReferenceArray<ZWeakRefData> ZWeakRefArray;

#endif // SHARE_GC_Z_ZREFERENCEARRAY_HPP
