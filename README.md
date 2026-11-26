# Media Molecule inspired serialization library for Odin

## Nodes

`shape` looks at any value through reflection as a `Node`: a data pointer, its declared type, and where it sits in its parent (name, tag, index). Nodes are made on demand from their parent and never stored, so walking costs no allocations and always sees the live data. Formats and tools are plain recursive procedures over nodes.

```odin
root := shape.node_of(&entity)

it := 0
for f in shape.iterate_fields(root, &it) {   // skips `shape:"skip"` fields
	fmt.println(f.name, f.kind)
}
```

| Kind       | Navigate                                       | Read / write                                   |
| ---------- | ---------------------------------------------- | ---------------------------------------------- |
| `.Struct`  | `iterate_fields`, `field`, `field_count`       | structs and bit fields alike                   |
| `.Array`   | `length`, `elem`                               | `resize`, `insert_elem`, `remove_elem`         |
| `.Map`     | `length`, `iterate_map`, `map_find`            | `map_insert`, `map_remove`, `map_reserve`      |
| `.Bit_Set` | `length`, `elem` gives a `.Bool` per member    | `get_bool`, `set_bool` on the members          |
| `.Union`   | `variant`, `variant_count`, `variant_name`     | `set_variant`                                  |
| `.String`  |                                                | `get_string`, `set_string`, `alloc_string`     |
| scalars    |                                                | `get_int`, `set_int`, `get_float`, `set_float` |

Fixed, enumerated (`[Kind]T`, elements named after the members), fixed capacity dynamic (`[dynamic; N]T`) and dynamic arrays and slices are all `.Array`. Bit field fields and bit set members are packed into bits, so always go through the accessors rather than `data`. `set_int` refuses values that do not fit the type or its bits. Types shape does not support (pointers, procedures, matrices, ...) are `.Invalid`.

### Inspector example

```odin
draw :: proc(n: shape.Node) {
	switch n.info.id {
	case Color: color_picker(n); return  // custom widgets per type
	}

	#partial switch n.kind {
	case .Struct:
		if imgui.TreeNode(n.name) {
			it := 0
			for f in shape.iterate_fields(n, &it) do draw(f)
			imgui.TreePop()
		}
	case .Array:
		if imgui.TreeNode(n.name) {
			// elem is random access, so a list clipper only touches visible rows
			for i in visible_rows(shape.length(n)) do draw(shape.elem(n, i))
			imgui.TreePop()
		}
	case .Int:
		v := i32(shape.get_int(n))
		if imgui.DragInt(n.name, &v) do shape.set_int(n, i128(v))
	case .Union:
		index, payload := shape.variant(n)
		if variant_combo(n, &index) do payload, _ = shape.set_variant(n, index)
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
