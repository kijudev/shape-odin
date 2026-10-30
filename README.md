# Media Molecule inspired serialization library for Odin

## S-expression notation

This library while providing a `shape` interface for serialization and deserialization, also provides a human-readable s-expression-like notation for data. This notation is designed to be easy to read and write, while also being easy to parse.

### Example

```lisp
(
    id 42
    name "Player \"One\""
    transform (
        pos [1.5 -2 10]
        rot [0 0 0 1]
        scale [1 1 1]
    )
    collider (
        kind 'Capsule
        extents [0.5 1.8 0.5]
        is_sensor false
        layers [true false true false]
    )
    sprite (
        uv [0.25 0.75]
        tint [255 128 0 255]
        frame -1
    )
    health 100
    velocity [3.25 -9.81]
    inventory {
        "sword" 1
        "potion" 5
    }
)
```

### Grammar

```ebnf
value      ::= struct | array | map | atom

struct     ::= "(" fields ")"
fields     ::= field fields | epsilon
field      ::= ident value

array      ::= "[" values "]"
values     ::= value values | epsilon

map        ::= "{" entries "}"
entries    ::= entry entries | epsilon
entry      ::= value value (* key, then value *)

atom       ::= number | bool | enum | string | "nil"

bool       ::= "true" | "false"
enum       ::= "'" ident | integer (* integer when the value has no named member *)

number     ::= integer fraction exponent
integer    ::= sign digits
sign       ::= "-" | epsilon
digits     ::= digit digits | digit
fraction   ::= "." digits | epsilon
exponent   ::= "e" exp-sign digits | epsilon
exp-sign   ::= "+" | "-"

ident      ::= ident-head ident-tail
ident-tail ::= ident-char ident-tail | epsilon
ident-head ::= letter | "_"
ident-char ::= letter | digit | "_"

string     ::= '"' chars '"'
chars      ::= char chars | epsilon
char       ::= plain | escape
plain      ::= (* any byte >= 0x20 except '"' and '\' *)
escape     ::= "\" ( '"' | "\" | "n" | "r" | "t" | "u" hex hex hex hex )

digit      ::= "0" ... "9"
hex        ::= digit | "a" ... "f"
letter     ::= "a" ... "z" | "A" ... "Z"
```

## JSON notation

The same `shape` walk can also read and write JSON through `Json_Reader` and `Json_Writer`. The mapping mirrors the s-expression notation:

- structs are objects, fields must appear in declaration order when deserializing
- arrays, slices and dynamic arrays are arrays
- maps are objects, primitive keys are stringified (`{"Capsule": ..., "42": ...}`)
- enums are their member name as a string, or an integer when the value has no named member
- NaN and infinite floats, and non UTF-8 strings, are `null`

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
