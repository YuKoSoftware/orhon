# Structs & Enums

## Structs

```
struct Player {
    pub name: str        // pub = accessible outside module
    health: f32             // private by default
    score: i32

    // static variable — no self, belongs to the type
    var defaultHealth: f32 = 100.0

    // static method — no self, called on type name
    func create(name: str) Player {
        return Player(name: name, score: 0, health: Player.defaultHealth)
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
    position: Vec2f = Vec2f(x: 0.0, y: 0.0)
}

// omit fields with defaults
var p: Player = Player(name: "hero")    // health=100.0, score=0, position=(0,0)

// override defaults
var p: Player = Player(name: "hero", health: 50.0)
```

Default values also work for enum variants, tuple fields, and function parameters:
```
// function parameter defaults
func greet(name: str, greeting: str = "hello") void { }
greet("world")              // uses default greeting
greet("world", "hi")        // overrides default

// tuple field defaults
const Config = (width: i32 = 800, height: i32 = 600, fullscreen: bool = false)
var cfg = Config(width: 800, height: 600, fullscreen: false)    // all explicit
var cfg = Config(width: 1920, height: 1080)                     // fullscreen uses default
```

### Rules
- Named instantiation always — `Player(name: "john", score: 0, health: 100.0)`
- `self` is always the explicit first argument for instance methods
- No `self` = static, `const& T` = immutable, `mut& T` = mutable, `T` = consuming
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
const p = Pair(i32, str)(first: 42, second: "hello")
var s = Stack(i32)(items: [...], top: 0)
s.push(10)
```

Inside a generic struct body, the struct name refers to the current instantiation (`@This()` in Zig). Type parameters are in scope for all fields and methods.

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

var d: Dog = Dog(animal: Animal(name: "rex"), breed: "labrador")
d.animal.speak()    // explicit, always clear where the method comes from
```

---

## Enums

Enums always require an explicit backing type — the compiler never silently chooses one. Hard compiler error if backing type is omitted.

```
// regular enum — named constants, explicit backing type
enum(u32) Direction {
    North
    South
    East
    West
}

// data-carrying enum — explicit backing type
enum(u32) Shape {
    Circle(radius: f32)
    Rectangle(width: f32, height: f32)
    Point                               // can mix — some variants with data, some without
}
```

### Instantiation
The enum type name is declared once on the variable — never repeated on the right hand side:
```
var d: Direction = North
var s: Shape = Circle(radius: 5.0)
```

### Methods on Enums
Same rules as structs — `self` as first argument, [[07-control-flow#Pattern Matching|match]] on self inside:
```
enum(u32) Shape {
    Circle(radius: f32)
    Rectangle(width: f32, height: f32)
    Point

    func area(self: const& Shape) f32 {
        match self {
            Circle    => { return 3.14 * Circle.radius * Circle.radius }
            Rectangle => { return Rectangle.width * Rectangle.height }
            Point     => { return 0.0 }
        }
    }
}
```

---

## Bitfields

A `bitfield` is its own declaration keyword — distinct from `enum`. Use it for named bit flags backed by an integer. The compiler assigns powers of 2 to each flag automatically.

```
bitfield(u32) Permissions {
    Read      // 0b0001
    Write     // 0b0010
    Execute   // 0b0100
    Delete    // 0b1000
}
```

### Instantiation
Pass any combination of flags to the constructor — order does not matter:
```
var p: Permissions = Permissions(Read, Write)
var q: Permissions = Permissions()             // empty — all flags off
```

### Operations
Four methods, no bitwise operators needed:
```
p.has(Read)       // bool — is this flag set?
p.set(Execute)    // add a flag
p.clear(Write)    // remove a flag
p.toggle(Read)    // flip a flag
```

Type safe — passing a flag from a different `bitfield` type is a hard compiler error.
