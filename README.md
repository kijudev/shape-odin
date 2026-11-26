# shape

Reflection based serialization for Odin, loosely inspired by how Media Molecule handles serialization. Instead of writing a serialize procedure per type, `shape` walks your values through their type info. JSON comes built in, and the same walking API can be used for your own formats or tools like an editor inspector.

## Saving and loading

```odin
import "shape"

entity := Entity{...}

text := shape.json_write(&entity, pretty = true)
defer delete(text)

loaded: Entity
if err, pos := shape.json_read(&loaded, text); err != .None {
	fmt.println("bad json:", err, "at", pos)
}
```

`json_write` returns a string allocated with `allocator` (`context.allocator` by default). `json_read` reports the first error and the position it stopped at. Once something fails it doesn't try to continue.

Fields have to be in declaration order in the JSON, which is always the case for files `json_write` produced. Hand written files have to follow that too.

## Where loaded data lives

Read into a zero value. Everything the reader allocates comes from the `allocator` you pass to `json_read`:

- dynamic arrays and maps get that allocator if they don't have one yet, and keep it, so a later `append` or `delete` does the right thing
- slices and strings are allocated from it too, but they don't remember it, so free them with the same allocator
- nested containers work the same way, all the way down

An arena is usually the easiest choice for loaded data, since you tend to throw it away in one go. Don't load into `context.temp_allocator` and keep the result: the arrays and maps will still point at the temp allocator after it's cleared.

Reading into a value that already holds data mostly works, but:

- maps are merged, not replaced: keys from the JSON are added or overwritten, the others stay
- dynamic arrays are resized in place, and whatever the old elements allocated leaks
- slices that grow get a new allocation and the old one isn't freed

## Skipping fields

Tag a field with `shape:"skip"` and it's left out of everything, JSON and node iteration alike:

```odin
Entity :: struct {
	id:      u64,
	scratch: [16]u8 `shape:"skip"`,
}
```

## Custom formats for some types

Both `Json_Writer` and `Json_Reader` have an `override` procedure that runs before every value. Return `true` if you handled it. The simplest way to write something custom is to convert it to a normal type and hand it back to the writer, so quoting and escaping still happen:

```odin
write_color :: proc(w: ^shape.Json_Writer, n: shape.Node) -> bool {
	if n.info.id != Color do return false

	c := (^Color)(n.data)^
	hex := fmt.tprintf("#%02x%02x%02x%02x", c.r, c.g, c.b, c.a)
	shape.json_write_node(w, shape.node_of(&hex))
	return true
}

w: shape.Json_Writer
shape.json_writer_init(&w, pretty = true)
defer shape.json_writer_destroy(&w)
w.override = write_color
shape.json_write_node(&w, shape.node_of(&entity))
text := shape.json_writer_string(&w)
```

Reading is the same in reverse: read into a local `string` with `json_read_node`, then parse it into the color. You can match on anything the node has, like the type, the field name, or a tag (`reflect.struct_tag_get(n.tag, "json")`). The override runs for every value, so keep the "not mine" check cheap.

## Walking values yourself

Everything above is built on nodes. `node_of(&value)` gives you a `Node`, which is a pointer to the value plus what `shape` worked out about its type. Moving to a child (a field, an element, a map entry) gives you another node pointing into the same memory. Nodes aren't stored anywhere: you make them as you go, and anything you set through them changes your actual data.

```odin
draw :: proc(n: shape.Node) {
	#partial switch v in n.value {
	case shape.Struct:
		it := 0
		for f in shape.iterate_fields(v, &it) do draw(f)
	case shape.Array:
		it: shape.Elem_Iterator
		for e in shape.iterate_elems(v, &it) do draw(e)
	case shape.Int:
		shape.set_int(v, shape.get_int(v) + 1)
	}
}

draw(shape.node_of(&entity))
```

`n.value` says what the value is. It's `nil` for types `shape` doesn't handle. The header has the rest: `name` (the field name, or the enum member name for enumerated array elements and bit set members), `tag`, `index` in the parent, `info` (the declared type), `data`, and `is_key` for map keys.

| Value          | Getting around                                      | Changing it                                       |
| -------------- | --------------------------------------------------- | ------------------------------------------------- |
| `Struct`       | `iterate_fields`, `field`, `count`                  | structs and bit fields (`packed`) both land here  |
| `Array`        | `length`, `iterate_elems`, `elem`                   | `resize`, `insert_elem`, `remove_elem`            |
| `Map`          | `length`, `iterate_map`, `map_find`                 | `map_insert`, `map_remove`, `map_reserve`         |
| `Bit_Set`      | `length`, `member` (one `Bool` per possible member) | `set_bool` on a member                            |
| `Union`        | `variant`, `variants`, `variant_name`               | `set_variant`                                     |
| `String`       |                                                     | `get_string`, `set_string`, `alloc_string`        |
| `Int`          |                                                     | `get_int`, `set_int`                              |
| `Enum`         |                                                     | `get_enum`, `set_enum`, `enum_name`, `enum_value` |
| `Float`        |                                                     | `get_float`, `set_float`                          |
| `Bool`, `Rune` |                                                     | `get_bool`, `set_bool`, `get_rune`, `set_rune`    |

Things worth knowing:

- `Array` covers fixed arrays, enumerated arrays (`[Kind]T`), `[dynamic; N]T`, dynamic arrays and slices. `layout` tells them apart and `is_resizable` tells you if `resize` works.
- `iterate_elems` is the quick way through a whole array. `elem` is random access, handy for a list that only shows the visible rows.
- `set_int` and the other setters return `false` instead of truncating when a value doesn't fit, which includes bit field fields narrower than their type.
- Bit field fields and bit set members are packed into bits, so go through the getters and setters instead of `data`.
- A node is only valid as long as the memory under it. After a `resize`, `insert_elem` or `map_insert`, get the children again from the parent.
- Don't change a map key in place, it breaks the map. Remove the entry and insert it again.
- `set_variant` always resets the union to a zeroed payload, even when it's already that variant.

### Inspector sketch

```odin
draw :: proc(n: shape.Node) {
	if n.info.id == Color {color_picker(n); return}

	imgui.PushID(i32(n.index))
	defer imgui.PopID()

	#partial switch v in n.value {
	case shape.Struct:
		if imgui.TreeNode(n.name) {
			it := 0
			for f in shape.iterate_fields(v, &it) do draw(f)
			imgui.TreePop()
		}
	case shape.Array:
		if imgui.TreeNode(n.name) {
			for i in visible_rows(shape.length(v)) do draw(shape.elem(v, i))
			imgui.TreePop()
		}
	case shape.Int:
		x := i32(shape.get_int(v))
		if imgui.DragInt(n.name, &x) do shape.set_int(v, i128(x))
	case shape.Union:
		index, payload := shape.variant(v)
		if variant_combo(v, &index) do payload, _ = shape.set_variant(v, index)
		if index >= 0 do draw(payload)
	}
}
```

## JSON format

- structs and bit fields are objects
- every kind of array is an array
- maps are objects, non string keys are written as strings (`{"Capsule": ..., "42": ...}`)
- enums are their member name, or a number if the value has no name
- bit sets are arrays of their members (`["Box", "Capsule"]`, `[1, 9]`, `["a", "z"]`)
- runes are one character strings
- unions are an object with one key naming the variant (`{"Circle": {"r": 0.5}}`, `{"int": 7}`), and `null` when nil. Named types use their name, others the type as written
- NaN, infinity and unsupported types are `null`

```json
{
  "id": 42,
  "name": "Player \"One\"",
  "collider": {
    "kind": "Capsule",
    "extents": [0.5, 1.8, 0.5],
    "is_sensor": false
  },
  "inventory": {
    "sword": 1,
    "potion": 5
  }
}
```

## Not supported yet

Pointers, procedures, matrices, SIMD vectors, complex numbers and quaternions show up as `nil` nodes and are written as `null`. There's no versioning yet either, so renaming or removing a field breaks old files.
