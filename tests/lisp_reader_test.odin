package shape_tests

import "../shape"
import "core:math"
import "core:testing"

@(test)
lisp_reader_compact :: proc(t: ^testing.T) {
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
	out := shape.lisp_read(&thing)
	defer delete(out)

	testing.expect_value(t, out, `(id 42 name "a \"b\"\n" kind 'Capsule alive true pos [1.5 -2])`)
}

@(test)
lisp_reader_pretty :: proc(t: ^testing.T) {
	Inner :: struct {
		x: u8,
	}
	Outer :: struct {
		inner: Inner,
		quad:  [4]int,
		items: []int,
	}

	items := []int{1, 2, 3, 4, 5}
	outer := Outer{{7}, {1, 2, 3, 4}, items}
	out := shape.lisp_read(&outer, pretty = true, tabsize = 2)
	defer delete(out)

	testing.expect_value(
		t,
		out,
		"(\n  inner (\n    x 7\n  )\n  quad [1 2 3 4]\n  items [\n    1\n    2\n    3\n    4\n    5\n  ]\n)",
	)
}

@(test)
lisp_reader_map_and_nan :: proc(t: ^testing.T) {
	Holder :: struct {
		m: map[string]int,
		f: f64,
	}

	holder := Holder {
		f = math.nan_f64(),
	}
	holder.m["k"] = 3
	defer delete(holder.m)

	out := shape.lisp_read(&holder)
	defer delete(out)

	testing.expect_value(t, out, `(m {"k" 3} f nil)`)
}
