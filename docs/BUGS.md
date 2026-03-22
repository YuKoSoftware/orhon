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

## Codegen — bitfield variants not namespaced

`Perms(Read, Write)` generates `Perms(Read, Write)` in Zig, but `Read` is not
in scope — it should be `.Read`. Bitfield variant names conflict with identifiers.

## Codegen — `mem` module not auto-imported

`mem.DebugAllocator()`, `mem.Arena()`, `mem.Page()` generate `mem.X()` in Zig
but `mem` is not imported. The allocator module needs codegen-level import wiring.

## Codegen — array literal to slice coercion

`system.run("echo", ["hello"])` and `parts.join(", ")` generate array literals
where Zig expects slices. Need `&` address-of operator for coercion.

## Codegen — Map.get returns optional

`Map(K,V).get()` returns `?V` in Zig but codegen treats it as `V`. Need null
union wrapping or `.?` unwrap at the call site.

## Codegen — Set/Map iteration

`for(set) |key|` and `for(map) |(key, value)|` don't work — Set/Map types are
not directly iterable in Zig. Need iterator bridge methods.

## Codegen — thread blocks

`thread(T) name { }` syntax is parsed but codegen was removed. Threading has been
redesigned as a language-level feature (see FUTURE.md). Old thread block syntax
will be replaced by the new `thread` keyword + `Handle(T)` model.
