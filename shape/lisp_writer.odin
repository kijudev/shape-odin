package shape

import "base:runtime"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Lisp_Writer_Error :: enum u8 {
	None,
	Parse_Field,
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

// S-expression syntax writer that parses a string into the walked value. It consumes
// the source in walk order, the first error sticks and turns every later step into a no-op,
// `pos` is left at the point of failure.
Lisp_Writer :: struct {
	using base: Visitor,
	src:        string,
	pos:        int,
	depth:      int,
	err:        Lisp_Writer_Error,
}

lisp_writer_init :: proc(w: ^Lisp_Writer, src: string, allocator := context.allocator) {
	w.base = Visitor {
		mode         = .Write,
		struct_begin = lisp_writer_struct_begin,
		struct_end   = lisp_writer_struct_end,
		array_begin  = lisp_writer_array_begin,
		array_end    = lisp_writer_array_end,
		map_begin    = lisp_writer_map_begin,
		map_end      = lisp_writer_map_end,
		string_begin = lisp_writer_string_begin,
		string_end   = lisp_writer_string_end,
		primitive    = lisp_writer_primitive,
		allocator    = allocator,
	}

	w.src = src
	w.pos = 0
	w.depth = 0
	w.err = .None
}

lisp_writer_reset :: proc(w: ^Lisp_Writer) {
	w.pos = 0
	w.depth = 0
	w.err = .None
}

// >-------------------------------------------------------------------- Actions

lisp_writer_struct_begin :: proc(v: ^Visitor, name: string, info: ^runtime.Type_Info) -> bool {
	w := (^Lisp_Writer)(v)

	field(w, name)
	expect(w, '(', .Parse_Struct)
	w.depth += 1

	return w.err == .None
}

lisp_writer_struct_end :: proc(v: ^Visitor) {
	w := (^Lisp_Writer)(v)
	expect(w, ')', .Parse_Struct)
	w.depth -= 1
}

lisp_writer_array_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	elem: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	w := (^Lisp_Writer)(v)
	field(w, name)
	expect(w, '[', .Parse_Array)
	w.depth += 1

	items := count_items(w)
	if fixed, ok := runtime.type_info_base(info).variant.(runtime.Type_Info_Array); ok {
		if items != fixed.count do fail(w, .Parse_Array)
	}

	count^ = items
	return w.err == .None
}

lisp_writer_array_end :: proc(v: ^Visitor) {
	w := (^Lisp_Writer)(v)
	expect(w, ']', .Parse_Array)
	w.depth -= 1
}

lisp_writer_map_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	key: ^runtime.Type_Info,
	value: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	w := (^Lisp_Writer)(v)
	field(w, name)
	expect(w, '{', .Parse_Map)
	w.depth += 1

	items := count_items(w)
	if items % 2 != 0 do fail(w, .Parse_Map)

	count^ = items / 2
	return w.err == .None
}

lisp_writer_map_end :: proc(v: ^Visitor) {
	w := (^Lisp_Writer)(v)
	expect(w, '}', .Parse_Map)
	w.depth -= 1
}

lisp_writer_string_begin :: proc(
	v: ^Visitor,
	name: string,
	info: ^runtime.Type_Info,
	count: ^int,
) -> bool {
	w := (^Lisp_Writer)(v)
	field(w, name)
	if !expect(w, '"', .Parse_String) do return false

	length, _, ok := decode_string(w.src, w.pos, nil)
	if !ok do fail(w, .Parse_String)

	count^ = length
	return w.err == .None
}

lisp_writer_string_end :: proc(v: ^Visitor, bytes: []byte) {
	w := (^Lisp_Writer)(v)
	_, w.pos, _ = decode_string(w.src, w.pos, bytes)
}

lisp_writer_primitive :: proc(
	v: ^Visitor,
	name: string,
	data: rawptr,
	ti: ^runtime.Type_Info,
	tag: reflect.Struct_Tag,
) {
	w := (^Lisp_Writer)(v)
	field(w, name)

	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer:
		if info.signed {
			store_signed(w, data, ti.size, parse_signed_int(w))
		} else {
			store_unsigned(w, data, ti.size, parse_unsigned_int(w))
		}

	case runtime.Type_Info_Float:
		f := parse_float(w)
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
		store_unsigned(w, data, ti.size, parse_bool(w) ? 1 : 0)

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
		if token(w) != "nil" do fail(w, .Parse_String)
	}
}

// >------------------------------------------------------------------ Utilities

@(private = "file")
fail :: proc(w: ^Lisp_Writer, err: Lisp_Writer_Error) {
	if w.err == .None do w.err = err
}

@(private = "file")
skip_ws :: proc(w: ^Lisp_Writer) -> bool {
	if w.err != .None do return false

	for w.pos < len(w.src) {
		c := w.src[w.pos]
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' do break
		w.pos += 1
	}

	return true
}

@(private = "file")
expect :: proc(w: ^Lisp_Writer, c: byte, err: Lisp_Writer_Error) -> bool {
	if !skip_ws(w) do return false

	if w.pos >= len(w.src) || w.src[w.pos] != c {
		fail(w, err)
		return false
	}

	w.pos += 1
	return true
}

@(private = "file")
token :: proc(w: ^Lisp_Writer) -> string {
	if !skip_ws(w) do return ""

	start := w.pos
	for w.pos < len(w.src) {
		switch w.src[w.pos] {
		case ' ', '\t', '\n', '\r', '(', ')', '[', ']', '{', '}', '"':
			return w.src[start:w.pos]
		}

		w.pos += 1
	}

	return w.src[start:w.pos]
}

@(private = "file")
count_items :: proc(w: ^Lisp_Writer) -> int {
	if w.err != .None do return 0

	count, depth, i := 0, 0, w.pos

	for i < len(w.src) {
		switch w.src[i] {
		case ' ', '\t', '\n', '\r':
			i += 1

		case '(', '[', '{':
			if depth == 0 do count += 1
			depth += 1
			i += 1

		case ')', ']', '}':
			if depth == 0 do return count
			depth -= 1
			i += 1

		case '"':
			if depth == 0 do count += 1
			i += 1

			for i < len(w.src) && w.src[i] != '"' {
				if w.src[i] == '\\' do i += 1
				i += 1
			}

			i += 1

		case:
			if depth == 0 do count += 1

			token: for i < len(w.src) {
				switch w.src[i] {
				case ' ', '\t', '\n', '\r', '(', ')', '[', ']', '{', '}', '"':
					break token
				}

				i += 1
			}
		}
	}

	return count
}

@(private = "file")
field :: proc(w: ^Lisp_Writer, name: string) {
	if w.depth == 0 || name == "" do return
	if token(w) != name do fail(w, .Parse_Field)
}

@(private = "file")
parse_signed_int :: proc(w: ^Lisp_Writer) -> i64 {
	tok := token(w)
	if w.err != .None do return 0

	value, ok := strconv.parse_i64_of_base(tok, 10)
	if !ok do fail(w, .Parse_Signed_Int)
	return value
}

@(private = "file")
parse_unsigned_int :: proc(w: ^Lisp_Writer) -> u64 {
	tok := token(w)
	if w.err != .None do return 0

	value, ok := strconv.parse_u64_of_base(tok, 10)
	if !ok do fail(w, .Parse_Unsigned_Int)
	return value
}

@(private = "file")
parse_float :: proc(w: ^Lisp_Writer) -> f64 {
	tok := token(w)
	if w.err != .None do return 0
	if tok == "nil" do return math.nan_f64()

	value, ok := strconv.parse_f64(tok)
	if !ok do fail(w, .Parse_Float)

	return value
}

@(private = "file")
parse_bool :: proc(w: ^Lisp_Writer) -> bool {
	switch token(w) {
	case "true":
		return true
	case "false":
		return false
	}

	fail(w, .Parse_Bool)
	return false
}

@(private = "file")
parse_enum :: proc(w: ^Lisp_Writer, info: runtime.Type_Info_Enum) -> i64 {
	tok := token(w)
	if w.err != .None do return 0

	if !strings.has_prefix(tok, "'") {
		value, ok := strconv.parse_i64_of_base(tok, 10)
		if !ok do fail(w, .Parse_Enum)
		return value
	}

	for name, i in info.names {
		if name == tok[1:] do return i64(info.values[i])
	}

	fail(w, .Parse_Enum)
	return 0
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
			case '"', '\\':
				c = e
			case 'n':
				c = '\n'
			case 'r':
				c = '\r'
			case 't':
				c = '\t'
			case 'u':
				if i + 4 > len(src) do return
				code, hex_ok := strconv.parse_u64_of_base(src[i:i + 4], 16)
				if !hex_ok do return
				i += 4

				bytes, n := utf8.encode_rune(rune(code))
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
store_unsigned :: proc(w: ^Lisp_Writer, data: rawptr, size: int, value: u64) {
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
store_signed :: proc(w: ^Lisp_Writer, data: rawptr, size: int, value: i64) {
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
