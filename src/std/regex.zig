// regex.zig — pattern matching sidecar for std::regex
// Recursive backtracking regex engine with basic syntax support.

const std = @import("std");
const _rt = @import("_orhon_rt");

const alloc = std.heap.page_allocator;
const OrhonResult = _rt.OrhonResult;

// ── Pattern AST ──

const Quantifier = enum { one, zero_or_more, one_or_more, zero_or_one };

const AtomTag = enum { literal, dot, class, group, anchor_start, anchor_end };

const Atom = struct {
    tag: AtomTag,
    // literal
    char: u8 = 0,
    // class
    ranges: []const [2]u8 = &.{},
    class_negated: bool = false,
    // group
    alternatives: []const Alternative = &.{},
    // quantifier
    quantifier: Quantifier = .one,
};

const Alternative = struct {
    atoms: []const Atom,
};

const Regex = struct {
    alternatives: []const Alternative,
};

// ── Parser ──

const Parser = struct {
    src: []const u8,
    pos: usize,

    fn init(pattern: []const u8) Parser {
        return .{ .src = pattern, .pos = 0 };
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn advance(self: *Parser) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    fn parseRegex(self: *Parser) ?Regex {
        var alts = std.ArrayListUnmanaged(Alternative){};
        if (self.parseAlternative()) |alt| {
            alts.append(alloc, alt) catch return null;
        } else return null;

        while (self.peek() == @as(u8, '|')) {
            _ = self.advance(); // skip |
            if (self.parseAlternative()) |alt| {
                alts.append(alloc, alt) catch return null;
            } else {
                // Empty alternative after | (matches empty string)
                alts.append(alloc, .{ .atoms = &.{} }) catch return null;
            }
        }
        return .{ .alternatives = alts.items };
    }

    fn parseAlternative(self: *Parser) ?Alternative {
        var atoms = std.ArrayListUnmanaged(Atom){};
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            if (self.parseAtom()) |atom| {
                atoms.append(alloc, atom) catch return null;
            } else break;
        }
        return .{ .atoms = atoms.items };
    }

    fn parseAtom(self: *Parser) ?Atom {
        const c = self.peek() orelse return null;
        var atom: Atom = undefined;

        switch (c) {
            '^' => {
                _ = self.advance();
                return .{ .tag = .anchor_start, .quantifier = .one };
            },
            '$' => {
                _ = self.advance();
                return .{ .tag = .anchor_end, .quantifier = .one };
            },
            '.' => {
                _ = self.advance();
                atom = .{ .tag = .dot };
            },
            '[' => {
                atom = self.parseClass() orelse return null;
            },
            '(' => {
                _ = self.advance(); // skip (
                const inner = self.parseRegex() orelse return null;
                if (self.peek() == @as(u8, ')')) {
                    _ = self.advance();
                }
                atom = .{ .tag = .group, .alternatives = inner.alternatives };
            },
            '\\' => {
                atom = self.parseEscape() orelse return null;
            },
            ')', '|' => return null,
            '*', '+', '?' => return null, // quantifier without atom
            else => {
                _ = self.advance();
                atom = .{ .tag = .literal, .char = c };
            },
        }

        // Parse optional quantifier
        if (self.peek()) |q| {
            switch (q) {
                '*' => {
                    _ = self.advance();
                    atom.quantifier = .zero_or_more;
                },
                '+' => {
                    _ = self.advance();
                    atom.quantifier = .one_or_more;
                },
                '?' => {
                    _ = self.advance();
                    atom.quantifier = .zero_or_one;
                },
                else => {
                    atom.quantifier = .one;
                },
            }
        } else {
            atom.quantifier = .one;
        }
        return atom;
    }

    fn parseClass(self: *Parser) ?Atom {
        _ = self.advance(); // skip [
        var negated = false;
        if (self.peek() == @as(u8, '^')) {
            negated = true;
            _ = self.advance();
        }

        var ranges = std.ArrayListUnmanaged([2]u8){};
        while (self.peek()) |c| {
            if (c == ']') {
                _ = self.advance();
                return .{ .tag = .class, .ranges = ranges.items, .class_negated = negated };
            }
            const ch = self.advance();
            // Check for range: a-z
            if (self.peek() == @as(u8, '-') and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                _ = self.advance(); // skip -
                const end = self.advance();
                ranges.append(alloc, .{ ch, end }) catch return null;
            } else {
                ranges.append(alloc, .{ ch, ch }) catch return null;
            }
        }
        return null; // unclosed class
    }

    fn parseEscape(self: *Parser) ?Atom {
        _ = self.advance(); // skip backslash
        const c = self.peek() orelse return null;
        _ = self.advance();
        return switch (c) {
            'd' => .{ .tag = .class, .ranges = &.{.{ '0', '9' }} },
            'D' => .{ .tag = .class, .ranges = &.{.{ '0', '9' }}, .class_negated = true },
            'w' => .{ .tag = .class, .ranges = &.{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } } },
            'W' => .{ .tag = .class, .ranges = &.{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } }, .class_negated = true },
            's' => .{ .tag = .class, .ranges = &.{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } } },
            'S' => .{ .tag = .class, .ranges = &.{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } }, .class_negated = true },
            'n' => .{ .tag = .literal, .char = '\n' },
            't' => .{ .tag = .literal, .char = '\t' },
            'r' => .{ .tag = .literal, .char = '\r' },
            else => .{ .tag = .literal, .char = c }, // escape special chars
        };
    }
};

// ── Matcher ──

fn matchChar(atom: Atom, c: u8) bool {
    return switch (atom.tag) {
        .literal => c == atom.char,
        .dot => c != '\n',
        .class => blk: {
            var found = false;
            for (atom.ranges) |range| {
                if (c >= range[0] and c <= range[1]) {
                    found = true;
                    break;
                }
            }
            break :blk if (atom.class_negated) !found else found;
        },
        else => false,
    };
}

fn matchAtoms(atoms: []const Atom, ai: usize, text: []const u8, ti: usize) ?usize {
    if (ai >= atoms.len) return ti; // all atoms matched

    const atom = atoms[ai];

    // Handle anchors
    if (atom.tag == .anchor_start) {
        if (ti != 0) return null;
        return matchAtoms(atoms, ai + 1, text, ti);
    }
    if (atom.tag == .anchor_end) {
        if (ti != text.len) return null;
        return matchAtoms(atoms, ai + 1, text, ti);
    }

    switch (atom.quantifier) {
        .one => {
            const end = matchSingle(atom, text, ti) orelse return null;
            return matchAtoms(atoms, ai + 1, text, end);
        },
        .zero_or_one => {
            // Try matching one, then try zero
            if (matchSingle(atom, text, ti)) |end| {
                if (matchAtoms(atoms, ai + 1, text, end)) |result| return result;
            }
            return matchAtoms(atoms, ai + 1, text, ti);
        },
        .zero_or_more => {
            return matchRepeat(atom, atoms, ai, text, ti, 0);
        },
        .one_or_more => {
            return matchRepeat(atom, atoms, ai, text, ti, 1);
        },
    }
}

fn matchSingle(atom: Atom, text: []const u8, ti: usize) ?usize {
    if (atom.tag == .group) {
        return matchRegex(.{ .alternatives = atom.alternatives }, text, ti);
    }
    if (ti >= text.len) return null;
    if (matchChar(atom, text[ti])) return ti + 1;
    return null;
}

fn matchRepeat(atom: Atom, atoms: []const Atom, ai: usize, text: []const u8, start: usize, min: usize) ?usize {
    // Greedy: find maximum matches, then backtrack
    var positions = std.ArrayListUnmanaged(usize){};
    positions.append(alloc, start) catch return null;

    var pos = start;
    while (matchSingle(atom, text, pos)) |next| {
        positions.append(alloc, next) catch return null;
        pos = next;
        if (pos == next and atom.tag == .group) break; // avoid infinite loop on empty group match
    }

    // Try from longest to shortest (greedy)
    var i = positions.items.len;
    while (i > min) {
        i -= 1;
        if (matchAtoms(atoms, ai + 1, text, positions.items[i])) |result| return result;
    }
    return null;
}

fn matchRegex(regex: Regex, text: []const u8, pos: usize) ?usize {
    for (regex.alternatives) |alt| {
        if (matchAtoms(alt.atoms, 0, text, pos)) |end| return end;
    }
    return null;
}

// ── Public API ──

pub fn matches(pattern: []const u8, text: []const u8) bool {
    var p = Parser.init(pattern);
    const regex = p.parseRegex() orelse return false;
    const end = matchRegex(regex, text, 0) orelse return false;
    return end == text.len;
}

pub fn find(pattern: []const u8, text: []const u8) OrhonResult([]const u8) {
    var p = Parser.init(pattern);
    const regex = p.parseRegex() orelse return .{ .err = .{ .message = "invalid pattern" } };

    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (matchRegex(regex, text, i)) |end| {
            if (end > i or i == text.len) {
                return .{ .ok = alloc.dupe(u8, text[i..end]) catch return .{ .err = .{ .message = "out of memory" } } };
            }
            // Zero-length match at position i — skip to avoid infinite loop
        }
    }
    return .{ .err = .{ .message = "no match" } };
}

pub fn findAll(pattern: []const u8, text: []const u8) OrhonResult([]const u8) {
    var p = Parser.init(pattern);
    const regex = p.parseRegex() orelse return .{ .err = .{ .message = "invalid pattern" } };

    var buf = std.ArrayListUnmanaged(u8){};
    var count: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (matchRegex(regex, text, i)) |end| {
            if (end > i) {
                if (count > 0) buf.append(alloc, '\n') catch {};
                buf.appendSlice(alloc, text[i..end]) catch {};
                count += 1;
                i = end - 1; // -1 because loop increments
                continue;
            }
        }
    }
    if (count == 0) return .{ .err = .{ .message = "no matches" } };
    return .{ .ok = buf.items };
}

pub fn replace(pattern: []const u8, text: []const u8, replacement: []const u8) OrhonResult([]const u8) {
    var p = Parser.init(pattern);
    const regex = p.parseRegex() orelse return .{ .err = .{ .message = "invalid pattern" } };

    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (matchRegex(regex, text, i)) |end| {
            if (end >= i) {
                var buf = std.ArrayListUnmanaged(u8){};
                buf.appendSlice(alloc, text[0..i]) catch {};
                buf.appendSlice(alloc, replacement) catch {};
                buf.appendSlice(alloc, text[end..]) catch {};
                return .{ .ok = buf.items };
            }
        }
    }
    return .{ .ok = alloc.dupe(u8, text) catch return .{ .err = .{ .message = "out of memory" } } };
}

pub fn replaceAll(pattern: []const u8, text: []const u8, replacement: []const u8) OrhonResult([]const u8) {
    var p = Parser.init(pattern);
    const regex = p.parseRegex() orelse return .{ .err = .{ .message = "invalid pattern" } };

    var buf = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (i < text.len) {
        if (matchRegex(regex, text, i)) |end| {
            if (end > i) {
                buf.appendSlice(alloc, replacement) catch {};
                i = end;
                continue;
            }
        }
        buf.append(alloc, text[i]) catch {};
        i += 1;
    }
    return .{ .ok = if (buf.items.len > 0) buf.items else alloc.dupe(u8, text) catch return .{ .err = .{ .message = "out of memory" } } };
}

// ── Tests ──

test "literal match" {
    try std.testing.expect(matches("hello", "hello"));
    try std.testing.expect(!matches("hello", "world"));
    try std.testing.expect(!matches("hello", "hello world"));
}

test "dot matches any" {
    try std.testing.expect(matches("h.llo", "hello"));
    try std.testing.expect(matches("h.llo", "hallo"));
    try std.testing.expect(!matches("h.llo", "hllo"));
}

test "star quantifier" {
    try std.testing.expect(matches("ab*c", "ac"));
    try std.testing.expect(matches("ab*c", "abc"));
    try std.testing.expect(matches("ab*c", "abbbc"));
}

test "plus quantifier" {
    try std.testing.expect(!matches("ab+c", "ac"));
    try std.testing.expect(matches("ab+c", "abc"));
    try std.testing.expect(matches("ab+c", "abbbc"));
}

test "question quantifier" {
    try std.testing.expect(matches("ab?c", "ac"));
    try std.testing.expect(matches("ab?c", "abc"));
    try std.testing.expect(!matches("ab?c", "abbc"));
}

test "character class" {
    try std.testing.expect(matches("[abc]", "a"));
    try std.testing.expect(matches("[abc]", "b"));
    try std.testing.expect(!matches("[abc]", "d"));
}

test "character range" {
    try std.testing.expect(matches("[a-z]+", "hello"));
    try std.testing.expect(!matches("[a-z]+", "HELLO"));
}

test "negated class" {
    try std.testing.expect(matches("[^0-9]+", "hello"));
    try std.testing.expect(!matches("[^0-9]+", "123"));
}

test "shorthand classes" {
    try std.testing.expect(matches("\\d+", "123"));
    try std.testing.expect(!matches("\\d+", "abc"));
    try std.testing.expect(matches("\\w+", "hello_123"));
    try std.testing.expect(matches("\\s", " "));
}

test "alternation" {
    try std.testing.expect(matches("cat|dog", "cat"));
    try std.testing.expect(matches("cat|dog", "dog"));
    try std.testing.expect(!matches("cat|dog", "bird"));
}

test "grouping" {
    try std.testing.expect(matches("(ab)+", "abab"));
    try std.testing.expect(!matches("(ab)+", "aabb"));
}

test "anchors" {
    try std.testing.expect(matches("^hello$", "hello"));
    try std.testing.expect(!matches("^hello$", "hello world"));
}

test "escape special chars" {
    try std.testing.expect(matches("a\\.b", "a.b"));
    try std.testing.expect(!matches("a\\.b", "axb"));
}

test "find" {
    const r = find("\\d+", "abc 123 def");
    try std.testing.expect(r == .ok);
    try std.testing.expect(std.mem.eql(u8, r.ok, "123"));
}

test "find no match" {
    const r = find("\\d+", "no numbers here");
    try std.testing.expect(r == .err);
}

test "findAll" {
    const r = findAll("\\d+", "a1b22c333");
    try std.testing.expect(r == .ok);
    try std.testing.expect(std.mem.eql(u8, r.ok, "1\n22\n333"));
}

test "replace" {
    const r = replace("\\d+", "hello 123 world", "NUM");
    try std.testing.expect(r == .ok);
    try std.testing.expect(std.mem.eql(u8, r.ok, "hello NUM world"));
}

test "replaceAll" {
    const r = replaceAll("\\d+", "a1b2c3", "X");
    try std.testing.expect(r == .ok);
    try std.testing.expect(std.mem.eql(u8, r.ok, "aXbXcX"));
}
