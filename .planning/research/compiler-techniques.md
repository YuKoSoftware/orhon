# Modern Compiler Techniques for Transpiler Architectures

**Project:** Orhon Compiler
**Researched:** 2026-03-27
**Scope:** IR design, incremental compilation, PEG error recovery, ownership checking, LSP architecture
**Confidence:** MEDIUM (based on training data through early 2025; web search unavailable for verification of post-2025 developments)

---

## 1. IR Design for Transpilers Targeting High-Level Languages

### The Core Problem

When your backend is another high-level language (Zig, C, JavaScript), your IR must serve a different master than traditional compiler IRs. LLVM IR optimizes for machine code generation. A transpiler IR optimizes for **readable, idiomatic output** in the target language.

### How Existing Transpilers Structure Their IRs

#### Nim -> C: Three-Level IR

Nim uses a multi-level approach:

1. **AST** (PNode tree) -- parsed syntax, macro-expanded
2. **Semantic AST** (PSym-annotated PNode) -- type-resolved, all overloads disambiguated
3. **C-specific IR** (cgen module) -- a thin mapping layer that walks the semantic AST and emits C code directly

Key insight: Nim does **not** have a standalone IR between semantic analysis and C codegen. The semantic AST *is* the IR. The cgen module contains target-specific decisions (how to represent Nim's GC'd types as C structs, how to emit closures as function-pointer+env pairs). This works because C is close enough to Nim's execution model.

**What Orhon can learn:** Orhon's current MIR annotation table (NodeMap keyed by AST node pointers) is similar to Nim's approach -- annotating the AST rather than building a separate tree. This is appropriate for a Zig transpiler because Zig is close to Orhon's execution model. The MirNode tree (Phase 3 lowering) adds a useful separation layer for future optimization passes.

#### V -> C: Almost No IR

V compiles almost directly from AST to C. The AST is typed during parsing (V does single-pass type inference). This is the simplest approach but the least extensible -- V has struggled with adding features that need whole-program analysis.

**What Orhon can learn:** V's struggle validates Orhon's choice to have separate analysis passes (ownership, borrow, thread safety) rather than trying to do everything in one traversal.

#### Haxe -> Multiple Backends: Abstract Typed AST

Haxe compiles to JavaScript, C++, C#, Java, Python, Lua, and more. Its architecture:

1. **Surface AST** -- parsed
2. **Typed AST** (texpr) -- fully resolved, all overloads disambiguated, all macros expanded
3. **Per-backend generators** -- each walks the typed AST and emits target code

The typed AST is the shared IR. Backend generators contain all target-specific decisions. This is the most proven architecture for multi-target transpilation, but Orhon only targets Zig, so the extra abstraction layer has limited value.

#### Crystal -> LLVM: Typed AST + SSA

Crystal uses a typed AST that it lowers to LLVM IR. Relevant because Crystal also has ownership-like semantics (reference types vs value types). Its typed AST carries enough information that codegen can make all decisions without re-analyzing.

### Recommendations for Orhon

**Current state assessment:** Orhon's MIR is well-designed for its purpose. The NodeMap annotation table (AST node -> NodeInfo with resolved_type, type_class, coercion) gives codegen everything it needs without re-analysis. The MirNode tree adds a clean lowered form.

**Specific improvements to consider:**

1. **Coercion chains, not single coercions.** Currently NodeInfo has `coercion: ?Coercion` -- a single optional coercion. Real code sometimes needs chains: `array_to_slice` then `value_to_const_ref`. Consider `coercions: []const Coercion` or a linked list of coercions. This becomes critical as the type system grows.

2. **Backend-agnostic vs backend-specific split.** The MIR currently mixes concerns -- `TypeClass` has `.safe_ptr` and `.raw_ptr` which are Orhon concepts, but the union registry generates `OrhonUnion_i32_String` names which are Zig-specific. Consider splitting:
   - `MirAnnotator` produces backend-agnostic annotations (type classifications, coercions needed)
   - `ZigLowerer` translates those to Zig-specific names and patterns

   This pays off if you ever want a second backend (WASM text, C) or if Zig's conventions change.

3. **Explicit scope tree in MIR.** For ownership and borrow analysis, the MIR should carry an explicit scope tree rather than relying on AST nesting. This enables future non-lexical lifetime analysis. The scope tree would track: which variables are live, what borrows are active, where moves happen.

4. **Side-effect tracking.** Mark each MIR node with side-effect information (pure, reads, writes, allocates, calls-unknown). This enables future optimizations like dead code elimination at the Orhon level before emitting Zig, and helps the LSP provide better diagnostics (unused variable that has no side effects vs unused variable that does).

---

## 2. Incremental Compilation Techniques

### The Landscape

#### Rust's Query-Based System (Salsa)

Rust replaced its traditional pass-based compiler with a **demand-driven query system** built on the Salsa framework. Key concepts:

- **Queries** replace passes. Instead of "run pass 5 on the whole program," you ask "what is the type of expression X?" The system computes and caches the answer.
- **Red-green algorithm.** When input changes, mark affected queries as "red" (may have changed). Re-execute red queries. If the result is the same as before, downstream queries stay "green" (unchanged). This propagates minimally.
- **Dependency tracking.** Every query records which other queries it read. When an input changes, only queries that transitively depend on it are invalidated.
- **Interning.** Large structures (types, names) are interned so comparison is pointer equality. This makes the red-green check cheap.

**Implementation complexity:** HIGH. Salsa required years of development. The Rust compiler team started in 2017-2018 and the migration is still not complete as of 2025. For a single-developer compiler, this is likely overkill.

#### Zig's Approach: Incremental at the Module Level

Zig's self-hosted compiler (stage 2/3) uses module-level granularity with per-function invalidation for some passes. Key techniques:

- **File-level dependency tracking.** If a file hasn't changed and none of its transitive imports have changed, skip recompilation.
- **Semantic hash.** Instead of timestamp comparison, hash the semantic content. Whitespace-only changes don't trigger recompilation.
- **Artifact caching.** Cache the generated machine code (or in Orhon's case, generated Zig) per module.

#### TypeScript's Project References and Watch Mode

TypeScript's incremental compilation (`--incremental` flag) is instructive for transpiler-to-text compilers:

- **Declaration file diffing.** After recompiling a module, diff its public interface (`.d.ts` file). If the interface hasn't changed, skip recompiling downstream modules.
- **Program structure reuse.** Keep the AST, type checker state, and symbol table in memory. On file change, only re-parse the changed file and re-type-check affected scopes.

This is the approach most relevant to Orhon because both are text-to-text compilers.

#### The "Adapt" Framework (Anders Hejlsberg, 2020s)

The idea behind TypeScript's fast incremental updates: keep a **structural diff** of the AST. When a file changes, parse only the changed region, splice the new subtree into the existing AST, and re-run type checking only on affected scopes. This requires a persistent (immutable) AST data structure, which is expensive in memory but enables O(change-size) recompilation.

### What Orhon Currently Does

Orhon's incremental compilation (from `cache.zig`) works at module granularity:
- Compare file modification timestamps
- If a module's files haven't changed and its dependencies haven't changed, skip passes 4-12 and reuse cached `.zig` files
- Cache stored in `.orh-cache/` (timestamps, deps.graph, generated Zig, warnings)

This is sound and appropriate for the compiler's current scale.

### Recommendations for Orhon

**Near-term (high value, moderate effort):**

1. **Semantic hashing instead of timestamps.** Replace timestamp comparison with a hash of the token stream (or a normalized AST hash). This avoids unnecessary recompilations when files are touched but not changed (git checkout, save without editing, formatting). Implementation: after lexing, hash the token kinds + text. Store hash in cache. Compare hash before checking deps.

2. **Interface diffing.** After running passes 1-5 on a changed module, compare its **public interface** (exported functions, types, constants) against the cached interface. If the interface is unchanged, downstream modules don't need recompilation even though the implementation changed. This is TypeScript's declaration-file trick. Implementation:
   - After declaration pass, serialize the module's public DeclTable to a canonical form
   - Hash it
   - Store the hash
   - When checking if downstream modules need recompilation, compare interface hash, not file hash

3. **Parallel module analysis.** Modules with no dependency relationship can be analyzed in parallel. The dependency graph from module resolution already provides this information. Zig's `std.Thread.Pool` or spawn threads for independent module groups. This matters once projects have 10+ modules.

**Medium-term (high value, high effort):**

4. **Per-function invalidation.** Instead of recompiling an entire module when one function changes, track which functions changed and only re-run passes 4-10 on those functions. Requires:
   - Per-function AST caching (store the AST subtree for each function)
   - Function-level dependency tracking (function A calls function B -- if B's signature changes, A needs re-checking)
   - Partial MIR update (update NodeMap entries for changed functions only)

**Long-term (consider but don't implement now):**

5. **Query-based architecture.** If Orhon grows to handle very large codebases (100+ modules), consider migrating to a query-based system. But this is a fundamental architecture change -- do not attempt incrementally. It requires designing the entire compiler as a set of memoized, dependency-tracked queries from the start.

---

## 3. Error Recovery in PEG Parsers

### The Problem with PEG Error Recovery

PEG parsers have a fundamental challenge with error reporting: because PEG uses ordered choice (`/`), a failure in one alternative silently tries the next. By the time the parser reports "no match," it has tried and failed many alternatives, and the deepest failure point is not always the most informative one.

Orhon's current approach (from `engine.zig`): track the **furthest failure position** (`furthest_pos`, `furthest_rule`, `furthest_expected`). This is the standard baseline approach and gives reasonable errors in most cases.

### State of the Art in PEG Error Recovery

#### Tree-sitter: Error Recovery via Incomplete Parses

Tree-sitter (used by most modern editors) is a GLR parser, not PEG, but its error recovery strategy is adaptable:

- **Error nodes.** When parsing fails, tree-sitter inserts an ERROR node in the tree and skips tokens until it finds a synchronization point (typically a statement or block boundary).
- **Incremental re-parsing.** Only re-parse the changed region of the file. The rest of the tree is reused.
- **Partial trees.** Even with errors, tree-sitter produces a complete tree (with ERROR nodes). This is critical for IDE support.

**Adaptable to PEG:** The key insight is to define **synchronization points** -- positions where the parser can resume after an error. In a PEG grammar, you can add special "panic mode" rules:

```
Statement <- ExprStmt / VarDecl / FuncDecl / ERROR_SYNC
ERROR_SYNC <- (!NEWLINE .)* NEWLINE   // skip to next line
```

#### pest (Rust PEG library): Labeled Failures

pest added "labeled failures" to PEG -- you annotate grammar rules with human-readable error labels:

```
number = @{ ASCII_DIGIT+ ~ ("." ~ ASCII_DIGIT+)? }
// Error: expected "a number"
```

When a labeled rule fails, the label is used in the error message instead of the raw rule name. This dramatically improves error quality with minimal implementation effort.

**Implementation for Orhon:** Add an optional label field to grammar rules in `orhon.peg`. When `engine.zig` records a failure at `furthest_pos`, use the label instead of the raw rule name. Example:

```
VarDecl <- 'var' IDENTIFIER ':' TypeExpr '=' Expr
          / 'var' IDENTIFIER '=' Expr
          {label: "variable declaration (var name: Type = value)"}
```

#### Bryan Ford's Original PEG Paper + Subsequent Work

Ford's "Packrat Parsing" papers discuss error recovery strategies:

1. **Labeled failures with merge.** Multiple alternative failures can be merged into a single error message: "expected number or string" instead of just reporting the last alternative tried.

2. **Error productions.** Add explicit error rules to the grammar that match common mistakes and produce targeted error messages:
   ```
   Assignment <- Identifier '=' Expr SEMICOLON
              /  Identifier '=' Expr {label: "missing semicolon after assignment"}
              /  Identifier Expr     {label: "missing '=' in assignment"}
   ```

3. **Recovery expressions.** A special PEG operator that says "if this alternative fails, skip to the next synchronization point and continue":
   ```
   Program <- (Statement / RECOVER_TO_NEWLINE)*
   ```

### Specific Error Reporting Improvements for PEG

**Technique: Expected-set accumulation.** Instead of tracking only the single furthest failure, accumulate all expected tokens at the furthest position. When alternatives `A / B / C` all fail at position P, the error message becomes "expected keyword, identifier, or '('" instead of just "expected '('".

Implementation in `engine.zig`:
```zig
// Replace single furthest_expected with a set
furthest_expected_set: std.EnumSet(TokenKind) = .{},

// In matching logic, when a terminal match fails at furthest_pos:
if (pos == self.furthest_pos) {
    self.furthest_expected_set.insert(expected_kind);
} else if (pos > self.furthest_pos) {
    self.furthest_expected_set = .{};
    self.furthest_expected_set.insert(expected_kind);
    self.furthest_pos = pos;
}
```

**Technique: Context stack.** Maintain a stack of "where we are" during parsing. When an error occurs, the stack gives context: "in function declaration, in parameter list, expected type annotation." Implementation: push/pop rule names onto a context stack during `matchRule`.

**Technique: Common mistake patterns.** After a parse failure, try known mistake patterns at the failure position:
- Missing colon: `var x i32 = 5` -- try inserting `:` and re-parsing
- Extra comma: `func foo(a: i32,)` -- try removing trailing `,` and re-parsing
- Wrong keyword: `function` instead of `func` -- check Levenshtein distance to keywords

### Recommendations for Orhon

1. **Expected-set accumulation** (LOW effort, HIGH impact). Replace single `furthest_expected` with a set. Dramatically improves error messages for almost zero cost.

2. **Labeled failures** (MEDIUM effort, HIGH impact). Add error labels to grammar rules. Parse the label from `orhon.peg` and use in error messages.

3. **Synchronization points** (MEDIUM effort, HIGH impact for LSP). Define sync points at statement boundaries. On parse failure, skip to the next sync point and continue parsing. This produces partial ASTs that the LSP can use for diagnostics, completion, and hover in files with errors.

4. **Common mistake detection** (MEDIUM effort, MEDIUM impact). After a failure, try a small set of token insertions/deletions at the failure point. If one succeeds, report a targeted error: "missing ':' in variable declaration."

---

## 4. Ownership/Borrow Checking Innovations

### What Has Changed Since Rust's Original Borrow Checker

#### Polonius: Flow-Sensitive Borrow Checking

Polonius is the next-generation Rust borrow checker (replacing the current NLL-based checker). Key differences:

- **NLL (current Rust):** Lifetimes are computed as regions of the control-flow graph. A borrow is live from its creation to its last use. The checker ensures no conflicting borrows overlap.

- **Polonius:** Uses a **location-sensitive** analysis based on Datalog. Instead of computing lifetime regions upfront, Polonius asks "at this specific program point, is this borrow still in use?" This accepts strictly more programs than NLL.

Example that Polonius accepts but NLL rejects:
```rust
fn get_or_insert(map: &mut HashMap<K, V>, key: K) -> &V {
    if let Some(v) = map.get(&key) {
        return v;  // NLL thinks the immutable borrow lives here
    }
    map.insert(key, default());  // NLL rejects: mutable borrow while immutable exists
    map.get(&key).unwrap()       // Polonius knows the immutable borrow ended
}
```

**Relevance to Orhon:** Orhon currently uses lexical lifetimes (from `borrow.zig`: borrows are dropped at scope exit via `dropBorrowsAtDepth`). This is simpler than even NLL. Moving to NLL-style analysis (borrows end at last use, not at scope exit) would accept more programs without sacrificing safety.

**Implementation sketch for Orhon NLL:**
1. Build a use-def chain for each variable during the type resolution pass
2. In borrow checking, a borrow's lifetime extends from creation to the **last use of the borrow reference**, not to the end of the scope
3. Check for conflicts only within the actual live range

This is significantly simpler than full Polonius but captures the most common cases where lexical lifetimes are too restrictive.

#### Vale's Generational References

Vale (experimental language by Evan Ovadia) introduces **generational references** -- a runtime safety mechanism that is simpler than borrow checking:

- Every allocation has a **generation counter** (incremented on deallocation)
- Every reference stores the generation it expects
- On dereference, compare generations -- if they don't match, the referent was freed
- Zero compile-time complexity, minimal runtime overhead (one integer comparison per deref)

**Relevance to Orhon:** This is a fundamentally different approach -- runtime checking instead of compile-time checking. Not applicable to Orhon's design goals (compile-time safety), but worth knowing about as a fallback for cases where static analysis is too conservative. Could be offered as an opt-in "unsafe-lite" mode.

#### Austral's Linear Types

Austral (by Fernando Borretti) uses **linear types** instead of borrow checking:

- Every value must be used exactly once (consumed)
- To "read" a value without consuming it, you explicitly borrow it and the compiler tracks that the borrow is returned
- No lifetimes, no complex inference -- the rules are syntactically local

This is simpler than Rust's approach but more verbose. Users must explicitly manage borrows.

**Relevance to Orhon:** Orhon already has ownership transfer (moves) and borrows. Austral's insight is that linearity (use-exactly-once) is a simpler foundation than Rust's affine types (use-at-most-once). Orhon's current model is closer to Rust (affine) which is the right choice for usability.

#### Mojo's Ownership Model

Mojo (by Chris Lattner/Modular) adds ownership to Python-like syntax:

- **`owned`** -- the function takes ownership
- **`borrowed`** (default for `def`) -- immutable reference, no lifetime tracking
- **`inout`** -- mutable reference, exclusive access guaranteed

Key insight: Mojo makes **borrowed the default** and makes it zero-cost by not tracking lifetimes for simple borrows. Lifetimes only matter when you store a reference in a struct (which Mojo restricts).

**Relevance to Orhon:** Orhon's `const &` (immutable borrow) and `&` (mutable borrow) are similar to Mojo's `borrowed` and `inout`. The key simplification from Mojo: **don't allow storing references in structs**. If references can only exist as function parameters and local variables, lifetime analysis is trivial -- the reference cannot outlive the function call. Orhon may already enforce this implicitly.

#### Hylo's (Val's) Mutable Value Semantics

Hylo (formerly Val, by Dave Abrahams and Dimitri Racordon) takes a different approach:

- All types have value semantics by default (copy on assignment)
- Mutation is explicit and tracked -- `inout` parameters
- No reference types at all -- instead, "projections" give temporary mutable access
- Copy-on-write optimization makes value semantics efficient

**Relevance to Orhon:** Orhon already distinguishes value types (primitives, copied) from reference types (structs, moved). Hylo's insight is that you can get most of the safety benefits by making everything a value and only allowing temporary mutable access. This is worth considering for Orhon's const-by-default philosophy.

### The "80% Safety" Question

Several approaches give most of Rust's safety with much less complexity:

| Approach | Safety | Complexity | Key Restriction |
|----------|--------|------------|-----------------|
| Lexical lifetimes (current Orhon) | ~70% | LOW | Conservative -- rejects valid programs |
| NLL (non-lexical lifetimes) | ~85% | MEDIUM | Borrow ends at last use |
| No references in structs | ~90% | LOW | Cannot store &T in a struct |
| Polonius (flow-sensitive) | ~95% | HIGH | Full dataflow analysis |
| Linear types (Austral) | ~95% | MEDIUM | User must be explicit |
| Generational refs (Vale) | ~99% | LOW (compile) | Runtime cost |

### Recommendations for Orhon

1. **Move from lexical to NLL lifetimes** (MEDIUM effort, HIGH impact). The biggest single improvement. Build use-def chains during type resolution, use them in borrow checking to end borrows at last use instead of scope exit. This eliminates the most common "fighting the borrow checker" scenarios.

2. **Restrict references in structs** (LOW effort, HIGH impact if not already done). If Orhon does not allow storing `&T` in struct fields (only function parameters and locals), borrow checking becomes dramatically simpler. This restriction is acceptable for most programs and matches Zig's philosophy.

3. **Partial move tracking** (MEDIUM effort, MEDIUM impact). Allow moving individual fields out of a struct, tracking which fields have been moved. The current code (`ownership.zig`) validates struct atomicity (no partial moves). Consider relaxing this to allow partial moves with compile-time tracking of which fields are still valid.

4. **Better error messages for ownership violations.** This is where Rust invests heavily. When a move error occurs, suggest the fix: "consider using `copy()` to create a copy" or "consider borrowing with `const &`". The ownership checker already has the information to generate these suggestions.

---

## 5. LSP Architecture for Fast Incremental Updates

### Patterns That Matter

#### Demand-Driven / Lazy Compilation

The most impactful pattern for LSP performance. Instead of analyzing the entire project on every keystroke:

1. **Only analyze the open file** on keystroke
2. **Use cached results** for imported modules
3. **Only run passes needed for the requested feature** (hover needs types, completion needs declarations, diagnostics need all passes)

Orhon's LSP currently runs passes 1-9 on document change. This is correct but can be optimized:

- **For completion:** Only need passes 1-4 (parse + declarations). Skip ownership, borrow, thread safety.
- **For hover:** Need passes 1-5 (parse + declarations + type resolution). Skip safety passes.
- **For diagnostics:** Need passes 1-9 (all analysis). But can be deferred -- run after a debounce period.

#### Debouncing and Cancellation

Critical for responsiveness:

- **Debounce:** Don't analyze on every keystroke. Wait 100-300ms after the last keystroke before starting analysis.
- **Cancellation:** If a new change arrives while analysis is running, cancel the current analysis and restart with the new content.

Implementation: run analysis in a separate thread. On new change, set a cancellation flag. Each pass checks the flag at the top of its main loop.

#### Virtual File System (VFS)

The LSP maintains an in-memory copy of open files (not the on-disk version). This is important because:
- The user is actively typing -- the file on disk may be saved or unsaved
- The LSP needs the latest content, not the last-saved content
- Multiple files may be open with unsaved changes that reference each other

Orhon's LSP likely already handles this via `textDocument/didChange` notifications, but the architecture should explicitly maintain a `VFS: StringHashMap([]const u8)` mapping URIs to current content.

#### Incremental Parsing

For large files, re-parsing the entire file on every keystroke is wasteful. Tree-sitter's approach:

1. Parse the full file initially -> get a CST
2. On edit, receive the edit range (start, end, new text)
3. Re-parse only the affected region
4. Splice the new subtree into the existing CST

For PEG parsers, this is harder because packrat memoization depends on position. But a simpler approach works:

- **Token-level diffing.** Re-lex the changed region. If the token stream only changed locally (common case: editing inside a function body), the memo table entries for tokens before the edit are still valid.
- **Scope-level re-analysis.** If the edit is inside a function body, only re-run type checking on that function. If the edit changes a declaration, re-check all dependents.

#### rust-analyzer's Architecture (Specific Details)

rust-analyzer is the gold standard for LSP implementations. Key architectural decisions:

1. **Lossless CST.** rust-analyzer uses a lossless Concrete Syntax Tree that preserves all whitespace and comments. This enables formatting, refactoring, and partial re-parsing.

2. **Salsa database.** All compiler state is stored in a Salsa database. Queries are memoized and dependency-tracked. Changing a file invalidates only affected queries.

3. **Two-phase analysis:**
   - **Syntax phase:** Parse files, resolve names, build module structure. Fast, done on every keystroke.
   - **Semantic phase:** Type inference, borrow checking, trait resolution. Lazy, computed on demand (hover, diagnostics).

4. **Cancellation tokens.** Every analysis operation checks a cancellation token periodically. When a new edit arrives, the current analysis is cancelled and restarted.

5. **Snapshot semantics.** The analysis always works on a consistent snapshot of the code. Edits during analysis don't corrupt state -- they queue a new analysis on the next snapshot.

### Recommendations for Orhon's LSP

**Near-term (HIGH impact):**

1. **Feature-gated pass execution.** Don't run all 9 passes for every request:
   - Completion: passes 1-4 (lex, parse, resolve modules, collect declarations)
   - Hover: passes 1-5 (add type resolution)
   - Go-to-definition: passes 1-4
   - Diagnostics: passes 1-9 (all analysis, debounced)

   This immediately makes completion and hover much faster.

2. **Debounce diagnostics.** Run diagnostic analysis (passes 6-9: ownership, borrow, thread safety, propagation) on a 300ms debounce timer. Show syntax errors (pass 1-2) immediately.

3. **Cancellation.** Add a cancellation flag checked at the start of each pass. On new `didChange`, set the flag, wait for current analysis to stop, then restart.

**Medium-term:**

4. **Per-function re-analysis.** Cache declaration tables and type maps per module. When a file changes, determine which functions were affected. If no public interface changed (no new/removed/modified function signatures, struct fields, or type aliases), only re-analyze the changed functions.

5. **In-memory file overlay.** Maintain an explicit VFS that maps file paths to content (from `didChange` notifications or disk). Pass this to the pipeline instead of reading from disk. This ensures the LSP always analyzes the latest content.

6. **Background indexing.** On workspace open, start indexing all `.orh` files in the background. Build a project-wide symbol index (all exported functions, types, constants across all modules). Use this for workspace symbol search and cross-module completion.

**Long-term:**

7. **Persistent AST with incremental parsing.** Re-lex only the changed range, invalidate only affected memo table entries, re-parse only the affected scope. This requires modifications to the PEG engine's memo table to support positional invalidation.

---

## 6. Cross-Cutting Insights

### What the Best Modern Compilers Have in Common

1. **Separation of analysis and representation.** The AST is for structure, the IR is for analysis results, codegen reads the IR. Orhon's MIR annotator follows this pattern well.

2. **Error accumulation, not early exit.** Collect all errors in a pass before stopping. Orhon already does this with Reporter.

3. **Interning for performance.** Intern all strings, types, and node pointers. Comparison becomes pointer/integer equality. Orhon partially does this (constants.zig has string constants) but could benefit from a general string interner for identifiers and type names.

4. **Explicit dependency graphs.** Track what depends on what -- at file level, module level, and function level. The granularity of your dependency tracking determines the granularity of your incremental compilation.

5. **Testable passes.** Each pass should be independently testable with mock inputs. Orhon's architecture (each pass is a self-contained module) already supports this.

### Specific Techniques Worth Implementing

| Technique | Effort | Impact | Applicable Pass |
|-----------|--------|--------|-----------------|
| String interning | MEDIUM | MEDIUM | All passes |
| Expected-set error accumulation | LOW | HIGH | PEG engine |
| NLL borrow lifetimes | MEDIUM | HIGH | Borrow checker |
| Feature-gated LSP passes | LOW | HIGH | LSP |
| Interface diffing for incremental | MEDIUM | HIGH | Cache |
| Semantic hashing | LOW | MEDIUM | Cache |
| Coercion chains in MIR | LOW | MEDIUM | MIR + Codegen |
| Cancellation tokens in LSP | LOW | HIGH | LSP |

### Priority Order for Implementation

1. **LSP feature-gated passes + cancellation** -- immediate user-visible improvement, low effort
2. **Expected-set error accumulation in PEG** -- dramatically better error messages, low effort
3. **Semantic hashing in cache** -- eliminates false recompilations, low effort
4. **NLL borrow lifetimes** -- accept more valid programs, medium effort
5. **Interface diffing for incremental compilation** -- major build speed improvement for multi-module projects, medium effort
6. **Coercion chains in MIR** -- unblocks future type system features, low effort
7. **String interning** -- performance foundation for everything else, medium effort

---

## Sources and Confidence

| Topic | Primary Source | Confidence |
|-------|----------------|------------|
| Nim's IR design | Training data (Nim compiler source, documentation) | MEDIUM |
| V's compilation approach | Training data (V documentation, blog posts) | MEDIUM |
| Haxe's multi-backend architecture | Training data (Haxe documentation) | MEDIUM |
| Rust's query-based/Salsa system | Training data (rustc-dev-guide, Salsa documentation, blog posts) | HIGH |
| Zig's incremental compilation | Training data (Zig source, Andrew Kelley's talks) | MEDIUM |
| Tree-sitter error recovery | Training data (tree-sitter documentation, GitHub) | HIGH |
| pest labeled failures | Training data (pest documentation) | MEDIUM |
| Polonius borrow checker | Training data (Niko Matsakis's blog, Polonius RFC) | HIGH |
| Vale's generational references | Training data (Vale documentation, Evan Ovadia's blog) | MEDIUM |
| Austral's linear types | Training data (Austral documentation, Fernando Borretti's blog) | MEDIUM |
| Mojo's ownership model | Training data (Mojo documentation, Modular blog) | MEDIUM |
| Hylo's mutable value semantics | Training data (Hylo/Val papers, Dave Abrahams's talks) | MEDIUM |
| rust-analyzer architecture | Training data (rust-analyzer documentation, Aleksey Kladov's blog) | HIGH |

**Note:** Web search and web fetch were unavailable during this research. All findings are based on training data (through early 2025). Post-2025 developments in Polonius, Mojo's ownership model, and other active projects may have changed. Recommend verifying specific version numbers and API details before implementation.
