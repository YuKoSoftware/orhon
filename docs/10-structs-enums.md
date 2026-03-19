# Structs & Enums

## Structs

```
struct Player {
    pub name: string        // pub = accessible outside module
    health: f32             // private by default
    score: i32

    // static variable — no self, belongs to the type
    var defaultHealth: f32 = 100.0

    // static method — no self, called on type name
    func create(name: string) Player {
        return Player(name: name, score: 0, health: Player.defaultHealth)
    }

    // immutable instance method
    func isAlive(self: const &Player) bool {
        return self.health > 0.0
    }

    // mutable instance method
    func takeDamage(self: var &Player, amount: f32) void {
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
    pub name: string
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
func greet(name: string, greeting: string = "hello") void { }
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
- No `self` = static, `const &T` = immutable, `var &T` = mutable, `T` = consuming
- Fields are private by default — `pub` makes them accessible outside the module

### Static Struct Variables
Static variables are shared across all instances. Both `var` and `const` are supported. Ownership rules apply — moving a static variable out makes it invalid.
```
struct Player {
    var defaultHealth: f32 = 100.0    // mutable, shared across all instances
    const maxPlayers: i32 = 64        // immutable, shared across all instances
}

Player.defaultHealth = 200.0          // allowed, var
Player.maxPlayers = 128               // compile error, const
```

### Composition
Explicit only — no automatic method forwarding:
```
struct Animal {
    name: string
    func speak(self: const &Animal) void { }
}

struct Dog {
    animal: Animal
    breed: string
}

var d: Dog = Dog(animal: Animal(name: "rex"), breed: "labrador")
d.animal.speak()    // explicit, always clear where the method comes from
```

---

## Enums

Enums always require an explicit backing type — the compiler never silently chooses one. Hard compiler error if backing type is omitted.

```
// regular enum — named constants, explicit backing type
enum Direction(u32) {
    North
    South
    East
    West
}

// bitfield enum — compiler assigns powers of 2 automatically
enum Permissions(u32, bitfield) {
    Read      // 0b0001
    Write     // 0b0010
    Execute   // 0b0100
    Delete    // 0b1000
}

// data-carrying enum — explicit backing type
enum Shape(u32) {
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

### Bitfield Enum Operations
Bitfield enums natively support flag operations. The underlying mechanism is standard bitwise operators on the backing integer type — `|` is bitwise OR, `&` is bitwise AND etc. The compiler knows the type is a bitfield enum and provides named convenience methods. Type safe — mixing flags from different enums is a hard compiler error.
```
var p: Permissions = Read | Write    // combine flags — bitwise OR on u32
p.has(Read)                          // check if set — bool, uses bitwise AND
p.set(Execute)                       // add flag — bitwise OR
p.clear(Write)                       // remove flag — bitwise AND NOT
p.toggle(Read)                       // toggle flag — bitwise XOR
```

### Methods on Enums
Same rules as structs — `self` as first argument, match on self inside:
```
enum Shape(u32) {
    Circle(radius: f32)
    Rectangle(width: f32, height: f32)
    Point

    func area(self: const &Shape) f32 {
        match self {
            Circle    => { return 3.14 * Circle.radius * Circle.radius }
            Rectangle => { return Rectangle.width * Rectangle.height }
            Point     => { return 0.0 }
        }
    }
}
```
