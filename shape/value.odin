package shape

import "base:intrinsics"
import "base:runtime"

// >----------------------------------------------------------------------- Scalars

// Unsigned 128 bit values above the i128 range come back wrapped, `v.signed` tells how to
// read them.
get_int :: proc(v: Int) -> i128 {
	// Plain integers stay in 64 bit math, this is the hot path of every serialized integer
	if v.bits.size == 0 && !v.swapped && v.size <= 8 {
		raw := u64(load_bits(v.data, int(v.size)))
		shift := u64(64 - v.size * 8)
		return v.signed ? i128(i64(raw << shift) >> shift) : i128(raw)
	}

	if v.bits.size != 0 {
		raw := load_bits(v.data, int(v.bits.backing)) >> v.bits.offset
		size := u128(v.bits.size)
		return extend(raw & bit_mask(size), size, v.signed)
	}

	raw := load_bits(v.data, int(v.size))
	if v.swapped do raw = byte_swap(raw, int(v.size))
	return extend(raw, u128(v.size) * 8, v.signed)
}

// Stores `value` if it fits the type, and its bits when packed.
set_int :: proc(v: Int, value: i128) -> bool {
	// Plain integers stay in 64 bit math, this is the hot path of every parsed integer
	if v.bits.size == 0 && !v.swapped && v.size <= 8 {
		shift := u64(64 - v.size * 8)
		raw: u64

		if v.signed {
			if value < i128(min(i64)) || value > i128(max(i64)) do return false
			raw = u64(i64(value))
			if i64(raw << shift) >> shift != i64(value) do return false
		} else {
			if value < 0 || value > i128(max(u64)) do return false
			raw = u64(value)
			if (raw << shift) >> shift != raw do return false
		}

		store_bits(v.data, int(v.size), u128(raw))
		return true
	}

	size := v.bits.size != 0 ? u128(v.bits.size) : u128(v.size) * 8
	mask := bit_mask(size)

	// It fits when cutting it down to its bits and back is lossless
	raw := u128(value) & mask
	if extend(raw, size, v.signed) != value do return false

	if v.bits.size != 0 {
		backing := load_bits(v.data, int(v.bits.backing))
		offset := u128(v.bits.offset)
		store_bits(v.data, int(v.bits.backing), (backing & ~(mask << offset)) | (raw << offset))
		return true
	}

	if v.swapped do raw = byte_swap(raw, int(v.size))
	store_bits(v.data, int(v.size), raw)
	return true
}

get_bool :: proc(v: Bool) -> bool {return get_int(Int(v)) != 0}

set_bool :: proc(v: Bool, value: bool) {set_int(Int(v), value ? 1 : 0)}

get_rune :: proc(v: Rune) -> rune {return rune(get_int(Int(v)))}

set_rune :: proc(v: Rune, value: rune) -> bool {return set_int(Int(v), i128(value))}

get_enum :: proc(v: Enum) -> i128 {return get_int(v.integer)}

// Any value of the backing type, named or not.
set_enum :: proc(v: Enum, value: i128) -> bool {return set_int(v.integer, value)}

enum_name :: proc(v: Enum, value: i128) -> (name: string, ok: bool) {
	for member, i in v.info.values {
		if i128(member) == value do return v.info.names[i], true
	}

	return
}

enum_value :: proc(v: Enum, name: string) -> (value: i128, ok: bool) {
	for member, i in v.info.names {
		if member == name do return i128(v.info.values[i]), true
	}

	return
}

get_float :: proc(v: Float) -> f64 {
	raw := load_bits(v.data, int(v.size))
	if v.swapped do raw = byte_swap(raw, int(v.size))

	switch v.size {
	case 2:
		return f64(transmute(f16)u16(raw))
	case 4:
		return f64(transmute(f32)u32(raw))
	case 8:
		return transmute(f64)u64(raw)
	}

	return 0
}

set_float :: proc(v: Float, value: f64) {
	raw: u128

	switch v.size {
	case 2:
		raw = u128(transmute(u16)f16(value))
	case 4:
		raw = u128(transmute(u32)f32(value))
	case 8:
		raw = u128(transmute(u64)value)
	}

	if v.swapped do raw = byte_swap(raw, int(v.size))
	store_bits(v.data, int(v.size), raw)
}

// >----------------------------------------------------------------------- Strings

get_string :: proc(v: String) -> string {
	return v.is_cstring ? string((^cstring)(v.data)^) : (^string)(v.data)^
}

// Points the string at `length` fresh bytes and returns them for the caller to fill, a
// cstring gets an extra zeroed terminator. The previous contents are not freed.
alloc_string :: proc(v: String, length: int, allocator := context.allocator) -> []byte {
	if v.is_cstring {
		mem, _ := runtime.mem_alloc(length + 1, 1, allocator)
		(^cstring)(v.data)^ = cstring(raw_data(mem))
		return mem[:length]
	}

	mem, _ := runtime.mem_alloc(length, 1, allocator)
	(^string)(v.data)^ = string(mem)
	return mem
}

set_string :: proc(v: String, s: string, allocator := context.allocator) {
	copy(alloc_string(v, len(s), allocator), s)
}

// >------------------------------------------------------------------------ Arrays

// Changes the length of a resizable array, kept elements stay and new ones are zeroed. A
// growing slice moves to a fresh allocation without freeing the old one, a dynamic array
// without an allocator takes `allocator`.
resize :: proc(a: Array, count: int, allocator := context.allocator) -> bool {
	if count < 0 do return false

	switch a.layout {
	case .Slice:
		raw := (^runtime.Raw_Slice)(a.data)

		if count > raw.len {
			mem, err := runtime.mem_alloc(count * a.stride, a.elem.align, allocator)
			if err != nil do return false
			intrinsics.mem_copy_non_overlapping(raw_data(mem), raw.data, raw.len * a.stride)
			raw.data = raw_data(mem)
		}

		raw.len = count

	case .Dynamic:
		raw := (^runtime.Raw_Dynamic_Array)(a.data)
		old := raw.len
		if raw.allocator.procedure == nil do raw.allocator = allocator

		if !runtime.__dynamic_array_resize(raw, a.stride, a.elem.align, count) do return false
		if count > old do zero_elems(raw.data, a.stride, old, count)

	case .Fixed_Capacity:
		if count > a.count do return false

		len_ptr := fixed_capacity_len(a)
		if count > len_ptr^ do zero_elems(a.data, a.stride, len_ptr^, count)
		len_ptr^ = count

	case .Fixed, .Enumerated:
		return false
	}

	return true
}

// Inserts a zeroed element at `i`, `i == length(a)` appends.
insert_elem :: proc(a: Array, i: int, allocator := context.allocator) -> bool {
	count := array_length(a)
	if i < 0 || i > count || !resize(a, count + 1, allocator) do return false

	at := rawptr(uintptr(elems(a)) + uintptr(i * a.stride))
	intrinsics.mem_copy(rawptr(uintptr(at) + uintptr(a.stride)), at, (count - i) * a.stride)
	intrinsics.mem_zero(at, a.stride)
	return true
}

// Removes element `i` keeping the order, the element's own allocations are not freed.
remove_elem :: proc(a: Array, i: int) -> bool {
	count := array_length(a)
	if i < 0 || i >= count || !is_resizable(a) do return false

	at := rawptr(uintptr(elems(a)) + uintptr(i * a.stride))
	intrinsics.mem_copy(at, rawptr(uintptr(at) + uintptr(a.stride)), (count - i - 1) * a.stride)
	return resize(a, count - 1)
}

// >-------------------------------------------------------------------------- Maps

// Makes room for `count` entries, a map without an allocator takes `allocator`.
map_reserve :: proc(m: Map, count: int, allocator := context.allocator) -> bool {
	if m.data.allocator.procedure == nil do m.data.allocator = allocator
	return runtime.map_reserve_dynamic(m.data, m.map_info, uintptr(count)) == nil
}

// Inserts or overwrites the entry for `key`, copying the key and the value from where they
// point, a nil `value` stores a zero value. Returns the stored value, a nil value on failure.
map_insert :: proc(m: Map, key: rawptr, value: rawptr, allocator := context.allocator) -> Node {
	if m.data.allocator.procedure == nil do m.data.allocator = allocator

	value := value
	if value == nil {
		zero, err := runtime.mem_alloc(m.value.size, m.value.align, allocator)
		if err != nil do return {}
		defer runtime.mem_free(raw_data(zero), allocator)
		value = raw_data(zero)
	}

	ptr, err := runtime.__dynamic_map_set_without_hash(m.data, m.map_info, key, value)
	if err != nil || ptr == nil do return {}
	return node_from(ptr, m.value)
}

// Removes the entry for `key`, its allocations are not freed.
map_remove :: proc(m: Map, key: rawptr) -> bool {
	_, _, ok := runtime.map_erase_dynamic(m.data, m.map_info, uintptr(key))
	return ok
}

// >------------------------------------------------------------------------ Unions

// Switches to variant `index`, -1 for nil, zeroing the union first even when it already
// holds that variant. Fails for an index out of range and for nil on a #no_nil union.
set_variant :: proc(u: Union, index: int) -> (payload: Node, ok: bool) {
	if index < -1 || index >= len(u.variants) || (index == -1 && u.no_nil) do return

	intrinsics.mem_zero(u.data, u.size)
	if index == -1 do return {}, true

	tag := index + (u.no_nil ? 0 : 1)
	store_bits(rawptr(uintptr(u.data) + u.tag_offset), int(u.tag_size), u128(tag))
	return node_from(u.data, u.variants[index]), true
}

// >--------------------------------------------------------------------- Internals

@(private = "file")
zero_elems :: proc(data: rawptr, stride, from, to: int) {
	intrinsics.mem_zero(rawptr(uintptr(data) + uintptr(from * stride)), (to - from) * stride)
}

@(private = "file")
byte_swap :: proc(raw: u128, size: int) -> u128 {
	switch size {
	case 2:
		return u128(intrinsics.byte_swap(u16(raw)))
	case 4:
		return u128(intrinsics.byte_swap(u32(raw)))
	case 8:
		return u128(intrinsics.byte_swap(u64(raw)))
	case 16:
		return intrinsics.byte_swap(raw)
	}

	return raw
}
