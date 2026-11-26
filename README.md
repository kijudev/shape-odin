# Media Molecule inspired serialization library for Odin

## Nodes

`shape` looks at any value through reflection as a `Node`: a header saying where the value sits (name, tag, index, declared type) and a `value` union saying what it is. Nodes are made on demand from their parent and never stored, so walking costs no allocations and always sees the live data. Formats and tools are plain recursive procedures that switch on `value`.

```odin
root := shape.node_of(&entity)

switch v in root.value {
case shape.Struct:
	it := 0
	for f in shape.iterate_fields(v, &it) do fmt.println(f.name)  // skips `shape:"skip"` fields
case shape.Int:
	shape.set_int(v, 42)
case:  // nil, a type shape does not support
}
```

The type is resolved once when the node is made, every variant carries what its procedures need:

| Variant   | Navigate                                              | Read / write                                       |
| --------- | ----------------------------------------------------- | -------------------------------------------------- |
| `Struct`  | `iterate_fields`, `field`, `count`                    | structs and bit fields (`packed`) alike            |
| `Array`   | `length`, `iterate_elems`, `elem`                     | `resize`, `insert_elem`, `remove_elem`             |
| `Map`     | `length`, `iterate_map`, `map_find`                   | `map_insert`, `map_remove`, `map_reserve`          |
| `Bit_Set` | `length`, `member` gives a `Bool` per possible member | `get_bool`, `set_bool` on the members              |
| `Union`   | `variant`, `variants`, `variant_name`                 | `set_variant`                                      |
| `String`  |                                                       | `get_string`, `set_string`, `alloc_string`         |
| `Int`     |                                                       | `get_int`, `set_int`                               |
| `Enum`    |                                                       | `get_enum`, `set_enum`, `enum_name`, `enum_value`  |
| `Float`, `Bool`, `Rune` |                                         | `get_float`, `set_float`, `get_bool`, ...          |

Fixed, enumerated (`[Kind]T`, elements named after the members), fixed capacity dynamic (`[dynamic; N]T`) and dynamic arrays and slices are all `Array`, see `layout`. Bit field fields and bit set members are packed into bits, the accessors handle that. `set_int` and friends refuse values that do not fit the type or its bits. `iterate_elems` is the fast way through a whole array, `elem` is random access for viewers that only show some rows.

### Inspector example

```odin
draw :: proc(n: shape.Node) {
	if n.info.id == Color {color_picker(n); return}  // custom widgets per type

	#partial switch v in n.value {
	case shape.Struct:
		if imgui.TreeNode(n.name) {
			it := 0
			for f in shape.iterate_fields(v, &it) do draw(f)
			imgui.TreePop()
		}
	case shape.Array:
		if imgui.TreeNode(n.name) {
			// elem is random access, so a list clipper only touches visible rows
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

## JSON notation

`json_write` and `json_read` serialize any value, `Json_Writer` and `Json_Reader` take an `override` procedure for custom handling of chosen nodes. The mapping:

- structs and bit fields are objects, fields must appear in declaration order when deserializing
- arrays of every kind are arrays
- maps are objects, primitive keys are stringified (`{"Capsule": ..., "42": ...}`)
- enums are their member name as a string, or an integer when the value has no named member
- bit sets are arrays of their members (`["Box", "Capsule"]`, `[1, 9]`, `["a", "z"]`)
- runes are one character strings
- unions are an object with a single key naming the variant (`{"Circle": {"r": 0.5}}`, `{"int": 7}`), nil is `null`. Named variants use their declared name, others the type as written
- NaN and infinite floats, and unsupported types, are `null`

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
