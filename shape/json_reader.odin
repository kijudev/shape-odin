package shape

import "base:runtime"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"

MAX_JSON_INLINE_ARRAY :: 4

JSON_READER_CAPACITY :: 4096
JSON_READER_PRETTY :: false
JSON_READER_TABSIZE: u8 : 4

// JSON syntax reader that ouputs to a string. Nesting is carried by walk's recursion, the
// reader only tracks the container it is currently inside. Map keys are always written as
// strings, primitive keys get quoted.
Json_Reader :: struct {
	using base: Visitor,
	builder:    strings.Builder,
	pretty:     bool,
	tabsize:    u8,
	depth:      int,
	has_items:  bool,
	inline:     bool,
}

json_reader_init :: proc(
	r: ^Json_Reader,
	capacity := JSON_READER_CAPACITY,
	pretty := JSON_READER_PRETTY,
	tabsize := JSON_READER_TABSIZE,
	allocator := context.allocator,
) {
	r.base = Visitor {
		mode         = .Read,
		struct_begin = json_reader_struct_begin,
		struct_end   = json_reader_struct_end,
		array_begin  = json_reader_array_begin,
		array_end    = json_reader_array_end,
		map_begin    = json_reader_map_begin,
		map_end      = json_reader_map_end,
		string_begin = json_reader_string_begin,
		string_end   = json_reader_string_end,
		primitive    = json_reader_primitive,
		allocator    = allocator,
	}

	r.pretty = pretty
	r.tabsize = tabsize
	r.depth = 0
	r.has_items = false
	r.inline = false

	strings.builder_init(&r.builder, 0, capacity, allocator)
}

json_reader_destroy :: proc(r: ^Json_Reader) {strings.builder_destroy(&r.builder)}

json_reader_reset :: proc(r: ^Json_Reader) {
	strings.builder_reset(&r.builder)
	r.depth = 0
	r.has_items = false
	r.inline = false
}

json_reader_string :: proc(r: ^Json_Reader) -> string {return strings.to_string(r.builder)}

// Serializes `value` in one call, the result is cloned with `allocator` before the reader is
// destroyed.
json_read :: proc(
	value: ^$T,
	capacity := JSON_READER_CAPACITY,
	pretty := JSON_READER_PRETTY,
	tabsize := JSON_READER_TABSIZE,
	allocator := context.allocator,
) -> string {
	r: Json_Reader
	json_reader_init(&r, capacity, pretty, tabsize, allocator)
	defer json_reader_destroy(&r)

	walk(&r, "", value, T)
	return strings.clone(json_reader_string(&r), allocator)
}

// >-------------------------------------------------------------------- Actions

json_reader_struct_begin :: proc(v: ^Visitor, name: string, info: ^runtime.Type_Info) -> bool {
	open((^Json_Reader)(v), name, '{')
	return true
}

json_reader_struct_end :: proc(v: ^Visitor) {close((^Json_Reader)(v), '}')}

json_reader_array_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	elem: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	r := (^Json_Reader)(v)
	open(r, name, '[')
	r.inline = count^ <= MAX_JSON_INLINE_ARRAY && is_primitive(elem)
	return true
}

json_reader_array_end :: proc(v: ^Visitor) {close((^Json_Reader)(v), ']')}

json_reader_map_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	key: ^runtime.Type_Info,
	value: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	open((^Json_Reader)(v), name, '{')
	return true
}

json_reader_map_end :: proc(v: ^Visitor) {close((^Json_Reader)(v), '}')}

json_reader_string_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	prefix((^Json_Reader)(v), name)
	return true
}

json_reader_string_end :: proc(v: ^Visitor, bytes: []byte) {
	write_quoted((^Json_Reader)(v), string(bytes))
}

json_reader_primitive :: proc(
	v: ^Visitor,
	name: string,
	data: rawptr,
	ti: ^runtime.Type_Info,
	tag: reflect.Struct_Tag,
) {
	r := (^Json_Reader)(v)
	// prefix clears the flag, enums are quoted on their own
	key := r.map_key
	prefix(r, name)
	buffer: [64]byte

	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer:
		s :=
			info.signed ? strconv.write_int(buffer[:], read_signed(data, ti.size), 10) : strconv.write_uint(buffer[:], read_unsigned(data, ti.size), 10)
		write_key_aware(r, s, key)

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
			write_key_aware(r, "null", key)
		} else {
			s := strconv.write_float(buffer[:], f, 'g', -1, ti.size * 8)
			write_key_aware(r, strings.trim_prefix(s, "+"), key)
		}

	case runtime.Type_Info_Boolean:
		write_key_aware(r, read_unsigned(data, ti.size) != 0 ? "true" : "false", key)

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
				write_quoted(r, info.names[i])
				return
			}
		}

		write_key_aware(r, strconv.write_int(buffer[:], val, 10), key)

	case runtime.Type_Info_String:
		// Only non UTF-8 strings land here, walk sends the rest to string_begin
		write_key_aware(r, "null", key)
	}
}

json_reader_write_string :: proc(r: ^Json_Reader, name: string, s: string) {
	prefix(r, name)
	write_quoted(r, s)
}

// >------------------------------------------------------------------ Internals

// Object keys must be strings in JSON, so a primitive map key is wrapped in quotes.
@(private = "file")
write_key_aware :: proc(r: ^Json_Reader, s: string, key: bool) {
	if key do strings.write_byte(&r.builder, '"')
	strings.write_string(&r.builder, s)
	if key do strings.write_byte(&r.builder, '"')
}

@(private = "file")
write_quoted :: proc(r: ^Json_Reader, s: string) {
	strings.write_byte(&r.builder, '"')
	start := 0

	for i in 0 ..< len(s) {
		c := s[i]

		if c >= 0x20 && c != '"' && c != '\\' do continue
		strings.write_string(&r.builder, s[start:i])

		switch c {
		case '"':
			strings.write_string(&r.builder, `\"`)
		case '\\':
			strings.write_string(&r.builder, `\\`)
		case '\n':
			strings.write_string(&r.builder, `\n`)
		case '\r':
			strings.write_string(&r.builder, `\r`)
		case '\t':
			strings.write_string(&r.builder, `\t`)
		case:
			hex := "0123456789abcdef"
			strings.write_string(&r.builder, `\u00`)
			strings.write_byte(&r.builder, hex[c >> 4])
			strings.write_byte(&r.builder, hex[c & 15])
		}

		start = i + 1
	}

	strings.write_string(&r.builder, s[start:])
	strings.write_byte(&r.builder, '"')
}

@(private = "file")
newline :: proc(r: ^Json_Reader) {
	if !r.pretty do return

	strings.write_byte(&r.builder, '\n')
	for _ in 0 ..< int(r.tabsize) * r.depth do strings.write_byte(&r.builder, ' ')
}

@(private = "file")
prefix :: proc(r: ^Json_Reader, name: string) {
	if r.depth == 0 do return

	// A map value follows its key after a colon, like a struct field after its name
	if r.map_value {
		r.map_value = false
		strings.write_string(&r.builder, r.pretty ? ": " : ":")
		return
	}

	r.map_key = false

	if r.has_items {
		strings.write_byte(&r.builder, ',')
		if r.pretty && r.inline do strings.write_byte(&r.builder, ' ')
	}
	r.has_items = true

	if !r.inline do newline(r)

	if name != "" {
		write_quoted(r, name)
		strings.write_string(&r.builder, r.pretty ? ": " : ":")
	}
}

@(private = "file")
open :: proc(r: ^Json_Reader, name: string, opener: byte) {
	prefix(r, name)
	strings.write_byte(&r.builder, opener)

	r.depth += 1
	r.has_items = false
	r.inline = false
}

@(private = "file")
close :: proc(r: ^Json_Reader, closer: byte) {
	r.depth -= 1
	if r.has_items && !r.inline do newline(r)
	strings.write_byte(&r.builder, closer)

	r.has_items = true
	r.inline = false
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
