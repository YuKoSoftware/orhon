# Orhon — Known Bugs

Bugs discovered during testing. Fix before v1.

---

## ~~Codegen — inferred union types not tracked~~ (FIXED v0.4.7)

Fixed by MIR Phase 1 integration. The MIR annotator resolves types from function
call returns via the resolver's type_map, so codegen queries `getTypeClass(node)`
instead of relying on hashmap registration from explicit annotations.

## ~~Codegen — arb union types not unified across functions~~ (FIXED v0.4.7)

Fixed by MIR UnionRegistry. Canonical union type deduplication ensures `(i32 | String)`
in different functions maps to the same generated Zig type.

## ~~Codegen — bitfield variants not namespaced~~ (FIXED v0.4.8)

Fixed by detecting bitfield constructor calls in codegen. `Perms(Read, Write)` now
generates `Perms{ .value = Perms.Read | Perms.Write }`. Method args like `p.has(Read)`
are qualified as `p.has(Perms.Read)` via MIR type lookup.

## ~~Codegen — `allocator` module not auto-imported~~ (FIXED v0.4.8)

Was a documentation issue — docs referenced `mem.*` but the module is `std::allocator`.
Stale `mem.orh`/`mem.zig` deleted, docs updated. `import std::allocator` works correctly.

## ~~Codegen — array literal to slice coercion~~ (FIXED v0.5.0)

Fixed by MIR Phase 3 coercion pass. The MIR annotator compares call argument types
with parameter types — when an array is passed where a slice is expected, the arg
node is marked with `coercion = .array_to_slice`. Codegen emits `&` prefix.

## ~~Codegen — Map.get returns optional~~ (FIXED v0.5.0)

Fixed by changing `Map.get()` bridge to return `OrhonNullable(V)` instead of `?V`.
Matches the existing pattern used by `str.indexOf()`. Codegen's null union handling
works correctly — `result.value` extracts the inner value after an `is not null` check.

## ~~Codegen — Set/Map iteration~~ (RESOLVED)

`for(set) |key|` direct syntax is not supported. Iteration works via bridge methods:
`for(map.keys()) |key|`, `for(set.items()) |item|`. This is by design — collections
expose slices through bridge methods, matching the Orhon bridge pattern.

## ~~Codegen — thread blocks~~ (FIXED v0.5.0)

Threading implemented as language-level feature. `thread name(params) Handle(T) { body }`
declares a thread function. Calling it spawns an OS thread and returns `Handle(T)`.
Handle methods: `.value` (block + move result), `.wait()`, `.done()`, `.join()`.

## Std — bridge functions named with Orhon keywords

Several std bridge functions use Orhon keywords as names (`size`, `match`). The lexer
tokenizes these as keyword tokens instead of identifiers, so parsing the raw std `.orh`
files fails. Affects `orhon gendoc .orh-cache/std` and any tooling that parses std source.

Fix: rename the affected bridge functions to non-keyword names (e.g. `length` instead of
`size`). Do not weaken the parser to accept keywords as identifiers.
