# Structs & Enums

## Structs

```
struct Player {
    pub name: str        // pub = accessible outside module
    health: f32             // private by default
    score: i32

    // static constant — no self, belongs to the type
    const defaultHealth: f32 = 100.0

    // static method — no self, called on type name
    func create(name: str) Player {
        return Player{name: name, score: 0, health: Player.defaultHealth}
    }

    // immutable instance method
    func isAlive(self: const& Player) bool {
        return self.health > 0.0
    }

    // mutable instance method
    func takeDamage(self: mut& Player, amount: f32) void {
        self.health = self.health - amount
    }

    // consuming instance method — takes ownership, caller loses it
    func destroy(self: Player) void {
        // player dropped at end of function
    }
}
```

### Default Field Values
Fields can have default values using `=`. Any field with a default can be omitted during instantiation:
```
struct Player {
    pub name: str
    health: f32 = 100.0      // default value
    score: i32 = 0           // default value
    position: Vec2f = Vec2f{x: 0.0, y: 0.0}
}

// omit fields with defaults
var p = Player{name: "hero"}    // health=100.0, score=0, position=(0,0)

// override defaults
var p = Player{name: "hero", health: 50.0}
```

Default values also work for tuple fields and function parameters:
```
// function parameter defaults
func greet(name: str, greeting: str = "hello") void { }
greet("world")              // uses default greeting
greet("world", "hi")        // overrides default

// tuple field defaults
const Config: type = {width: i32 = 800, height: i32 = 600, fullscreen: bool = false}
var cfg = Config{width: 800, height: 600, fullscreen: false}    // all explicit
var cfg = Config{width: 1920, height: 1080}                     // fullscreen uses default
```

### Rules
- Named instantiation always — `Player{name: "john", score: 0, health: 100.0}`
- Instance methods have the enclosing struct type as their first parameter — the name is the programmer's choice
- No struct-type first param = static, `const& T` = immutable, `mut& T` = mutable, `T` = consuming
- Fields are private by default — `pub` makes them accessible outside the module

### Generic Structs
Structs can take type parameters (see [[02-types#Generics with `any`]]). The compiler generates a concrete type for each usage.
```
pub struct Pair(A: type, B: type) {
    pub first: A
    pub second: B
}

pub struct Stack(T: type) {
    items: [100]T
    top: i32 = 0

    pub func push(self: mut& Stack, val: T) void {
        self.items[self.top] = val
        self.top = self.top + 1
    }

    pub func peek(self: const& Stack) T {
        return self.items[self.top - 1]
    }
}

// usage
const p = Pair(i32, str){first: 42, second: "hello"}
var s = Stack(i32){items: [...], top: 0}
s.push(10)
```

Inside a generic struct body, the struct name refers to the current instantiation (`@This()` in Zig). Type parameters are in scope for all fields and methods.

### Self-Referencing Type — `@this`

`@this` refers to the enclosing struct type inside a struct body. Maps to `@This()` in Zig. Use it for self-referencing fields and method signatures in compt-generated structs.

```
struct Node {
    pub value: i32
    pub next: (null | mut& @this)    // @this = Node
}

compt func Wrapper(T: type) type {
    return struct {
        inner: T

        pub func get(self: const& @this) T {
            return self.inner
        }
    }
}
```

`Self` is deprecated — use `@this` instead. Using `Self` produces a compiler warning.

### Static Struct Constants
Static constants are shared across all instances. Only `const` is supported — no mutable shared state.
```
struct Player {
    const maxPlayers: i32 = 64        // immutable, shared across all instances
    const defaultHealth: f32 = 100.0  // immutable
}

const max = Player.maxPlayers         // access via type name
```

### Composition
Explicit only — no automatic method forwarding:
```
struct Animal {
    name: str
    func speak(self: const& Animal) void { }
}

struct Dog {
    animal: Animal
    breed: str
}

var d = Dog{animal: Animal{name: "rex"}, breed: "labrador"}
d.animal.speak()    // explicit, always clear where the method comes from
```

---

## Enums

Enums always require an explicit backing type — the compiler never silently chooses one. Hard compiler error if backing type is omitted.

```
enum(u32) Direction {
    North
    South
    East
    West
}
```

### Instantiation
The enum type name is declared once on the variable — never repeated on the right hand side:
```
var d: Direction = North
```

Enums are value-only — no methods, no data on variants. Methods belong on structs. If behavior is needed for enum values, wrap in a struct.

### Tagged unions — use unions + structs instead
Enums are value-only — variants cannot carry data. For tagged union patterns, use [[02-types#Unions|union types]] with structs:
```
struct Circle { radius: f32 }
struct Rectangle { width: f32, height: f32 }
const Shape = (Circle | Rectangle | null)
```

---

## Blueprints

Blueprints define strict interface contracts. A struct that lists a blueprint must implement every method in it — the compiler enforces this at the declaration site.

```
blueprint Measurable {
    func measure(self: const& Measurable) f32
}

blueprint Scalable {
    func scale(self: mut& Scalable, factor: f32) ()
}
```

### Struct conformance

Use `: Blueprint` syntax after the struct name. Multiple blueprints are separated by commas.

```
struct Circle: Measurable {
    radius: f32

    pub func measure(self: const& Circle) f32 {
        return self.radius * self.radius * 3.14
    }
}

struct Rectangle: Measurable, Scalable {
    width: f32
    height: f32

    pub func measure(self: const& Rectangle) f32 {
        return self.width * self.height
    }

    pub func scale(self: mut& Rectangle, factor: f32) () {
        self.width = self.width * factor
        self.height = self.height * factor
    }
}
```

### Rules

- Blueprint methods have no body — signature only
- Return type is optional; omitting it defaults to `void`
- Blueprints are pure erasure — no vtable, no runtime overhead. The compiler validates conformance and then discards the blueprint declaration entirely
- `pub blueprint` is valid for blueprints exported from a module
- If a struct lists a blueprint but is missing a required method, the compiler reports an error

---

## Bitfields

Bitfields are now provided by `std::bitfield` — a pure Zig comptime library. See `use std::bitfield` for the `Bitfield` function.
