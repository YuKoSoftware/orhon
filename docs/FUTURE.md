# Kodr — Future Ideas

Ideas and language decisions that are not yet committed. These may make it into the language, get rejected, or evolve into something else.

---

## Enforce `const` for never-reassigned variables

Currently Kodr allows `var x: i32 = 5` even if `x` is never reassigned. Zig already enforces this and errors when a `var` is never mutated.

The idea: Kodr itself (in an analysis pass, likely Pass 6 — ownership) emits a proper Kodr error like:

```
error: 'x' is never reassigned — use const
  var x: i32 = 5
      ^
```

**Arguments for:** catches mistakes early, enforces intentionality about mutability, fits the "safe language" philosophy, unnecessary mutability is a code smell.

**Arguments against:** non-trivial to implement correctly (need to track all assignments per variable across scopes), may be annoying for beginners.

**Status:** not started, low priority for now.
