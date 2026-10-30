package shape

import "base:runtime"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"

MAX_LISP_INLINE_ARRAY :: 4

// S-expression syntax reader that ouputs to a string. Nesting is carried by walk's
// recursion, the reader only tracks the container it is currently inside.
Lisp_Reader :: struct {
	using base: Visitor,
	builder:    strings.Builder,
	pretty:     bool,
	tabsize:    u8,
	depth:      int,
	has_items:  bool,
	inline:     bool,
}

lisp_reader_init :: proc(
	r: ^Lisp_Reader,
	capacity := 4096,
	pretty := false,
	tabsize: u8 = 4,
	allocator := context.allocator,
) {
	r.base = Visitor {
		mode         = .Read,
		struct_begin = lisp_reader_struct_begin,
		struct_end   = lisp_reader_struct_end,
		array_begin  = lisp_reader_array_begin,
		array_end    = lisp_reader_array_end,
		map_begin    = lisp_reader_map_begin,
		map_end      = lisp_reader_map_end,
		string_begin = lisp_reader_string_begin,
		string_end   = lisp_reader_string_end,
		primitive    = lisp_reader_primitive,
		allocator    = allocator,
	}

	r.pretty = pretty
	r.tabsize = tabsize
	r.depth = 0
	r.has_items = false
	r.inline = false

	strings.builder_init(&r.builder, 0, capacity, allocator)
}

lisp_reader_destroy :: proc(r: ^Lisp_Reader) {strings.builder_destroy(&r.builder)}

lisp_reader_reset :: proc(r: ^Lisp_Reader) {
	strings.builder_reset(&r.builder)
	r.depth = 0
	r.has_items = false
	r.inline = false
}

lisp_reader_string :: proc(r: ^Lisp_Reader) -> string {return strings.to_string(r.builder)}

// >-------------------------------------------------------------------- Actions

lisp_reader_struct_begin :: proc(v: ^Visitor, name: string, info: ^runtime.Type_Info) -> bool {
	open((^Lisp_Reader)(v), name, '(')
	return true
}

lisp_reader_struct_end :: proc(v: ^Visitor) {close((^Lisp_Reader)(v), ')')}

lisp_reader_array_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	elem: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	r := (^Lisp_Reader)(v)
	open(r, name, '[')
	r.inline = count^ <= MAX_LISP_INLINE_ARRAY && is_primitive(elem)
	return true
}

lisp_reader_array_end :: proc(v: ^Visitor) {close((^Lisp_Reader)(v), ']')}

lisp_reader_map_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	key: ^runtime.Type_Info,
	value: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	open((^Lisp_Reader)(v), name, '{')
	return true
}

lisp_reader_map_end :: proc(v: ^Visitor) {close((^Lisp_Reader)(v), '}')}

lisp_reader_string_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	prefix((^Lisp_Reader)(v), name)
	return true
}

lisp_reader_string_end :: proc(v: ^Visitor, bytes: []byte) {
	write_quoted((^Lisp_Reader)(v), string(bytes))
}

lisp_reader_primitive :: proc(
	v: ^Visitor,
	name: string,
	data: rawptr,
	ti: ^runtime.Type_Info,
	tag: reflect.Struct_Tag,
) {
	r := (^Lisp_Reader)(v)
	prefix(r, name)
	buffer: [64]byte

	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer:
		s :=
			info.signed ? strconv.write_int(buffer[:], read_signed(data, ti.size), 10) : strconv.write_uint(buffer[:], read_unsigned(data, ti.size), 10)
		strings.write_string(&r.builder, s)

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
			strings.write_string(&r.builder, "nil")
		} else {
			s := strconv.write_float(buffer[:], f, 'g', -1, ti.size * 8)
			strings.write_string(&r.builder, strings.trim_prefix(s, "+"))
		}

	case runtime.Type_Info_Boolean:
		strings.write_string(&r.builder, read_unsigned(data, ti.size) != 0 ? "true" : "false")

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
				strings.write_byte(&r.builder, '\'')
				strings.write_string(&r.builder, info.names[i])
				return
			}
		}

		strings.write_string(&r.builder, strconv.write_int(buffer[:], val, 10))

	case runtime.Type_Info_String:
		// Only non UTF-8 strings land here, walk sends the rest to string_begin
		strings.write_string(&r.builder, "nil")
	}
}

lisp_reader_write_string :: proc(r: ^Lisp_Reader, name: string, s: string) {
	prefix(r, name)
	write_quoted(r, s)
}

// >------------------------------------------------------------------ Internals

@(private = "file")
write_quoted :: proc(r: ^Lisp_Reader, s: string) {
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
newline :: proc(r: ^Lisp_Reader) {
	if !r.pretty do return

	strings.write_byte(&r.builder, '\n')
	for _ in 0 ..< int(r.tabsize) * r.depth do strings.write_byte(&r.builder, ' ')
}

@(private = "file")
prefix :: proc(r: ^Lisp_Reader, name: string) {
	if r.depth == 0 do return

	// A map value sits on the line of its key, like a struct field after its name
	if r.map_value {
		r.map_value = false
		strings.write_byte(&r.builder, ' ')
		return
	}

	if r.has_items && (!r.pretty || r.inline) do strings.write_byte(&r.builder, ' ')
	r.has_items = true

	if !r.inline do newline(r)

	if name != "" {
		strings.write_string(&r.builder, name)
		strings.write_byte(&r.builder, ' ')
	}
}

@(private = "file")
open :: proc(r: ^Lisp_Reader, name: string, opener: byte) {
	prefix(r, name)
	strings.write_byte(&r.builder, opener)

	r.depth += 1
	r.has_items = false
	r.inline = false
}

@(private = "file")
close :: proc(r: ^Lisp_Reader, closer: byte) {
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
