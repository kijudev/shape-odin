package shape

import "base:intrinsics"
import "base:runtime"
import "core:reflect"

// A value seen through reflection. Nodes are made on demand from their parent and never
// stored, so they always reflect the live data and cost nothing to throw away. A node stays
// valid as long as the memory it points into does, resizing an array or inserting into a map
// invalidates the nodes inside it.
//
//	switch v in n.value {
//	case shape.Int:    shape.set_int(v, 42)
//	case shape.Struct: for f in shape.iterate_fields(v, &it) {...}
//	}
Node :: struct {
	// What the value is, nil for types shape does not support (pointers, procedures,
	// matrices, ...).
	value:  Value,

	// The value's memory, for a value packed into bits the integer holding it.
	data:   rawptr,

	// The declared, possibly named, type.
	info:   ^runtime.Type_Info,

	// Field name, or the enum member name of an enumerated array element or bit set member.
	// Empty for other elements and map entries.
	name:   string,
	tag:    reflect.Struct_Tag,

	// Position in the parent: field, element, or map slot index. -1 for a root.
	index:  int,

	// A map key, changing it in place breaks the map, remove and insert it instead.
	is_key: bool,
}

Value :: union {
	Struct,
	Array,
	Map,
	Bit_Set,
	Union,
	String,
	Int,
	Float,
	Bool,
	Rune,
	Enum,
}

// A struct or a bit_field, see iterate_fields.
Struct :: struct {
	data:   rawptr,
	info:   ^runtime.Type_Info,
	count:  int,
	packed: bool, // a bit_field
}

Array :: struct {
	data:   rawptr,
	elem:   ^runtime.Type_Info,
	stride: int,
	count:  int,
	info:   ^runtime.Type_Info,
	layout: Array_Layout,
}

Array_Layout :: enum u8 {
	Fixed,
	Enumerated,
	Fixed_Capacity,
	Slice,
	Dynamic,
}

Map :: struct {
	data:     ^runtime.Raw_Map,
	key:      ^runtime.Type_Info,
	value:    ^runtime.Type_Info,
	map_info: ^runtime.Map_Info,
}

Bit_Set :: struct {
	data:  rawptr,
	elem:  ^runtime.Type_Info,
	lower: i64,
	count: int,
	size:  u8,
}

Union :: struct {
	data:       rawptr,
	variants:   []^runtime.Type_Info,
	tag_offset: uintptr,
	size:       int,
	tag_size:   u8,
	no_nil:     bool,
}

String :: struct {
	data:       rawptr,
	is_cstring: bool,
}

Int :: struct {
	data:    rawptr,
	size:    u8,
	signed:  bool,
	swapped: bool,
	bits:    Bit_Range,
}

Bool :: distinct Int
Rune :: distinct Int

Enum :: struct {
	using integer: Int,
	info:          ^runtime.Type_Info_Enum,
}

Float :: struct {
	data:    rawptr,
	size:    u8,
	swapped: bool,
}

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
	return {
		value = value_of(data, info),
		data = data,
		info = info,
		name = name,
		tag = tag,
		index = index,
	}
}

// Resolves the type once, so the accessors work from the variant alone.
value_of :: proc(data: rawptr, info: ^runtime.Type_Info) -> Value {
	base := runtime.type_info_base(info)

	#partial switch &v in base.variant {
	case runtime.Type_Info_Struct:
		return Struct{data, base, int(v.field_count), false}
	case runtime.Type_Info_Bit_Field:
		return Struct{data, base, v.field_count, true}

	case runtime.Type_Info_Array:
		return Array{data, v.elem, v.elem_size, v.count, base, .Fixed}
	case runtime.Type_Info_Enumerated_Array:
		return Array{data, v.elem, v.elem_size, v.count, base, .Enumerated}
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		return Array{data, v.elem, v.elem_size, v.capacity, base, .Fixed_Capacity}
	case runtime.Type_Info_Slice:
		return Array{data, v.elem, v.elem_size, 0, base, .Slice}
	case runtime.Type_Info_Dynamic_Array:
		return Array{data, v.elem, v.elem_size, 0, base, .Dynamic}

	case runtime.Type_Info_Map:
		return Map{(^runtime.Raw_Map)(data), v.key, v.value, v.map_info}

	case runtime.Type_Info_Bit_Set:
		return Bit_Set{data, v.elem, v.lower, int(v.upper - v.lower + 1), u8(base.size)}

	case runtime.Type_Info_Union:
		// Pointer only unions keep no tag
		if len(v.variants) == 0 || v.tag_type == nil do break
		return Union{data, v.variants, v.tag_offset, base.size, u8(v.tag_type.size), v.no_nil}

	case runtime.Type_Info_String:
		if v.encoding != .UTF_8 do break
		return String{data, v.is_cstring}

	case runtime.Type_Info_Integer:
		return Int {
			data = data,
			size = u8(base.size),
			signed = v.signed,
			swapped = is_foreign(v.endianness),
		}
	case runtime.Type_Info_Float:
		return Float{data, u8(base.size), is_foreign(v.endianness)}
	case runtime.Type_Info_Boolean:
		return Bool{data = data, size = u8(base.size)}
	case runtime.Type_Info_Rune:
		return Rune{data = data, size = 4, signed = true}
	case runtime.Type_Info_Enum:
		backing, _ := value_of(data, v.base).(Int)
		return Enum{backing, &v}
	}

	return nil
}

// >-------------------------------------------------------------------- Structs

// Field `i` in declaration order, skipped ones included. Out of range gives a nil value.
field :: proc(s: Struct, i: int) -> Node {
	if i < 0 || i >= s.count do return {}

	if s.packed {
		info := &s.info.variant.(runtime.Type_Info_Bit_Field)
		f := node_from(s.data, info.types[i], info.names[i], reflect.Struct_Tag(info.tags[i]), i)
		pack(&f.value, {u8(info.bit_offsets[i]), u8(info.bit_sizes[i]), u8(s.info.size)})
		return f
	}

	info := &s.info.variant.(runtime.Type_Info_Struct)
	data := rawptr(uintptr(s.data) + info.offsets[i])
	return node_from(data, info.types[i], info.names[i], reflect.Struct_Tag(info.tags[i]), i)
}

// Fields in declaration order, without the ones tagged `shape:"skip"`.
//
//	it := 0
//	for f in shape.iterate_fields(s, &it) {...}
iterate_fields :: proc(s: Struct, it: ^int) -> (f: Node, ok: bool) {
	for it^ < s.count {
		f = field(s, it^)
		it^ += 1

		// Most fields have no tag, skip parsing those.
		if len(f.tag) == 0 || reflect.struct_tag_get(f.tag, "shape") != "skip" do return f, true
	}

	return {}, false
}

// >--------------------------------------------------------------------- Arrays

length :: proc {
	array_length,
	map_length,
	bit_set_length,
}

array_length :: proc(a: Array) -> int {
	switch a.layout {
	case .Fixed, .Enumerated:
		return a.count
	case .Fixed_Capacity:
		return fixed_capacity_len(a)^
	case .Slice:
		return (^runtime.Raw_Slice)(a.data).len
	case .Dynamic:
		return (^runtime.Raw_Dynamic_Array)(a.data).len
	}

	return 0
}

// Element `i`, out of range gives a nil value.
elem :: proc(a: Array, i: int) -> Node {
	if i < 0 || i >= array_length(a) do return {}

	e := node_from(rawptr(uintptr(elems(a)) + uintptr(i * a.stride)), a.elem, index = i)
	if a.layout == .Enumerated do e.name = enumerated_name(a, i)
	return e
}

Elem_Iterator :: struct {
	node:  Node,
	index: int,
}

// Elements in order. Faster than elem over a whole array, the element type is resolved once
// and every next element only moves the data.
//
//	it: shape.Elem_Iterator
//	for e in shape.iterate_elems(a, &it) {...}
iterate_elems :: proc(a: Array, it: ^Elem_Iterator) -> (e: Node, ok: bool) {
	i := it.index
	if i >= array_length(a) do return
	it.index += 1

	if i == 0 {
		it.node = elem(a, 0)
		return it.node, true
	}

	rebase(&it.node, rawptr(uintptr(elems(a)) + uintptr(i * a.stride)))
	it.node.index = i
	if a.layout == .Enumerated do it.node.name = enumerated_name(a, i)
	return it.node, true
}

// Whether resize, insert_elem and remove_elem work on it.
is_resizable :: proc(a: Array) -> bool {
	return a.layout == .Slice || a.layout == .Dynamic || a.layout == .Fixed_Capacity
}

// >--------------------------------------------------------------------- Bit sets

bit_set_length :: proc(b: Bit_Set) -> int {return b.count}

// Whether member `i` (the value `b.lower + i`) is in the set, as a Bool node named after the
// enum member. Out of range gives a nil value.
member :: proc(b: Bit_Set, i: int) -> Node {
	if i < 0 || i >= b.count do return {}

	name, _ := enum_name_of(b.elem, i128(b.lower) + i128(i))
	return {
		value = Bool{data = b.data, size = 1, bits = {u8(i), 1, b.size}},
		data = b.data,
		info = type_info_of(bool),
		name = name,
		index = i,
	}
}

// >------------------------------------------------------------------------- Maps

map_length :: proc(m: Map) -> int {return runtime.map_len(m.data^)}

// Entries in storage order, `index` on both nodes is the entry's slot.
//
//	it := 0
//	for key, value in shape.iterate_map(m, &it) {...}
iterate_map :: proc(m: Map, it: ^int) -> (key, value: Node, ok: bool) {
	ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(m.data^, m.map_info)

	for it^ < int(runtime.map_cap(m.data^)) {
		slot := it^
		it^ += 1
		if !runtime.map_hash_is_valid(hs[slot]) do continue

		k := runtime.map_cell_index_dynamic(ks, m.map_info.ks, uintptr(slot))
		v := runtime.map_cell_index_dynamic(vs, m.map_info.vs, uintptr(slot))

		key = node_from(rawptr(k), m.key, index = slot)
		key.is_key = true
		return key, node_from(rawptr(v), m.value, index = slot), true
	}

	return
}

// The value stored for `key`, which points at a value of the key type.
map_find :: proc(m: Map, key: rawptr) -> (value: Node, ok: bool) {
	slot := runtime.map_lookup_dynamic(m.data^, m.map_info, uintptr(key)) or_return
	_, vs, _, _, _ := runtime.map_kvh_data_dynamic(m.data^, m.map_info)
	v := runtime.map_cell_index_dynamic(vs, m.map_info.vs, slot)
	return node_from(rawptr(v), m.value, index = int(slot)), true
}

// >----------------------------------------------------------------------- Unions

// The active variant and its payload, -1 and a nil value for nil.
variant :: proc(u: Union) -> (index: int, payload: Node) {
	tag := load_bits(rawptr(uintptr(u.data) + u.tag_offset), int(u.tag_size))
	index = int(tag) - (u.no_nil ? 0 : 1)
	if index < 0 || index >= len(u.variants) do return -1, {}

	return index, node_from(u.data, u.variants[index])
}

// Name a variant goes by, the declared name for named types, otherwise the type as written
// (`int`, `[]string`), which is written into `buffer`.
variant_name :: proc(u: Union, i: int, buffer: []byte) -> string {
	if i < 0 || i >= len(u.variants) do return ""

	ti := u.variants[i]
	if named, ok := ti.variant.(runtime.Type_Info_Named); ok do return named.name

	written := 0
	_ = runtime.write_typeid(&written, buffer, ti.id)
	return string(buffer[:written])
}

// >-------------------------------------------------------------------- Internals

@(private)
elems :: proc(a: Array) -> rawptr {
	switch a.layout {
	case .Fixed, .Enumerated, .Fixed_Capacity:
		return a.data
	case .Slice:
		return (^runtime.Raw_Slice)(a.data).data
	case .Dynamic:
		return (^runtime.Raw_Dynamic_Array)(a.data).data
	}

	return nil
}

@(private = "file")
enumerated_name :: proc(a: Array, i: int) -> string {
	info := &a.info.variant.(runtime.Type_Info_Enumerated_Array)
	name, _ := enum_name_of(info.index, i128(info.min_value) + i128(i))
	return name
}

// Points a node at another value of the same type.
@(private = "file")
rebase :: proc(n: ^Node, data: rawptr) {
	n.data = data

	switch &v in n.value {
	case Struct:
		v.data = data
	case Array:
		v.data = data
	case Map:
		v.data = (^runtime.Raw_Map)(data)
	case Bit_Set:
		v.data = data
	case Union:
		v.data = data
	case String:
		v.data = data
	case Int:
		v.data = data
	case Float:
		v.data = data
	case Bool:
		v.data = data
	case Rune:
		v.data = data
	case Enum:
		v.data = data
	}
}

@(private)
fixed_capacity_len :: proc(a: Array) -> ^int {
	info := &a.info.variant.(runtime.Type_Info_Fixed_Capacity_Dynamic_Array)
	return (^int)(uintptr(a.data) + info.len_offset)
}

@(private)
enum_name_of :: proc(info: ^runtime.Type_Info, value: i128) -> (name: string, ok: bool) {
	e := runtime.type_info_base(info).variant.(runtime.Type_Info_Enum) or_return

	for v, i in e.values {
		if i128(v) == value do return e.names[i], true
	}

	return
}

// Marks an integer like value as living in `bits` of its data.
@(private = "file")
pack :: proc(value: ^Value, bits: Bit_Range) {
	#partial switch &v in value {
	case Int:
		v.bits = bits
	case Bool:
		v.bits = bits
	case Rune:
		v.bits = bits
	case Enum:
		v.bits = bits
	}
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
lowest_one :: proc(bits: u128) -> int {return int(intrinsics.count_trailing_zeros(bits))}

@(private)
count_ones :: proc(bits: u128) -> int {return int(intrinsics.count_ones(bits))}
