package shape_tests

import "../shape"
import "core:math"
import "core:testing"

@(test)
json_writer_compact :: proc(t: ^testing.T) {
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
	out := shape.json_write(&thing)
	defer delete(out)

	testing.expect_value(
		t,
		out,
		`{"id":42,"name":"a \"b\"\n","kind":"Capsule","alive":true,"pos":[1.5,-2]}`,
	)
}

@(test)
json_writer_pretty :: proc(t: ^testing.T) {
	Inner :: struct {
		x: u8,
	}
	Outer :: struct {
		inner: Inner,
		pair:  [2]int,
	}

	outer := Outer{{7}, {1, 2}}
	out := shape.json_write(&outer, pretty = true, tabsize = 2)
	defer delete(out)

	testing.expect_value(t, out, "{\n  \"inner\": {\n    \"x\": 7\n  },\n  \"pair\": [1, 2]\n}")
}

@(test)
json_writer_map_keys_and_nan :: proc(t: ^testing.T) {
	Holder :: struct {
		m: map[int]bool,
		f: f32,
	}

	holder := Holder {
		f = math.inf_f32(1),
	}
	holder.m[5] = true
	defer delete(holder.m)

	out := shape.json_write(&holder)
	defer delete(out)

	testing.expect_value(t, out, `{"m":{"5":true},"f":null}`)
}

@(test)
json_writer_bits_and_unions :: proc(t: ^testing.T) {
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
		int,
	}
	Flags :: bit_field u16 {
		level: u8   | 4,
		delta: i8   | 4,
		kind:  Kind | 2,
		on:    bool | 1,
	}
	Thing :: struct {
		kinds:  bit_set[Kind],
		digits: bit_set[0 ..< 10],
		chars:  bit_set['a' ..= 'z'],
		flags:  Flags,
		a:      Shape,
		b:      Shape,
		c:      Shape,
	}

	thing := Thing {
		kinds  = {.Box, .Capsule},
		digits = {1, 9},
		chars  = {'c'},
		flags  = {level = 15, delta = -3, kind = .Sphere, on = true},
		a      = Circle{0.5},
		b      = 7,
	}
	out := shape.json_write(&thing)
	defer delete(out)

	testing.expect_value(
		t,
		out,
		`{"kinds":["Box","Capsule"],"digits":[1,9],"chars":["c"],` +
		`"flags":{"level":15,"delta":-3,"kind":"Sphere","on":true},` +
		`"a":{"Circle":{"r":0.5}},"b":{"int":7},"c":null}`,
	)
}
