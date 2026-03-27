# Architecture Patterns

**Domain:** Language feature implementation architecture for Orhon
**Researched:** 2026-03-27

## Current Architecture

Orhon's 12-pass pipeline is well-structured. New language features slot into existing passes:

```
Source (.orh)
    |
1.  Lexer        -- new keywords here (try, trait, impl)
    |
2.  PEG Parser   -- grammar rules for new syntax
    |
3.  Module Resolution -- unchanged for most features
    |
4.  Declaration Pass  -- trait declarations, impl blocks
    |
5.  Compt & Type Resolution -- trait bounds, derive expansion
    |
6.  Ownership    -- closure capture analysis
    |
7.  Borrow Check -- closure borrow rules
    |
8.  Thread Safety -- unchanged for most features
    |
9.  Error Propagation -- try keyword validation
    |
10. MIR          -- new MirNode variants for new constructs
    |
11. Codegen      -- Zig emission for new constructs
    |
12. Zig Compiler -- unchanged
```

## Feature Implementation Patterns

### Pattern 1: `try` Keyword (Error Propagation)

**Scope:** Lexer, PEG, Resolver, Error Propagation, MIR, Codegen
**Complexity:** Low-Medium

```
// Orhon
var value: i32 = try divide(10, 0)

// Generated Zig
const value = try divide(10, 0);
```

**Implementation path:**
1. Lexer: Add `try` as keyword token
2. PEG: Add `try_expr <- 'try' call_expr` rule
3. Parser: New `NodeKind.try_expr` variant
4. Error Propagation (pass 9): Validate enclosing function returns `(Error | T)`. If not, compile error: "try used in function that does not return Error"
5. MIR: `try_expr` MirNode wrapping inner call
6. Codegen: Emit Zig `try` directly (1:1 mapping)

**Why this is clean:** Direct Zig mapping. No complex transformation needed.

### Pattern 2: Traits / Interfaces

**Scope:** Lexer, PEG, Declarations, Resolver, MIR, Codegen
**Complexity:** Medium-High

**Recommended design:**
```
// Orhon
trait Drawable {
    func draw(self: const &Self) void
    func bounds(self: const &Self) Rect
}

impl Drawable for Circle {
    func draw(self: const &Circle) void { ... }
    func bounds(self: const &Circle) Rect { ... }
}

func render(item: any where Drawable) void {
    item.draw()
}
```

**Implementation path:**
1. Lexer: `trait`, `impl` keywords
2. PEG: `trait_decl`, `impl_block` rules
3. Declarations (pass 4): Collect trait definitions (method signatures), impl registrations (type -> trait -> methods)
4. Resolver (pass 5): When `any where Trait` is instantiated, verify the concrete type has an `impl Trait` block with all required methods. Compile error if missing.
5. MIR: Trait-constrained generics resolve to concrete method calls (monomorphization, not vtables)
6. Codegen: Same as current generic codegen -- generate concrete functions per type

**Key decision -- monomorphization, not vtables:**
Orhon already monomorphizes generics via `any`. Trait-constrained generics should work the same way -- generate a concrete function for each type that satisfies the constraint. This means:
- No runtime overhead (no vtable dispatch)
- Larger binary (one copy per type)
- Same approach as Rust (default), Zig (comptime), C++ (templates)

**Why not vtables:** Orhon targets systems programming where runtime dispatch cost matters. Monomorphization is the right default. If dynamic dispatch is ever needed, it can be added later as an explicit opt-in (`dyn Trait`).

### Pattern 3: Closures

**Scope:** Lexer, PEG, Declarations, Ownership, Borrow, MIR, Codegen
**Complexity:** Medium-High

**Recommended design:**
```
// Orhon
var multiplier: i32 = 5
var transform: func(i32) i32 = func(x: i32) i32 { return x * multiplier }
```

**Implementation path:**
1. Captures: Compiler identifies referenced outer variables (like thread captures -- already done)
2. Ownership: Captured variables follow normal rules -- move into closure by default for `var`, auto-borrow for `const`
3. Codegen: Emit Zig struct with captured fields + call method. This is how Zig handles closures internally.

**Key decision -- capture semantics:**
- `const` captures: auto-borrow as `const &` (read-only, zero cost)
- `var` captures: move into closure (closure owns the value)
- Explicit `copy()` or `&` for other behaviors
- This is consistent with Orhon's existing ownership model

### Pattern 4: `#derive`

**Scope:** PEG, Declarations, Codegen
**Complexity:** Medium (requires traits first)

```
// Orhon
#derive(Eq, Hash)
struct Point {
    x: f32
    y: f32
}

// Compiler generates:
impl Eq for Point {
    func eq(self: const &Point, other: const &Point) bool {
        return self.x == other.x and self.y == other.y
    }
}
impl Hash for Point {
    func hash(self: const &Point, hasher: &Hasher) void {
        hasher.update(self.x)
        hasher.update(self.y)
    }
}
```

**Implementation:** At declaration pass, expand `#derive` into synthetic `impl` blocks by iterating struct fields. This is a compile-time code generation step, not a macro.

## Component Boundaries

| Component | Responsibility | New Features Touch |
|-----------|---------------|--------------------|
| Lexer | Tokenize new keywords | try, trait, impl |
| PEG Grammar | Parse new syntax | All new features |
| Declarations | Collect trait/impl definitions | Traits, derive |
| Resolver | Validate trait bounds on generics | Constrained generics |
| Ownership | Closure capture analysis | Closures |
| Borrow Check | Closure borrow rules | Closures |
| Error Propagation | Validate `try` context | try keyword |
| MIR | New node types | All new features |
| Codegen | Zig emission | All new features |

## Anti-Patterns to Avoid

### Anti-Pattern 1: Vtable Dispatch by Default
**What:** Using virtual method tables for trait method calls
**Why bad:** Runtime overhead on every call, contradicts systems language positioning
**Instead:** Monomorphize -- generate concrete code per type (like Rust's default)

### Anti-Pattern 2: Implicit Closure Captures
**What:** Closures silently capturing mutable references to outer variables
**Why bad:** Breaks ownership model, source of bugs in JavaScript/Python
**Instead:** Move semantics for var captures, auto-borrow for const captures, explicit otherwise

### Anti-Pattern 3: Feature Interaction Explosion
**What:** Adding features that interact in complex ways (e.g., generic closures implementing traits with associated types)
**Why bad:** Exponential complexity in the compiler and for users
**Instead:** Each feature should be simple and self-contained. Interactions should be natural, not designed.

### Anti-Pattern 4: Codegen Special Cases
**What:** Adding if/else branches in codegen for specific language features
**Why bad:** Codegen is already 3000+ lines; special cases compound
**Instead:** New features should map to existing MIR patterns or introduce clean new MirNode types

## Sources

- Orhon COMPILER.md, TODO.md architecture documentation
- Training data on Rust trait implementation, Zig comptime patterns (MEDIUM confidence)
