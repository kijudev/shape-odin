package shape_tests

import "../shape"
import "core:testing"

@(test)
lisp_writer_parse :: proc(t: ^testing.T) {
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
		count: map[string]u8,
	}

	src := `(
		id -3
		name "a \"b\"\n"
		kind 'Capsule
		pos [1.5 -2]
		tags ["x" "y"]
		count {"k" 9}
	)`

	thing: Thing
	err, pos := shape.lisp_write(&thing, src, context.temp_allocator)

	testing.expect_value(t, err, shape.Lisp_Writer_Error.None)
	testing.expect_value(t, pos, len(src))
	testing.expect_value(t, thing.id, -3)
	testing.expect_value(t, thing.name, "a \"b\"\n")
	testing.expect_value(t, thing.kind, Kind.Capsule)
	testing.expect_value(t, thing.pos, [2]f32{1.5, -2})
	testing.expect_value(t, len(thing.tags), 2)
	testing.expect_value(t, thing.tags[1], "y")
	testing.expect_value(t, thing.count["k"], 9)
}

@(test)
lisp_writer_roundtrip :: proc(t: ^testing.T) {
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
		out := shape.lisp_read(&thing, pretty = pretty)
		defer delete(out)

		back: Thing
		err, pos := shape.lisp_write(&back, out, context.temp_allocator)

		testing.expect_value(t, err, shape.Lisp_Writer_Error.None)
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
lisp_writer_errors :: proc(t: ^testing.T) {
	Small :: struct {
		a: u8,
	}
	Fixed :: struct {
		v: [3]int,
	}

	small: Small
	fixed: Fixed

	err, pos := shape.lisp_write(&small, `(b 1)`, context.temp_allocator)
	testing.expect_value(t, err, shape.Lisp_Writer_Error.Parse_Field)
	testing.expect_value(t, pos, 2)

	err, _ = shape.lisp_write(&small, `(a 300)`, context.temp_allocator)
	testing.expect_value(t, err, shape.Lisp_Writer_Error.Out_Of_Range)

	err, _ = shape.lisp_write(&small, `(a x)`, context.temp_allocator)
	testing.expect_value(t, err, shape.Lisp_Writer_Error.Parse_Unsigned_Int)

	err, _ = shape.lisp_write(&fixed, `(v [1 2])`, context.temp_allocator)
	testing.expect_value(t, err, shape.Lisp_Writer_Error.Parse_Array)

	err, _ = shape.lisp_write(&small, `(a 1`, context.temp_allocator)
	testing.expect_value(t, err, shape.Lisp_Writer_Error.Parse_Struct)
}
