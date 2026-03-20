// ═══════════════════════════════════════════════════════════
// Kodr — Complete Syntax Overview
// Every language construct in one file.
// ═══════════════════════════════════════════════════════════

// ── Module & Metadata ───────────────────────────────────────

module main

#name    = "myproject"
#version = Version(1, 0, 0)
#build   = exe
#bitsize = 32

// ── Imports ─────────────────────────────────────────────────

import std::console
import std::fs
import std::math
import std::mem
import mymodule
import std::utils as u

// ── Variables ───────────────────────────────────────────────

var counter: i32 = 0
const MAX: i32 = 100
const PI: f64 = 3.14159
const name: String = "hello"
const hex: u32 = 0xFF
const bin: u8 = 0b1010
const oct: u8 = 0o77
const big: i64 = 1_000_000

// ── Functions ───────────────────────────────────────────────

func add(a: i32, b: i32) i32 {
    return a + b
}

pub func greet(name: String) String {
    return "hello " ++ name
}

func divide(a: i32, b: i32) (Error | i32) {
    if(b == 0) { return Error("division by zero") }
    return a / b
}

func find(id: i32) (null | i32) {
    if(id < 0) { return null }
    return id * 10
}

// ── Compt Functions (compile-time) ──────────────────────────

compt func doubled(n: i32) i32 {
    return n * 2
}

compt func Vec2(T: any) type {
    return struct {
        x: T
        y: T
    }
}

// ── Generic Functions ───────────────────────────────────────

func identity(val: any) any {
    return val
}

compt func describe(val: any) String {
    if(val is i32) { return "integer" }
    if(val is not f32) { return "not float" }
    return "other"
}

// ── Function Pointers ───────────────────────────────────────

func negate(x: i32) i32 { return 0 - x }
func apply(f: func(i32) i32, x: i32) i32 { return f(x) }
const fp: func(i32) i32 = negate

// ── Structs ─────────────────────────────────────────────────

struct Player {
    pub name: String
    health: f32 = 100.0
    score: i32 = 0

    var activeCount: i32 = 0
    const maxPlayers: i32 = 64

    func create(n: String) Player {
        return Player(name: n)
    }

    func isAlive(self: const &Player) bool {
        return self.health > 0.0
    }

    func takeDamage(self: var &Player, amount: f32) void {
        self.health = self.health - amount
    }

    func destroy(self: Player) void { }
}

var p: Player = Player(name: "hero", health: 50.0)
var p2: Player = Player.create("hero")

// ── Enums ───────────────────────────────────────────────────

enum Direction(u8) {
    North
    South
    East
    West

    func opposite(self: const &Direction) Direction {
        match(self) {
            North => { return South }
            South => { return North }
            East  => { return West }
            West  => { return East }
        }
        return North
    }
}

enum Shape(u32) {
    Circle(radius: f32)
    Rectangle(width: f32, height: f32)
    Point
}

const d: Direction = North
const s: Shape = Circle(radius: 5.0)

// ── Bitfields ───────────────────────────────────────────────

bitfield Permissions(u32) {
    Read
    Write
    Execute
}

var perms: Permissions = Permissions(Read, Write)
perms.set(Execute)
perms.clear(Write)
perms.toggle(Read)
const hasRead: bool = perms.has(Read)

// ── Tuples ──────────────────────────────────────────────────

func minMax(a: i32, b: i32) (min: i32, max: i32) {
    if(a < b) { return (min: a, max: b) }
    return (min: b, max: a)
}

const result = minMax(3, 7)
const x: i32 = result.min
const min, max = minMax(3, 7)

// ── Error Handling ──────────────────────────────────────────

const ErrNotFound: Error = Error("not found")

func safeDivide(a: i32, b: i32) (Error | i32) {
    if(b == 0) { return Error("division by zero") }
    return a / b
}

const r = safeDivide(10, 2)
if(r is Error) { }
if(r is not Error) { const val: i32 = r.i32 }

match(r) {
    Error => { }
    i32   => { }
}

// ── Null Handling ───────────────────────────────────────────

func findPlayer(id: i32) (null | i32) {
    if(id < 0) { return null }
    return id * 10
}

const found: (null | i32) = findPlayer(5)
if(found is null) { }
if(found is not null) { const val: i32 = found.i32 }

var nullable: (null | i32) = null
nullable = 42

match(found) {
    null => { }
    i32  => { }
}

// ── Control Flow ────────────────────────────────────────────

if(x > 0) {
    // ...
} else {
    // ...
}

for(0..10) |i| { }
for(arr) |val| { }
for(arr, 0..) |val, idx| { }

var i: i32 = 0
while(i < 10) : (i += 1) { }
while(true) { break }
for(arr) |val| { if(val == 0) { continue } }

// ── Pattern Matching ────────────────────────────────────────

match(n) {
    1    => { }
    2..5 => { }
    else => { }
}

match(s) {
    "hello" => { }
    "world" => { }
    else    => { }
}

match(d) {
    North => { }
    South => { }
    else  => { }
}

// ── Defer ───────────────────────────────────────────────────

func example() void {
    defer { }
    {
        defer { }
    }
}

// ── Operators ───────────────────────────────────────────────

// arithmetic:     + - * / %
// comparison:     == != < > <= >=
// logical:        and or not
// bitwise:        & | ^ ! >> <<
// concatenation:  ++ (strings and arrays only)
// type check:     is, is not
// assignment:     += -= *= /=

// ── Compiler Functions ──────────────────────────────────────

cast(i64, x)
cast(f32, x)
copy(x)
move(x)
swap(x, y)
assert(x)
assert(x, "message")
size(Player)
align(f64)
typename(x)
typeid(x)

// ── Overflow Helpers ────────────────────────────────────────

wrap(a + b)
sat(a + b)
const checked = overflow(a + b)

// ── Arrays & Slices ─────────────────────────────────────────

const fixed: [3]i32 = [10, 20, 30]
var slice: []i32 = [1, 2, 3, 4, 5]
const part: []i32 = fixed[1..3]
const len: usize = fixed.len
const val: i32 = fixed[0]

// ── Collections ─────────────────────────────────────────────

var items: List(i32) = List(i32)
defer { items.free() }
items.add(10)
items.get(0)
items.set(0, 20)
items.remove(0)

var scores: Map(String, i32) = Map(String, i32)
defer { scores.free() }
scores.put("alice", 42)
if(scores.has("alice")) { scores.get("alice") }
scores.remove("alice")

var seen: Set(i32) = Set(i32)
defer { seen.free() }
seen.add(1)
seen.has(1)
seen.remove(1)

// shared allocator
const alloc = mem.DebugAllocator()
var a: List(i32) = List(i32, alloc)
var b: List(i32) = List(i32, alloc)

// ── String Operations ───────────────────────────────────────

const s: String = "  hello world  "
s.contains("world")
s.startsWith("hello")
s.endsWith("world")
s.trim()
s.trimLeft()
s.trimRight()
s.indexOf("world")
s.lastIndexOf("o")
s.count("o")
const before, after = s.split(" ")

// ── Format ──────────────────────────────────────────────────

const fmt = Format(String, i32)
const msg: String = fmt("{} scored {} points", "alice", 42)

// ── Pointers ────────────────────────────────────────────────

var val: i32 = 10
const ptr: Ptr(i32) = Ptr(i32, &val)
const v: i32 = ptr.value

const raw: RawPtr(i32) = RawPtr(i32, &val)
const rv: i32 = raw[0]

// ── File I/O ────────────────────────────────────────────────

const f: File = File("config.txt")
const content = f.read()
f.write("data")
f.append("more")
f.size()
f.exists()
f.close()

const dir: Dir = Dir("src/")
dir.list()
dir.exists()
dir.close()

fs.exists("path")
fs.delete("path")
fs.rename("old", "new")
fs.createDir("path")
fs.deleteDir("path")

// ── Math ────────────────────────────────────────────────────

const sq: f64 = math.sqrt(16.0)
const pw: f64 = math.pow(2.0, 10.0)
const ab: f64 = math.abs(0.0 - 5.0)
const mn: f64 = math.min(3.0, 7.0)
const mx: f64 = math.max(3.0, 7.0)
const fl: f64 = math.floor(3.7)
const cl: f64 = math.ceil(3.2)
const sn: f64 = math.sin(0.0)
const cs: f64 = math.cos(0.0)
const pi: f64 = math.PI()

// ── Allocators ──────────────────────────────────────────────

const a1 = mem.SMP()
const a2 = mem.DebugAllocator()
const a3 = mem.Arena()
const a4 = mem.Temp(4096)
const a5 = mem.Page()

var buf: []i32 = a2.alloc(i32, 100)
const single: i32 = a2.allocOne(i32, 42)
a2.free(buf)
a2.free(single)
a3.freeAll()

// ── Extern Functions (Zig bridge) ───────────────────────────

extern func doThing(x: i32) void
// paired .zig sidecar file required — same name as module

// ── Testing ─────────────────────────────────────────────────

test "description" {
    assert(add(2, 3) == 5)
    assert(add(2, 3) == 5, "custom message")
}
