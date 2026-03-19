# Style Guide

Naming conventions are never enforced by the compiler — style is up to the programmer. However the following guidelines are used for all official Kodr code including the standard library. Following them is recommended for consistency across the ecosystem.

## Naming Conventions

```
// types — PascalCase
// structs, enums, tuples, unions
struct PlayerHealth { }
enum Direction(u32) { }
const Point = (x: f32, y: f32)
const MyUnion = (i32 | f32)

// functions — camelCase
func takeDamage() void { }
func isAlive() bool { }

// variables and constants — camelCase
var playerHealth: f32 = 100.0
const maxPlayers: i32 = 64

// compt constants — SCREAMING_SNAKE_CASE
compt MAX_PLAYERS: i32 = 64
compt PI: f32 = 3.14159

// modules — lowercase, no separators, keep short
module mathutils
module playerphysics

// enum variants — PascalCase
enum Direction(u32) {
    North
    South
    East
    West
}

// bitfield enum variants — PascalCase
enum Permissions(u32, bitfield) {
    Read
    Write
    Execute
}

// error constants — PascalCase with Err prefix
const ErrNotFound: Error = Error("not found")
const ErrDivByZero: Error = Error("division by zero")
```

## Reasoning
- `PascalCase` for types — universally understood, immediately signals "this is a type"
- `camelCase` for functions and variables — clean, minimal, widely used
- `SCREAMING_SNAKE_CASE` for compt constants — signals compile time constant, universally understood
- `lowercase` for modules — clean, no separators, module names should be short and descriptive
- `Err` prefix for error constants — immediately signals what it is at the call site
