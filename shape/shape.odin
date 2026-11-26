package shape

import "base:intrinsics"
import "base:runtime"
import "core:reflect"

Visitor_Mode :: enum {
	Read,
	Write,
	Inspect,
}

Visitor :: struct {
	// Config
	mode:         Visitor_Mode,
	version:      u32,
	allocator:    runtime.Allocator,

	// Set by walk while visiting a map key or value, the first action to see it should clear it.
	map_key:      bool,
	map_value:    bool,

	// Actions, `count` is filled by walk, in .Read mode the visitor replaces it with the
	// length found in the source and walk allocates the container. `info` is the declared (possibly named) type, use type_info_base for its layout.
	struct_begin: proc(v: ^Visitor, name: string, info: ^runtime.Type_Info) -> bool,
	struct_end:   proc(v: ^Visitor),
	array_begin:  proc(
		v: ^Visitor,
		name: string,
		info: ^runtime.Type_Info,
		elem: ^runtime.Type_Info,
		count: ^int,
	) -> bool,
	array_end:    proc(v: ^Visitor),
	map_begin:    proc(
		v: ^Visitor,
		name: string,
		info: ^runtime.Type_Info,
		key: ^runtime.Type_Info,
		value: ^runtime.Type_Info,
		count: ^int,
	) -> bool,
	map_end:      proc(v: ^Visitor),

	// UTF-8 strings and cstrings, `bytes` is the content to emit, or in .Read mode the
	// freshly allocated `count` bytes to fill.
	string_begin: proc(v: ^Visitor, name: string, info: ^runtime.Type_Info, count: ^int) -> bool,
	string_end:   proc(v: ^Visitor, bytes: []byte),
	primitive:    proc(
		v: ^Visitor,
		name: string,
		data: rawptr,
		info: ^runtime.Type_Info,
		tag: reflect.Struct_Tag,
	),

	// Unions, `variant` is an index into the union's variants or -1 for nil, in .Read mode the
	// visitor replaces it with the one found in the source. walk then visits the payload under
	// the variant's name (see union_variant_name). A nil union is handled entirely by
	// union_begin, which returns false so neither the payload nor union_end are visited.
	union_begin:  proc(v: ^Visitor, name: string, info: ^runtime.Type_Info, variant: ^int) -> bool,
	union_end:    proc(v: ^Visitor),

	// Optional, called in .Read mode when a parsed value does not fit where walk stores it, a
	// bit_set element outside the set's range or a bit_field value wider than its bits.
	invalid:      proc(v: ^Visitor, name: string, info: ^runtime.Type_Info),

	// Escape hatch.
	overrides:    map[typeid]proc(v: ^Visitor, name: string, data: rawptr),
}

walk :: proc(v: ^Visitor, name: string, data: rawptr, tid: typeid, tag: reflect.Struct_Tag = "") {
	if procedure, ok := v.overrides[tid]; ok {
		procedure(v, name, data)
		return
	}

	ti := type_info_of(tid)
	tib := runtime.type_info_base(ti)

	#partial switch info in tib.variant {
	case runtime.Type_Info_Struct:
		if !v.struct_begin(v, name, ti) do return

		for i in 0 ..< int(info.field_count) {
			field_tag := reflect.Struct_Tag(info.tags[i])
			if reflect.struct_tag_get(field_tag, "shape") == "skip" do continue

			walk(
				v,
				info.names[i],
				rawptr(uintptr(data) + info.offsets[i]),
				info.types[i].id,
				field_tag,
			)
		}

		v.struct_end(v)

	case runtime.Type_Info_Array:
		count := info.count
		if !v.array_begin(v, name, ti, info.elem, &count) do return

		for i in 0 ..< info.count {
			walk(v, "", rawptr(uintptr(data) + uintptr(i * info.elem_size)), info.elem.id)
		}

		v.array_end(v)

	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(data)
		count := raw.len
		if !v.array_begin(v, name, ti, info.elem, &count) do return

		if v.mode == .Read {
			raw.data = alloc_elems(v, info.elem, info.elem_size, count)
			raw.len = count
		}

		for i in 0 ..< raw.len {
			walk(v, "", rawptr(uintptr(raw.data) + uintptr(i * info.elem_size)), info.elem.id)
		}

		v.array_end(v)

	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(data)
		count := raw.len
		if !v.array_begin(v, name, ti, info.elem, &count) do return

		if v.mode == .Read {
			raw.data = alloc_elems(v, info.elem, info.elem_size, count)
			raw.len = count
			raw.cap = count
			raw.allocator = v.allocator
		}

		for i in 0 ..< raw.len {
			walk(v, "", rawptr(uintptr(raw.data) + uintptr(i * info.elem_size)), info.elem.id)
		}

		v.array_end(v)

	case runtime.Type_Info_Map:
		raw := (^runtime.Raw_Map)(data)
		count := runtime.map_len(raw^)
		if !v.map_begin(v, name, ti, info.key, info.value, &count) do return

		if v.mode == .Read {
			raw.allocator = v.allocator
			_ = runtime.map_reserve_dynamic(raw, info.map_info, uintptr(count))

			key, _ := runtime.mem_alloc(info.key.size, info.key.align, v.allocator)
			value, _ := runtime.mem_alloc(info.value.size, info.value.align, v.allocator)
			defer runtime.mem_free(raw_data(key), v.allocator)
			defer runtime.mem_free(raw_data(value), v.allocator)

			for _ in 0 ..< count {
				runtime.mem_zero(raw_data(key), len(key))
				runtime.mem_zero(raw_data(value), len(value))

				v.map_key = true
				walk(v, "", raw_data(key), info.key.id)
				v.map_key = false
				v.map_value = true
				walk(v, "", raw_data(value), info.value.id)
				v.map_value = false

				runtime.__dynamic_map_set_without_hash(
					raw,
					info.map_info,
					raw_data(key),
					raw_data(value),
				)
			}
		} else {
			it := 0
			for key, value in reflect.iterate_map(any{data, tid}, &it) {
				v.map_key = true
				walk(v, "", key.data, key.id)
				v.map_key = false
				v.map_value = true
				walk(v, "", value.data, value.id)
				v.map_value = false
			}
		}

		v.map_end(v)

	case runtime.Type_Info_String:
		if info.encoding != .UTF_8 {
			v.primitive(v, name, data, ti, tag)
			return
		}

		bytes :=
			info.is_cstring ? transmute([]byte)string((^cstring)(data)^) : transmute([]byte)(^string)(data)^
		count := len(bytes)
		if !v.string_begin(v, name, ti, &count) do return

		if v.mode == .Read {
			if info.is_cstring {
				// One extra zeroed byte for the terminator
				mem, _ := runtime.mem_alloc(count + 1, 1, v.allocator)
				(^cstring)(data)^ = cstring(raw_data(mem))
				bytes = mem[:count]
			} else {
				bytes, _ = runtime.mem_alloc(count, 1, v.allocator)
				(^string)(data)^ = string(bytes)
			}
		}

		v.string_end(v, bytes)

	// Visited as an array of its elements, every element goes through a scratch value so the
	// visitor sees a plain enum or integer.
	case runtime.Type_Info_Bit_Set:
		bits := load_bits(data, ti.size)
		count := int(intrinsics.count_ones(bits))
		if !v.array_begin(v, name, ti, info.elem, &count) do return

		scratch: u128

		if v.mode == .Read {
			bits = 0

			for _ in 0 ..< count {
				scratch = 0
				walk(v, "", &scratch, info.elem.id)

				bit := extend(scratch, u128(info.elem.size * 8), is_signed(info.elem)) - i128(info.lower)
				if bit < 0 || bit > i128(info.upper - info.lower) {
					invalid(v, name, ti)
					continue
				}

				bits |= 1 << u128(bit)
			}

			store_bits(data, ti.size, bits)
		} else {
			// Visit the set bits only, lowest first
			for rest := bits; rest != 0; rest &= rest - 1 {
				scratch = u128(i128(info.lower) + i128(intrinsics.count_trailing_zeros(rest)))
				walk(v, "", &scratch, info.elem.id)
			}
		}

		v.array_end(v)

	// Visited as a struct, every field is unpacked into a scratch value of its declared type.
	case runtime.Type_Info_Bit_Field:
		if !v.struct_begin(v, name, ti) do return

		backing := load_bits(data, ti.size)

		for i in 0 ..< info.field_count {
			field_tag := reflect.Struct_Tag(info.tags[i])
			if reflect.struct_tag_get(field_tag, "shape") == "skip" do continue

			field := info.types[i]
			size, offset := u128(info.bit_sizes[i]), u128(info.bit_offsets[i])
			mask := size >= 128 ? ~u128(0) : (1 << size) - 1
			signed := is_signed(field)

			// The visitor only sees the low bytes that fit the field's own type
			scratch := u128(extend((backing >> offset) & mask, size, signed))
			walk(v, info.names[i], &scratch, field.id, field_tag)

			if v.mode == .Read {
				// The value fits when cutting it down to its bits and back is lossless
				value := extend(scratch, u128(field.size * 8), signed)
				if extend(u128(value) & mask, size, signed) != value {
					invalid(v, info.names[i], field)
					continue
				}

				backing = (backing & ~(mask << offset)) | ((u128(value) & mask) << offset)
			}
		}

		if v.mode == .Read do store_bits(data, ti.size, backing)
		v.struct_end(v)

	case runtime.Type_Info_Union:
		// Pointer only unions keep no tag, and walk does not follow pointers anyway
		if len(info.variants) == 0 || info.tag_type == nil do return

		any_union := any{data, tid}
		first_tag := info.no_nil ? 0 : 1
		variant := int(reflect.get_union_variant_raw_tag(any_union)) - first_tag

		ok := v.union_begin(v, name, ti, &variant)

		if v.mode == .Read {
			runtime.mem_zero(data, ti.size)
			if variant >= 0 do reflect.set_union_variant_raw_tag(any_union, i64(variant + first_tag))
		}

		if !ok || variant < 0 do return

		buffer: [128]byte
		payload := info.variants[variant]
		walk(v, union_variant_name(payload, buffer[:]), data, payload.id)

		v.union_end(v)

	case runtime.Type_Info_Integer,
	     runtime.Type_Info_Float,
	     runtime.Type_Info_Boolean,
	     runtime.Type_Info_Rune,
	     runtime.Type_Info_Enum:
		v.primitive(v, name, data, ti, tag)
	}
}

// Name a union variant is visited under, the declared name for named types, otherwise the
// type as written (`int`, `[]string`). Unnamed types are written into `buffer`.
union_variant_name :: proc(variant: ^runtime.Type_Info, buffer: []byte) -> string {
	if named, ok := variant.variant.(runtime.Type_Info_Named); ok do return named.name

	n := 0
	_ = runtime.write_typeid(&n, buffer, variant.id)
	return string(buffer[:n])
}

@(private = "file")
invalid :: proc(v: ^Visitor, name: string, info: ^runtime.Type_Info) {
	if v.invalid != nil do v.invalid(v, name, info)
}

@(private = "file")
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

@(private = "file")
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

@(private = "file")
is_signed :: proc(ti: ^runtime.Type_Info) -> bool {
	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer:
		return info.signed
	case runtime.Type_Info_Rune:
		return true
	case runtime.Type_Info_Enum:
		return is_signed(info.base)
	}

	return false
}

// The low `size` bits of `raw` as a value, sign extended from the top one when `signed`.
@(private = "file")
extend :: proc(raw: u128, size: u128, signed: bool) -> i128 {
	if !signed || size >= 128 do return i128(raw)

	shift := 128 - size
	return i128(raw << shift) >> shift
}

@(private = "file")
alloc_elems :: proc(v: ^Visitor, elem: ^runtime.Type_Info, elem_size, count: int) -> rawptr {
	if count == 0 do return nil
	mem, _ := runtime.mem_alloc(count * elem_size, elem.align, v.allocator)
	return raw_data(mem)
}
