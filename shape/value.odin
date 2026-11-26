package shape

import "base:intrinsics"
import "base:runtime"

// >----------------------------------------------------------------------- Scalars

// Value of an .Int, .Enum, .Bool or .Rune node, packed or not. Unsigned 128 bit values above
// the i128 range come back wrapped, `n.signed` tells how to read them.
get_int :: proc(n: Node) -> i128 {
	signed := n.signed

	// Plain integers stay in 64 bit math, this is the hot path of every serialized integer
	if n.bits.size == 0 && !n.swapped && n.info.size <= 8 {
		raw := u64(load_bits(n.data, n.info.size))
		shift := u64(64 - n.info.size * 8)
		return signed ? i128(i64(raw << shift) >> shift) : i128(raw)
	}

	if n.bits.size != 0 {
		raw := load_bits(n.data, int(n.bits.backing)) >> n.bits.offset
		size := u128(n.bits.size)
		return extend(raw & bit_mask(size), size, signed)
	}

	raw := load_bits(n.data, n.info.size)
	if n.swapped do raw = byte_swap(raw, n.info.size)
	return extend(raw, u128(n.info.size * 8), signed)
}

// Stores `value` if it fits the node's type, and its bits when packed.
set_int :: proc(n: Node, value: i128) -> bool {
	signed := n.signed

	// Plain integers stay in 64 bit math, this is the hot path of every parsed integer
	if n.bits.size == 0 && !n.swapped && n.info.size <= 8 {
		shift := u64(64 - n.info.size * 8)
		raw: u64

		if signed {
			if value < i128(min(i64)) || value > i128(max(i64)) do return false
			raw = u64(i64(value))
			if i64(raw << shift) >> shift != i64(value) do return false
		} else {
			if value < 0 || value > i128(max(u64)) do return false
			raw = u64(value)
			if (raw << shift) >> shift != raw do return false
		}

		store_bits(n.data, n.info.size, u128(raw))
		return true
	}
	size := n.bits.size != 0 ? u128(n.bits.size) : u128(n.info.size * 8)
	mask := bit_mask(size)

	// It fits when cutting it down to its bits and back is lossless
	raw := u128(value) & mask
	if extend(raw, size, signed) != value do return false

	if n.bits.size != 0 {
		backing := load_bits(n.data, int(n.bits.backing))
		offset := u128(n.bits.offset)
		store_bits(n.data, int(n.bits.backing), (backing & ~(mask << offset)) | (raw << offset))
		return true
	}

	if n.swapped do raw = byte_swap(raw, n.info.size)
	store_bits(n.data, n.info.size, raw)
	return true
}

get_bool :: proc(n: Node) -> bool {return get_int(n) != 0}

set_bool :: proc(n: Node, value: bool) {set_int(n, value ? 1 : 0)}

get_float :: proc(n: Node) -> f64 {
	raw := load_bits(n.data, n.info.size)
	if n.swapped do raw = byte_swap(raw, n.info.size)

	switch n.info.size {
	case 2:
		return f64(transmute(f16)u16(raw))
	case 4:
		return f64(transmute(f32)u32(raw))
	case 8:
		return transmute(f64)u64(raw)
	}

	return 0
}

set_float :: proc(n: Node, value: f64) {
	raw: u128

	switch n.info.size {
	case 2:
		raw = u128(transmute(u16)f16(value))
	case 4:
		raw = u128(transmute(u32)f32(value))
	case 8:
		raw = u128(transmute(u64)value)
	}

	if n.swapped do raw = byte_swap(raw, n.info.size)
	store_bits(n.data, n.info.size, raw)
}

enum_name :: proc(info: ^runtime.Type_Info, value: i128) -> (name: string, ok: bool) {
	e := runtime.type_info_base(info).variant.(runtime.Type_Info_Enum) or_return

	for v, i in e.values {
		if i128(v) == value do return e.names[i], true
	}

	return
}

enum_value :: proc(info: ^runtime.Type_Info, name: string) -> (value: i128, ok: bool) {
	e := runtime.type_info_base(info).variant.(runtime.Type_Info_Enum) or_return

	for member, i in e.names {
		if member == name do return i128(e.values[i]), true
	}

	return
}

// >----------------------------------------------------------------------- Strings

get_string :: proc(n: Node) -> string {
	info, ok := runtime.type_info_base(n.info).variant.(runtime.Type_Info_String)
	if !ok do return ""
	return info.is_cstring ? string((^cstring)(n.data)^) : (^string)(n.data)^
}

// Points the string at `length` fresh bytes and returns them for the caller to fill, a
// cstring gets an extra zeroed terminator. The previous contents are not freed.
alloc_string :: proc(n: Node, length: int, allocator := context.allocator) -> []byte {
	info, ok := runtime.type_info_base(n.info).variant.(runtime.Type_Info_String)
	if !ok do return nil

	if info.is_cstring {
		mem, _ := runtime.mem_alloc(length + 1, 1, allocator)
		(^cstring)(n.data)^ = cstring(raw_data(mem))
		return mem[:length]
	}

	mem, _ := runtime.mem_alloc(length, 1, allocator)
	(^string)(n.data)^ = string(mem)
	return mem
}

set_string :: proc(n: Node, s: string, allocator := context.allocator) {
	copy(alloc_string(n, len(s), allocator), s)
}

// >------------------------------------------------------------------------ Arrays

// Changes the length of a resizable array, kept elements stay and new ones are zeroed. A
// growing slice moves to a fresh allocation without freeing the old one, a dynamic array
// without an allocator takes `allocator`.
resize :: proc(n: Node, count: int, allocator := context.allocator) -> bool {
	if count < 0 do return false
	elem, size := array_elem(n.info)

	#partial switch info in runtime.type_info_base(n.info).variant {
	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(n.data)

		if count > raw.len {
			mem, err := runtime.mem_alloc(count * size, elem.align, allocator)
			if err != nil do return false
			intrinsics.mem_copy_non_overlapping(raw_data(mem), raw.data, raw.len * size)
			raw.data = raw_data(mem)
		}

		raw.len = count

	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(n.data)
		old := raw.len
		if raw.allocator.procedure == nil do raw.allocator = allocator

		if !runtime.__dynamic_array_resize(raw, size, elem.align, count) do return false
		if count > old do intrinsics.mem_zero(rawptr(uintptr(raw.data) + uintptr(old * size)), (count - old) * size)

	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		if count > info.capacity do return false

		len_ptr := (^int)(uintptr(n.data) + info.len_offset)
		if count > len_ptr^ do intrinsics.mem_zero(rawptr(uintptr(n.data) + uintptr(len_ptr^ * size)), (count - len_ptr^) * size)
		len_ptr^ = count

	case:
		return false
	}

	return true
}

// Inserts a zeroed element at `i`, `i == length(n)` appends.
insert_elem :: proc(n: Node, i: int, allocator := context.allocator) -> bool {
	count := length(n)
	if i < 0 || i > count || !resize(n, count + 1, allocator) do return false

	_, size := array_elem(n.info)
	at := elem(n, i).data
	intrinsics.mem_copy(rawptr(uintptr(at) + uintptr(size)), at, (count - i) * size)
	intrinsics.mem_zero(at, size)
	return true
}

// Removes element `i` keeping the order, the element's own allocations are not freed.
remove_elem :: proc(n: Node, i: int) -> bool {
	count := length(n)
	if i < 0 || i >= count || !is_resizable(n) do return false

	_, size := array_elem(n.info)
	at := elem(n, i).data
	intrinsics.mem_copy(at, rawptr(uintptr(at) + uintptr(size)), (count - i - 1) * size)
	return resize(n, count - 1)
}

// >-------------------------------------------------------------------------- Maps

// Makes room for `count` entries, a map without an allocator takes `allocator`.
map_reserve :: proc(n: Node, count: int, allocator := context.allocator) -> bool {
	info := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Map) or_return
	raw := (^runtime.Raw_Map)(n.data)
	if raw.allocator.procedure == nil do raw.allocator = allocator

	return runtime.map_reserve_dynamic(raw, info.map_info, uintptr(count)) == nil
}

// Inserts or overwrites the entry for `key`, copying the key and the value from where they
// point, a nil `value` stores a zero value. Returns the stored value, an .Invalid node on
// failure.
map_insert :: proc(n: Node, key: rawptr, value: rawptr, allocator := context.allocator) -> Node {
	info, ok := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Map)
	if !ok do return {}
	raw := (^runtime.Raw_Map)(n.data)
	if raw.allocator.procedure == nil do raw.allocator = allocator

	value := value
	if value == nil {
		zero, err := runtime.mem_alloc(info.value.size, info.value.align, allocator)
		if err != nil do return {}
		defer runtime.mem_free(raw_data(zero), allocator)
		value = raw_data(zero)
	}

	ptr, err := runtime.__dynamic_map_set_without_hash(raw, info.map_info, key, value)
	if err != nil || ptr == nil do return {}
	return node_from(ptr, info.value)
}

// The value stored for `key`.
map_find :: proc(n: Node, key: rawptr) -> (value: Node, ok: bool) {
	info := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Map) or_return
	raw := (^runtime.Raw_Map)(n.data)

	slot := runtime.map_lookup_dynamic(raw^, info.map_info, uintptr(key)) or_return
	_, vs, _, _, _ := runtime.map_kvh_data_dynamic(raw^, info.map_info)
	v := runtime.map_cell_index_dynamic(vs, info.map_info.vs, slot)
	return node_from(rawptr(v), info.value, index = int(slot)), true
}

// Removes the entry for `key`, its allocations are not freed.
map_remove :: proc(n: Node, key: rawptr) -> bool {
	info := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Map) or_return
	_, _, ok := runtime.map_erase_dynamic((^runtime.Raw_Map)(n.data), info.map_info, uintptr(key))
	return ok
}

// >------------------------------------------------------------------------ Unions

// Switches to variant `index`, -1 for nil, zeroing the union first even when it already
// holds that variant. Fails for an index out of range and for nil on a #no_nil union.
set_variant :: proc(n: Node, index: int) -> (payload: Node, ok: bool) {
	info := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Union) or_return
	if n.kind != .Union || index < -1 || index >= len(info.variants) do return
	if index == -1 && info.no_nil do return

	intrinsics.mem_zero(n.data, n.info.size)
	if index == -1 do return {}, true

	first_tag := info.no_nil ? 0 : 1
	set_union_tag(n, i64(index + first_tag))
	return node_from(n.data, info.variants[index], n.name, n.tag, n.index), true
}

// >--------------------------------------------------------------------- Internals

@(private = "file")
set_union_tag :: proc(n: Node, tag: i64) {
	info := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Union)
	store_bits(rawptr(uintptr(n.data) + info.tag_offset), info.tag_type.size, u128(tag))
}

@(private = "file")
array_elem :: proc(info: ^runtime.Type_Info) -> (elem: ^runtime.Type_Info, size: int) {
	#partial switch v in runtime.type_info_base(info).variant {
	case runtime.Type_Info_Array:
		return v.elem, v.elem_size
	case runtime.Type_Info_Enumerated_Array:
		return v.elem, v.elem_size
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		return v.elem, v.elem_size
	case runtime.Type_Info_Slice:
		return v.elem, v.elem_size
	case runtime.Type_Info_Dynamic_Array:
		return v.elem, v.elem_size
	}

	return
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
