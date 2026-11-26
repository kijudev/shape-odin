# Media Molecule inspired serialization library for Odin

## JSON notation

The `shape` walk can read and write JSON through `Json_Writer` and `Json_Reader`. The mapping:

- structs are objects, fields must appear in declaration order when deserializing
- arrays, slices and dynamic arrays are arrays
- maps are objects, primitive keys are stringified (`{"Capsule": ..., "42": ...}`)
- enums are their member name as a string, or an integer when the value has no named member
- NaN and infinite floats, and non UTF-8 strings, are `null`
- bit sets are arrays of their elements (`["Box", "Capsule"]`, `[1, 9]`, `["a", "z"]`)
- bit fields are objects like structs, every field holds its unpacked value
- runes are one character strings
- unions are an object with a single key naming the variant (`{"Circle": {"r": 0.5}}`, `{"int": 7}`), nil is `null`. Named variants use their declared name, others the type as written

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
