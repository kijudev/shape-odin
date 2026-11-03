package shape_tests

import "../shape"
import "core:testing"

@(test)
json_writer_parse :: proc(t: ^testing.T) {
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
	err, pos := shape.json_write(&thing, src, context.temp_allocator)

	testing.expect_value(t, err, shape.Json_Writer_Error.None)
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
json_writer_roundtrip :: proc(t: ^testing.T) {
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
		out := shape.json_read(&thing, pretty = pretty)
		defer delete(out)

		back: Thing
		err, pos := shape.json_write(&back, out, context.temp_allocator)

		testing.expect_value(t, err, shape.Json_Writer_Error.None)
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
json_writer_errors :: proc(t: ^testing.T) {
	Small :: struct {
		a: u8,
		b: u8,
	}
	Fixed :: struct {
		v: [3]int,
	}

	small: Small
	fixed: Fixed

	err, _ := shape.json_write(&small, `{"b":1,"a":2}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Writer_Error.Parse_Field)

	err, _ = shape.json_write(&small, `{"a":1 "b":2}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Writer_Error.Parse_Separator)

	err, _ = shape.json_write(&small, `{"a":256,"b":0}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Writer_Error.Out_Of_Range)

	err, _ = shape.json_write(&small, `{"a":true,"b":0}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Writer_Error.Parse_Unsigned_Int)

	err, _ = shape.json_write(&fixed, `{"v":[1,2]}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Writer_Error.Parse_Array)
}
