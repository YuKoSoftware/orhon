// syntaxgen.zig — Orhon syntax reference generator
// Outputs a human-readable language quick-reference with Orhon code examples.

const std = @import("std");

pub fn generateSyntaxDoc(allocator: std.mem.Allocator, output_path: []const u8) !void {
    _ = allocator;
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(SYNTAX_DOC);
    std.debug.print("Generated: {s}\n", .{output_path});
}

const SYNTAX_DOC =
    \\# Orhon — Syntax Reference
    \\
    \\> Auto-generated quick-reference for the Orhon programming language.
    \\
    \\---
    \\
    \\## Modules
    \\
    \\Every `.orh` file starts with a module declaration.
    \\
    \\```orhon
    \\module myapp
    \\```
    \\
    \\### Metadata
    \\
    \\```orhon
    \\#build = exe
    \\#version = 1.0.0
    \\#dep "libs/math"
    \\```
    \\
    \\### Imports
    \\
    \\```orhon
    \\import std::console       // namespaced: console.println(...)
    \\use std::collections      // merged into scope: List(i32)
    \\import mylib as ml        // aliased: ml.doStuff()
    \\```
    \\
    \\---
    \\
    \\## Variables
    \\
    \\```orhon
    \\const x: i32 = 42          // immutable
    \\var count: i32 = 0         // mutable
    \\const name = "hello"       // type inferred
    \\```
    \\
    \\### Destructuring
    \\
    \\```orhon
    \\const a, b, c = getTuple()
    \\var x, y = getPoint()
    \\```
    \\
    \\---
    \\
    \\## Functions
    \\
    \\```orhon
    \\func add(a: i32, b: i32) i32 {
    \\    return a + b
    \\}
    \\
    \\pub func greet(name: str) void {
    \\    console.println(name)
    \\}
    \\```
    \\
    \\### Default parameters
    \\
    \\```orhon
    \\func connect(host: str, port: i32 = 8080) void {
    \\    // ...
    \\}
    \\```
    \\
    \\### Named arguments
    \\
    \\```orhon
    \\connect(host: "localhost", port: 3000)
    \\```
    \\
    \\### Thread functions
    \\
    \\```orhon
    \\thread worker(data: i32) void {
    \\    // runs in a separate thread
    \\}
    \\```
    \\
    \\### Compt (compile-time) functions
    \\
    \\```orhon
    \\pub compt func maxSize() i32 {
    \\    return 1024
    \\}
    \\```
    \\
    \\---
    \\
    \\## Types
    \\
    \\### Primitive types
    \\
    \\`i8` `i16` `i32` `i64` `i128` `u8` `u16` `u32` `u64` `f32` `f64` `bool` `void` `usize` `str`
    \\
    \\### Type aliases
    \\
    \\```orhon
    \\const Speed: type = f64
    \\```
    \\
    \\### Pointer types
    \\
    \\```orhon
    \\const& T         // immutable borrow
    \\mut& T           // mutable borrow
    \\```
    \\
    \\### Slice and array types
    \\
    \\```orhon
    \\[]i32             // slice
    \\[10]i32           // fixed-size array
    \\```
    \\
    \\### Union types
    \\
    \\```orhon
    \\(i32 | f64 | str)          // tagged union
    \\(Error | T)                // error or value
    \\(null | T)                 // null or value
    \\```
    \\
    \\### Function types
    \\
    \\```orhon
    \\func(i32, i32) i32         // function signature type
    \\```
    \\
    \\### Named tuple types
    \\
    \\```orhon
    \\(x: f32, y: f32)           // named tuple
    \\```
    \\
    \\---
    \\
    \\## Structs
    \\
    \\```orhon
    \\pub struct Vec2 {
    \\    pub x: f32
    \\    pub y: f32
    \\}
    \\
    \\struct Player {
    \\    name: str
    \\    health: i32 = 100        // default value
    \\
    \\    pub func create(name: str) Player {
    \\        return Player(name: name)
    \\    }
    \\
    \\    pub func isAlive(self: const& Player) bool {
    \\        return self.health > 0
    \\    }
    \\
    \\    pub func takeDamage(self: mut& Player, amount: i32) void {
    \\        self.health = self.health - amount
    \\    }
    \\}
    \\```
    \\
    \\### Generic structs
    \\
    \\```orhon
    \\struct Pair(T: type) {
    \\    first: T
    \\    second: T
    \\}
    \\```
    \\
    \\### Constructors
    \\
    \\```orhon
    \\const p = Vec2(x: 1.0, y: 2.0)
    \\const hero = Player.create("hero")
    \\```
    \\
    \\---
    \\
    \\## Blueprints (traits)
    \\
    \\```orhon
    \\blueprint Printable {
    \\    func toString() str
    \\}
    \\
    \\struct Point: Printable {
    \\    x: i32
    \\    y: i32
    \\
    \\    pub func toString(self: const& Point) str {
    \\        return "Point"
    \\    }
    \\}
    \\```
    \\
    \\---
    \\
    \\## Enums
    \\
    \\```orhon
    \\pub enum(u8) Color {
    \\    Red
    \\    Green
    \\    Blue
    \\}
    \\
    \\enum(u8) Direction {
    \\    North
    \\    South
    \\    East
    \\    West
    \\
    \\    pub func opposite(self: const& Direction) Direction {
    \\        match(self) {
    \\            North => { return South }
    \\            South => { return North }
    \\            East  => { return West }
    \\            West  => { return East }
    \\        }
    \\        return North
    \\    }
    \\}
    \\```
    \\
    \\### Enums with explicit values
    \\
    \\```orhon
    \\enum(i32) HttpStatus {
    \\    OK = 200
    \\    NotFound = 404
    \\    ServerError = 500
    \\}
    \\```
    \\
    \\---
    \\
    \\## Statements
    \\
    \\### If / elif / else
    \\
    \\```orhon
    \\if (x > 0) {
    \\    console.println("positive")
    \\} elif (x == 0) {
    \\    console.println("zero")
    \\} else {
    \\    console.println("negative")
    \\}
    \\```
    \\
    \\### While loop
    \\
    \\```orhon
    \\while (count < 10) {
    \\    count = count + 1
    \\}
    \\
    \\// with continue expression
    \\while (i < 100) : (i += 1) {
    \\    // ...
    \\}
    \\```
    \\
    \\### For loop
    \\
    \\```orhon
    \\for (items) |val| {
    \\    console.println(val)
    \\}
    \\
    \\// with index
    \\for (items) |val, i| {
    \\    // ...
    \\}
    \\
    \\// range
    \\for (0..10) |i| {
    \\    // ...
    \\}
    \\```
    \\
    \\### Match
    \\
    \\```orhon
    \\match(color) {
    \\    Red   => { console.println("red") }
    \\    Green => { console.println("green") }
    \\    else  => { console.println("other") }
    \\}
    \\```
    \\
    \\### Match with guards
    \\
    \\```orhon
    \\match(value) {
    \\    (x if x > 0)  => { console.println("positive") }
    \\    (x if x == 0) => { console.println("zero") }
    \\    else           => { console.println("negative") }
    \\}
    \\```
    \\
    \\### Match with ranges
    \\
    \\```orhon
    \\match(score) {
    \\    (90..100) => { console.println("A") }
    \\    (80..89)  => { console.println("B") }
    \\    else      => { console.println("C") }
    \\}
    \\```
    \\
    \\### Return
    \\
    \\```orhon
    \\return x + y
    \\```
    \\
    \\### Defer
    \\
    \\```orhon
    \\defer {
    \\    file.close()
    \\}
    \\```
    \\
    \\### Break / Continue
    \\
    \\```orhon
    \\while (true) {
    \\    if (done) { break }
    \\    if (skip) { continue }
    \\}
    \\```
    \\
    \\---
    \\
    \\## Expressions
    \\
    \\### Operators (by precedence, lowest to highest)
    \\
    \\| Level | Operators | Description |
    \\|-------|-----------|-------------|
    \\| 12 | `..` | range |
    \\| 11 | `or` | logical OR |
    \\| 10 | `and` | logical AND |
    \\| 9 | `not` | logical NOT (prefix) |
    \\| 8 | `==` `!=` `<` `>` `<=` `>=` `is` | comparison / type check |
    \\| 7 | `\|` | bitwise OR |
    \\| 6 | `^` | bitwise XOR |
    \\| 5 | `&` | bitwise AND |
    \\| 4 | `<<` `>>` | bit shift |
    \\| 3 | `+` `++` `-` | addition, concatenation |
    \\| 2 | `*` `/` `%` | multiplication |
    \\| 1 | `!` `-` `const&` `mut&` | unary prefix |
    \\| 0 | `.` `[]` `()` | postfix: field, index, call |
    \\
    \\### Assignment operators
    \\
    \\`=` `+=` `-=` `*=` `/=`
    \\
    \\### Type checking
    \\
    \\```orhon
    \\if (value is Error) {
    \\    // handle error
    \\}
    \\if (result is not null) {
    \\    // use result
    \\}
    \\```
    \\
    \\### String interpolation
    \\
    \\```orhon
    \\const msg = "Hello, @{name}! You are @{age} years old."
    \\```
    \\
    \\### Array and slice literals
    \\
    \\```orhon
    \\const nums = [1, 2, 3]
    \\const empty = []
    \\```
    \\
    \\### Tuple literals
    \\
    \\```orhon
    \\const point = (x: 10, y: 20)
    \\```
    \\
    \\### Error literals
    \\
    \\```orhon
    \\const err = Error("something went wrong")
    \\```
    \\
    \\---
    \\
    \\## Compiler Functions
    \\
    \\| Function | Description |
    \\|----------|-------------|
    \\| `@cast(value)` | Type cast |
    \\| `@copy(value)` | Deep copy |
    \\| `@move(value)` | Move ownership |
    \\| `@swap(a, b)` | Swap values |
    \\| `@assert(cond)` | Runtime assertion |
    \\| `@size(T)` | Size of type in bytes |
    \\| `@align(T)` | Alignment of type |
    \\| `@typename(T)` | Type name as string |
    \\| `@typeid(T)` | Unique type identifier |
    \\| `@typeOf(value)` | Type of a value |
    \\| `@hasField(T, name)` | Check if struct has field |
    \\| `@hasDecl(T, name)` | Check if type has declaration |
    \\| `@fieldType(T, name)` | Type of a struct field |
    \\| `@fieldNames(T)` | Names of all struct fields |
    \\
    \\---
    \\
    \\## Collections
    \\
    \\```orhon
    \\use std::collections
    \\
    \\var list = List(i32){}
    \\list.add(1)
    \\list.add(2)
    \\const val = list.get(0)
    \\
    \\var map = Map(str, i32){}
    \\map.put("a", 1)
    \\const v = map.get("a")
    \\
    \\var set = Set(i32){}
    \\set.add(42)
    \\const exists = set.has(42)
    \\```
    \\
    \\---
    \\
    \\## Allocators
    \\
    \\```orhon
    \\import std::allocator
    \\
    \\var smp = allocator.SMP.create()     // production (lock-free)
    \\var dbg = allocator.Debug.create()    // leak detection
    \\var arena = allocator.Arena.create()  // batch allocation
    \\```
    \\
    \\---
    \\
    \\## Tests
    \\
    \\```orhon
    \\test "addition works" {
    \\    const result = add(2, 3)
    \\    @assert(result == 5)
    \\}
    \\```
    \\
    \\---
    \\
    \\## Doc Comments
    \\
    \\```orhon
    \\/// Adds two integers and returns the result.
    \\pub func add(a: i32, b: i32) i32 {
    \\    return a + b
    \\}
    \\```
    \\
    \\---
    \\
    \\## Keywords
    \\
    \\`func` `var` `const` `if` `else` `elif` `for` `while` `return`
    \\`import` `use` `pub` `match` `struct` `enum` `defer` `thread`
    \\`null` `void` `compt` `any` `module` `test` `and` `or` `not` `as`
    \\`break` `continue` `true` `false` `is` `type` `blueprint`
    \\
;

test "syntaxgen generates output" {
    const allocator = std.testing.allocator;
    const tmp = "/tmp/_orhon_syntax_test.md";
    try generateSyntaxDoc(allocator, tmp);
    std.fs.cwd().deleteFile(tmp) catch {};
}
