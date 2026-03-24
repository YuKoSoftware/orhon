// xml.zig — minimal XML tag parser sidecar for std::xml
// Path-based API consistent with json. Handles elements, text, attributes,
// self-closing tags. No namespaces, DTD, CDATA, or processing instructions.

const std = @import("std");

const alloc = std.heap.page_allocator;

// ── Internal: Lightweight XML Node ──

const XmlNode = struct {
    tag: []const u8,
    attrs: []const Attr,
    text: []const u8,
    children: []const XmlNode,
};

const Attr = struct {
    name: []const u8,
    value: []const u8,
};

// ── Parser ──

fn skipWhitespace(src: []const u8, pos: usize) usize {
    var i = pos;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r')) : (i += 1) {}
    return i;
}

fn parseAttr(src: []const u8, pos: usize) ?struct { attr: Attr, end: usize } {
    var i = skipWhitespace(src, pos);
    if (i >= src.len or src[i] == '>' or src[i] == '/' or src[i] == '?') return null;

    // Attribute name
    const name_start = i;
    while (i < src.len and src[i] != '=' and src[i] != ' ' and src[i] != '>' and src[i] != '/') : (i += 1) {}
    const name = src[name_start..i];
    if (name.len == 0) return null;

    i = skipWhitespace(src, i);
    if (i >= src.len or src[i] != '=') return null;
    i += 1; // skip '='
    i = skipWhitespace(src, i);
    if (i >= src.len) return null;

    // Attribute value (quoted)
    const quote = src[i];
    if (quote != '"' and quote != '\'') return null;
    i += 1;
    const val_start = i;
    while (i < src.len and src[i] != quote) : (i += 1) {}
    const value = src[val_start..i];
    if (i < src.len) i += 1; // skip closing quote

    return .{ .attr = .{ .name = name, .value = value }, .end = i };
}

fn parseNode(src: []const u8, pos: usize) ?struct { node: XmlNode, end: usize } {
    var i = skipWhitespace(src, pos);
    if (i >= src.len or src[i] != '<') return null;
    i += 1;

    // Skip comments (<!-- ... -->)
    if (i + 2 < src.len and src[i] == '!' and src[i + 1] == '-' and src[i + 2] == '-') {
        if (std.mem.indexOf(u8, src[i..], "-->")) |end| {
            return parseNode(src, i + end + 3);
        }
        return null;
    }

    // Skip processing instructions (<?...?>)
    if (i < src.len and src[i] == '?') {
        if (std.mem.indexOf(u8, src[i..], "?>")) |end| {
            return parseNode(src, i + end + 2);
        }
        return null;
    }

    // Skip declaration (<!DOCTYPE ...>)
    if (i < src.len and src[i] == '!') {
        while (i < src.len and src[i] != '>') : (i += 1) {}
        if (i < src.len) i += 1;
        return parseNode(src, i);
    }

    // Tag name
    const tag_start = i;
    while (i < src.len and src[i] != ' ' and src[i] != '>' and src[i] != '/' and src[i] != '\t' and src[i] != '\n' and src[i] != '\r') : (i += 1) {}
    const tag = src[tag_start..i];
    if (tag.len == 0) return null;

    // Attributes
    var attrs = std.ArrayListUnmanaged(Attr){};
    while (true) {
        if (parseAttr(src, i)) |result| {
            attrs.append(alloc, result.attr) catch {};
            i = result.end;
        } else break;
    }

    i = skipWhitespace(src, i);

    // Self-closing tag
    if (i < src.len and src[i] == '/') {
        i += 1;
        if (i < src.len and src[i] == '>') i += 1;
        return .{
            .node = .{
                .tag = tag,
                .attrs = attrs.items,
                .text = "",
                .children = &.{},
            },
            .end = i,
        };
    }

    if (i < src.len and src[i] == '>') i += 1 else return null;

    // Children and text content
    var children = std.ArrayListUnmanaged(XmlNode){};
    var text_buf = std.ArrayListUnmanaged(u8){};

    while (i < src.len) {
        // Check for closing tag
        if (i + 1 < src.len and src[i] == '<' and src[i + 1] == '/') {
            // Skip </tag>
            i += 2;
            while (i < src.len and src[i] != '>') : (i += 1) {}
            if (i < src.len) i += 1;
            break;
        }

        // Try to parse child element
        if (src[i] == '<') {
            if (parseNode(src, i)) |child_result| {
                children.append(alloc, child_result.node) catch {};
                i = child_result.end;
                continue;
            }
        }

        // Accumulate text
        text_buf.append(alloc, src[i]) catch {};
        i += 1;
    }

    // Trim text
    const raw_text = text_buf.items;
    const trimmed = std.mem.trim(u8, raw_text, " \t\n\r");

    return .{
        .node = .{
            .tag = tag,
            .attrs = attrs.items,
            .text = trimmed,
            .children = children.items,
        },
        .end = i,
    };
}

fn parseDocument(src: []const u8) ?XmlNode {
    if (parseNode(src, 0)) |result| {
        return result.node;
    }
    return null;
}

// ── Path Resolution ──
// Walks dot-separated path segments to find the target node.

fn resolveNode(root: XmlNode, path: []const u8) ?XmlNode {
    var current = root;
    var remaining = path;

    // First segment must match root tag
    const first_dot = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
    const first_seg = remaining[0..first_dot];
    if (!std.mem.eql(u8, current.tag, first_seg)) return null;
    remaining = if (first_dot < remaining.len) remaining[first_dot + 1 ..] else "";

    while (remaining.len > 0) {
        const dot = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
        const segment = remaining[0..dot];
        remaining = if (dot < remaining.len) remaining[dot + 1 ..] else "";

        var found = false;
        for (current.children) |child| {
            if (std.mem.eql(u8, child.tag, segment)) {
                current = child;
                found = true;
                break;
            }
        }
        if (!found) return null;
    }
    return current;
}

fn resolveAll(root: XmlNode, path: []const u8) []const XmlNode {
    // Find parent path and target tag
    var last_dot: usize = 0;
    var found_dot = false;
    for (path, 0..) |c, idx| {
        if (c == '.') {
            last_dot = idx;
            found_dot = true;
        }
    }

    if (!found_dot) {
        // Path is just the root tag
        if (std.mem.eql(u8, root.tag, path)) {
            const result = alloc.alloc(XmlNode, 1) catch return &.{};
            result[0] = root;
            return result;
        }
        return &.{};
    }

    const parent_path = path[0..last_dot];
    const target_tag = path[last_dot + 1 ..];

    const parent = resolveNode(root, parent_path) orelse return &.{};

    var matches = std.ArrayListUnmanaged(XmlNode){};
    for (parent.children) |child| {
        if (std.mem.eql(u8, child.tag, target_tag)) {
            matches.append(alloc, child) catch {};
        }
    }
    return matches.items;
}

// ── Public API ──

pub fn get(source: []const u8, path: []const u8) anyerror![]const u8 {
    const root = parseDocument(source) orelse {
        return error.invalid_xml;
    };
    const node = resolveNode(root, path) orelse {
        return error.path_not_found;
    };
    if (node.text.len > 0) {
        return alloc.dupe(u8, node.text) catch return error.out_of_memory;
    }
    return "";
}

pub fn getAttr(source: []const u8, path: []const u8, attr: []const u8) anyerror![]const u8 {
    const root = parseDocument(source) orelse {
        return error.invalid_xml;
    };
    const node = resolveNode(root, path) orelse {
        return error.path_not_found;
    };
    for (node.attrs) |a| {
        if (std.mem.eql(u8, a.name, attr)) {
            return alloc.dupe(u8, a.value) catch return error.out_of_memory;
        }
    }
    return error.attribute_not_found;
}

pub fn getAll(source: []const u8, path: []const u8) anyerror![]const u8 {
    const root = parseDocument(source) orelse {
        return error.invalid_xml;
    };
    const nodes = resolveAll(root, path);
    if (nodes.len == 0) {
        return error.no_matching_elements;
    }

    var buf = std.ArrayListUnmanaged(u8){};
    for (nodes, 0..) |node, i| {
        if (i > 0) buf.append(alloc, '\n') catch {};
        buf.appendSlice(alloc, node.text) catch {};
    }
    return if (buf.items.len > 0) buf.items else "";
}

pub fn hasTag(source: []const u8, path: []const u8) bool {
    const root = parseDocument(source) orelse return false;
    return resolveNode(root, path) != null;
}

// ── Tests ──

test "get text content" {
    const xml = "<root><name>orhon</name></root>";
    const result = try get(xml, "root.name");
    try std.testing.expect(std.mem.eql(u8, result, "orhon"));
}

test "get nested" {
    const xml = "<root><user><name>yunus</name></user></root>";
    const result = try get(xml, "root.user.name");
    try std.testing.expect(std.mem.eql(u8, result, "yunus"));
}

test "get attribute" {
    const xml = "<root><item id=\"42\">text</item></root>";
    const result = try getAttr(xml, "root.item", "id");
    try std.testing.expect(std.mem.eql(u8, result, "42"));
}

test "getAll repeated elements" {
    const xml = "<root><item>a</item><item>b</item><item>c</item></root>";
    const result = try getAll(xml, "root.item");
    try std.testing.expect(std.mem.eql(u8, result, "a\nb\nc"));
}

test "hasTag true" {
    const xml = "<root><child/></root>";
    try std.testing.expect(hasTag(xml, "root.child"));
}

test "hasTag false" {
    const xml = "<root><child/></root>";
    try std.testing.expect(!hasTag(xml, "root.other"));
}

test "self-closing tag" {
    const xml = "<root><empty/></root>";
    try std.testing.expect(hasTag(xml, "root.empty"));
    const result = try get(xml, "root.empty");
    try std.testing.expect(std.mem.eql(u8, result, ""));
}

test "attribute with single quotes" {
    const xml = "<root><item name='test'/></root>";
    const result = try getAttr(xml, "root.item", "name");
    try std.testing.expect(std.mem.eql(u8, result, "test"));
}

test "missing path" {
    const xml = "<root><a>1</a></root>";
    const result = get(xml, "root.b");
    try std.testing.expectError(error.path_not_found, result);
}

test "invalid xml" {
    const result = get("not xml at all", "root");
    try std.testing.expectError(error.invalid_xml, result);
}

test "xml declaration skipped" {
    const xml = "<?xml version=\"1.0\"?><root><name>test</name></root>";
    const result = try get(xml, "root.name");
    try std.testing.expect(std.mem.eql(u8, result, "test"));
}

test "comment skipped" {
    const xml = "<!-- comment --><root><name>test</name></root>";
    const result = try get(xml, "root.name");
    try std.testing.expect(std.mem.eql(u8, result, "test"));
}
