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

## Codegen — array literal to slice coercion

`system.run("echo", ["hello"])` and `parts.join(", ")` generate array literals
where Zig expects slices. Need `&` address-of operator for coercion.

## Codegen — Map.get returns optional

`Map(K,V).get()` returns `?V` in Zig but codegen treats it as `V`. Need null
union wrapping or `.?` unwrap at the call site.

## ~~Codegen — Set/Map iteration~~ (RESOLVED)

`for(set) |key|` direct syntax is not supported. Iteration works via bridge methods:
`for(map.keys()) |key|`, `for(set.items()) |item|`. This is by design — collections
expose slices through bridge methods, matching the Orhon bridge pattern.

## Codegen — thread blocks

`thread(T) name { }` syntax is parsed but codegen was removed. Threading has been
redesigned as a language-level feature (see FUTURE.md). Old thread block syntax
will be replaced by the new `thread` keyword + `Handle(T)` model.
