#+feature dynamic-literals
package main

import "../shape"
import "core:fmt"
import vmem "core:mem/virtual"

Transform :: struct {
	pos:   [3]f32,
	rot:   [4]f32,
	scale: [3]f32,
}

Shape_Kind :: enum u8 {
	Box,
	Sphere,
	Capsule,
}

Collider :: struct {
	kind:      Shape_Kind,
	extents:   [3]f32,
	is_sensor: bool,
	layers:    [4]bool,
}

Sprite :: struct {
	uv:    [2]f32,
	tint:  [4]u8,
	frame: i16,
}

Entity :: struct {
	id:        u64,
	name:      string,
	transform: Transform,
	collider:  Collider,
	sprite:    Sprite,
	health:    i32,
	velocity:  [2]f64,
	path:      [3][2]i32,
	history:   [6]f32,
	tags:      []string,
	waypoints: [dynamic][2]i32,
	inventory: map[string]i32,
	sprites:   map[Shape_Kind]Sprite,
	scratch:   [16]u8 `shape:"skip"`,
}

TAGS := []string{"enemy", "flying"}

main :: proc() {
	arena: vmem.Arena
	if err := vmem.arena_init_growing(&arena); err != nil {
		fmt.println("Arena init failed:", err)
		return
	}
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	entity := create_entity(123, "Test Entity")

	lisp_roundtrip(&entity)
	json_roundtrip(&entity)
}

lisp_roundtrip :: proc(entity: ^Entity) {
	reader: shape.Lisp_Reader
	shape.lisp_reader_init(&reader, 64 * 1024, pretty = true, tabsize = 4)

	shape.walk(&reader, "entity", entity, Entity)
	serialized := shape.lisp_reader_string(&reader)
	fmt.println("Lisp serialized:", serialized)

	deserialized: Entity
	writer: shape.Lisp_Writer
	shape.lisp_writer_init(&writer, serialized)
	shape.walk(&writer, "entity", &deserialized, Entity)

	if writer.err != .None {
		fmt.println("Lisp deserialization failed:", writer.err, "at", writer.pos)
		return
	}

	report("Lisp", entities_equal(entity, &deserialized))
}

json_roundtrip :: proc(entity: ^Entity) {
	reader: shape.Json_Reader
	shape.json_reader_init(&reader, 64 * 1024, pretty = true, tabsize = 4)

	shape.walk(&reader, "entity", entity, Entity)
	serialized := shape.json_reader_string(&reader)
	fmt.println("JSON serialized:", serialized)

	deserialized: Entity
	writer: shape.Json_Writer
	shape.json_writer_init(&writer, serialized)
	shape.walk(&writer, "entity", &deserialized, Entity)

	if writer.err != .None {
		fmt.println("JSON deserialization failed:", writer.err, "at", writer.pos)
		return
	}

	report("JSON", entities_equal(entity, &deserialized))
}

entities_equal :: proc(a, b: ^Entity) -> bool {
	return(
		a.id == b.id &&
		a.name == b.name &&
		len(a.tags) == len(b.tags) &&
		len(a.waypoints) == len(b.waypoints) &&
		a.waypoints[1] == b.waypoints[1] &&
		a.inventory["shield"] == b.inventory["shield"] &&
		len(a.inventory) == len(b.inventory) &&
		a.sprites[.Capsule] == b.sprites[.Capsule] \
	)
}

report :: proc(format: string, ok: bool) {
	fmt.println(format, ok ? "deserialization successful!" : "deserialization failed!")
}

create_entity :: proc(id: u64, name: string) -> Entity {
	return Entity {
		id = id,
		name = name,
		transform = {pos = {0, 0, 0}, rot = {0, 0, 0, 1}, scale = {1, 1, 1}},
		collider = {
			kind = .Box,
			extents = {1, 1, 1},
			is_sensor = false,
			layers = {true, true, true, true},
		},
		sprite = {uv = {0, 0}, tint = {255, 255, 255, 255}, frame = 0},
		health = 100,
		velocity = {0, 0},
		path = {{0, 0}, {0, 0}, {0, 0}},
		history = {0, 0, 0, 0, 0, 0},
		tags = TAGS,
		waypoints = [dynamic][2]i32{{1, 2}, {3, 4}, {5, 6}},
		inventory = map[string]i32{"sword" = 1, "shield" = 2, "potion" = 5},
		sprites = map[Shape_Kind]Sprite {
			.Box = {uv = {0, 1}, tint = {1, 2, 3, 4}, frame = 2},
			.Capsule = {uv = {0.5, 0.5}, tint = {9, 9, 9, 9}, frame = -3},
		},
	}
}
