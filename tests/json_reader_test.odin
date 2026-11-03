package shape_tests

import "../shape"
import "core:math"
import "core:testing"

@(test)
json_reader_compact :: proc(t: ^testing.T) {
	Kind :: enum {
		Box,
		Capsule,
	}
	Thing :: struct {
		id:    int,
		name:  string,
		kind:  Kind,
		alive: bool,
		pos:   [2]f32,
	}

	thing := Thing{42, "a \"b\"\n", .Capsule, true, {1.5, -2}}
	out := shape.json_read(&thing)
	defer delete(out)

	testing.expect_value(
		t,
		out,
		`{"id":42,"name":"a \"b\"\n","kind":"Capsule","alive":true,"pos":[1.5,-2]}`,
	)
}

@(test)
json_reader_pretty :: proc(t: ^testing.T) {
	Inner :: struct {
		x: u8,
	}
	Outer :: struct {
		inner: Inner,
		pair:  [2]int,
	}

	outer := Outer{{7}, {1, 2}}
	out := shape.json_read(&outer, pretty = true, tabsize = 2)
	defer delete(out)

	testing.expect_value(t, out, "{\n  \"inner\": {\n    \"x\": 7\n  },\n  \"pair\": [1, 2]\n}")
}

@(test)
json_reader_map_keys_and_nan :: proc(t: ^testing.T) {
	Holder :: struct {
		m: map[int]bool,
		f: f32,
	}

	holder := Holder {
		f = math.inf_f32(1),
	}
	holder.m[5] = true
	defer delete(holder.m)

	out := shape.json_read(&holder)
	defer delete(out)

	testing.expect_value(t, out, `{"m":{"5":true},"f":null}`)
}
