// http.zig — HTTP client sidecar for std::http
// Wraps Zig's std.http.Client for simple GET/POST requests.

const std = @import("std");

const alloc = std.heap.smp_allocator;

const max_body = 10 * 1024 * 1024; // 10 MB

// ── GET ──

pub fn get(url: []const u8) anyerror![]const u8 {
    const uri = std.Uri.parse(url) catch {
        return error.invalid_url;
    };

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var header_buf: [16384]u8 = undefined;
    var req = client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
    }) catch {
        return error.could_not_open_request;
    };
    defer req.deinit();

    req.send() catch {
        return error.send_failed;
    };
    req.finish() catch {
        return error.request_failed;
    };
    req.wait() catch {
        return error.no_response;
    };

    const body = req.reader().readAllAlloc(alloc, max_body) catch {
        return error.could_not_read_response_body;
    };
    return body;
}

// ── POST ──

pub fn post(url: []const u8, body: []const u8, content_type: []const u8) anyerror![]const u8 {
    const uri = std.Uri.parse(url) catch {
        return error.invalid_url;
    };

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var header_buf: [16384]u8 = undefined;
    var req = client.open(.POST, uri, .{
        .server_header_buffer = &header_buf,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = content_type },
        },
    }) catch {
        return error.could_not_open_request;
    };
    defer req.deinit();

    req.send() catch {
        return error.send_failed;
    };
    req.writer().writeAll(body) catch {
        return error.could_not_write_body;
    };
    req.finish() catch {
        return error.request_failed;
    };
    req.wait() catch {
        return error.no_response;
    };

    const resp_body = req.reader().readAllAlloc(alloc, max_body) catch {
        return error.could_not_read_response_body;
    };
    return resp_body;
}

// ── URL Parsing ──

fn parseUri(url: []const u8) ?std.Uri {
    return std.Uri.parse(url) catch return null;
}

pub fn urlScheme(url: []const u8) anyerror![]const u8 {
    const uri = parseUri(url) orelse return error.invalid_url;
    const scheme = uri.scheme;
    return alloc.dupe(u8, scheme) catch return error.out_of_memory;
}

pub fn urlHost(url: []const u8) anyerror![]const u8 {
    const uri = parseUri(url) orelse return error.invalid_url;
    const host = uri.host orelse return error.no_host_in_url;
    const raw = host.toRawSlice();
    return alloc.dupe(u8, raw) catch return error.out_of_memory;
}

pub fn urlPort(url: []const u8) anyerror!i32 {
    const uri = parseUri(url) orelse return error.invalid_url;
    if (uri.port) |p| return @intCast(p);
    return 0;
}

pub fn urlPath(url: []const u8) anyerror![]const u8 {
    const uri = parseUri(url) orelse return error.invalid_url;
    const raw = uri.path.toRawSlice();
    if (raw.len == 0) return "/";
    return alloc.dupe(u8, raw) catch return error.out_of_memory;
}

pub fn urlQuery(url: []const u8) anyerror![]const u8 {
    const uri = parseUri(url) orelse return error.invalid_url;
    if (uri.query) |q| {
        const raw = q.toRawSlice();
        return alloc.dupe(u8, raw) catch return error.out_of_memory;
    }
    return "";
}

pub fn urlBuild(scheme: []const u8, host: []const u8, port: i32, path: []const u8, query: []const u8) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    buf.appendSlice(alloc, scheme) catch return "";
    buf.appendSlice(alloc, "://") catch return "";
    buf.appendSlice(alloc, host) catch return "";
    if (port > 0) {
        const port_str = std.fmt.allocPrint(alloc, ":{d}", .{port}) catch return "";
        buf.appendSlice(alloc, port_str) catch return "";
    }
    if (path.len > 0 and path[0] != '/') buf.append(alloc, '/') catch return "";
    buf.appendSlice(alloc, path) catch return "";
    if (query.len > 0) {
        buf.append(alloc, '?') catch return "";
        buf.appendSlice(alloc, query) catch return "";
    }
    return buf.items;
}

// ── Tests ──

test "urlScheme" {
    const r = try urlScheme("https://example.com/path?q=1");
    try std.testing.expect(std.mem.eql(u8, r, "https"));
}

test "urlHost" {
    const r = try urlHost("https://example.com:8080/path");
    try std.testing.expect(std.mem.eql(u8, r, "example.com"));
}

test "urlPort" {
    const r = try urlPort("https://example.com:8080/path");
    try std.testing.expectEqual(@as(i32, 8080), r);
}

test "urlPort default" {
    const r = try urlPort("https://example.com/path");
    try std.testing.expectEqual(@as(i32, 0), r);
}

test "urlPath" {
    const r = try urlPath("https://example.com/api/v1/users");
    try std.testing.expect(std.mem.eql(u8, r, "/api/v1/users"));
}

test "urlQuery" {
    const r = try urlQuery("https://example.com/search?q=orhon&lang=en");
    try std.testing.expect(std.mem.eql(u8, r, "q=orhon&lang=en"));
}

test "urlBuild" {
    const result = urlBuild("https", "example.com", 8080, "/api", "key=val");
    try std.testing.expect(std.mem.eql(u8, result, "https://example.com:8080/api?key=val"));
}

test "urlBuild no port no query" {
    const result = urlBuild("http", "localhost", 0, "/", "");
    try std.testing.expect(std.mem.eql(u8, result, "http://localhost/"));
}
