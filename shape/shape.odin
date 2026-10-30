package shape

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

	// Actions, `count` is filled by walk, in .Write mode the visitor replaces it with the
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
	// UTF-8 strings and cstrings, `bytes` is the content to emit, or in .Write mode the
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

	// Escape hatch.
	ovverides:    map[typeid]proc(v: ^Visitor, name: string, data: rawptr),
}

walk :: proc(v: ^Visitor, name: string, data: rawptr, tid: typeid, tag: reflect.Struct_Tag = "") {
	if procedure, ok := v.ovverides[tid]; ok {
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

		if v.mode == .Write {
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

		if v.mode == .Write {
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

		if v.mode == .Write {
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

				runtime.__dynamic_map_set_without_hash(raw, info.map_info, raw_data(key), raw_data(value))
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

		if v.mode == .Write {
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

	case runtime.Type_Info_Integer,
	     runtime.Type_Info_Float,
	     runtime.Type_Info_Boolean,
	     runtime.Type_Info_Enum:
		v.primitive(v, name, data, ti, tag)
	}
}

@(private = "file")
alloc_elems :: proc(v: ^Visitor, elem: ^runtime.Type_Info, elem_size, count: int) -> rawptr {
	if count == 0 do return nil
	mem, _ := runtime.mem_alloc(count * elem_size, elem.align, v.allocator)
	return raw_data(mem)
}
