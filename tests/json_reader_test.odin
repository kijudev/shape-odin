package shape_tests

import "../shape"
import "core:testing"
import "core:unicode/utf8"

@(test)
json_reader_parse :: proc(t: ^testing.T) {
	Kind :: enum {
		Box,
		Capsule,
	}
	Thing :: struct {
		id:    i32,
		name:  string,
		kind:  Kind,
		pos:   [2]f32,
		tags:  []string,
		count: map[int]u8,
	}

	src := `{
		"id": -3,
		"name": "a \"b\"\né",
		"kind": "Capsule",
		"pos": [1.5, -2],
		"tags": ["x", "y"],
		"count": {"4": 9}
	}`

	thing: Thing
	err, pos := shape.json_read(&thing, src, context.temp_allocator)

	testing.expect_value(t, err, shape.Json_Reader_Error.None)
	testing.expect_value(t, pos, len(src))
	testing.expect_value(t, thing.id, -3)
	testing.expect_value(t, thing.name, "a \"b\"\né")
	testing.expect_value(t, thing.kind, Kind.Capsule)
	testing.expect_value(t, thing.pos, [2]f32{1.5, -2})
	testing.expect_value(t, len(thing.tags), 2)
	testing.expect_value(t, thing.tags[1], "y")
	testing.expect_value(t, thing.count[4], 9)
}

@(test)
json_reader_roundtrip :: proc(t: ^testing.T) {
	Kind :: enum {
		Box,
		Capsule,
	}
	Inner :: struct {
		kind:  Kind,
		scale: f64,
	}
	Thing :: struct {
		a:     int,
		b:     bool,
		c:     string,
		inner: Inner,
		list:  [dynamic]Inner,
		empty: []int,
		table: map[string][]u16,
	}

	thing := Thing {
		a     = -1,
		b     = true,
		c     = "tab\tquote\"",
		inner = {.Capsule, 0.25},
	}
	append(&thing.list, Inner{.Box, 1}, Inner{.Capsule, -2.5})
	defer delete(thing.list)
	values := []u16{1, 65535}
	thing.table["v"] = values
	defer delete(thing.table)

	for pretty in ([]bool{false, true}) {
		out := shape.json_write(&thing, pretty = pretty)
		defer delete(out)

		back: Thing
		err, pos := shape.json_read(&back, out, context.temp_allocator)

		testing.expect_value(t, err, shape.Json_Reader_Error.None)
		testing.expect_value(t, pos, len(out))
		testing.expect_value(t, back.a, thing.a)
		testing.expect_value(t, back.b, thing.b)
		testing.expect_value(t, back.c, thing.c)
		testing.expect_value(t, back.inner, thing.inner)
		testing.expect_value(t, len(back.list), 2)
		testing.expect_value(t, back.list[1], thing.list[1])
		testing.expect_value(t, len(back.empty), 0)
		testing.expect_value(t, len(back.table), 1)
		testing.expect_value(t, len(back.table["v"]), 2)
		testing.expect_value(t, back.table["v"][1], 65535)
	}
}

@(test)
json_reader_errors :: proc(t: ^testing.T) {
	Small :: struct {
		a: u8,
		b: u8,
	}
	Fixed :: struct {
		v: [3]int,
	}

	small: Small
	fixed: Fixed

	err, _ := shape.json_read(&small, `{"b":1,"a":2}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Parse_Field)

	err, _ = shape.json_read(&small, `{"a":1 "b":2}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Parse_Separator)

	err, _ = shape.json_read(&small, `{"a":256,"b":0}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Out_Of_Range)

	err, _ = shape.json_read(&small, `{"a":true,"b":0}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Parse_Unsigned_Int)

	err, _ = shape.json_read(&fixed, `{"v":[1,2]}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Parse_Array)
}

@(test)
json_reader_bits_and_unions :: proc(t: ^testing.T) {
	Kind :: enum u8 {
		Box,
		Sphere,
		Capsule,
	}
	Circle :: struct {
		r: f32,
	}
	Shape :: union {
		Circle,
		[]string,
	}
	Strict :: union #no_nil {
		int,
		bool,
	}
	Flags :: bit_field u16 {
		level: u8   | 4,
		delta: i8   | 4,
		kind:  Kind | 2,
		on:    bool | 1,
	}
	Thing :: struct {
		kinds:  bit_set[Kind; u8],
		digits: bit_set[-2 ..= 70],
		chars:  bit_set['a' ..= 'z'],
		flags:  Flags,
		a:      Shape,
		b:      Shape,
		c:      Shape,
		d:      Strict,
		shapes: map[string]Shape,
	}

	thing := Thing {
		kinds  = {.Sphere},
		digits = {-2, 0, 70},
		chars  = {'a', 'z'},
		flags  = {level = 9, delta = -8, kind = .Capsule, on = false},
		a      = Circle{2},
		b      = []string{"x"},
		d      = false,
	}
	thing.shapes["round"] = Circle{1}
	thing.shapes["none"] = nil
	defer delete(thing.shapes)

	for pretty in ([]bool{false, true}) {
		out := shape.json_write(&thing, pretty = pretty)
		defer delete(out)

		back: Thing
		err, pos := shape.json_read(&back, out, context.temp_allocator)

		testing.expect_value(t, err, shape.Json_Reader_Error.None)
		testing.expect_value(t, pos, len(out))
		testing.expect_value(t, back.kinds, thing.kinds)
		testing.expect_value(t, back.digits, thing.digits)
		testing.expect_value(t, back.chars, thing.chars)
		testing.expect_value(t, back.flags, thing.flags)
		testing.expect_value(t, back.a.(Circle), Circle{2})
		testing.expect_value(t, back.b.([]string)[0], "x")
		testing.expect(t, back.c == nil)
		testing.expect_value(t, back.d.(bool), false)
		testing.expect_value(t, len(back.shapes), 2)
		testing.expect_value(t, back.shapes["round"].(Circle), Circle{1})
		testing.expect(t, back.shapes["none"] == nil)
	}
}

@(test)
json_reader_bits_and_unions_errors :: proc(t: ^testing.T) {
	Kind :: enum {
		Box,
		Capsule,
	}
	Bits :: struct {
		digits: bit_set[0 ..< 4],
	}
	Flags :: bit_field u8 {
		level: u8 | 3,
		delta: i8 | 3,
	}
	Packed :: struct {
		flags: Flags,
	}
	Shape :: union {
		int,
		Kind,
	}
	Strict :: union #no_nil {
		int,
		bool,
	}
	Holder :: struct {
		s: Shape,
	}
	Strict_Holder :: struct {
		s: Strict,
	}
	Letter :: struct {
		c: rune,
	}

	bits: Bits
	packed: Packed
	holder: Holder
	strict: Strict_Holder
	letter: Letter

	err, _ := shape.json_read(&bits, `{"digits":[1,4]}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Out_Of_Range)

	err, _ = shape.json_read(&packed, `{"flags":{"level":8,"delta":0}}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Out_Of_Range)

	err, _ = shape.json_read(&packed, `{"flags":{"level":0,"delta":-5}}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Out_Of_Range)

	err, _ = shape.json_read(&packed, `{"flags":{"level":7,"delta":-4}}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.None)
	testing.expect_value(t, packed.flags.level, 7)
	testing.expect_value(t, packed.flags.delta, -4)

	err, _ = shape.json_read(&holder, `{"s":{"Kind":"Capsule"}}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.None)
	testing.expect_value(t, holder.s.(Kind), Kind.Capsule)

	err, _ = shape.json_read(&holder, `{"s":{"f32":1}}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Parse_Union)

	err, _ = shape.json_read(&holder, `{"s":5}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Parse_Union)

	err, _ = shape.json_read(&strict, `{"s":null}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Parse_Union)

	err, _ = shape.json_read(&letter, `{"c":"ab"}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Parse_Rune)

	err, _ = shape.json_read(&letter, `{"c":"é"}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.None)
	testing.expect_value(t, letter.c, 'é')

	err, _ = shape.json_read(&letter, `{"c":"\ufffd"}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.None)
	testing.expect_value(t, letter.c, utf8.RUNE_ERROR)
}
