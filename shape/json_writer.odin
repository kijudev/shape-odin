package shape

import "base:runtime"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"

MAX_JSON_INLINE_ARRAY :: 4

JSON_WRITER_CAPACITY :: 4096
JSON_WRITER_PRETTY :: false
JSON_WRITER_TABSIZE: u8 : 4

// JSON syntax writer that ouputs to a string. Nesting is carried by walk's recursion, the
// writer only tracks the container it is currently inside. Map keys are always written as
// strings, primitive keys get quoted.
Json_Writer :: struct {
	using base: Visitor,
	builder:    strings.Builder,
	pretty:     bool,
	tabsize:    u8,
	depth:      int,
	has_items:  bool,
	inline:     bool,
}

json_writer_init :: proc(
	w: ^Json_Writer,
	capacity := JSON_WRITER_CAPACITY,
	pretty := JSON_WRITER_PRETTY,
	tabsize := JSON_WRITER_TABSIZE,
	allocator := context.allocator,
) {
	w.base = Visitor {
		mode         = .Write,
		struct_begin = json_writer_struct_begin,
		struct_end   = json_writer_struct_end,
		array_begin  = json_writer_array_begin,
		array_end    = json_writer_array_end,
		map_begin    = json_writer_map_begin,
		map_end      = json_writer_map_end,
		string_begin = json_writer_string_begin,
		string_end   = json_writer_string_end,
		primitive    = json_writer_primitive,
		allocator    = allocator,
	}

	w.pretty = pretty
	w.tabsize = tabsize
	w.depth = 0
	w.has_items = false
	w.inline = false

	strings.builder_init(&w.builder, 0, capacity, allocator)
}

json_writer_destroy :: proc(w: ^Json_Writer) {strings.builder_destroy(&w.builder)}

json_writer_reset :: proc(w: ^Json_Writer) {
	strings.builder_reset(&w.builder)
	w.depth = 0
	w.has_items = false
	w.inline = false
}

json_writer_string :: proc(w: ^Json_Writer) -> string {return strings.to_string(w.builder)}

// Serializes `value` in one call, the result is cloned with `allocator` before the writer is
// destroyed.
json_write :: proc(
	value: ^$T,
	capacity := JSON_WRITER_CAPACITY,
	pretty := JSON_WRITER_PRETTY,
	tabsize := JSON_WRITER_TABSIZE,
	allocator := context.allocator,
) -> string {
	w: Json_Writer
	json_writer_init(&w, capacity, pretty, tabsize, allocator)
	defer json_writer_destroy(&w)

	walk(&w, "", value, T)
	return strings.clone(json_writer_string(&w), allocator)
}

// >-------------------------------------------------------------------- Actions

json_writer_struct_begin :: proc(v: ^Visitor, name: string, info: ^runtime.Type_Info) -> bool {
	open((^Json_Writer)(v), name, '{')
	return true
}

json_writer_struct_end :: proc(v: ^Visitor) {close((^Json_Writer)(v), '}')}

json_writer_array_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	elem: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	w := (^Json_Writer)(v)
	open(w, name, '[')
	w.inline = count^ <= MAX_JSON_INLINE_ARRAY && is_primitive(elem)
	return true
}

json_writer_array_end :: proc(v: ^Visitor) {close((^Json_Writer)(v), ']')}

json_writer_map_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	key: ^runtime.Type_Info,
	value: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	open((^Json_Writer)(v), name, '{')
	return true
}

json_writer_map_end :: proc(v: ^Visitor) {close((^Json_Writer)(v), '}')}

json_writer_string_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	prefix((^Json_Writer)(v), name)
	return true
}

json_writer_string_end :: proc(v: ^Visitor, bytes: []byte) {
	write_quoted((^Json_Writer)(v), string(bytes))
}

json_writer_primitive :: proc(
	v: ^Visitor,
	name: string,
	data: rawptr,
	ti: ^runtime.Type_Info,
	tag: reflect.Struct_Tag,
) {
	w := (^Json_Writer)(v)
	// prefix clears the flag, enums are quoted on their own
	key := w.map_key
	prefix(w, name)
	buffer: [64]byte

	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer:
		s :=
			info.signed ? strconv.write_int(buffer[:], read_signed(data, ti.size), 10) : strconv.write_uint(buffer[:], read_unsigned(data, ti.size), 10)
		write_key_aware(w, s, key)

	case runtime.Type_Info_Float:
		f: f64

		switch ti.size {
		case 2:
			f = f64((^f16)(data)^)
		case 4:
			f = f64((^f32)(data)^)
		case 8:
			f = (^f64)(data)^
		}

		if math.is_nan(f) || math.is_inf(f) {
			write_key_aware(w, "null", key)
		} else {
			s := strconv.write_float(buffer[:], f, 'g', -1, ti.size * 8)
			write_key_aware(w, strings.trim_prefix(s, "+"), key)
		}

	case runtime.Type_Info_Boolean:
		write_key_aware(w, read_unsigned(data, ti.size) != 0 ? "true" : "false", key)

	case runtime.Type_Info_Enum:
		base := runtime.type_info_base(info.base)
		val: i64

		if bi, ok := base.variant.(runtime.Type_Info_Integer); ok && bi.signed {
			val = read_signed(data, base.size)
		} else {
			val = i64(read_unsigned(data, base.size))
		}

		for ev, i in info.values {
			if i64(ev) == val {
				write_quoted(w, info.names[i])
				return
			}
		}

		write_key_aware(w, strconv.write_int(buffer[:], val, 10), key)

	case runtime.Type_Info_String:
		// Only non UTF-8 strings land here, walk sends the rest to string_begin
		write_key_aware(w, "null", key)
	}
}

json_writer_write_string :: proc(w: ^Json_Writer, name: string, s: string) {
	prefix(w, name)
	write_quoted(w, s)
}

// >------------------------------------------------------------------ Internals

// Object keys must be strings in JSON, so a primitive map key is wrapped in quotes.
@(private = "file")
write_key_aware :: proc(w: ^Json_Writer, s: string, key: bool) {
	if key do strings.write_byte(&w.builder, '"')
	strings.write_string(&w.builder, s)
	if key do strings.write_byte(&w.builder, '"')
}

@(private = "file")
write_quoted :: proc(w: ^Json_Writer, s: string) {
	strings.write_byte(&w.builder, '"')
	start := 0

	for i in 0 ..< len(s) {
		c := s[i]

		if c >= 0x20 && c != '"' && c != '\\' do continue
		strings.write_string(&w.builder, s[start:i])

		switch c {
		case '"':
			strings.write_string(&w.builder, `\"`)
		case '\\':
			strings.write_string(&w.builder, `\\`)
		case '\n':
			strings.write_string(&w.builder, `\n`)
		case '\r':
			strings.write_string(&w.builder, `\r`)
		case '\t':
			strings.write_string(&w.builder, `\t`)
		case:
			hex := "0123456789abcdef"
			strings.write_string(&w.builder, `\u00`)
			strings.write_byte(&w.builder, hex[c >> 4])
			strings.write_byte(&w.builder, hex[c & 15])
		}

		start = i + 1
	}

	strings.write_string(&w.builder, s[start:])
	strings.write_byte(&w.builder, '"')
}

@(private = "file")
newline :: proc(w: ^Json_Writer) {
	if !w.pretty do return

	strings.write_byte(&w.builder, '\n')
	for _ in 0 ..< int(w.tabsize) * w.depth do strings.write_byte(&w.builder, ' ')
}

@(private = "file")
prefix :: proc(w: ^Json_Writer, name: string) {
	if w.depth == 0 do return

	// A map value follows its key after a colon, like a struct field after its name
	if w.map_value {
		w.map_value = false
		strings.write_string(&w.builder, w.pretty ? ": " : ":")
		return
	}

	w.map_key = false

	if w.has_items {
		strings.write_byte(&w.builder, ',')
		if w.pretty && w.inline do strings.write_byte(&w.builder, ' ')
	}
	w.has_items = true

	if !w.inline do newline(w)

	if name != "" {
		write_quoted(w, name)
		strings.write_string(&w.builder, w.pretty ? ": " : ":")
	}
}

@(private = "file")
open :: proc(w: ^Json_Writer, name: string, opener: byte) {
	prefix(w, name)
	strings.write_byte(&w.builder, opener)

	w.depth += 1
	w.has_items = false
	w.inline = false
}

@(private = "file")
close :: proc(w: ^Json_Writer, closer: byte) {
	w.depth -= 1
	if w.has_items && !w.inline do newline(w)
	strings.write_byte(&w.builder, closer)

	w.has_items = true
	w.inline = false
}

@(private = "file")
is_primitive :: proc(ti: ^runtime.Type_Info) -> bool {
	#partial switch _ in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Struct,
	     runtime.Type_Info_Array,
	     runtime.Type_Info_Slice,
	     runtime.Type_Info_Dynamic_Array,
	     runtime.Type_Info_Map:
		return false
	}

	return true
}

@(private = "file")
read_unsigned :: proc(data: rawptr, size: int) -> u64 {
	switch size {
	case 1:
		return u64((^u8)(data)^)
	case 2:
		return u64((^u16)(data)^)
	case 4:
		return u64((^u32)(data)^)
	case 8:
		return (^u64)(data)^
	}

	return 0
}

@(private = "file")
read_signed :: proc(data: rawptr, size: int) -> i64 {
	switch size {
	case 1:
		return i64((^i8)(data)^)
	case 2:
		return i64((^i16)(data)^)
	case 4:
		return i64((^i32)(data)^)
	case 8:
		return (^i64)(data)^
	}

	return 0
}
