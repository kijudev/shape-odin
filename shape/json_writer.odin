package shape

import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

MAX_JSON_INLINE_ARRAY :: 4

JSON_WRITER_CAPACITY :: 4096
JSON_WRITER_PRETTY :: false
JSON_WRITER_TABSIZE: u8 : 4

// Writes nodes as JSON into a string.
//
// - structs and bit_fields are objects, fields in declaration order
// - arrays are arrays, enumerated arrays included
// - maps are objects, primitive keys are stringified (`{"Capsule": ..., "42": ...}`)
// - bit sets are arrays of their members
// - unions are an object with a single key naming the variant, nil is `null`
// - enums are their member name, or an integer when the value has no named member
// - runes are one character strings
// - NaN and infinite floats, and unsupported types, are `null`
Json_Writer :: struct {
	builder:  strings.Builder,
	pretty:   bool,
	tabsize:  u8,
	depth:    int,

	// Optional, called before every value, returning true means it wrote the value itself.
	override: proc(w: ^Json_Writer, n: Node) -> bool,
}

json_writer_init :: proc(
	w: ^Json_Writer,
	capacity := JSON_WRITER_CAPACITY,
	pretty := JSON_WRITER_PRETTY,
	tabsize := JSON_WRITER_TABSIZE,
	allocator := context.allocator,
) {
	w.pretty = pretty
	w.tabsize = tabsize
	w.depth = 0
	strings.builder_init(&w.builder, 0, capacity, allocator)
}

json_writer_destroy :: proc(w: ^Json_Writer) {strings.builder_destroy(&w.builder)}

json_writer_reset :: proc(w: ^Json_Writer) {
	strings.builder_reset(&w.builder)
	w.depth = 0
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

	json_write_node(&w, node_of(value))
	return strings.clone(json_writer_string(&w), allocator)
}

json_write_node :: proc(w: ^Json_Writer, n: Node) {
	if w.override != nil && w.override(w, n) do return

	switch v in n.value {
	case Struct:
		first := true
		open(w, '{')
		it := 0
		for f in iterate_fields(v, &it) {
			item(w, &first, false)
			write_name(w, f.name)
			json_write_node(w, f)
		}
		close(w, '}', first, false)

	case Array:
		count := array_length(v)
		inline := count <= MAX_JSON_INLINE_ARRAY && count > 0 && is_primitive(elem(v, 0).value)

		first := true
		open(w, '[')
		it: Elem_Iterator
		for e in iterate_elems(v, &it) {
			item(w, &first, inline)
			json_write_node(w, e)
		}
		close(w, ']', first, inline)

	case Bit_Set:
		bits := load_bits(v.data, int(v.size))
		inline := count_ones(bits) <= MAX_JSON_INLINE_ARRAY

		first := true
		open(w, '[')
		for rest := bits; rest != 0; rest &= rest - 1 {
			item(w, &first, inline)
			// Members go out as values of the element type, so enums get their names
			member := u128(i128(v.lower) + i128(lowest_one(rest)))
			json_write_node(w, node_from(&member, v.elem))
		}
		close(w, ']', first, inline)

	case Map:
		first := true
		open(w, '{')
		it := 0
		for key, value in iterate_map(v, &it) {
			item(w, &first, false)
			write_key(w, key)
			strings.write_string(&w.builder, w.pretty ? ": " : ":")
			json_write_node(w, value)
		}
		close(w, '}', first, false)

	case Union:
		index, payload := variant(v)
		if index < 0 {
			strings.write_string(&w.builder, "null")
			return
		}

		buffer: [128]byte
		first := true
		open(w, '{')
		item(w, &first, false)
		write_name(w, variant_name(v, index, buffer[:]))
		json_write_node(w, payload)
		close(w, '}', first, false)

	case String:
		write_quoted(w, get_string(v))

	case Int, Float, Bool, Rune, Enum:
		write_scalar(w, n.value, false)

	case:
		strings.write_string(&w.builder, "null")
	}
}

// >--------------------------------------------------------------------- Internals

// Object keys must be strings in JSON, so a primitive map key is wrapped in quotes.
@(private = "file")
write_key :: proc(w: ^Json_Writer, key: Node) {
	#partial switch _ in key.value {
	case Int, Float, Bool, Rune, Enum:
		write_scalar(w, key.value, true)
	case:
		json_write_node(w, key)
	}
}

@(private = "file")
write_scalar :: proc(w: ^Json_Writer, value: Value, key: bool) {
	buffer: [64]byte

	#partial switch v in value {
	case Int:
		write_key_aware(w, format_int(buffer[:], get_int(v), v.signed), key)

	case Float:
		f := get_float(v)

		if math.is_nan(f) || math.is_inf(f) {
			write_key_aware(w, "null", key)
		} else {
			s := strconv.write_float(buffer[:], f, 'g', -1, int(v.size) * 8)
			write_key_aware(w, strings.trim_prefix(s, "+"), key)
		}

	case Bool:
		write_key_aware(w, get_bool(v) ? "true" : "false", key)

	case Enum:
		value := get_enum(v)
		if name, ok := enum_name(v, value); ok {
			write_quoted(w, name)
		} else {
			write_key_aware(w, format_int(buffer[:], value, v.signed), key)
		}

	case Rune:
		bytes, length := utf8.encode_rune(get_rune(v))
		write_quoted(w, string(bytes[:length]))
	}
}

@(private = "file")
format_int :: proc(buffer: []byte, value: i128, signed: bool) -> string {
	if !signed || value >= 0 do return strconv.write_u128(buffer, u128(value), 10)

	// Negating the minimum wraps to itself, which as u128 is still the right magnitude
	buffer[0] = '-'
	return string(buffer[:len(strconv.write_u128(buffer[1:], u128(-value), 10)) + 1])
}

@(private = "file")
write_key_aware :: proc(w: ^Json_Writer, s: string, key: bool) {
	if key do strings.write_byte(&w.builder, '"')
	strings.write_string(&w.builder, s)
	if key do strings.write_byte(&w.builder, '"')
}

@(private = "file")
write_name :: proc(w: ^Json_Writer, name: string) {
	write_quoted(w, name)
	strings.write_string(&w.builder, w.pretty ? ": " : ":")
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
open :: proc(w: ^Json_Writer, opener: byte) {
	strings.write_byte(&w.builder, opener)
	w.depth += 1
}

// Separates an item from the previous one and indents it, inline items share a line.
@(private = "file")
item :: proc(w: ^Json_Writer, first: ^bool, inline: bool) {
	if !first^ {
		strings.write_byte(&w.builder, ',')
		if w.pretty && inline do strings.write_byte(&w.builder, ' ')
	}
	first^ = false

	if !inline do newline(w)
}

@(private = "file")
close :: proc(w: ^Json_Writer, closer: byte, first: bool, inline: bool) {
	w.depth -= 1
	if !first && !inline do newline(w)
	strings.write_byte(&w.builder, closer)
}

@(private = "file")
is_primitive :: proc(value: Value) -> bool {
	#partial switch _ in value {
	case Struct, Array, Map, Bit_Set, Union:
		return false
	}

	return true
}
