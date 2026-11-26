package shape_tests

import "../shape"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:testing"

@(test)
node_struct_fields :: proc(t: ^testing.T) {
	Thing :: struct {
		a:       int,
		hidden:  int `shape:"skip"`,
		b:       string `meta:"x"`,
		pointer: ^int,
	}

	thing := Thing{1, 2, "b", nil}
	root := shape.node_of(&thing)

	testing.expect_value(t, root.kind, shape.Kind.Struct)
	testing.expect_value(t, root.index, -1)
	testing.expect_value(t, shape.field_count(root), 4)

	names: [dynamic]string
	defer delete(names)

	it := 0
	for f in shape.iterate_fields(root, &it) do append(&names, f.name)
	testing.expect_value(t, len(names), 3)
	testing.expect_value(t, names[1], "b")

	b := shape.field(root, 2)
	testing.expect_value(t, b.index, 2)
	testing.expect_value(t, b.tag, `meta:"x"`)
	testing.expect_value(t, shape.get_string(b), "b")
	testing.expect_value(t, shape.field(root, 3).kind, shape.Kind.Invalid)
	testing.expect_value(t, shape.field(root, 9).kind, shape.Kind.Invalid)

	shape.set_int(shape.field(root, 0), 42)
	testing.expect_value(t, thing.a, 42)

	shape.set_string(b, "changed", context.temp_allocator)
	testing.expect_value(t, thing.b, "changed")
}

@(test)
node_scalars :: proc(t: ^testing.T) {
	Kind :: enum u8 {
		Box,
		Capsule,
	}
	Thing :: struct {
		small: i8,
		big:   u128,
		be:    u32be,
		kind:  Kind,
		f:     f16,
		c:     cstring,
	}

	thing: Thing
	root := shape.node_of(&thing)
	small, big, be := shape.field(root, 0), shape.field(root, 1), shape.field(root, 2)

	testing.expect(t, shape.set_int(small, -128))
	testing.expect(t, !shape.set_int(small, 128))
	testing.expect_value(t, thing.small, -128)

	// u128 values above the i128 range go in with the same bits
	testing.expect(t, shape.set_int(big, -1))
	testing.expect_value(t, thing.big, max(u128))

	testing.expect(t, shape.set_int(be, 0x01020304))
	testing.expect_value(t, thing.be, 0x01020304)
	testing.expect_value(t, shape.get_int(be), 0x01020304)

	testing.expect(t, !shape.set_int(shape.field(root, 3), 256))
	name, ok := shape.enum_name(shape.field(root, 3).info, 1)
	testing.expect(t, ok)
	testing.expect_value(t, name, "Capsule")

	shape.set_float(shape.field(root, 4), 0.5)
	testing.expect_value(t, thing.f, 0.5)

	shape.set_string(shape.field(root, 5), "c", context.temp_allocator)
	testing.expect_value(t, thing.c, "c")

	// Full range integers and the other byte order survive JSON
	out := shape.json_write(&thing)
	defer delete(out)

	back: Thing
	err, _ := shape.json_read(&back, out, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.None)
	testing.expect_value(t, back.big, max(u128))
	testing.expect_value(t, back.be, thing.be)
}

@(test)
node_bits :: proc(t: ^testing.T) {
	Kind :: enum u8 {
		Box,
		Sphere,
		Capsule,
	}
	Flags :: bit_field u16 {
		level: u8   | 4,
		delta: i8   | 4,
		kind:  Kind | 2,
	}
	Thing :: struct {
		flags: Flags,
		kinds: bit_set[Kind],
	}

	thing := Thing {
		flags = {level = 3, delta = -2, kind = .Sphere},
	}
	root := shape.node_of(&thing)
	flags, kinds := shape.field(root, 0), shape.field(root, 1)

	testing.expect_value(t, flags.kind, shape.Kind.Struct)
	delta := shape.field(flags, 1)
	testing.expect_value(t, shape.get_int(delta), -2)
	testing.expect(t, !shape.set_int(delta, 8))
	testing.expect(t, shape.set_int(delta, -8))
	testing.expect_value(t, thing.flags.delta, -8)
	// Neighbours keep their bits
	testing.expect_value(t, thing.flags.level, 3)
	testing.expect_value(t, thing.flags.kind, Kind.Sphere)

	testing.expect_value(t, shape.length(kinds), 3)
	capsule := shape.elem(kinds, 2)
	testing.expect_value(t, capsule.kind, shape.Kind.Bool)
	testing.expect_value(t, capsule.name, "Capsule")
	shape.set_bool(capsule, true)
	testing.expect_value(t, thing.kinds, bit_set[Kind]{.Capsule})
	testing.expect(t, shape.get_bool(capsule))
	testing.expect_value(t, shape.elem(kinds, 3).kind, shape.Kind.Invalid)
}

@(test)
node_arrays :: proc(t: ^testing.T) {
	Kind :: enum {
		Box,
		Capsule,
	}
	Thing :: struct {
		dyn:   [dynamic]int,
		sl:    []int,
		fixed: [dynamic; 3]int,
		named: [Kind]f32,
	}

	thing: Thing
	thing.dyn.allocator = context.temp_allocator
	root := shape.node_of(&thing)
	dyn, sl, fixed, named := shape.field(root, 0), shape.field(root, 1), shape.field(root, 2), shape.field(root, 3)

	testing.expect(t, shape.resize(dyn, 2))
	shape.set_int(shape.elem(dyn, 0), 1)
	shape.set_int(shape.elem(dyn, 1), 3)
	testing.expect(t, shape.insert_elem(dyn, 1))
	shape.set_int(shape.elem(dyn, 1), 2)
	testing.expect_value(t, len(thing.dyn), 3)
	testing.expect_value(t, thing.dyn[2], 3)
	testing.expect(t, shape.remove_elem(dyn, 0))
	testing.expect_value(t, thing.dyn[0], 2)
	testing.expect_value(t, len(thing.dyn), 2)

	testing.expect(t, shape.resize(sl, 2, context.temp_allocator))
	shape.set_int(shape.elem(sl, 1), 7)
	testing.expect(t, shape.resize(sl, 3, context.temp_allocator))
	testing.expect_value(t, thing.sl[1], 7)
	testing.expect_value(t, thing.sl[2], 0)

	testing.expect(t, shape.is_resizable(fixed))
	testing.expect(t, shape.resize(fixed, 3))
	testing.expect(t, !shape.resize(fixed, 4))
	testing.expect_value(t, len(thing.fixed), 3)

	testing.expect(t, !shape.is_resizable(named))
	testing.expect_value(t, shape.length(named), 2)
	testing.expect_value(t, shape.elem(named, 1).name, "Capsule")
	shape.set_float(shape.elem(named, 1), 2.5)
	testing.expect_value(t, thing.named[.Capsule], 2.5)

	out := shape.json_write(&thing)
	defer delete(out)
	testing.expect_value(t, out, `{"dyn":[2,3],"sl":[0,7,0],"fixed":[0,0,0],"named":[0,2.5]}`)

	back: Thing
	err, _ := shape.json_read(&back, out, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.None)
	testing.expect_value(t, back.dyn[1], 3)
	testing.expect_value(t, len(back.fixed), 3)
	testing.expect_value(t, back.named[.Capsule], 2.5)

	err, _ = shape.json_read(&back, `{"dyn":[],"sl":[],"fixed":[1,2,3,4],"named":[0,0]}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Parse_Array)
}

@(test)
node_maps :: proc(t: ^testing.T) {
	scores: map[string]int
	defer delete(scores)
	scores["a"] = 1
	scores["b"] = 2

	root := shape.node_of(&scores)
	testing.expect_value(t, shape.length(root), 2)

	sum, keys := 0, 0
	it := 0
	for key, value in shape.iterate_map(root, &it) {
		testing.expect(t, key.is_key)
		testing.expect_value(t, key.index, value.index)
		sum += int(shape.get_int(value))
		keys += 1
	}
	testing.expect_value(t, sum, 3)
	testing.expect_value(t, keys, 2)

	key := "c"
	stored := shape.map_insert(root, &key, nil)
	testing.expect_value(t, stored.kind, shape.Kind.Int)
	shape.set_int(stored, 5)
	testing.expect_value(t, scores["c"], 5)

	found, ok := shape.map_find(root, &key)
	testing.expect(t, ok)
	testing.expect_value(t, shape.get_int(found), 5)

	testing.expect(t, shape.map_remove(root, &key))
	testing.expect(t, !shape.map_remove(root, &key))
	testing.expect_value(t, len(scores), 2)
}

@(test)
node_unions :: proc(t: ^testing.T) {
	Circle :: struct {
		r: f32,
	}
	Shape :: union {
		Circle,
		int,
	}
	Strict :: union #no_nil {
		int,
		bool,
	}
	Thing :: struct {
		s:      Shape,
		strict: Strict,
	}

	thing := Thing{Circle{1}, 5}
	root := shape.node_of(&thing)
	s, strict := shape.field(root, 0), shape.field(root, 1)

	index, payload := shape.variant(s)
	testing.expect_value(t, index, 0)
	testing.expect_value(t, payload.name, "s")
	testing.expect_value(t, payload.kind, shape.Kind.Struct)
	testing.expect(t, shape.allows_nil(s))

	buffer: [64]byte
	testing.expect_value(t, shape.variant_count(s), 2)
	testing.expect_value(t, shape.variant_name(s, 0, buffer[:]), "Circle")
	testing.expect_value(t, shape.variant_name(s, 1, buffer[:]), "int")

	payload, _ = shape.set_variant(s, 1)
	shape.set_int(payload, 9)
	testing.expect_value(t, thing.s.(int), 9)

	_, ok := shape.set_variant(s, -1)
	testing.expect(t, ok)
	testing.expect(t, thing.s == nil)
	index, payload = shape.variant(s)
	testing.expect_value(t, index, -1)
	testing.expect_value(t, payload.kind, shape.Kind.Invalid)

	testing.expect(t, !shape.allows_nil(strict))
	_, ok = shape.set_variant(strict, -1)
	testing.expect(t, !ok)
	_, ok = shape.set_variant(strict, 2)
	testing.expect(t, !ok)
	testing.expect_value(t, thing.strict.(int), 5)
}

@(test)
node_unsupported_json :: proc(t: ^testing.T) {
	Thing :: struct {
		a: int,
		p: ^int,
	}

	value := 3
	thing := Thing{1, &value}
	out := shape.json_write(&thing)
	defer delete(out)
	testing.expect_value(t, out, `{"a":1,"p":null}`)

	back: Thing
	err, _ := shape.json_read(&back, out, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.None)
	testing.expect_value(t, back.a, 1)

	err, _ = shape.json_read(&back, `{"a":1,"p":3}`, context.temp_allocator)
	testing.expect_value(t, err, shape.Json_Reader_Error.Parse_Null)
}

@(test)
json_overrides :: proc(t: ^testing.T) {
	Color :: distinct [4]u8
	Thing :: struct {
		tint:  Color,
		ratio: f32 `json:"percent"`,
	}

	// Colors as "#rrggbbaa" strings, picked by type
	write_color :: proc(w: ^shape.Json_Writer, n: shape.Node) -> bool {
		if n.info.id != Color do return false

		c := (^Color)(n.data)^
		hex := fmt.tprintf("#%02x%02x%02x%02x", c.r, c.g, c.b, c.a)
		shape.json_write_node(w, shape.node_of(&hex))
		return true
	}

	read_color :: proc(r: ^shape.Json_Reader, n: shape.Node) -> bool {
		if n.info.id != Color do return false

		hex: string
		shape.json_read_node(r, shape.node_of(&hex))
		c := (^Color)(n.data)
		for i in 0 ..< 4 {
			value, _ := strconv.parse_u64_of_base(hex[1 + i * 2:][:2], 16)
			c[i] = u8(value)
		}
		return true
	}

	thing := Thing{{255, 128, 0, 255}, 0.25}

	w: shape.Json_Writer
	shape.json_writer_init(&w)
	defer shape.json_writer_destroy(&w)
	w.override = write_color
	shape.json_write_node(&w, shape.node_of(&thing))
	out := shape.json_writer_string(&w)
	testing.expect_value(t, out, `{"tint":"#ff8000ff","ratio":0.25}`)

	back: Thing
	r: shape.Json_Reader
	shape.json_reader_init(&r, out, context.temp_allocator)
	r.override = read_color
	shape.json_read_node(&r, shape.node_of(&back))
	testing.expect_value(t, r.err, shape.Json_Reader_Error.None)
	testing.expect_value(t, back.tint, thing.tint)

	// Fields picked by tag, scaled through a stand-in value of another type
	write_percent :: proc(w: ^shape.Json_Writer, n: shape.Node) -> bool {
		if reflect.struct_tag_get(n.tag, "json") != "percent" do return false

		percent := int(shape.get_float(n) * 100)
		shape.json_write_node(w, shape.node_of(&percent))
		return true
	}

	shape.json_writer_reset(&w)
	w.override = write_percent
	shape.json_write_node(&w, shape.node_of(&thing))
	testing.expect_value(t, shape.json_writer_string(&w), `{"tint":[255,128,0,255],"ratio":25}`)
}
