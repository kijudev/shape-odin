package shape

import "base:runtime"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:unicode/utf16"
import "core:unicode/utf8"

Json_Writer_Error :: enum u8 {
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

// JSON syntax writer that parses a string into the walked value. It consumes the source in
// walk order, so struct fields must appear in declaration order. The first error sticks and
// turns every later step into a no-op, `pos` is left at the point of failure.
Json_Writer :: struct {
	using base: Visitor,
	src:        string,
	pos:        int,
	depth:      int,
	has_items:  bool,
	err:        Json_Writer_Error,
}

json_writer_init :: proc(w: ^Json_Writer, src: string, allocator := context.allocator) {
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

	w.src = src
	w.pos = 0
	w.depth = 0
	w.has_items = false
	w.err = .None
}

json_writer_reset :: proc(w: ^Json_Writer) {
	w.pos = 0
	w.depth = 0
	w.has_items = false
	w.err = .None
}

// >-------------------------------------------------------------------- Actions

json_writer_struct_begin :: proc(v: ^Visitor, name: string, info: ^runtime.Type_Info) -> bool {
	w := (^Json_Writer)(v)
	open(w, name, '{', .Parse_Struct)
	return w.err == .None
}

json_writer_struct_end :: proc(v: ^Visitor) {close((^Json_Writer)(v), '}', .Parse_Struct)}

json_writer_array_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	elem: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	w := (^Json_Writer)(v)
	open(w, name, '[', .Parse_Array)

	items := count_items(w)
	if fixed, ok := runtime.type_info_base(info).variant.(runtime.Type_Info_Array); ok {
		if items != fixed.count do fail(w, .Parse_Array)
	}

	count^ = items
	return w.err == .None
}

json_writer_array_end :: proc(v: ^Visitor) {close((^Json_Writer)(v), ']', .Parse_Array)}

json_writer_map_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	key: ^runtime.Type_Info,
	value: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	w := (^Json_Writer)(v)
	open(w, name, '{', .Parse_Map)

	count^ = count_items(w)
	return w.err == .None
}

json_writer_map_end :: proc(v: ^Visitor) {close((^Json_Writer)(v), '}', .Parse_Map)}

json_writer_string_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	w := (^Json_Writer)(v)
	prefix(w, name)
	if !expect(w, '"', .Parse_String) do return false

	length, _, ok := decode_string(w.src, w.pos, nil)
	if !ok do fail(w, .Parse_String)

	count^ = length
	return w.err == .None
}

json_writer_string_end :: proc(v: ^Visitor, bytes: []byte) {
	w := (^Json_Writer)(v)
	_, w.pos, _ = decode_string(w.src, w.pos, bytes)
}

json_writer_primitive :: proc(
	v: ^Visitor,
	name: string,
	data: rawptr,
	ti: ^runtime.Type_Info,
	tag: reflect.Struct_Tag,
) {
	w := (^Json_Writer)(v)
	// prefix clears the flag, a primitive map key arrives wrapped in quotes
	key := w.map_key
	prefix(w, name)

	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer:
		if info.signed {
			store_signed(w, data, ti.size, parse_signed_int(w, key))
		} else {
			store_unsigned(w, data, ti.size, parse_unsigned_int(w, key))
		}

	case runtime.Type_Info_Float:
		f := parse_float(w, key)
		if w.err != .None do return

		switch ti.size {
		case 2:
			(^f16)(data)^ = f16(f)
		case 4:
			(^f32)(data)^ = f32(f)
		case 8:
			(^f64)(data)^ = f
		}

	case runtime.Type_Info_Boolean:
		store_unsigned(w, data, ti.size, parse_bool(w, key) ? 1 : 0)

	case runtime.Type_Info_Enum:
		val := parse_enum(w, info)
		base := runtime.type_info_base(info.base)

		if bi, ok := base.variant.(runtime.Type_Info_Integer); ok && bi.signed {
			store_signed(w, data, base.size, val)
		} else {
			store_unsigned(w, data, base.size, u64(val))
		}

	case runtime.Type_Info_String:
		// Only non UTF-8 strings land here, walk sends the rest to string_begin
		if scalar(w, key, .Parse_String) != "null" do fail(w, .Parse_String)
	}
}

// >------------------------------------------------------------------ Utilities

@(private = "file")
fail :: proc(w: ^Json_Writer, err: Json_Writer_Error) {
	if w.err == .None do w.err = err
}

@(private = "file")
skip_ws :: proc(w: ^Json_Writer) -> bool {
	if w.err != .None do return false

	for w.pos < len(w.src) {
		c := w.src[w.pos]
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' do break
		w.pos += 1
	}

	return true
}

@(private = "file")
expect :: proc(w: ^Json_Writer, c: byte, err: Json_Writer_Error) -> bool {
	if !skip_ws(w) do return false

	if w.pos >= len(w.src) || w.src[w.pos] != c {
		fail(w, err)
		return false
	}

	w.pos += 1
	return true
}

@(private = "file")
token :: proc(w: ^Json_Writer) -> string {
	if !skip_ws(w) do return ""

	start := w.pos
	for w.pos < len(w.src) {
		switch w.src[w.pos] {
		case ' ', '\t', '\n', '\r', '{', '}', '[', ']', '"', ',', ':':
			return w.src[start:w.pos]
		}

		w.pos += 1
	}

	return w.src[start:w.pos]
}

// Raw contents of a quoted string without escapes, for field names, enum names and
// primitive map keys, which never need them.
@(private = "file")
quoted :: proc(w: ^Json_Writer, err: Json_Writer_Error) -> string {
	if !expect(w, '"', err) do return ""

	start := w.pos
	for w.pos < len(w.src) && w.src[w.pos] != '"' {
		if w.src[w.pos] == '\\' {
			fail(w, err)
			return ""
		}

		w.pos += 1
	}

	end := w.pos
	if !expect(w, '"', err) do return ""
	return w.src[start:end]
}

@(private = "file")
scalar :: proc(w: ^Json_Writer, key: bool, err: Json_Writer_Error) -> string {
	return key ? quoted(w, err) : token(w)
}

// Items are separated by commas at the container's own depth, a map entry is one item.
@(private = "file")
count_items :: proc(w: ^Json_Writer) -> int {
	if !skip_ws(w) do return 0
	if w.pos < len(w.src) && (w.src[w.pos] == ']' || w.src[w.pos] == '}') do return 0

	count, depth, i := 1, 0, w.pos

	for i < len(w.src) {
		switch w.src[i] {
		case '{', '[':
			depth += 1

		case '}', ']':
			if depth == 0 do return count
			depth -= 1

		case ',':
			if depth == 0 do count += 1

		case '"':
			i += 1

			for i < len(w.src) && w.src[i] != '"' {
				if w.src[i] == '\\' do i += 1
				i += 1
			}
		}

		i += 1
	}

	return count
}

@(private = "file")
prefix :: proc(w: ^Json_Writer, name: string) {
	if w.depth == 0 do return

	if w.map_value {
		w.map_value = false
		expect(w, ':', .Parse_Separator)
		return
	}

	w.map_key = false

	if w.has_items do expect(w, ',', .Parse_Separator)
	w.has_items = true

	if name == "" do return
	if quoted(w, .Parse_Field) != name do fail(w, .Parse_Field)
	expect(w, ':', .Parse_Separator)
}

@(private = "file")
open :: proc(w: ^Json_Writer, name: string, opener: byte, err: Json_Writer_Error) {
	prefix(w, name)
	expect(w, opener, err)

	w.depth += 1
	w.has_items = false
}

@(private = "file")
close :: proc(w: ^Json_Writer, closer: byte, err: Json_Writer_Error) {
	expect(w, closer, err)

	w.depth -= 1
	w.has_items = true
}

@(private = "file")
parse_signed_int :: proc(w: ^Json_Writer, key: bool) -> i64 {
	tok := scalar(w, key, .Parse_Signed_Int)
	if w.err != .None do return 0

	value, ok := strconv.parse_i64_of_base(tok, 10)
	if !ok do fail(w, .Parse_Signed_Int)
	return value
}

@(private = "file")
parse_unsigned_int :: proc(w: ^Json_Writer, key: bool) -> u64 {
	tok := scalar(w, key, .Parse_Unsigned_Int)
	if w.err != .None do return 0

	value, ok := strconv.parse_u64_of_base(tok, 10)
	if !ok do fail(w, .Parse_Unsigned_Int)
	return value
}

@(private = "file")
parse_float :: proc(w: ^Json_Writer, key: bool) -> f64 {
	tok := scalar(w, key, .Parse_Float)
	if w.err != .None do return 0
	if tok == "null" do return math.nan_f64()

	value, ok := strconv.parse_f64(tok)
	if !ok do fail(w, .Parse_Float)

	return value
}

@(private = "file")
parse_bool :: proc(w: ^Json_Writer, key: bool) -> bool {
	switch scalar(w, key, .Parse_Bool) {
	case "true":
		return true
	case "false":
		return false
	}

	fail(w, .Parse_Bool)
	return false
}

// Enums are names in quotes, or bare integers when the value has no named member. As a map
// key the integer is quoted too, so a quoted integer is accepted as well.
@(private = "file")
parse_enum :: proc(w: ^Json_Writer, info: runtime.Type_Info_Enum) -> i64 {
	if !skip_ws(w) do return 0

	tok: string
	if w.pos < len(w.src) && w.src[w.pos] == '"' {
		tok = quoted(w, .Parse_Enum)
		if w.err != .None do return 0

		for name, i in info.names {
			if name == tok do return i64(info.values[i])
		}
	} else {
		tok = token(w)
	}

	value, ok := strconv.parse_i64_of_base(tok, 10)
	if !ok do fail(w, .Parse_Enum)
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
store_unsigned :: proc(w: ^Json_Writer, data: rawptr, size: int, value: u64) {
	if w.err != .None do return
	if size < 8 && value >> uint(size * 8) != 0 {
		fail(w, .Out_Of_Range)
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
store_signed :: proc(w: ^Json_Writer, data: rawptr, size: int, value: i64) {
	if w.err != .None do return
	if size < 8 && value >> uint(size * 8 - 1) != 0 && value >> uint(size * 8 - 1) != -1 {
		fail(w, .Out_Of_Range)
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
