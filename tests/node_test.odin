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
	s, is_struct := root.value.(shape.Struct)

	testing.expect(t, is_struct)
	testing.expect_value(t, root.index, -1)
	testing.expect_value(t, s.count, 4)

	names: [dynamic]string
	defer delete(names)

	it := 0
	for f in shape.iterate_fields(s, &it) do append(&names, f.name)
	testing.expect_value(t, len(names), 3)
	testing.expect_value(t, names[1], "b")

	b := shape.field(s, 2)
	testing.expect_value(t, b.index, 2)
	testing.expect_value(t, b.tag, `meta:"x"`)
	testing.expect_value(t, shape.get_string(b.value.(shape.String)), "b")
	testing.expect(t, shape.field(s, 3).value == nil)
	testing.expect(t, shape.field(s, 9).value == nil)

	shape.set_int(shape.field(s, 0).value.(shape.Int), 42)
	testing.expect_value(t, thing.a, 42)

	shape.set_string(b.value.(shape.String), "changed", context.temp_allocator)
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
		r:     rune,
		on:    b32,
	}

	thing: Thing
	s := shape.node_of(&thing).value.(shape.Struct)
	small := shape.field(s, 0).value.(shape.Int)
	big := shape.field(s, 1).value.(shape.Int)
	be := shape.field(s, 2).value.(shape.Int)
	kind := shape.field(s, 3).value.(shape.Enum)

	testing.expect(t, shape.set_int(small, -128))
	testing.expect(t, !shape.set_int(small, 128))
	testing.expect_value(t, thing.small, -128)

	// u128 values above the i128 range go in with the same bits
	testing.expect(t, shape.set_int(big, -1))
	testing.expect_value(t, thing.big, max(u128))

	testing.expect(t, be.swapped)
	testing.expect(t, shape.set_int(be, 0x01020304))
	testing.expect_value(t, thing.be, 0x01020304)
	testing.expect_value(t, shape.get_int(be), 0x01020304)

	testing.expect(t, !shape.set_enum(kind, 256))
	testing.expect(t, shape.set_enum(kind, 1))
	testing.expect_value(t, thing.kind, Kind.Capsule)
	name, ok := shape.enum_name(kind, 1)
	testing.expect(t, ok)
	testing.expect_value(t, name, "Capsule")

	shape.set_float(shape.field(s, 4).value.(shape.Float), 0.5)
	testing.expect_value(t, thing.f, 0.5)

	shape.set_string(shape.field(s, 5).value.(shape.String), "c", context.temp_allocator)
	testing.expect_value(t, thing.c, "c")

	testing.expect(t, shape.set_rune(shape.field(s, 6).value.(shape.Rune), 'é'))
	testing.expect_value(t, thing.r, 'é')

	shape.set_bool(shape.field(s, 7).value.(shape.Bool), true)
	testing.expect_value(t, thing.on, true)

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
	s := shape.node_of(&thing).value.(shape.Struct)
	flags, is_struct := shape.field(s, 0).value.(shape.Struct)
	kinds := shape.field(s, 1).value.(shape.Bit_Set)

	testing.expect(t, is_struct)
	testing.expect(t, flags.packed)
	delta := shape.field(flags, 1).value.(shape.Int)
	testing.expect_value(t, shape.get_int(delta), -2)
	testing.expect(t, !shape.set_int(delta, 8))
	testing.expect(t, shape.set_int(delta, -8))
	testing.expect_value(t, thing.flags.delta, -8)
	// Neighbours keep their bits
	testing.expect_value(t, thing.flags.level, 3)
	testing.expect_value(t, thing.flags.kind, Kind.Sphere)
	testing.expect(t, shape.set_enum(shape.field(flags, 2).value.(shape.Enum), 2))
	testing.expect_value(t, thing.flags.kind, Kind.Capsule)

	testing.expect_value(t, shape.length(kinds), 3)
	capsule := shape.member(kinds, 2)
	testing.expect_value(t, capsule.name, "Capsule")
	shape.set_bool(capsule.value.(shape.Bool), true)
	testing.expect_value(t, thing.kinds, bit_set[Kind]{.Capsule})
	testing.expect(t, shape.get_bool(capsule.value.(shape.Bool)))
	testing.expect(t, shape.member(kinds, 3).value == nil)
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
	s := shape.node_of(&thing).value.(shape.Struct)
	dyn := shape.field(s, 0).value.(shape.Array)
	sl := shape.field(s, 1).value.(shape.Array)
	fixed := shape.field(s, 2).value.(shape.Array)
	named := shape.field(s, 3).value.(shape.Array)

	set :: proc(a: shape.Array, i: int, value: i128) {
		shape.set_int(shape.elem(a, i).value.(shape.Int), value)
	}

	testing.expect(t, shape.resize(dyn, 2))
	set(dyn, 0, 1)
	set(dyn, 1, 3)
	testing.expect(t, shape.insert_elem(dyn, 1))
	set(dyn, 1, 2)
	testing.expect_value(t, len(thing.dyn), 3)
	testing.expect_value(t, thing.dyn[2], 3)
	testing.expect(t, shape.remove_elem(dyn, 0))
	testing.expect_value(t, thing.dyn[0], 2)
	testing.expect_value(t, len(thing.dyn), 2)
	testing.expect(t, shape.elem(dyn, 2).value == nil)

	testing.expect(t, shape.resize(sl, 2, context.temp_allocator))
	set(sl, 1, 7)
	testing.expect(t, shape.resize(sl, 3, context.temp_allocator))
	testing.expect_value(t, thing.sl[1], 7)
	testing.expect_value(t, thing.sl[2], 0)

	testing.expect(t, shape.is_resizable(fixed))
	testing.expect(t, shape.resize(fixed, 3))
	testing.expect(t, !shape.resize(fixed, 4))
	testing.expect_value(t, len(thing.fixed), 3)

	testing.expect(t, !shape.is_resizable(named))
	testing.expect_value(t, shape.length(named), 2)
	capsule := shape.elem(named, 1)
	testing.expect_value(t, capsule.name, "Capsule")
	shape.set_float(capsule.value.(shape.Float), 2.5)
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

	m := shape.node_of(&scores).value.(shape.Map)
	testing.expect_value(t, shape.length(m), 2)

	sum, keys := 0, 0
	it := 0
	for key, value in shape.iterate_map(m, &it) {
		testing.expect(t, key.is_key)
		testing.expect_value(t, key.index, value.index)
		sum += int(shape.get_int(value.value.(shape.Int)))
		keys += 1
	}
	testing.expect_value(t, sum, 3)
	testing.expect_value(t, keys, 2)

	key := "c"
	stored, is_int := shape.map_insert(m, &key, nil).value.(shape.Int)
	testing.expect(t, is_int)
	shape.set_int(stored, 5)
	testing.expect_value(t, scores["c"], 5)

	found, ok := shape.map_find(m, &key)
	testing.expect(t, ok)
	testing.expect_value(t, shape.get_int(found.value.(shape.Int)), 5)

	testing.expect(t, shape.map_remove(m, &key))
	testing.expect(t, !shape.map_remove(m, &key))
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
	root := shape.node_of(&thing).value.(shape.Struct)
	s := shape.field(root, 0).value.(shape.Union)
	strict := shape.field(root, 1).value.(shape.Union)

	index, payload := shape.variant(s)
	testing.expect_value(t, index, 0)
	_, is_struct := payload.value.(shape.Struct)
	testing.expect(t, is_struct)
	testing.expect(t, !s.no_nil)

	buffer: [64]byte
	testing.expect_value(t, len(s.variants), 2)
	testing.expect_value(t, shape.variant_name(s, 0, buffer[:]), "Circle")
	testing.expect_value(t, shape.variant_name(s, 1, buffer[:]), "int")

	payload, _ = shape.set_variant(s, 1)
	shape.set_int(payload.value.(shape.Int), 9)
	testing.expect_value(t, thing.s.(int), 9)

	_, ok := shape.set_variant(s, -1)
	testing.expect(t, ok)
	testing.expect(t, thing.s == nil)
	index, payload = shape.variant(s)
	testing.expect_value(t, index, -1)
	testing.expect(t, payload.value == nil)

	testing.expect(t, strict.no_nil)
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

		percent := int(shape.get_float(n.value.(shape.Float)) * 100)
		shape.json_write_node(w, shape.node_of(&percent))
		return true
	}

	shape.json_writer_reset(&w)
	w.override = write_percent
	shape.json_write_node(&w, shape.node_of(&thing))
	testing.expect_value(t, shape.json_writer_string(&w), `{"tint":[255,128,0,255],"ratio":25}`)
}
