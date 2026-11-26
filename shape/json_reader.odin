package shape

import "base:runtime"
import "core:math"
import "core:reflect"
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
	Parse_String,
	Parse_Struct,
	Parse_Array,
	Parse_Map,
	Out_Of_Range,
}

// JSON syntax reader that parses a string into the walked value. It consumes the source in
// walk order, so struct fields must appear in declaration order. The first error sticks and
// turns every later step into a no-op, `pos` is left at the point of failure.
Json_Reader :: struct {
	using base: Visitor,
	src:        string,
	pos:        int,
	depth:      int,
	has_items:  bool,
	err:        Json_Reader_Error,
}

json_reader_init :: proc(r: ^Json_Reader, src: string, allocator := context.allocator) {
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

	r.src = src
	r.pos = 0
	r.depth = 0
	r.has_items = false
	r.err = .None
}

json_reader_reset :: proc(r: ^Json_Reader) {
	r.pos = 0
	r.depth = 0
	r.has_items = false
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

	walk(&r, "", value, T)
	return r.err, r.pos
}

// >-------------------------------------------------------------------- Actions

json_reader_struct_begin :: proc(v: ^Visitor, name: string, info: ^runtime.Type_Info) -> bool {
	r := (^Json_Reader)(v)
	open(r, name, '{', .Parse_Struct)
	return r.err == .None
}

json_reader_struct_end :: proc(v: ^Visitor) {close((^Json_Reader)(v), '}', .Parse_Struct)}

json_reader_array_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	elem: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	r := (^Json_Reader)(v)
	open(r, name, '[', .Parse_Array)

	items := count_items(r)
	if fixed, ok := runtime.type_info_base(info).variant.(runtime.Type_Info_Array); ok {
		if items != fixed.count do fail(r, .Parse_Array)
	}

	count^ = items
	return r.err == .None
}

json_reader_array_end :: proc(v: ^Visitor) {close((^Json_Reader)(v), ']', .Parse_Array)}

json_reader_map_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	key: ^runtime.Type_Info,
	value: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	r := (^Json_Reader)(v)
	open(r, name, '{', .Parse_Map)

	count^ = count_items(r)
	return r.err == .None
}

json_reader_map_end :: proc(v: ^Visitor) {close((^Json_Reader)(v), '}', .Parse_Map)}

json_reader_string_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	r := (^Json_Reader)(v)
	prefix(r, name)
	if !expect(r, '"', .Parse_String) do return false

	length, _, ok := decode_string(r.src, r.pos, nil)
	if !ok do fail(r, .Parse_String)

	count^ = length
	return r.err == .None
}

json_reader_string_end :: proc(v: ^Visitor, bytes: []byte) {
	r := (^Json_Reader)(v)
	_, r.pos, _ = decode_string(r.src, r.pos, bytes)
}

json_reader_primitive :: proc(
	v: ^Visitor,
	name: string,
	data: rawptr,
	ti: ^runtime.Type_Info,
	tag: reflect.Struct_Tag,
) {
	r := (^Json_Reader)(v)
	// prefix clears the flag, a primitive map key arrives wrapped in quotes
	key := r.map_key
	prefix(r, name)

	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer:
		if info.signed {
			store_signed(r, data, ti.size, parse_signed_int(r, key))
		} else {
			store_unsigned(r, data, ti.size, parse_unsigned_int(r, key))
		}

	case runtime.Type_Info_Float:
		f := parse_float(r, key)
		if r.err != .None do return

		switch ti.size {
		case 2:
			(^f16)(data)^ = f16(f)
		case 4:
			(^f32)(data)^ = f32(f)
		case 8:
			(^f64)(data)^ = f
		}

	case runtime.Type_Info_Boolean:
		store_unsigned(r, data, ti.size, parse_bool(r, key) ? 1 : 0)

	case runtime.Type_Info_Enum:
		val := parse_enum(r, info)
		base := runtime.type_info_base(info.base)

		if bi, ok := base.variant.(runtime.Type_Info_Integer); ok && bi.signed {
			store_signed(r, data, base.size, val)
		} else {
			store_unsigned(r, data, base.size, u64(val))
		}

	case runtime.Type_Info_String:
		// Only non UTF-8 strings land here, walk sends the rest to string_begin
		if scalar(r, key, .Parse_String) != "null" do fail(r, .Parse_String)
	}
}

// >------------------------------------------------------------------ Utilities

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
prefix :: proc(r: ^Json_Reader, name: string) {
	if r.depth == 0 do return

	if r.map_value {
		r.map_value = false
		expect(r, ':', .Parse_Separator)
		return
	}

	r.map_key = false

	if r.has_items do expect(r, ',', .Parse_Separator)
	r.has_items = true

	if name == "" do return
	if quoted(r, .Parse_Field) != name do fail(r, .Parse_Field)
	expect(r, ':', .Parse_Separator)
}

@(private = "file")
open :: proc(r: ^Json_Reader, name: string, opener: byte, err: Json_Reader_Error) {
	prefix(r, name)
	expect(r, opener, err)

	r.depth += 1
	r.has_items = false
}

@(private = "file")
close :: proc(r: ^Json_Reader, closer: byte, err: Json_Reader_Error) {
	expect(r, closer, err)

	r.depth -= 1
	r.has_items = true
}

@(private = "file")
parse_signed_int :: proc(r: ^Json_Reader, key: bool) -> i64 {
	tok := scalar(r, key, .Parse_Signed_Int)
	if r.err != .None do return 0

	value, ok := strconv.parse_i64_of_base(tok, 10)
	if !ok do fail(r, .Parse_Signed_Int)
	return value
}

@(private = "file")
parse_unsigned_int :: proc(r: ^Json_Reader, key: bool) -> u64 {
	tok := scalar(r, key, .Parse_Unsigned_Int)
	if r.err != .None do return 0

	value, ok := strconv.parse_u64_of_base(tok, 10)
	if !ok do fail(r, .Parse_Unsigned_Int)
	return value
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
parse_enum :: proc(r: ^Json_Reader, info: runtime.Type_Info_Enum) -> i64 {
	if !skip_ws(r) do return 0

	tok: string
	if r.pos < len(r.src) && r.src[r.pos] == '"' {
		tok = quoted(r, .Parse_Enum)
		if r.err != .None do return 0

		for name, i in info.names {
			if name == tok do return i64(info.values[i])
		}
	} else {
		tok = token(r)
	}

	value, ok := strconv.parse_i64_of_base(tok, 10)
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

@(private = "file")
store_unsigned :: proc(r: ^Json_Reader, data: rawptr, size: int, value: u64) {
	if r.err != .None do return
	if size < 8 && value >> uint(size * 8) != 0 {
		fail(r, .Out_Of_Range)
		return
	}

	switch size {
	case 1:
		(^u8)(data)^ = u8(value)
	case 2:
		(^u16)(data)^ = u16(value)
	case 4:
		(^u32)(data)^ = u32(value)
	case 8:
		(^u64)(data)^ = value
	}
}

@(private = "file")
store_signed :: proc(r: ^Json_Reader, data: rawptr, size: int, value: i64) {
	if r.err != .None do return
	if size < 8 && value >> uint(size * 8 - 1) != 0 && value >> uint(size * 8 - 1) != -1 {
		fail(r, .Out_Of_Range)
		return
	}

	switch size {
	case 1:
		(^i8)(data)^ = i8(value)
	case 2:
		(^i16)(data)^ = i16(value)
	case 4:
		(^i32)(data)^ = i32(value)
	case 8:
		(^i64)(data)^ = value
	}
}
