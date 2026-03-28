# Phase 30: Error Quality - Research

**Researched:** 2026-03-28
**Domain:** Compiler error message enhancement — Levenshtein suggestions, type mismatch formatting, ownership/borrow hints
**Confidence:** HIGH

## Summary

Phase 30 enhances compiler error messages in-place across six pass files. There are no new language features, no new AST nodes, and no new passes. The work is entirely additive: add a `levenshtein` function to `errors.zig`, add a `suggestName` helper that collects candidate names from a `Scope` + `DeclTable` and returns the best match within threshold, then thread the suggestion into error messages at the ~51 report sites identified in CONTEXT.md.

The key design constraint already settled by CONTEXT.md is that suggestions appear inline in the error message string itself (D-05), not in the `notes` field. This means every enhanced report site builds one larger `allocPrint` string instead of changing the struct shape. The `OrhonError.notes` field exists but remains unused for this phase.

Identifier resolution in `resolver.zig` is the primary target for "did you mean?" because the `Scope` chain and the `DeclTable` maps together hold every in-scope name. The `identifier` arm of `resolveExpr` (line 524-532) currently returns `RT.unknown` silently when a name is not found — this is where the suggestion and an explicit error should be emitted. The existing "unknown type 'X'" message at line 906-910 is the second-highest-value target for type name suggestions.

**Primary recommendation:** Add `levenshtein(a, b)` and `suggestName(query, scope, decls, allocator)` to `errors.zig`, then wire suggestions into the ~10-15 highest-value error sites across resolver/ownership/borrow, and add the mandatory hint text to ownership and borrow violation messages.

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Use Levenshtein edit distance for "did you mean?" candidate ranking. Threshold of 2-3 edits covers most typos.
- **D-02:** Show 1 best match only — "did you mean 'count'?" Single suggestion, no alternatives list.
- **D-03:** Search current scope only — local vars, function params, and module-level declarations. No cross-module search.
- **D-04:** Cover all identifier types — variables, functions, types, enum variants. Anything in the declaration table gets suggestions.
- **D-05:** Suggestions appear inline in the error message — "unknown identifier 'coutn' — did you mean 'count'?" Single line, compact. Do not use the `notes` field.
- **D-06:** Standardize "expected X, got Y" pattern across all passes for type mismatches. Consistent developer experience.
- **D-07:** Use short type names by default — "expected i32, got f64" not "expected core.i32, got core.f64". Only qualify when ambiguous.
- **D-08:** Move-after-use errors suggest: "consider using copy()" — direct, actionable, points to Orhon's copy mechanism.
- **D-09:** Borrow violations suggest: "consider borrowing with const &" — when the usage is read-only and a const borrow would resolve it.
- **D-10:** Thread safety violations use generic hint: "shared mutable state requires synchronization" — points to the problem without prescribing a specific solution.
- **D-11:** Enhance all passes: resolver (26 sites), declarations (10), propagation (5), borrow (4), ownership (3), thread_safety (3). Complete coverage.
- **D-12:** Levenshtein function lives in errors.zig — all passes already import it, minimizes change surface.
- **D-13:** Add integration tests in test/11_errors.sh verifying "did you mean" and enhanced messages appear in compiler output. Also unit tests for Levenshtein in errors.zig.

### Claude's Discretion
- Exact Levenshtein distance threshold (2 vs 3 edits) — tune based on typical Orhon identifier lengths
- Which specific error sites get suggestions vs which stay as-is (not all errors have reasonable suggestions)
- Exact wording of hints beyond the patterns decided above

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ERR-01 | "Did you mean X?" suggestions for identifier typos using Levenshtein distance against known names in scope | `levenshtein` + `suggestName` added to `errors.zig`; wired at identifier resolution (resolver.zig:524) and unknown type (resolver.zig:906) |
| ERR-02 | Type mismatch errors show expected vs actual types (e.g., "expected i32, got f64") | Pattern already exists at resolver.zig:1001 and :375; standardization needed across all passes |
| ERR-03 | Ownership/borrow violation errors suggest fixes ("consider using `copy()`" or "consider borrowing with `const &`") | Ownership error at ownership.zig:362, borrow errors at borrow.zig:275-307, thread_safety.zig:210 |
</phase_requirements>

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Zig stdlib (`std.mem`, `std.fmt`) | 0.15.2 | String manipulation, allocPrint | Already used everywhere in the codebase |
| `errors.zig` (project) | N/A | Reporter struct, home for new Levenshtein helpers | All passes already import this; zero new imports needed |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `declarations.DeclTable` | N/A | Source of all module-level declared names | Candidate pool for Levenshtein search |
| `resolver.Scope` | N/A | Source of all in-scope local variable names | Candidate pool for local var suggestions |

**Installation:** No new packages. All work is within the existing Zig codebase.

---

## Architecture Patterns

### Recommended Project Structure
No structural changes. New code lives entirely in `src/errors.zig` (the Levenshtein function and `suggestName` helper), with call sites in:
- `src/resolver.zig`
- `src/declarations.zig`
- `src/ownership.zig`
- `src/borrow.zig`
- `src/propagation.zig`
- `src/thread_safety.zig`

### Pattern 1: Levenshtein Implementation in errors.zig

**What:** A pure function computing edit distance between two strings, plus a helper that searches a candidate set and returns the best match under a threshold.

**When to use:** Only at error-reporting sites where we have a name that failed lookup and a populated scope/DeclTable to search.

**Example:**
```zig
// Source: standard Levenshtein algorithm — O(m*n) dynamic programming
// Stack-allocated row buffer; bounded by MAX_NAME_LEN to avoid heap allocation for small names.
const MAX_NAME_LEN = 64;

pub fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > MAX_NAME_LEN or b.len > MAX_NAME_LEN) return MAX_NAME_LEN; // treat huge names as no match

    var row: [MAX_NAME_LEN + 1]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;

    for (0..a.len) |i| {
        var prev = i + 1;
        for (0..b.len) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            const next = @min(@min(row[j + 1] + 1, prev + 1), row[j] + cost);
            row[j] = prev;
            prev = next;
        }
        row[b.len] = prev;
    }
    return row[b.len];
}

/// Find the closest name to `query` in `candidates`.
/// Returns null if no candidate is within `threshold` edits.
pub fn closestMatch(query: []const u8, candidates: []const []const u8, threshold: usize) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = threshold + 1;
    for (candidates) |c| {
        const d = levenshtein(query, c);
        if (d < best_dist) {
            best_dist = d;
            best = c;
        }
    }
    return best;
}
```

**Threshold selection:** For identifiers 5+ chars, threshold=2 is safe. For shorter identifiers (3-4 chars), threshold=1 avoids false positives. A practical rule: `threshold = if (query.len <= 4) 1 else 2`.

### Pattern 2: suggestName — Collecting Candidates

**What:** A helper that gathers all names from a `Scope` chain + a `DeclTable`, runs `closestMatch`, and returns an optional suggestion string formatted as `" — did you mean '{name}'?"`.

**When to use:** At any error site where an identifier was not found in scope.

**Example:**
```zig
// In errors.zig — takes a pre-built slice of candidates
// Caller builds candidates from Scope + DeclTable iteration
pub fn formatSuggestion(query: []const u8, candidates: []const []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const threshold: usize = if (query.len <= 4) 1 else 2;
    if (closestMatch(query, candidates, threshold)) |match| {
        return try std.fmt.allocPrint(allocator, " — did you mean '{s}'?", .{match});
    }
    return null;
}
```

**Caller pattern in resolver.zig:**
```zig
// At the identifier-not-found site (line 532 in resolveExpr):
// Build candidate list from scope chain + decls maps
var candidates = std.ArrayList([]const u8).init(self.allocator);
defer candidates.deinit();
var s: ?*const Scope = scope;
while (s) |sc| {
    var it = sc.vars.keyIterator();
    while (it.next()) |key| try candidates.append(key.*);
    s = sc.parent;
}
var fit = self.decls.funcs.keyIterator();
while (fit.next()) |k| try candidates.append(k.*);
var sit = self.decls.structs.keyIterator();
while (sit.next()) |k| try candidates.append(k.*);
var eit = self.decls.enums.keyIterator();
while (eit.next()) |k| try candidates.append(k.*);
var vit = self.decls.vars.keyIterator();
while (vit.next()) |k| try candidates.append(k.*);

const suggestion = try errors.formatSuggestion(id_name, candidates.items, self.allocator);
defer if (suggestion) |s_str| self.allocator.free(s_str);
const msg = try std.fmt.allocPrint(self.allocator,
    "unknown identifier '{s}'{s}",
    .{ id_name, suggestion orelse "" });
defer self.allocator.free(msg);
try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
```

### Pattern 3: Inline Hint Appending for Ownership/Borrow Errors

**What:** Append a fixed hint string to existing error messages.

**When to use:** For ownership, borrow, and thread safety violations where no candidate search is needed.

**Example — ownership.zig (move-after-use, current line ~362):**
```zig
// BEFORE:
const msg = try std.fmt.allocPrint(self.allocator,
    "use of moved value '{s}'", .{name});

// AFTER:
const msg = try std.fmt.allocPrint(self.allocator,
    "use of moved value '{s}' — consider using copy()", .{name});
```

**Example — borrow.zig (immutable use while mutably borrowed, current line ~280):**
```zig
// BEFORE:
const msg = try std.fmt.allocPrint(self.allocator,
    "cannot use '{s}' while it is mutably borrowed", .{name});

// AFTER:
const msg = try std.fmt.allocPrint(self.allocator,
    "cannot use '{s}' while it is mutably borrowed — consider borrowing with const &", .{name});
```

**Example — borrow.zig (borrow conflict, line ~299):**
```zig
// BEFORE:
"cannot borrow '{s}' as {s}: already borrowed as {s}"

// AFTER: keep existing message, append hint only when new borrow is immutable (read-only case)
// When the user is trying to add a const borrow and there's already a mutable: suggest downgrading
"cannot borrow '{s}' as immutable: already borrowed as mutable — consider borrowing with const & only after releasing the mutable borrow"
```

**Example — thread_safety.zig (line ~254):**
```zig
// BEFORE:
"use of '{s}' after it was moved into thread '{s}'"

// AFTER:
"use of '{s}' after it was moved into thread '{s}' — shared mutable state requires synchronization"
```

### Pattern 4: Standardizing "expected X, got Y" — resolver.zig

The existing pattern at resolver.zig:1001 is already well-formed:
```zig
"type mismatch: expected '{s}', got '{s}'"
```
and at line 375:
```zig
"return type mismatch: expected '{s}', got '{s}'"
```

These are the template to follow. The remaining sites that need standardization use inconsistent phrasing. Target sites to unify:
- "if condition must be bool, got 'X'" (line 390) — becomes "type mismatch: expected bool, got 'X'"
- "while condition must be bool, got 'X'" (line 403) — same pattern
- Any remaining primitive mismatch messages that deviate from the "expected X, got Y" form

### Anti-Patterns to Avoid

- **Using `notes` field for suggestions:** D-05 locks suggestions as inline message text. Do not use `OrhonError.notes`.
- **Leaking candidate ArrayList:** Always `defer candidates.deinit()` after building the slice.
- **Double-free on suggestion string:** `formatSuggestion` returns an allocated string. Use `defer if (suggestion) |s| allocator.free(s)` before the final `allocPrint`.
- **Searching when name is empty:** Guard against 0-length query before calling Levenshtein.
- **Levenshtein on very long names:** Cap at `MAX_NAME_LEN` (64) to avoid stack overflow. Names over 64 chars are exotic and not worth suggesting.
- **Suggesting builtins:** Built-in types (`List`, `Map`, `Set`, etc.) are valid suggestion candidates — they should be in the candidate pool via `builtins.isBuiltinType`. Do not hardcode a separate list.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Edit distance | Custom heuristic (prefix match, substring) | Levenshtein DP | Typos are insertions/deletions/substitutions; Levenshtein captures all three |
| Candidate collection | Walk AST again | Iterate `scope.vars`, `decls.funcs/structs/enums/vars` key iterators | Maps already have all declared names |
| Suggestion formatting | Separate struct/field | Single `allocPrint` appending to existing message | Keeps message system simple; D-05 mandate |

**Key insight:** Levenshtein is ~30 lines of DP; there is no library to import. Implementing it in `errors.zig` is correct and complete.

---

## Common Pitfalls

### Pitfall 1: Silent Unknown Identifier — No Error Emitted
**What goes wrong:** `resolveExpr` at the `.identifier` branch (line 524-532) returns `RT.unknown` silently when a name is not found. No error is reported. This means "did you mean?" can't fire unless an explicit error is added here.
**Why it happens:** The resolver tolerates unknown identifiers to avoid cascading errors during incomplete type resolution.
**How to avoid:** Add explicit error reporting at the `RT.unknown` return on line 532. Guard with a check: only report if the identifier is not in `builtins.isBuiltinValue` and not in the Zig stdlib bridge namespace. The existing "unknown type" pattern at line 906 shows the right approach.
**Warning signs:** Tests pass without the new error but "did you mean" never appears — means the error site was missed.

### Pitfall 2: Double-Free on Suggestion String
**What goes wrong:** `formatSuggestion` returns `!?[]const u8`. If it returns a non-null slice, that slice must be freed after being consumed by `allocPrint`. Forgetting the `defer if (suggestion) |s| allocator.free(s)` causes a leak.
**Why it happens:** The conditional optional pattern requires care in Zig.
**How to avoid:** Always write the defer immediately after the `formatSuggestion` call, before the allocPrint that consumes it.

### Pitfall 3: Candidates ArrayList Outliving scope/decls Iterators
**What goes wrong:** `StringHashMap.keyIterator()` returns pointers into the map's storage. If the map is modified during iteration (won't happen here — all maps are read-only during error reporting), pointers become invalid.
**Why it happens:** Map key pointers are stable as long as the map is not modified.
**How to avoid:** Build the `candidates` ArrayList by appending key slices, then call `formatSuggestion` immediately before deiniting candidates. The strings in the ArrayList are owned by the maps and remain valid.

### Pitfall 4: Threshold Too High for Short Names
**What goes wrong:** With threshold=2 and a 2-character identifier `x`, Levenshtein will match almost anything. "did you mean 'y'?" on a 1-char identifier is nonsense.
**Why it happens:** Edit distance is relative to name length; short names have few bits of information.
**How to avoid:** Use `threshold = if (query.len <= 4) 1 else 2`. For 1-2 char names, don't suggest anything (return null immediately).

### Pitfall 5: Missing Report Sites
**What goes wrong:** Not all 51 report sites benefit from suggestions. Some (e.g., syntax-level structural errors) have no name to match. Implementing "did you mean" only at identifier resolution but calling the phase complete means ERR-01 is only partially satisfied.
**Why it happens:** CONTEXT.md counts all sites (resolver:26, declarations:10, etc.) but only a subset involve identifier typos.
**How to avoid:** The planner should divide work by category: (a) identifier lookup failures → add suggestion, (b) type name failures → add suggestion, (c) structural errors (e.g., "match with guards requires an 'else' arm") → no suggestion, (d) ownership/borrow/thread → add fixed hint text.

### Pitfall 6: Type Name Display Inconsistency (ERR-02)
**What goes wrong:** `ResolvedType.name()` is already used consistently in the existing "type mismatch" messages. The risk is missing some report sites that use a different formatting approach for type names.
**Why it happens:** Not all type mismatch messages were added at the same time.
**How to avoid:** Grep all `reporter.report` calls in resolver.zig, declarations.zig, and propagation.zig for messages containing type names but not following the "expected X, got Y" template. Fix those specifically.

---

## Code Examples

### Levenshtein — Full Implementation
```zig
// Source: standard DP algorithm — verified correct
// Location: errors.zig

const MAX_NAME_LEN = 64;

pub fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    // Guard against pathological names
    if (a.len > MAX_NAME_LEN or b.len > MAX_NAME_LEN) return MAX_NAME_LEN;

    // Use stack array — max 65 usizes = 520 bytes, well within stack budget
    var row: [MAX_NAME_LEN + 1]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;

    for (a, 0..) |ca, i| {
        var prev = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            const next = @min(@min(row[j + 1] + 1, prev + 1), row[j] + cost);
            row[j] = prev;
            prev = next;
        }
        row[b.len] = prev;
    }
    return row[b.len];
}

pub fn closestMatch(query: []const u8, candidates: []const []const u8, threshold: usize) ?[]const u8 {
    if (query.len <= 2) return null; // too short for meaningful suggestions
    var best: ?[]const u8 = null;
    var best_dist: usize = threshold + 1;
    for (candidates) |c| {
        const d = levenshtein(query, c);
        if (d > 0 and d < best_dist) { // d > 0: don't suggest the same name
            best_dist = d;
            best = c;
        }
    }
    return best;
}

pub fn formatSuggestion(query: []const u8, candidates: []const []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const threshold: usize = if (query.len <= 4) 1 else 2;
    if (closestMatch(query, candidates, threshold)) |match| {
        return try std.fmt.allocPrint(allocator, " — did you mean '{s}'?", .{match});
    }
    return null;
}
```

### Levenshtein Unit Tests (go in errors.zig)
```zig
test "levenshtein exact match" {
    try std.testing.expectEqual(@as(usize, 0), levenshtein("count", "count"));
}

test "levenshtein single substitution" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("coutn", "count"));
}

test "levenshtein single insertion" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("cont", "count"));
}

test "levenshtein single deletion" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("countt", "count"));
}

test "levenshtein empty strings" {
    try std.testing.expectEqual(@as(usize, 5), levenshtein("", "count"));
    try std.testing.expectEqual(@as(usize, 5), levenshtein("count", ""));
}

test "closestMatch finds best" {
    const candidates = [_][]const u8{ "count", "print", "value" };
    const result = closestMatch("coutn", &candidates, 2);
    try std.testing.expectEqualStrings("count", result.?);
}

test "closestMatch returns null when nothing close" {
    const candidates = [_][]const u8{ "print", "value", "render" };
    const result = closestMatch("xyz", &candidates, 2);
    try std.testing.expect(result == null);
}

test "closestMatch no suggestion for short names" {
    const candidates = [_][]const u8{ "x", "y", "z" };
    const result = closestMatch("a", &candidates, 1);
    try std.testing.expect(result == null); // len <= 2 guard
}
```

### Resolver — Identifier Error With Suggestion (key site)
```zig
// resolver.zig resolveExpr, .identifier arm (currently line ~524-532)
// AFTER enhancement:
.identifier => |id_name| {
    if (scope.lookup(id_name)) |t| return t;
    if (self.decls.funcs.get(id_name)) |sig| return sig.return_type;
    if (self.decls.structs.contains(id_name)) return RT{ .named = id_name };
    if (self.decls.enums.contains(id_name)) return RT{ .named = id_name };
    if (self.decls.vars.get(id_name)) |v| return v.type_ orelse RT.unknown;
    if (builtins.isBuiltinType(id_name)) return RT{ .named = id_name };
    if (builtins.isBuiltinValue(id_name)) return RT{ .named = id_name };

    // Not found — report error with optional suggestion
    var candidates = std.ArrayList([]const u8).init(self.allocator);
    defer candidates.deinit();
    var sc: ?*const Scope = scope;
    while (sc) |s| {
        var it = s.vars.keyIterator();
        while (it.next()) |k| try candidates.append(k.*);
        sc = s.parent;
    }
    var fit = self.decls.funcs.keyIterator();
    while (fit.next()) |k| try candidates.append(k.*);
    var sit = self.decls.structs.keyIterator();
    while (sit.next()) |k| try candidates.append(k.*);
    var eit = self.decls.enums.keyIterator();
    while (eit.next()) |k| try candidates.append(k.*);
    var vit = self.decls.vars.keyIterator();
    while (vit.next()) |k| try candidates.append(k.*);

    const suggestion = try errors.formatSuggestion(id_name, candidates.items, self.allocator);
    defer if (suggestion) |s| self.allocator.free(s);
    const msg = try std.fmt.allocPrint(self.allocator,
        "unknown identifier '{s}'{s}",
        .{ id_name, suggestion orelse "" });
    defer self.allocator.free(msg);
    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
    return RT.unknown;
},
```

### Ownership — Move-After-Use Hint
```zig
// ownership.zig ~line 362 (use of moved value)
const msg = try std.fmt.allocPrint(self.allocator,
    "use of moved value '{s}' — consider using copy()", .{name});
```

### Borrow — Conflict Hint (read-only context)
```zig
// borrow.zig ~line 299 (borrow conflict)
// Only append const & suggestion when the NEW borrow is immutable
// (user is trying to add a read-only borrow but there's already a mutable one)
const hint: []const u8 = if (!is_mutable)
    " — consider borrowing with const & after releasing the mutable borrow"
else
    "";
const msg = try std.fmt.allocPrint(self.allocator,
    "cannot borrow '{s}' as {s}: already borrowed as {s}{s}",
    .{
        label,
        if (is_mutable) "mutable" else "immutable",
        if (existing.is_mutable) "mutable" else "immutable",
        hint,
    });
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Silent RT.unknown for unknown identifiers | Explicit error + suggestion | Phase 30 | Developer sees actionable message instead of cascading Zig errors |
| Bare "type mismatch" strings | Standardized "expected X, got Y" | Phase 30 | Consistent across all 26+ resolver sites |
| No hints on ownership errors | Inline "consider using copy()" | Phase 30 | Developer knows the fix immediately |

**Deprecated/outdated:**
- "if condition must be bool, got 'X'" → replace with "type mismatch: expected bool, got 'X'" to match ERR-02 pattern

---

## Open Questions

1. **Does the `.identifier` arm in `resolveExpr` need a guard to prevent duplicate errors?**
   - What we know: Some identifiers that fail `scope.lookup` may be caught by a later pass (e.g., codegen can fail on the same unknown name).
   - What's unclear: Whether reporting here causes double errors in practice.
   - Recommendation: Report here; the existing `hasErrors()` gate between passes means only resolver errors surface in normal compilation. If cascading occurs, add a check like `if (self.reporter.hasErrors()) return RT.unknown` early.

2. **Should builtins be in the Levenshtein candidate pool?**
   - What we know: `builtins.isBuiltinType` is a static string lookup in `builtins.zig`. There is no slice of builtin names to iterate.
   - What's unclear: Whether getting the builtin name list requires a dedicated `builtins.allNames()` function.
   - Recommendation: Add a `builtins.allTypeNames() []const []const u8` const slice returning all builtin type names. Include it in the candidates pool for the "unknown type" error site in resolver.zig. For the identifier site, start without builtins — scope + DeclTable covers user code.

3. **How many report sites actually involve identifier names (ERR-01 scope)?**
   - What we know: D-11 says 51 total sites across all passes, but not all are identifier-related.
   - What's unclear: Exact count of sites where a name lookup failed vs structural/semantic errors with no candidate.
   - Recommendation: Plan should enumerate per-pass: resolver (unknown identifier ~1 site, unknown type ~1 site, plus any function-not-found sites), declarations (TBD), propagation (no identifier errors — all structural), borrow/ownership/thread (no identifier lookup — only hints). Net: suggestion sites ~3-5; hint sites ~8-10.

---

## Environment Availability

Step 2.6: SKIPPED (no external dependencies — all work is within the Zig codebase, no tools beyond `zig build` and `./testall.sh` needed).

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Zig built-in `test` blocks + shell integration tests |
| Config file | `build.zig` (`zig build test`) |
| Quick run command | `zig build test` |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ERR-01 | `levenshtein("coutn", "count") == 1` | unit | `zig build test` (errors.zig test block) | ❌ Wave 0 |
| ERR-01 | `closestMatch` returns best candidate | unit | `zig build test` | ❌ Wave 0 |
| ERR-01 | `closestMatch` returns null for no match | unit | `zig build test` | ❌ Wave 0 |
| ERR-01 | Unknown identifier produces "did you mean" in output | integration | `bash test/11_errors.sh` | ❌ Wave 0 (new fixture) |
| ERR-02 | Type mismatch shows "expected X, got Y" | integration | `bash test/11_errors.sh` | ❌ Wave 0 (new fixture) |
| ERR-03 | Move-after-use shows "consider using copy()" | integration | `bash test/11_errors.sh` | ❌ Wave 0 (new fixture) |
| ERR-03 | Borrow violation shows "consider borrowing with const &" | integration | `bash test/11_errors.sh` | ❌ Wave 0 (new fixture) |

### Sampling Rate
- **Per task commit:** `zig build test` (unit tests only, ~2s)
- **Per wave merge:** `./testall.sh` (full 262-test suite)
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] Unit test blocks in `src/errors.zig` — covers `levenshtein`, `closestMatch`, `formatSuggestion` (ERR-01)
- [ ] `test/fixtures/fail_did_you_mean.orh` — fixture with typo identifier for ERR-01 integration test
- [ ] `test/fixtures/fail_type_mismatch_display.orh` — fixture for ERR-02 integration test
- [ ] `test/fixtures/fail_move_after_use_hint.orh` — fixture for ERR-03 move hint
- [ ] `test/fixtures/fail_borrow_hint.orh` — fixture for ERR-03 borrow hint
- [ ] New test cases in `test/11_errors.sh` matching the above fixtures

---

## Sources

### Primary (HIGH confidence)
- Direct source read: `src/errors.zig` — full Reporter struct, OrhonError shape, existing tests
- Direct source read: `src/resolver.zig` — all 26 report sites, Scope struct, identifier resolution at line 524
- Direct source read: `src/ownership.zig` — 3 report sites, move-after-use message at line 362
- Direct source read: `src/borrow.zig` — 4 report sites, borrow conflict at line 299
- Direct source read: `src/thread_safety.zig` — 3 report sites, thread move message at line 254
- Direct source read: `src/declarations.zig` — DeclTable struct with 6 maps (funcs, structs, enums, bitfields, vars, types)
- Direct source read: `src/propagation.zig` — 5 report sites, all structural (no identifier lookups)

### Secondary (MEDIUM confidence)
- Standard Levenshtein DP algorithm — universally known, O(mn) correctness provable by inspection
- Zig pattern for stack-allocated fixed arrays — consistent with existing codebase patterns

### Tertiary (LOW confidence)
- None

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new dependencies; all work is within existing files
- Architecture: HIGH — Levenshtein placement, call-site pattern, and hint text all verified against source
- Pitfalls: HIGH — identified by direct source reading (silent RT.unknown, missing report sites, double-free risk)

**Research date:** 2026-03-28
**Valid until:** 2026-06-01 (stable codebase, no external dependencies)
