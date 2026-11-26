package shape

import "base:runtime"
import "core:math"
import "core:strconv"
import "core:unicode/utf16"
import "core:unicode/utf8"

Json_Reader_Error :: enum u8 {
	None,
	Parse_Field,
	Parse_Separator,
	Parse_Signed_Int,
	Parse_Unsigned_Int,
	Parse_Float,
	Parse_Bool,
	Parse_Enum,
	Parse_Rune,
	Parse_String,
	Parse_Struct,
	Parse_Array,
	Parse_Map,
	Parse_Union,
	Parse_Null,
	Out_Of_Range,
}

// Parses JSON into nodes, reading the format json_write produces. Struct fields must appear in
// declaration order. The first error sticks and turns every later step into a no-op, `pos` is
// left at the point of failure.
Json_Reader :: struct {
	src:       string,
	pos:       int,
	err:       Json_Reader_Error,
	allocator: runtime.Allocator,

	// Optional, called before every value, returning true means it read the value itself.
	override:  proc(r: ^Json_Reader, n: Node) -> bool,
}

json_reader_init :: proc(r: ^Json_Reader, src: string, allocator := context.allocator) {
	r.src = src
	r.allocator = allocator
	json_reader_reset(r)
}

json_reader_reset :: proc(r: ^Json_Reader) {
	r.pos = 0
	r.err = .None
}

// Parses `src` into `value` in one call, `pos` is where parsing stopped.
json_read :: proc(
	value: ^$T,
	src: string,
	allocator := context.allocator,
) -> (
	err: Json_Reader_Error,
	pos: int,
) {
	r: Json_Reader
	json_reader_init(&r, src, allocator)

	json_read_node(&r, node_of(value))
	return r.err, r.pos
}

json_read_node :: proc(r: ^Json_Reader, n: Node) {
	if r.err != .None do return
	if r.override != nil && r.override(r, n) do return

	switch v in n.value {
	case Struct:
		expect(r, '{', .Parse_Struct)
		first := true
		it := 0
		for f in iterate_fields(v, &it) {
			if !first do expect(r, ',', .Parse_Separator)
			first = false

			if quoted(r, .Parse_Field) != f.name do fail(r, .Parse_Field)
			expect(r, ':', .Parse_Separator)
			json_read_node(r, f)
			if r.err != .None do return
		}
		expect(r, '}', .Parse_Struct)

	case Array:
		if !expect(r, '[', .Parse_Array) do return
		count := count_items(r)

		fits := is_resizable(v) ? resize(v, count, r.allocator) : count == array_length(v)
		if !fits {
			fail(r, .Parse_Array)
			return
		}

		it: Elem_Iterator
		for e in iterate_elems(v, &it) {
			if e.index > 0 do expect(r, ',', .Parse_Separator)
			json_read_node(r, e)
			if r.err != .None do return
		}
		expect(r, ']', .Parse_Array)

	case Bit_Set:
		if !expect(r, '[', .Parse_Array) do return
		count := count_items(r)
		store_bits(v.data, int(v.size), 0)

		for i in 0 ..< count {
			if i > 0 do expect(r, ',', .Parse_Separator)

			// Members come as values of the element type, read through a scratch value
			scratch: u128
			value := node_from(&scratch, v.elem)
			json_read_node(r, value)
			if r.err != .None do return

			m := member(v, int(integer_of(value.value) - i128(v.lower)))
			flag, ok := m.value.(Bool)
			if !ok {
				fail(r, .Out_Of_Range)
				return
			}
			set_bool(flag, true)
		}
		expect(r, ']', .Parse_Array)

	case Map:
		if !expect(r, '{', .Parse_Map) do return
		count := count_items(r)
		map_reserve(v, count, r.allocator)

		// Entries are read into scratch values and copied in, the map hashes the finished key
		key_mem, _ := runtime.mem_alloc(v.key.size, v.key.align, r.allocator)
		value_mem, _ := runtime.mem_alloc(v.value.size, v.value.align, r.allocator)
		defer runtime.mem_free(raw_data(key_mem), r.allocator)
		defer runtime.mem_free(raw_data(value_mem), r.allocator)

		for i in 0 ..< count {
			if i > 0 do expect(r, ',', .Parse_Separator)
			runtime.mem_zero(raw_data(key_mem), len(key_mem))
			runtime.mem_zero(raw_data(value_mem), len(value_mem))

			key := node_from(raw_data(key_mem), v.key)
			key.is_key = true
			read_key(r, key)
			expect(r, ':', .Parse_Separator)
			json_read_node(r, node_from(raw_data(value_mem), v.value))
			if r.err != .None do return

			map_insert(v, raw_data(key_mem), raw_data(value_mem), r.allocator)
		}
		expect(r, '}', .Parse_Map)

	case Union:
		if !skip_ws(r) do return

		if r.pos >= len(r.src) || r.src[r.pos] != '{' {
			_, ok := set_variant(v, -1)
			if token(r) != "null" || !ok do fail(r, .Parse_Union)
			return
		}

		expect(r, '{', .Parse_Union)
		key := quoted(r, .Parse_Union)
		if r.err != .None do return

		buffer: [128]byte
		for i in 0 ..< len(v.variants) {
			if variant_name(v, i, buffer[:]) != key do continue

			payload, _ := set_variant(v, i)
			expect(r, ':', .Parse_Separator)
			json_read_node(r, payload)
			expect(r, '}', .Parse_Union)
			return
		}

		fail(r, .Parse_Union)

	case String:
		if !expect(r, '"', .Parse_String) do return

		length, _, ok := decode_string(r.src, r.pos, nil)
		if !ok {
			fail(r, .Parse_String)
			return
		}

		_, r.pos, _ = decode_string(r.src, r.pos, alloc_string(v, length, r.allocator))

	case Int, Float, Bool, Rune, Enum:
		read_scalar(r, n.value, false)

	case:
		if token(r) != "null" do fail(r, .Parse_Null)
	}
}

// >--------------------------------------------------------------------- Internals

// A primitive map key arrives wrapped in quotes.
@(private = "file")
read_key :: proc(r: ^Json_Reader, key: Node) {
	#partial switch _ in key.value {
	case Int, Float, Bool, Rune, Enum:
		read_scalar(r, key.value, true)
	case:
		json_read_node(r, key)
	}
}

@(private = "file")
read_scalar :: proc(r: ^Json_Reader, value: Value, key: bool) {
	fits := true

	#partial switch v in value {
	case Int:
		parsed := v.signed ? parse_signed_int(r, key) : parse_unsigned_int(r, key)
		fits = r.err != .None || set_int(v, parsed)

	case Float:
		f := parse_float(r, key)
		if r.err == .None do set_float(v, f)

	case Bool:
		b := parse_bool(r, key)
		if r.err == .None do set_bool(v, b)

	case Enum:
		parsed := parse_enum(r, v)
		fits = r.err != .None || set_enum(v, parsed)

	case Rune:
		parsed := parse_rune(r)
		fits = r.err != .None || set_rune(v, parsed)
	}

	if !fits do fail(r, .Out_Of_Range)
}

// Integer like values (bit set members) as one number.
@(private = "file")
integer_of :: proc(value: Value) -> i128 {
	#partial switch v in value {
	case Int:
		return get_int(v)
	case Enum:
		return get_enum(v)
	case Rune:
		return i128(get_rune(v))
	case Bool:
		return get_bool(v) ? 1 : 0
	}

	return 0
}

// A string holding exactly one code point.
@(private = "file")
parse_rune :: proc(r: ^Json_Reader) -> rune {
	if !expect(r, '"', .Parse_Rune) do return 0

	buffer: [4]byte
	length, _, ok := decode_string(r.src, r.pos, nil)
	if !ok || length == 0 || length > len(buffer) {
		fail(r, .Parse_Rune)
		return 0
	}

	_, r.pos, _ = decode_string(r.src, r.pos, buffer[:length])
	value, n := utf8.decode_rune(buffer[:length])

	// A lone RUNE_ERROR of width 1 is an invalid byte, an encoded U+FFFD is three wide
	if n != length || (value == utf8.RUNE_ERROR && n == 1) {
		fail(r, .Parse_Rune)
		return 0
	}

	return value
}


@(private = "file")
fail :: proc(r: ^Json_Reader, err: Json_Reader_Error) {
	if r.err == .None do r.err = err
}

@(private = "file")
skip_ws :: proc(r: ^Json_Reader) -> bool {
	if r.err != .None do return false

	for r.pos < len(r.src) {
		c := r.src[r.pos]
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' do break
		r.pos += 1
	}

	return true
}

@(private = "file")
expect :: proc(r: ^Json_Reader, c: byte, err: Json_Reader_Error) -> bool {
	if !skip_ws(r) do return false

	if r.pos >= len(r.src) || r.src[r.pos] != c {
		fail(r, err)
		return false
	}

	r.pos += 1
	return true
}

@(private = "file")
token :: proc(r: ^Json_Reader) -> string {
	if !skip_ws(r) do return ""

	start := r.pos
	for r.pos < len(r.src) {
		switch r.src[r.pos] {
		case ' ', '\t', '\n', '\r', '{', '}', '[', ']', '"', ',', ':':
			return r.src[start:r.pos]
		}

		r.pos += 1
	}

	return r.src[start:r.pos]
}

// Raw contents of a quoted string without escapes, for field names, enum names and
// primitive map keys, which never need them.
@(private = "file")
quoted :: proc(r: ^Json_Reader, err: Json_Reader_Error) -> string {
	if !expect(r, '"', err) do return ""

	start := r.pos
	for r.pos < len(r.src) && r.src[r.pos] != '"' {
		if r.src[r.pos] == '\\' {
			fail(r, err)
			return ""
		}

		r.pos += 1
	}

	end := r.pos
	if !expect(r, '"', err) do return ""
	return r.src[start:end]
}

@(private = "file")
scalar :: proc(r: ^Json_Reader, key: bool, err: Json_Reader_Error) -> string {
	return key ? quoted(r, err) : token(r)
}

// Items are separated by commas at the container's own depth, a map entry is one item.
@(private = "file")
count_items :: proc(r: ^Json_Reader) -> int {
	if !skip_ws(r) do return 0
	if r.pos < len(r.src) && (r.src[r.pos] == ']' || r.src[r.pos] == '}') do return 0

	count, depth, i := 1, 0, r.pos

	for i < len(r.src) {
		switch r.src[i] {
		case '{', '[':
			depth += 1

		case '}', ']':
			if depth == 0 do return count
			depth -= 1

		case ',':
			if depth == 0 do count += 1

		case '"':
			i += 1

			for i < len(r.src) && r.src[i] != '"' {
				if r.src[i] == '\\' do i += 1
				i += 1
			}
		}

		i += 1
	}

	return count
}


@(private = "file")
parse_signed_int :: proc(r: ^Json_Reader, key: bool) -> i128 {
	tok := scalar(r, key, .Parse_Signed_Int)
	if r.err != .None do return 0

	value, ok := strconv.parse_i128_of_base(tok, 10)
	if !ok do fail(r, .Parse_Signed_Int)
	return value
}

// Returned as the i128 with the same bits, which is what set_int expects for u128.
@(private = "file")
parse_unsigned_int :: proc(r: ^Json_Reader, key: bool) -> i128 {
	tok := scalar(r, key, .Parse_Unsigned_Int)
	if r.err != .None do return 0

	value, ok := strconv.parse_u128_of_base(tok, 10)
	if !ok do fail(r, .Parse_Unsigned_Int)
	return i128(value)
}

@(private = "file")
parse_float :: proc(r: ^Json_Reader, key: bool) -> f64 {
	tok := scalar(r, key, .Parse_Float)
	if r.err != .None do return 0
	if tok == "null" do return math.nan_f64()

	value, ok := strconv.parse_f64(tok)
	if !ok do fail(r, .Parse_Float)

	return value
}

@(private = "file")
parse_bool :: proc(r: ^Json_Reader, key: bool) -> bool {
	switch scalar(r, key, .Parse_Bool) {
	case "true":
		return true
	case "false":
		return false
	}

	fail(r, .Parse_Bool)
	return false
}

// Enums are names in quotes, or bare integers when the value has no named member. As a map
// key the integer is quoted too, so a quoted integer is accepted as well.
@(private = "file")
parse_enum :: proc(r: ^Json_Reader, e: Enum) -> i128 {
	if !skip_ws(r) do return 0

	tok: string
	if r.pos < len(r.src) && r.src[r.pos] == '"' {
		tok = quoted(r, .Parse_Enum)
		if r.err != .None do return 0
		if value, ok := enum_value(e, tok); ok do return value
	} else {
		tok = token(r)
	}

	value, ok := strconv.parse_i128_of_base(tok, 10)
	if !ok do fail(r, .Parse_Enum)
	return value
}

// Decodes the string body starting at `pos` (just past the opening quote) into `out` and
// returns the decoded length and the position past the closing quote. With `out == nil` it
// only measures, so the same rules size the allocation and fill it.
@(private = "file")
decode_string :: proc(src: string, pos: int, out: []byte) -> (length, end: int, ok: bool) {
	i := pos

	for i < len(src) {
		c := src[i]
		i += 1

		switch c {
		case '"':
			return length, i, true

		case '\\':
			if i >= len(src) do return
			e := src[i]
			i += 1

			switch e {
			case '"', '\\', '/':
				c = e
			case 'b':
				c = '\b'
			case 'f':
				c = '\f'
			case 'n':
				c = '\n'
			case 'r':
				c = '\r'
			case 't':
				c = '\t'
			case 'u':
				r, hex_ok := decode_hex4(src, &i)
				if !hex_ok do return

				// Code points above the BMP come as a surrogate pair of escapes
				if utf16.is_surrogate(r) {
					if i + 2 > len(src) || src[i] != '\\' || src[i + 1] != 'u' do return
					i += 2

					low, low_ok := decode_hex4(src, &i)
					if !low_ok do return

					r = utf16.decode_surrogate_pair(r, low)
					if r == utf16.REPLACEMENT_CHAR do return
				}

				bytes, n := utf8.encode_rune(r)
				if out != nil do copy(out[length:], bytes[:n])
				length += n
				continue
			case:
				return
			}

		case:
			if c < 0x20 do return
		}

		if out != nil do out[length] = c
		length += 1
	}

	return
}

@(private = "file")
decode_hex4 :: proc(src: string, i: ^int) -> (r: rune, ok: bool) {
	if i^ + 4 > len(src) do return
	code, hex_ok := strconv.parse_u64_of_base(src[i^:i^ + 4], 16)
	if !hex_ok do return

	i^ += 4
	return rune(code), true
}
