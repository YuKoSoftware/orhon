# Complete Example

This example covers the entire Kodr language. Read it as a short tutorial.

```
module main

main.build = build.exe
main.version = Version(1, 0, 0)
main.name = "example"

import std::console

// --- NUMERIC LITERALS ---
compt HEX_COLOR: u32 = 0xFF_AA_00
compt MAX_HEALTH: f32 = 100.0
compt BIG_NUMBER: i64 = 1_000_000

// generic function — any resolved at compile time
func identity(val: any) any {
    return val
}

// compt function returning a type
compt func Pair(A: any, B: any) type {
    return struct {
        first: A
        second: B
    }
}

// --- ENUMS ---
// regular enum with explicit backing type
enum Direction(u32) {
    North
    South
    East
    West
}

// bitfield enum — compiler assigns powers of 2
enum Permissions(u32, bitfield) {
    Read      // 0b0001
    Write     // 0b0010
    Execute   // 0b0100
}

// data carrying enum with method
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

// --- STRUCTS ---
struct Player {
    pub name: String
    health: f32 = MAX_HEALTH
    score: i32 = 0

    const maxPlayers: i32 = 64
    var activeCount: i32 = 0

    func create(name: String) Player {
        Player.activeCount = Player.activeCount + 1
        return Player(name: name)
    }

    func isAlive(self: const &Player) bool {
        return self.health > 0.0
    }

    func takeDamage(self: var &Player, amount: f32) void {
        self.health = self.health - amount
    }

    func destroy(self: Player) void {
        Player.activeCount = Player.activeCount - 1
    }
}

// --- TUPLES ---
const MinMax = (min: i32, max: i32)

func findMinMax(arr: []i32) MinMax {
    return MinMax(min: arr[0], max: arr[arr.len - 1])
}

// --- ERROR HANDLING ---
const ErrDivByZero: Error = Error("ERROR: division by zero")

func divide(a: i32, b: i32) (Error | i32) {
    if(b == 0) {
        return ErrDivByZero
    }
    return a / b
}

// null handling
func findPlayer(id: i32) (null | Player) {
    if(id < 0) {
        return null
    }
    return Player.create("found")
}

// recursive function
func fibonacci(n: i32) i32 {
    if(n <= 1) { return n }
    return fibonacci(n - 1) + fibonacci(n - 2)
}

// first class function
const Transform = *const fn(i32) i32

func double(x: i32) i32 {
    return x * 2
}

func applyToAll(arr: []i32, f: Transform) void {
    for(arr) |val| {
        console.println(f(val))
    }
}

func main() void {

    // --- VARIABLES ---
    var x: i32 = 42
    var name = "hello\nworld"
    var flag = true
    const pi: f32 = 3.141_592
    compt SIZE: usize = 1_024

    // --- STRUCT USAGE ---
    var p = Player.create("hero")
    p.takeDamage(10.0)

    if(p.isAlive()) {
        console.println(p.name)
    }

    // --- ENUM USAGE ---
    var d: Direction = North
    match d {
        North => { console.println("going north") }
        South => { console.println("going south") }
        East  => { console.println("going east") }
        West  => { console.println("going west") }
    }

    // --- BITFIELD ENUM ---
    var perms: Permissions = Read | Write
    perms.set(Execute)
    perms.clear(Write)
    perms.toggle(Execute)

    // --- DATA CARRYING ENUM ---
    var s: Shape = Circle(radius: 5.0)
    console.println(s.area())

    // is / is not — type comparison
    if(s is Circle) {
        console.println("its a circle")
    }

    // --- ERROR HANDLING ---
    var result = divide(10, 2)
    if(result is Error) {
        if(result.Error == ErrDivByZero) {
            console.println("division by zero")
        }
        return
    }
    console.println(result.i32)

    // --- NULL HANDLING ---
    var found = findPlayer(1)
    if(found is null) {
        console.println("not found")
        return
    }
    console.println(found.Player.name)

    // --- TUPLES ---
    var min, max = findMinMax([3, 1, 4, 1, 5, 9, 2, 6])
    console.println(min)
    console.println(max)

    // --- COMPT PAIR TYPE ---
    var pair: Pair(i32, String) = Pair(i32, String)(first: 42, second: "hello")
    console.println(pair.first)

    // --- LOOPS ---
    for(0..5) |i| {
        console.println(i)
    }

    for([1, 2, 3, 4, 5], 0..) |val, idx| {
        console.println(val)
        console.println(idx)
    }

    var i: i32 = 0
    while(i < 10) : (i += 1) {
        if(i == 5) { continue }
        console.println(i)
    }

    // --- FIRST CLASS FUNCTIONS ---
    applyToAll([1, 2, 3, 4, 5], double)

    // --- RECURSION ---
    console.println(fibonacci(10))

    // --- COMPILER FUNCTIONS ---
    console.println(size(Player))
    console.println(align(f64))
    console.println(typename(p))
    console.println(typeid(p))

    // --- THREADING ---
    var data: []i32 = [1, 2, 3, 4, 5, 6]
    var left, right = data.splitAt(3)

    Thread([]i32) thread_a { return left }
    Thread([]i32) thread_b { return right }

    var leftResult: []i32 = thread_a.value
    var rightResult: []i32 = thread_b.value

    // async IO
    Async(String) my_request {
        return "fetched data"
    }
    var response = my_request.value

    // --- POINTERS ---
    var val: i32 = 10
    var ptr = Ptr(i32, &val)
    console.println(ptr.value)

    // --- MEMORY ALLOCATION ---
    import std::mem

    var a = mem.GPA()
    var box = a.allocOne(i32, 42)
    console.println(box)
    a.free(box)

    var buf: []i32 = a.alloc(i32, 10)
    a.free(buf)

    // --- DEFER ---
    defer { console.println("cleanup") }
    console.println("before cleanup")
}

test"player takes damage correctly" {
    var p = Player.create("test")
    p.takeDamage(50.0)
    assert(p.health == 50.0)
    assert(p.isAlive())
}

test"divide returns error on zero" {
    var result = divide(10, 0)
    assert(result is Error)
    assert(result.Error == ErrDivByZero)
}

test"fibonacci is correct" {
    assert(fibonacci(0) == 0)
    assert(fibonacci(1) == 1)
    assert(fibonacci(10) == 55)
}
```
