package shape

import "base:intrinsics"
import "base:runtime"
import "core:reflect"

// What a node holds, decided by its base type.
Kind :: enum u8 {
	Invalid, // a type shape does not support (pointers, procedures, matrices, ...)
	Struct, // structs and bit_fields, see iterate_fields
	Array, // fixed, enumerated, fixed capacity dynamic and dynamic arrays and slices, see elem
	Map, // see iterate_map
	Bit_Set, // one .Bool element per possible member, see elem and bit_set_elem
	Union, // see variant
	String, // UTF-8 strings and cstrings
	Int,
	Float,
	Bool,
	Rune,
	Enum,
}

// A value seen through reflection. Nodes are made on demand from their parent and never
// stored, so they always reflect the live data and cost nothing to throw away. A node stays
// valid as long as the memory it points into does, resizing an array or inserting into a map
// invalidates the nodes inside it.
Node :: struct {
	// The value, for a value packed into bits (`bits.size != 0`) the integer holding it, so it
	// must go through get_int and friends.
	data:    rawptr,

	// The declared, possibly named, type, use type_info_base for its layout.
	info:    ^runtime.Type_Info,

	// Field name, the enum member name of an enumerated array element or bit set member, or
	// the union's own name for its payload. Empty for other elements and map entries.
	name:    string,
	tag:     reflect.Struct_Tag,

	// Position in the parent: field, element, or map slot index. -1 for a root.
	index:   int,
	kind:    Kind,

	// Signed integer, rune, or enum with a signed base.
	signed:  bool,

	// A map key, changing it in place breaks the map, remove and insert it instead.
	is_key:  bool,

	// Stored in the other byte order, like `u32be` on little endian.
	swapped: bool,
	bits:    Bit_Range,
}

// Where a value packed into an integer lives, a bit_field field or a bit_set member.
Bit_Range :: struct {
	offset:  u8,
	size:    u8, // 0 when the value is not packed
	backing: u8, // size of the holding integer in bytes
}

node_of :: proc(value: ^$T, name := "") -> Node {
	return node_from(value, type_info_of(T), name)
}

node_from :: proc(
	data: rawptr,
	info: ^runtime.Type_Info,
	name := "",
	tag := reflect.Struct_Tag(""),
	index := -1,
) -> Node {
	n := Node {
		data  = data,
		info  = info,
		name  = name,
		tag   = tag,
		index = index,
	}
	n.kind, n.signed, n.swapped = classify(info)
	return n
}

kind_of :: proc(info: ^runtime.Type_Info) -> Kind {
	kind, _, _ := classify(info)
	return kind
}

// Kind, signedness and byte order in one pass, so accessors do not look the type up again.
@(private = "file")
classify :: proc(info: ^runtime.Type_Info) -> (kind: Kind, signed, swapped: bool) {
	#partial switch v in runtime.type_info_base(info).variant {
	case runtime.Type_Info_Struct, runtime.Type_Info_Bit_Field:
		return .Struct, false, false
	case runtime.Type_Info_Array,
	     runtime.Type_Info_Enumerated_Array,
	     runtime.Type_Info_Fixed_Capacity_Dynamic_Array,
	     runtime.Type_Info_Slice,
	     runtime.Type_Info_Dynamic_Array:
		return .Array, false, false
	case runtime.Type_Info_Map:
		return .Map, false, false
	case runtime.Type_Info_Bit_Set:
		return .Bit_Set, false, false
	case runtime.Type_Info_Union:
		// Pointer only unions keep no tag
		return len(v.variants) > 0 && v.tag_type != nil ? .Union : .Invalid, false, false
	case runtime.Type_Info_String:
		return v.encoding == .UTF_8 ? .String : .Invalid, false, false
	case runtime.Type_Info_Integer:
		return .Int, v.signed, is_foreign(v.endianness)
	case runtime.Type_Info_Float:
		return .Float, false, is_foreign(v.endianness)
	case runtime.Type_Info_Boolean:
		return .Bool, false, false
	case runtime.Type_Info_Rune:
		return .Rune, true, false
	case runtime.Type_Info_Enum:
		_, signed, swapped = classify(v.base)
		return .Enum, signed, swapped
	}

	return .Invalid, false, false
}

@(private = "file")
is_foreign :: proc(endianness: runtime.Platform_Endianness) -> bool {
	switch endianness {
	case .Little:
		return ODIN_ENDIAN != .Little
	case .Big:
		return ODIN_ENDIAN != .Big
	case .Platform:
	}

	return false
}

// >---------------------------------------------------------------------- Structs

// Number of fields of a struct or bit_field, skipped ones included.
field_count :: proc(n: Node) -> int {
	#partial switch info in runtime.type_info_base(n.info).variant {
	case runtime.Type_Info_Struct:
		return int(info.field_count)
	case runtime.Type_Info_Bit_Field:
		return info.field_count
	}

	return 0
}

field :: proc(n: Node, i: int) -> Node {
	#partial switch info in runtime.type_info_base(n.info).variant {
	case runtime.Type_Info_Struct:
		if i < 0 || i >= int(info.field_count) do break
		data := rawptr(uintptr(n.data) + info.offsets[i])
		return node_from(data, info.types[i], info.names[i], reflect.Struct_Tag(info.tags[i]), i)

	case runtime.Type_Info_Bit_Field:
		if i < 0 || i >= info.field_count do break
		f := node_from(n.data, info.types[i], info.names[i], reflect.Struct_Tag(info.tags[i]), i)
		f.bits = {u8(info.bit_offsets[i]), u8(info.bit_sizes[i]), u8(n.info.size)}
		return f
	}

	return {}
}

// Fields in declaration order, without the ones tagged `shape:"skip"`.
//
//	it := 0
//	for f in shape.iterate_fields(n, &it) {...}
iterate_fields :: proc(n: Node, it: ^int) -> (f: Node, ok: bool) {
	for {
		// field gives a node without a type past the last field
		f = field(n, it^)
		if f.info == nil do return {}, false
		it^ += 1

		// Most fields have no tag, skip parsing those
		if len(f.tag) == 0 || reflect.struct_tag_get(f.tag, "shape") != "skip" do return f, true
	}
}

// >----------------------------------------------------------------------- Arrays

// Elements of an array, entries of a map, or possible members of a bit set.
length :: proc(n: Node) -> int {
	#partial switch info in runtime.type_info_base(n.info).variant {
	case runtime.Type_Info_Array:
		return info.count
	case runtime.Type_Info_Enumerated_Array:
		return info.count
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		return (^int)(uintptr(n.data) + info.len_offset)^
	case runtime.Type_Info_Slice:
		return (^runtime.Raw_Slice)(n.data).len
	case runtime.Type_Info_Dynamic_Array:
		return (^runtime.Raw_Dynamic_Array)(n.data).len
	case runtime.Type_Info_Map:
		return runtime.map_len((^runtime.Raw_Map)(n.data)^)
	case runtime.Type_Info_Bit_Set:
		return int(info.upper - info.lower + 1)
	}

	return 0
}

// Element `i` of an array, or a .Bool for whether member `i` of a bit set is in it. Out of
// range gives an .Invalid node.
elem :: proc(n: Node, i: int) -> Node {
	if i < 0 do return {}

	#partial switch info in runtime.type_info_base(n.info).variant {
	case runtime.Type_Info_Array:
		if i >= info.count do break
		return node_from(
			rawptr(uintptr(n.data) + uintptr(i * info.elem_size)),
			info.elem,
			index = i,
		)

	case runtime.Type_Info_Enumerated_Array:
		if i >= info.count do break
		e := node_from(rawptr(uintptr(n.data) + uintptr(i * info.elem_size)), info.elem, index = i)
		e.name, _ = enum_name(info.index, i128(info.min_value) + i128(i))
		return e

	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		if i >= (^int)(uintptr(n.data) + info.len_offset)^ do break
		return node_from(
			rawptr(uintptr(n.data) + uintptr(i * info.elem_size)),
			info.elem,
			index = i,
		)

	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(n.data)
		if i >= raw.len do break
		return node_from(
			rawptr(uintptr(raw.data) + uintptr(i * info.elem_size)),
			info.elem,
			index = i,
		)

	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(n.data)
		if i >= raw.len do break
		return node_from(
			rawptr(uintptr(raw.data) + uintptr(i * info.elem_size)),
			info.elem,
			index = i,
		)

	case runtime.Type_Info_Bit_Set:
		if i > int(info.upper - info.lower) do break
		e := node_from(n.data, type_info_of(bool), index = i)
		e.bits = {u8(i), 1, u8(n.info.size)}
		e.name, _ = enum_name(info.elem, i128(info.lower) + i128(i))
		return e
	}

	return {}
}

// Element type of a bit set and the value of its member 0.
bit_set_elem :: proc(n: Node) -> (elem: ^runtime.Type_Info, lower: i128) {
	info, ok := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Bit_Set)
	if !ok do return
	return info.elem, i128(info.lower)
}

// Whether resize, insert_elem and remove_elem work on it.
is_resizable :: proc(n: Node) -> bool {
	#partial switch _ in runtime.type_info_base(n.info).variant {
	case runtime.Type_Info_Slice,
	     runtime.Type_Info_Dynamic_Array,
	     runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		return true
	}

	return false
}

// >------------------------------------------------------------------------- Maps

// Entries in storage order, `index` on both nodes is the entry's slot.
//
//	it := 0
//	for key, value in shape.iterate_map(n, &it) {...}
iterate_map :: proc(n: Node, it: ^int) -> (key, value: Node, ok: bool) {
	info := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Map) or_return
	raw := (^runtime.Raw_Map)(n.data)
	ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw^, info.map_info)

	for it^ < int(runtime.map_cap(raw^)) {
		slot := it^
		it^ += 1
		if !runtime.map_hash_is_valid(hs[slot]) do continue

		k := runtime.map_cell_index_dynamic(ks, info.map_info.ks, uintptr(slot))
		v := runtime.map_cell_index_dynamic(vs, info.map_info.vs, uintptr(slot))

		key = node_from(rawptr(k), info.key, index = slot)
		key.is_key = true
		return key, node_from(rawptr(v), info.value, index = slot), true
	}

	return
}

// >----------------------------------------------------------------------- Unions

variant_count :: proc(n: Node) -> int {
	info, ok := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Union)
	return ok ? len(info.variants) : 0
}

variant_type :: proc(n: Node, i: int) -> ^runtime.Type_Info {
	info, ok := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Union)
	if !ok || i < 0 || i >= len(info.variants) do return nil
	return info.variants[i]
}

// Whether the union can be nil, false for #no_nil.
allows_nil :: proc(n: Node) -> bool {
	info, ok := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Union)
	return ok && !info.no_nil
}

// Name a variant goes by, the declared name for named types, otherwise the type as written
// (`int`, `[]string`), which is written into `buffer`.
variant_name :: proc(n: Node, i: int, buffer: []byte) -> string {
	ti := variant_type(n, i)
	if ti == nil do return ""
	if named, ok := ti.variant.(runtime.Type_Info_Named); ok do return named.name

	written := 0
	_ = runtime.write_typeid(&written, buffer, ti.id)
	return string(buffer[:written])
}

// The active variant and its payload, -1 and an .Invalid node for nil.
variant :: proc(n: Node) -> (index: int, payload: Node) {
	info, ok := runtime.type_info_base(n.info).variant.(runtime.Type_Info_Union)
	if !ok || n.kind != .Union do return -1, {}

	tag := load_bits(rawptr(uintptr(n.data) + info.tag_offset), info.tag_type.size)
	index = int(tag) - (info.no_nil ? 0 : 1)
	if index < 0 do return -1, {}

	return index, node_from(n.data, info.variants[index], n.name, n.tag, n.index)
}

// >-------------------------------------------------------------------- Internals

@(private)
load_bits :: proc(data: rawptr, size: int) -> u128 {
	switch size {
	case 1:
		return u128((^u8)(data)^)
	case 2:
		return u128((^u16)(data)^)
	case 4:
		return u128((^u32)(data)^)
	case 8:
		return u128((^u64)(data)^)
	case 16:
		return (^u128)(data)^
	}

	return 0
}

@(private)
store_bits :: proc(data: rawptr, size: int, bits: u128) {
	switch size {
	case 1:
		(^u8)(data)^ = u8(bits)
	case 2:
		(^u16)(data)^ = u16(bits)
	case 4:
		(^u32)(data)^ = u32(bits)
	case 8:
		(^u64)(data)^ = u64(bits)
	case 16:
		(^u128)(data)^ = bits
	}
}

@(private)
bit_mask :: proc(size: u128) -> u128 {
	return size >= 128 ? ~u128(0) : (1 << size) - 1
}

// The low `size` bits of `raw` as a value, sign extended from the top one when `signed`.
@(private)
extend :: proc(raw: u128, size: u128, signed: bool) -> i128 {
	if !signed || size >= 128 do return i128(raw)

	shift := 128 - size
	return i128(raw << shift) >> shift
}

@(private)
count_ones :: proc(bits: u128) -> int {return int(intrinsics.count_ones(bits))}

@(private)
lowest_one :: proc(bits: u128) -> int {return int(intrinsics.count_trailing_zeros(bits))}
