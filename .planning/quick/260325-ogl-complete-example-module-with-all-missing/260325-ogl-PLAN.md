---
phase: quick
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - src/templates/example/example.orh
  - src/templates/example/data_types.orh
  - src/templates/example/advanced.orh
autonomous: true
requirements: [QUICK-01]
must_haves:
  truths:
    - "example module compiles successfully via orhon build (stage 09 passes)"
    - "All implemented builtins (copy, move, swap, size, align, typename) have live examples"
    - "Const auto-borrow pattern is demonstrated with a struct parameter"
    - "Module metadata directives (#name, #version, #build) are documented"
    - "Bridge declarations are explained as comment-only reference"
  artifacts:
    - path: "src/templates/example/example.orh"
      provides: "Module metadata docs, bridge reference comments"
      contains: "#name"
    - path: "src/templates/example/data_types.orh"
      provides: "size/align/typename builtins, copy/move/swap demos"
      contains: "typename"
    - path: "src/templates/example/advanced.orh"
      provides: "Const auto-borrow demo, data-carrying enum comment"
      contains: "auto-borrow"
  key_links:
    - from: "src/templates/example/data_types.orh"
      to: "src/builtins.zig"
      via: "compiler built-in functions"
      pattern: "copy\\(|move\\(|swap\\("
---

<objective>
Complete the example module (living language manual) with all missing implemented language features.

Purpose: The example module ships with every `orhon init` project and must cover every implemented feature. Several builtins and patterns added in recent phases are missing.
Output: Updated example module files that compile and pass stage 09.
</objective>

<execution_context>
@/home/yunus/.claude/get-shit-done/workflows/execute-plan.md
@/home/yunus/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@src/templates/example/example.orh
@src/templates/example/data_types.orh
@src/templates/example/advanced.orh
@src/builtins.zig
@docs/10-structs-enums.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add builtins and metadata to data_types.orh and example.orh</name>
  <files>src/templates/example/data_types.orh, src/templates/example/example.orh</files>
  <action>
**In data_types.orh**, add the following NEW sections before the Tests section:

1. **size() / align() / typename() builtins** section:
```
// --- size / align / typename ---

// size(T) -- compile-time byte size of a type
// align(T) -- compile-time alignment of a type

func size_demo() i32 {
    return size(i32)
}

func align_demo() i32 {
    return align(i64)
}
```
Note: `typename()` returns a string at runtime which is hard to assert on simply. Add it as a compt func or comment-only demo:
```
// typename(value) -- returns the type name as a string at runtime
// Example: typename(42) returns "i32"
```

2. **copy() / move() / swap() ownership builtins** section:
```
// --- Ownership Builtins ---

// copy(value) -- explicit deep copy, bypasses auto-borrow
// move(value) -- explicit move, original becomes invalid

func copy_demo() i32 {
    const a: [3]i32 = [1, 2, 3]
    var b: [3]i32 = copy(a)
    b[0] = 99
    return b[0]
}

// swap(a, b) -- swaps two values in place

func swap_demo() i32 {
    var x: i32 = 10
    var y: i32 = 20
    swap(x, y)
    return x
}
```

3. Add tests for the new functions:
```
test "size and align" {
    assert(size_demo() == 4)
    assert(align_demo() == 8)
}

test "copy" {
    assert(copy_demo() == 99)
}

test "swap" {
    assert(swap_demo() == 20)
}
```

**In example.orh**, add a documentation section near the top (after the Constants section, before Structs):

1. **Module Metadata** section (comment-only, since metadata is in the anchor file main.orh):
```
// --- Module Metadata Directives ---

// These directives go in the module's anchor file (e.g. main.orh):
//   #name    = "myproject"        -- project name
//   #version = Version(1, 0, 0)   -- semantic version
//   #build   = exe                -- build target: exe, lib, staticlib, dynlib
//   #bitsize = 32                 -- default integer/float width (32 or 64)
```

2. **Bridge Declarations** section (comment-only, since bridges are stdlib-internal):
```
// --- Bridge Declarations ---

// bridge functions declare an Orhon interface backed by a Zig sidecar file.
// Used in std modules — not typically in user code.
//
//   pub bridge func get(source: String, path: String) (Error | String)
//
// The compiler pairs the .orh file with a same-name .zig sidecar,
// re-exporting the Zig implementation through the Orhon type system.
```

IMPORTANT: Keep all existing code in both files untouched. Only ADD new sections. Follow the existing style: `// --- Section Name ---` headers (match file convention), 1 blank line between comment and code.

Check the file's existing section header style before writing. data_types.orh uses `// --- X ---` style. example.orh uses `// --- X ---` with long dash lines. Match each file's style exactly.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build 2>&1 | head -5</automated>
  </verify>
  <done>All new sections added, compiler builds without errors (templates are @embedFile'd)</done>
</task>

<task type="auto">
  <name>Task 2: Add const auto-borrow demo and data-carrying enum comment to advanced.orh</name>
  <files>src/templates/example/advanced.orh</files>
  <action>
**In advanced.orh**, add the following NEW sections before the Tests section:

1. **Const Auto-Borrow** section — demonstrates Phase 8 feature where passing a const struct to a function auto-promotes to `*const T`:
```
// --- Const Auto-Borrow ---

// When a const struct is passed to a function taking a value parameter,
// the compiler automatically borrows it as *const T at the call site.
// No copy is made — the callee receives a read-only reference.

struct Vec2 {
    pub x: f64
    pub y: f64
}

func vec2_sum(v: Vec2) f64 {
    return v.x + v.y
}

func auto_borrow_demo() i32 {
    const v: Vec2 = Vec2(x: 3.0, y: 4.0)
    // v is const — compiler auto-borrows as &v at call site
    const s: f64 = vec2_sum(v)
    if(s == 7.0) { return 1 }
    return 0
}

// copy() bypasses auto-borrow — produces an owned mutable copy

func copy_bypass_demo() i32 {
    const v: Vec2 = Vec2(x: 1.0, y: 2.0)
    var v2: Vec2 = copy(v)
    v2.x = 10.0
    return cast(i32, v2.x)
}
```

2. **Data-Carrying Enums** section (COMMENT ONLY — parsed but codegen not yet complete):
```
// --- Data-Carrying Enums (planned) ---

// Orhon supports enum variants with attached data (parsed, codegen in progress):
//
//   enum(u32) Shape {
//       Circle(radius: f32)
//       Rectangle(width: f32, height: f32)
//       Point
//   }
//
//   var s: Shape = Circle(radius: 5.0)
//
//   match s {
//       Circle    => { var area: f32 = 3.14 * Circle.radius * Circle.radius }
//       Rectangle => { var area: f32 = Rectangle.width * Rectangle.height }
//       Point     => { }
//   }
```

3. Add tests for the new live functions:
```
test "auto-borrow" {
    assert(auto_borrow_demo() == 1)
}

test "copy bypass" {
    assert(copy_bypass_demo() == 10)
}
```

IMPORTANT: Keep all existing code untouched. Only ADD new sections. Match the file's existing style: `// --- X ---` section headers with long dash lines.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && ./testall.sh 2>&1 | tail -20</automated>
  </verify>
  <done>All new sections compile, testall.sh passes (especially stages 09 and 10), const auto-borrow and copy bypass are live examples, data-carrying enums are documented as comment-only</done>
</task>

</tasks>

<verification>
1. `zig build` succeeds (templates compile via @embedFile)
2. `./testall.sh` passes all 11 stages
3. `orhon init` + `orhon build` in a temp dir produces a working binary with the updated example module
</verification>

<success_criteria>
- Example module covers: copy(), move(), swap(), size(), align(), typename(), const auto-borrow, module metadata, bridge declarations (comment), data-carrying enums (comment)
- All new live code compiles and tests pass
- Stage 09 (language features) passes
- No existing examples broken
</success_criteria>

<output>
After completion, create `.planning/quick/260325-ogl-complete-example-module-with-all-missing/260325-ogl-SUMMARY.md`
</output>
