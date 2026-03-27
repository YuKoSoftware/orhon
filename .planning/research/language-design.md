# Language Design Research: Modern Trends Informing Orhon

**Domain:** Programming language design, developer experience, tooling
**Researched:** 2026-03-27
**Overall confidence:** MEDIUM (based on training data through early 2025; web search/fetch unavailable for live verification)

**Caveat:** All findings below are sourced from training data. No live web verification was possible during this research session. Findings are marked with confidence levels. Claims about specific library versions or very recent (2025-2026) developments should be independently verified.

---

## 1. Language Features Trending in 2024-2026

### What New Languages Are Doing

**Gleam** (BEAM target, v1.0 shipped March 2024) [MEDIUM confidence]
- **Use-based type inference** -- types flow from how values are used, minimal annotations needed
- **Labeled arguments** with reordering -- `greet(name: "Jo", greeting: "Hi")` in any order
- **Use expressions** for resource cleanup (like Go's `defer` but with guarantees)
- **No mutation at all** -- immutable everything, functional core
- **Dead simple generics** -- no constraints, just parametric polymorphism
- **Excellent error messages** -- Elm-inspired, always showing what was expected vs what was found
- **Key insight for Orhon:** Gleam proves that extreme simplicity can be a feature, not a limitation. Their community grew fast because the language is learnable in a weekend.

**Roc** (LLVM target, pre-1.0) [MEDIUM confidence]
- **Platform system** -- separates pure app logic from I/O effects. Apps declare which "platform" they run on (web server, CLI, game engine), and the platform provides all I/O capabilities
- **Abilities** (like traits/interfaces but simpler) -- `Eq`, `Hash`, etc. with no inheritance hierarchy
- **Automatic memory management without GC** -- reference counting with compile-time elision of unnecessary refcount operations (morphic analysis)
- **Tag unions** that are open by default -- `[Ok value, Err problem]` without declaring a type upfront
- **Key insight for Orhon:** The platform/app separation is philosophically interesting -- it forces clean architecture. Orhon's bridge system is conceptually similar (isolate unsafe I/O in Zig sidecars).

**Mojo** (MLAI-focused, Python superset) [MEDIUM confidence]
- **Ownership model inspired by Rust** but with `borrowed` (immutable ref), `inout` (mutable ref), `owned` (transfer) keywords on function parameters
- **`var` vs `let`** for mutability (later simplified)
- **SIMD-first** -- `SIMD[DType.float32, 4]` as first-class type
- **Compile-time metaprogramming** via `alias` and `@parameter` decorators
- **Progressive typing** -- can write untyped Python-like code or fully typed systems code
- **Key insight for Orhon:** Mojo's parameter keywords (`borrowed`, `inout`, `owned`) are remarkably close to Orhon's `const &T`, `&T`, `T` convention. Orhon's approach is cleaner (uses type syntax, not extra keywords).

**Vale** (novel memory safety approach) [LOW confidence -- project velocity uncertain]
- **Generational references** -- each allocation has a generation counter; references carry the generation they were created with; mismatch = runtime error (but very fast, ~0.5% overhead claimed)
- **Region borrowing** -- entire regions of the heap can be immutably borrowed, enabling safe concurrent access without per-object borrow tracking
- **Key insight for Orhon:** Vale's approach is interesting as a "what if we accepted tiny runtime cost for massive simplicity gains." Orhon chose Rust-style compile-time-only checking, which is the right call for a Zig-targeting language, but Vale's region concept could inform future batch-safety features.

**Hylo** (formerly Val, by Dave Abrahams) [MEDIUM confidence]
- **Mutable value semantics** -- the core innovation. All types have value semantics (like Swift structs), but the compiler uses in-place mutation under the hood when safe (no copies needed if no one else can see the value)
- **Law of exclusivity** enforced at compile time -- if you have a mutable reference, no one else can access the value
- **No reference types at all** -- everything is a value, period. References exist only as function parameters
- **Key insight for Orhon:** Hylo validates Orhon's "no returning references" rule. Hylo takes it further -- no reference types at all. Orhon's `Ptr(T)` / `RawPtr(T)` escape hatches are pragmatic for systems work that Hylo doesn't target.

**Austral** (linear types for safety) [MEDIUM confidence]
- **Linear types** -- every value must be used exactly once. Cannot be silently dropped, cannot be duplicated
- **Capability-based security** -- I/O operations require a capability token that must be passed explicitly
- **Explicit universe system** -- types are either "Free" (can be copied/dropped) or "Linear" (must be consumed exactly once)
- **Key insight for Orhon:** Austral's linear types are a stricter version of Orhon's ownership. The capability-based I/O is interesting but likely too academic for Orhon's "simplicity" goal. The explicit universe (Free vs Linear) concept maps well to Orhon's "primitives copy, non-primitives move" distinction.

**Carbon** (Google, C++ successor) [MEDIUM confidence]
- **Bidirectional C++ interop** -- can call C++ from Carbon and vice versa with zero overhead
- **Checked and unchecked generics** -- can choose between C++-template-style (unchecked, any operation allowed) and Rust-trait-style (checked, only allowed operations)
- **Pattern matching** on types with `match`
- **Key insight for Orhon:** Carbon's "checked + unchecked" generics dual mode is interesting. Orhon currently has unchecked generics (`any` resolves at instantiation). Adding optional constraints (`T where T: Hashable`) -- already in TODO -- is the right next step.

**Flix** (JVM, functional + logic) [LOW confidence]
- **First-class Datalog constraints** -- logic programming built into the type system
- **Polymorphic effects** -- functions declare what effects they perform (IO, State, etc.)
- **Stratified negation in Datalog** -- sound logic programming without runtime surprises
- **Key insight for Orhon:** Too academic for Orhon's audience. Effect systems are worth tracking (see section 3) but Flix's approach is research-grade.

### Synthesis: What Developers Want (2024-2026)

Based on discourse patterns across HN, Reddit r/ProgrammingLanguages, and language community forums [LOW-MEDIUM confidence]:

1. **Simplicity over power** -- Gleam's rapid adoption proves developers are tired of complex languages. They want fewer features done well, not more features done adequately.

2. **Memory safety without lifetime annotations** -- The #1 Rust complaint. Developers want Rust's guarantees without Rust's learning curve. Orhon's "no lifetime annotations ever" is a strong differentiator.

3. **Fast compilation** -- Zig's fast compilation is a major draw. Orhon inherits this via transpilation. This matters more than most language designers think.

4. **Good error messages** -- Elm, Gleam, and Rust set the bar. "Did you mean X?" suggestions, showing expected vs actual, linking to docs. This is table-stakes now.

5. **Sum types / algebraic data types** -- Every new language has them. Orhon has unions and data-carrying enums, which covers this.

6. **Pattern matching** -- Orhon has `match`. Pattern guards (`case x if x > 0`) are in TODO and should be prioritized.

7. **Null safety** -- Orhon's `(null | T)` is the right approach. Every modern language does this now.

---

## 2. Type System Innovations

### What's Practical for a Simplicity-Focused Language

**Algebraic Effects** [MEDIUM confidence]
- **What:** Functions declare what "effects" they perform (IO, State, Exception, Async). Callers must handle these effects. Pioneered by Eff, adopted by Koka, explored by OCaml 5.
- **Practical benefit:** Unifies error handling, async, and state into one mechanism. A function that does IO and might fail has type `() -> {IO, Error} int`.
- **For Orhon:** TOO COMPLEX. Effects are elegant in theory but add significant cognitive load. Orhon's approach (errors via union types, IO via bridge) is simpler and sufficient. Algebraic effects are a solution looking for a problem in systems languages.
- **Verdict:** Skip. Not aligned with Orhon's simplicity goal.

**Refinement Types** [MEDIUM confidence]
- **What:** Types with predicates. `type Positive = { x: i32 | x > 0 }`. Checked at compile time when possible, runtime when not. Languages: Liquid Haskell, F*, some TypeScript libraries.
- **Practical benefit:** Catches invalid states at the type level. A function taking `Positive` can never receive 0 or negative.
- **For Orhon:** A lightweight version could be valuable. Rather than full refinement types (which require SMT solvers), consider **newtype wrappers with validation**:
  ```
  struct Positive {
      value: i32
      func new(v: i32) (Error | Positive) {
          if(v <= 0) { return Error("must be positive") }
          return Positive(value: v)
      }
  }
  ```
  Orhon can already do this. No language change needed -- just document the pattern.
- **Verdict:** Skip as a language feature. Document the struct-validation pattern instead.

**Dependent Types (practical subset)** [MEDIUM confidence]
- **What:** Types that depend on values. `Vector(n, T)` where `n` is a runtime value, not just a type parameter. Full dependent types (Idris, Agda) are research-grade.
- **Practical subset:** Zig's `comptime` is essentially "dependent types for the practical programmer." Orhon's `compt` inherits this.
- **For Orhon:** Already have the practical subset via `compt`. No need for more.
- **Verdict:** Already covered by `compt`.

**Row Polymorphism** [MEDIUM confidence]
- **What:** Functions that work on any struct/record containing at least certain fields. `func getName(r: { name: String, ...rest }) String`. Languages: OCaml (object types), PureScript, Gleam (in a limited way).
- **Practical benefit:** Ad-hoc polymorphism without interfaces/traits. Any struct with a `name: String` field works.
- **For Orhon:** Interesting but conflicts with nominal typing philosophy. Orhon uses named types everywhere (tuples are nominal, not structural). Adding structural typing would be a philosophical contradiction.
- **Verdict:** Skip. Would undermine Orhon's nominal type system.

**Structural Typing** [MEDIUM confidence]
- **What:** Type compatibility based on structure, not name. Go interfaces work this way.
- **For Orhon:** Explicitly rejected -- Orhon tuples with identical fields but different names are different types. This is the right call for safety.
- **Verdict:** Already decided against. Correct decision.

**Trait/Interface System** [HIGH confidence -- well-understood space]
- **What:** Declaring behavioral contracts that types can implement. Rust traits, Go interfaces, Haskell typeclasses, Swift protocols.
- **For Orhon:** The TODO mentions "generic constraints" (`T where T: Drawable`). This is the right next step. Recommendation:
  - Use `trait` keyword (familiar, clear)
  - Explicit `impl Trait for Type` (no automatic/structural satisfaction)
  - Keep it simple: methods only, no associated types initially
  - No trait inheritance (composition via requiring multiple traits)
  ```
  trait Drawable {
      func draw(self: const &Self) void
  }

  impl Drawable for Circle {
      func draw(self: const &Circle) void { ... }
  }

  func render(item: any where Drawable) void {
      item.draw()
  }
  ```
- **Verdict:** HIGH PRIORITY. Needed for generic constraints. Keep it minimal.

### Recommendation for Orhon's Type System Evolution

1. **Traits/interfaces** -- the single most impactful type system addition. Enables constrained generics, which are already in TODO.
2. **Everything else** -- skip. Orhon's type system is already well-designed for its niche. Adding complexity without clear payoff contradicts the "Zig-level simplicity" goal.

---

## 3. Error Handling Evolution

### Current Landscape

**Orhon's approach** -- `(Error | T)` union types with mandatory handling. Maps to Zig's `anyerror!T`. Clean, simple, zero-cost.

**How other languages handle errors:**

| Language | Mechanism | Boilerplate | Safety |
|----------|-----------|-------------|--------|
| Rust | `Result<T, E>` + `?` operator | Low (with `?`) | High |
| Zig | `anyerror!T` + `try` + `catch` | Low | High |
| Go | `(T, error)` tuple return | HIGH | Medium (can ignore) |
| Swift | `throws` + `try` + typed throws (5.9+) | Medium | High |
| Kotlin | Exceptions + `Result<T>` | Low | Medium |
| Gleam | `Result(value, error)` + `use` | Low | High |

**Trends in error handling (2024-2025):** [MEDIUM confidence]

1. **The `?` operator pattern is winning.** Rust popularized it, Zig has `try` (equivalent), Swift added `try`. Developers want single-character error propagation. Orhon should consider this.

2. **Typed/structured errors** -- Swift 5.9 added typed throws (`throws(MyError)`). Rust always had typed errors. The trend is away from stringly-typed errors toward structured error types. Orhon's `Error("message")` is stringly-typed, mapping to Zig error codes. This is simpler but less expressive.

3. **Error context/wrapping** -- Rust's `anyhow` and `thiserror` crates show developers want to add context to errors as they propagate. Go's `fmt.Errorf("opening config: %w", err)` wrapping pattern. Currently hard in Orhon since errors are flat strings.

4. **Gleam's `use` expression** -- syntactic sugar that flattens nested Result handling:
   ```gleam
   use user <- result.try(find_user(id))
   use profile <- result.try(load_profile(user))
   Ok(render(profile))
   ```
   This eliminates the "pyramid of doom" from nested error checks.

### Recommendations for Orhon

**SHORT TERM -- Add `try` keyword for error propagation:**
```
// Current (verbose)
var result: (Error | i32) = divide(10, 0)
if(result is Error) { return result.Error }
var value: i32 = result.value

// With try (concise)
var value: i32 = try divide(10, 0)    // propagates error to caller if Error
```
This is essentially what Zig's `try` does, and Orhon maps to Zig anyway. The function must return `(Error | T)` to use `try`. Compile error otherwise.

**MEDIUM TERM -- Error context:**
Consider allowing error wrapping or chaining. This could be as simple as:
```
var value: i32 = try divide(10, 0) else Error("division failed in calculate()")
```
Where `else Error(...)` replaces the original error with a contextual one.

**SKIP -- Effect-based error handling.** Too complex, doesn't fit the language philosophy.

---

## 4. Developer Tooling That Matters

### Tier 1: Table Stakes (must have for adoption) [HIGH confidence]

| Tool | Status in Orhon | Priority |
|------|----------------|----------|
| **Formatter** (`orhon fmt`) | Exists, basic | Enhance (line-length awareness in TODO) |
| **LSP** | Exists, basic | Enhance (incremental sync in TODO) |
| **Package manager** | Not started | HIGH -- see below |
| **Build system** | Exists (`orhon build`) | Good, extend for C/C++ sources |
| **Test runner** | Exists (`orhon test`) | Good |
| **Error messages** | Basic | CRITICAL to improve (see TODO) |

**Package manager is the biggest gap.** Every successful language ships one:
- Rust: Cargo (integral to adoption, universally praised)
- Go: Go modules (builtin)
- Zig: build.zig.zon + package manager (still maturing)
- Gleam: gleam add/remove (simple, effective)

Orhon has `#dep` syntax and `Version` tuples but no actual dependency resolution, registry, or fetching. This is fine for now (the language is pre-1.0) but will be critical before wider adoption.

### Tier 2: Expected for Serious Use [HIGH confidence]

| Tool | Impact | Notes |
|------|--------|-------|
| **Documentation generator** | High | `orhon gendoc` exists (from `///` comments). Good. |
| **Debugger integration** | High | In TODO. Debug symbols + source mapping from `.orh` -> generated Zig -> binary. Hard but essential. |
| **Playground / REPL** | Medium | Web playground lowers adoption barrier significantly. Not a REPL (compiled language), but an online sandbox. |
| **Syntax highlighting** | High | VS Code extension exists. Good. |
| **Profiler** | Medium | Can lean on Zig/system profilers initially |

### Tier 3: Nice to Have [MEDIUM confidence]

| Tool | Impact | Notes |
|------|--------|-------|
| **Linter** | Low | Formatter + compiler warnings cover most cases |
| **Migration tool** | Low | Too early |
| **Benchmark framework** | Medium | Could be built as a library, not language feature |
| **Tree-sitter grammar** | Medium | Enables highlighting in many editors. Should exist alongside the PEG grammar |

### Recommendations

1. **Error messages are the single highest-ROI tooling investment.** Every user hits errors. Good messages = faster learning = more adoption = bigger community. Invest heavily here.

2. **Package manager can wait** until the language stabilizes more, but design the `#dep` system with future resolution in mind.

3. **Web playground** (even simple) dramatically lowers the "try it" barrier. Gleam's playground drove significant adoption. Could compile to WASM (Orhon already targets `wasm32-freestanding`).

4. **Tree-sitter grammar** enables highlighting in Neovim, Helix, Zed, and other modern editors beyond VS Code. Worth doing.

---

## 5. Compile-Time Computation Trends

### Landscape [HIGH confidence -- well-understood space]

| Language | Mechanism | Power | Complexity |
|----------|-----------|-------|------------|
| Zig | `comptime` | Very high -- arbitrary code at compile time | Medium -- same language, but compile errors can be confusing |
| Rust | `const fn` + const generics | Medium -- growing, but still limited | Low |
| D | CTFE | Very high -- almost all D code can run at compile time | Medium |
| Nim | Macros + `static` blocks | Very high -- AST manipulation | High |
| C++ | `constexpr` + `consteval` | Growing | High (C++ complexity) |
| Mojo | `alias` + `@parameter` | High | Medium |

### What Orhon Has

Orhon's `compt` maps directly to Zig's `comptime`. This is already one of the most powerful compile-time systems in any language. Key capabilities:
- Type generation (`compt func Box(T: type) type`)
- First-class `type` values
- Compile-time function execution
- Generic instantiation via `any`

### Trends and Recommendations

1. **Compile-time reflection** is the next frontier. Zig's `@typeInfo()` enables powerful generic code. Orhon should expose this via `compt` functions that inspect types:
   ```
   compt func fields(T: type) []FieldInfo { ... }
   ```
   This enables serialization, debugging, and generic algorithms. [MEDIUM confidence on timing]

2. **Compile-time string processing** -- generating code from strings, format string validation at compile time. Zig does this with `comptime` + `@Type`. Orhon's string interpolation could be validated at compile time.

3. **Declarative derive** -- Rust's `#[derive(Debug, Clone, PartialEq)]` is enormously popular. Rather than macros, Orhon could use `compt` to generate standard implementations:
   ```
   #derive(Eq, Hash, Debug)
   struct Point {
       x: f32
       y: f32
   }
   ```
   This requires traits (see section 2) as a prerequisite.

4. **DON'T add macros.** Zig explicitly avoids macros, and Orhon should too. `compt` + traits + `#derive` covers the use cases without the complexity and readability costs of macro systems.

---

## 6. FFI and Interop Patterns

### How Orhon's Bridge Compares [HIGH confidence]

Orhon's bridge system is actually well-designed relative to the competition:

| Language | FFI Approach | Orhon Comparison |
|----------|-------------|-----------------|
| Rust | `extern "C"`, `bindgen`, `cbindgen` | Orhon's bridge is simpler -- the Zig sidecar handles all C interop |
| Go | `cgo` -- inline C in Go files | Messy, slow. Orhon's approach is cleaner |
| Zig | Native C interop, `@cImport` | Orhon delegates to Zig's C interop via bridge. Smart. |
| Swift | C/ObjC bridging header | Complex, Apple-specific |
| Carbon | Native C++ interop | Ambitious but Carbon-specific |
| Mojo | Python interop via import | Different domain |

**Orhon's key advantage:** By targeting Zig, Orhon gets Zig's excellent C interop for free. The bridge system is the right abstraction -- it keeps the complexity in Zig where it belongs.

### Gaps and Recommendations

1. **C/C++ source compilation** (already in TODO) -- `#linkC` exists for linking, but compiling `.c`/`.cpp` as part of the build is missing. This is the #1 FFI gap. Tamga hits this with VMA.

2. **Binding generator** -- Currently users write bridge declarations by hand. A tool that reads C headers and generates `.orh` bridge + `.zig` sidecar pairs would dramatically reduce FFI friction:
   ```bash
   orhon bindgen vulkan.h --module vulkan
   # generates vulkan.orh (bridge declarations) + vulkan.zig (sidecar)
   ```
   This is a significant project but high-impact for systems programming use.

3. **Bridge struct layout control** -- For C interop, struct field order and padding matter. Orhon should support `#packed` or `#extern` annotations that guarantee C-compatible layout:
   ```
   #extern
   struct SDL_Event {
       event_type: u32
       timestamp: u64
   }
   ```
   This maps to Zig's `extern struct`.

4. **Callback support** -- Passing Orhon functions as C callbacks requires function pointer types with C calling convention. The bridge system should support:
   ```
   bridge func setCallback(cb: extern func(i32) void) void
   ```

---

## 7. Community Building for New Languages

### What Works [MEDIUM confidence -- based on observed patterns]

**Gleam's approach (fastest-growing new language 2024):**
- **Friendly, inclusive community tone** -- explicit code of conduct, welcoming to beginners
- **Excellent documentation from day 1** -- language tour, cookbook, standard library docs
- **Small, focused language** -- learnable in a weekend
- **Regular release cadence** with clear changelogs
- **Discord community** -- real-time help, low barrier
- **"Gleam by example"** -- practical code snippets for common tasks
- **Package ecosystem** (Hex.pm integration) -- easy to publish and discover packages

**Zig's approach:**
- **Andrew Kelley's talks and streams** -- personality-driven, technical depth
- **"Software I'm Interested In" newsletter** -- regular communication
- **Zig Software Foundation** -- institutional backing
- **Compiler development in public** -- issues, PRs, design discussions all visible
- **Focus on "replacing C/C++"** -- clear mission that attracts a specific audience
- **Excellent compiler error messages** -- first impression matters

**Roc's approach:**
- **"Fast, friendly, functional"** -- three-word pitch
- **Zulip chat** -- public, searchable, archival
- **Contributor-friendly** -- explicit "good first issue" labeling
- **Design philosophy docs** -- explaining WHY decisions were made, not just WHAT

### What Doesn't Work
- **Complexity as a selling point** -- "our type system can express X" does not attract users
- **No documentation** -- kills adoption faster than any other factor
- **Breaking changes without migration paths** -- erodes trust
- **"It's like Rust but..."** -- being defined by another language limits your identity

### Recommendations for Orhon

1. **One-sentence pitch is strong:** "A simple yet powerful language that is safe." Keep using this.

2. **Example module as living manual is genius.** This is Orhon's best community feature. Every `orhon init` gives users a working reference. Keep it updated.

3. **Web playground** -- this is the single biggest adoption accelerator for new languages. Gleam, Go, Rust, Zig all have them. Orhon can target WASM.

4. **"Orhon by Example"** website -- short, focused examples for every feature. Like "Go by Example" or "Rust by Example." Can be auto-generated from the example module.

5. **Design rationale documentation** -- Explain WHY Orhon chose "no closures," "no lifetime annotations," "nominal tuples." These are interesting design decisions that attract language enthusiasts and help users understand the philosophy.

6. **Blog/changelog** -- Regular updates ("What's new in Orhon 0.11") build momentum and show the project is alive.

---

## 8. Orhon-Specific Opportunities

Based on the research above and deep reading of Orhon's current state, here are the highest-impact opportunities:

### Already on the Right Track
- **No lifetime annotations** -- This is Orhon's killer feature vs Rust. Every new language designer cites lifetime annotations as the #1 barrier to Rust adoption. Orhon solves this with lexical lifetimes + no reference returns.
- **Bridge system** -- Cleaner than any FFI I've seen in new languages. The "all interop through Zig" decision is smart.
- **`compt`** -- Direct mapping to Zig's most powerful feature. No other transpiled language gets this right.
- **Explicit allocators** -- Aligns with the Zig philosophy and systems programming expectations.
- **Named construction** -- `Player(name: "john", score: 0)` is clearer than positional args. Good decision.

### Highest-Impact Next Steps (ordered)

1. **`try` keyword for error propagation** -- Single biggest ergonomic improvement. Eliminates 3-4 lines of boilerplate per error-returning call. Maps cleanly to Zig's `try`.

2. **Traits / interfaces** -- Prerequisite for constrained generics, `#derive`, and numerous library patterns. Keep it minimal: methods only, explicit `impl`, no inheritance.

3. **Error message quality** -- "Did you mean X?" suggestions, expected vs actual displays, fix suggestions for ownership/borrow violations. This is the highest-ROI tooling work.

4. **Pattern guards in match** -- `case x if x > 0`. Small feature, big ergonomic win. Already in TODO.

5. **`#derive` for common traits** -- Once traits exist, `#derive(Eq, Hash, Debug)` eliminates massive boilerplate. Implement via `compt`, not macros.

6. **C/C++ source compilation** -- Unblocks Tamga and any serious systems project. Already in TODO.

7. **First-class closures** -- Already in TODO. Needed for callbacks, event handlers, functional patterns. Keep them simple: `fn(T) R` with captured environment, ownership of captures follows normal rules.

### Features to Explicitly NOT Add

| Feature | Why Not |
|---------|---------|
| Macros | `compt` covers the use cases without readability costs. Zig made this choice and it's correct. |
| Algebraic effects | Too complex. Orhon's union-based errors + bridge-based I/O is simpler and sufficient. |
| Row polymorphism / structural typing | Contradicts Orhon's nominal type system. Consistency matters more than flexibility here. |
| Garbage collection | Contradicts the systems language positioning. Explicit allocators are the right choice. |
| Exceptions | Already decided against. Union-based errors are better in every way for a compiled language. |
| Operator overloading | Leads to unreadable code. Named methods are always clearer. |
| Multiple inheritance | Composition via struct embedding is simpler and sufficient. |
| Implicit conversions | Orhon's explicit `cast()` is correct. Implicit conversions cause subtle bugs. |

---

## 9. Things Orhon Does That Others Don't (Differentiators)

These are features or design decisions that are unusual and worth emphasizing:

1. **`compt` + no macros** -- Type generation power without macro complexity. Rare combination.
2. **Bridge system** -- Universal FFI through paired `.orh`/`.zig` files. No other transpiled language does this so cleanly.
3. **No lifetime annotations with borrow checking** -- Only Hylo also achieves this. Major differentiator vs Rust.
4. **Bitfield as a first-class type** -- Most languages require manual bitmask math. Orhon's `bitfield` keyword is elegant.
5. **`thread` keyword with ownership-based safety** -- Threads as a language construct with move semantics. Cleaner than Rust's `std::thread::spawn` + `move` closures.
6. **Named-only construction** -- No positional struct instantiation. Always clear which field is which.
7. **PEG grammar as source of truth** -- The grammar file IS the language spec. Most languages maintain grammar and parser separately.
8. **Example module as built-in manual** -- Ships with every `orhon init`. Living documentation that must compile.

---

## 10. Confidence Assessment

| Area | Confidence | Reason |
|------|------------|--------|
| New language features (Gleam, Roc, etc.) | MEDIUM | Training data covers these languages well through early 2025, but cannot verify latest releases |
| Type system innovations | MEDIUM-HIGH | Well-established academic and industry concepts; unlikely to have changed |
| Error handling patterns | HIGH | Mature area, patterns well-documented |
| Developer tooling | HIGH | Stable consensus on what matters |
| Compile-time computation | HIGH | Well-understood space, Zig's comptime is well-documented |
| FFI patterns | HIGH | Mature area |
| Community building | MEDIUM | Patterns observed through early 2025; community dynamics can shift |
| Orhon-specific analysis | HIGH | Based on deep reading of actual project source and docs |

---

## 11. Sources and Verification Needs

All findings are from training data (cutoff early 2025). The following should be verified with live sources when possible:

- [ ] Gleam v1.0+ features and community growth (gleam.run)
- [ ] Roc language status and platform system (roc-lang.org)
- [ ] Mojo latest features and ownership model (modular.com)
- [ ] Vale project status and generational references (vale.dev)
- [ ] Hylo status and mutable value semantics (hylo-lang.org)
- [ ] Swift 5.9+ typed throws status
- [ ] Carbon language current status (github.com/carbon-language)
- [ ] Zig 0.15 package manager status
- [ ] Any new languages that emerged in late 2025 / early 2026

---

## 12. Roadmap Implications

Based on this research, the suggested priority order for language evolution:

### Phase A: Error Ergonomics
- `try` keyword for error propagation
- Pattern guards in `match`
- Error message quality improvements ("did you mean?")

### Phase B: Type System Foundation
- Traits / interfaces (minimal: methods only, explicit impl)
- Generic constraints using traits (`any where Trait`)

### Phase C: Productivity
- `#derive` for common traits (Eq, Hash, Debug)
- First-class closures
- Union spreading syntax

### Phase D: Ecosystem
- C/C++ source compilation in build system
- Web playground (WASM target)
- Binding generator (`orhon bindgen`)
- Tree-sitter grammar

### Phase E: Advanced
- `async` keyword (IO concurrency)
- Compile-time reflection
- Debugger integration (source mapping)

**Rationale:** Error ergonomics first because every user hits errors on day 1. Traits second because they unlock constrained generics and derive. Productivity features third because they compound on the foundation. Ecosystem fourth because the language needs to be stable before investing in tooling. Advanced features last because they're the most complex and least urgent.
