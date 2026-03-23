// http.zig — HTTP client sidecar for std::http
// Wraps Zig's std.http.Client for simple GET/POST requests.

const std = @import("std");
const _rt = @import("_orhon_rt");

const alloc = std.heap.page_allocator;
const OrhonResult = _rt.OrhonResult;

const max_body = 10 * 1024 * 1024; // 10 MB

// ── GET ──

pub fn get(url: []const u8) OrhonResult([]const u8) {
    const uri = std.Uri.parse(url) catch {
        return .{ .err = .{ .message = "invalid URL" } };
    };

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var header_buf: [16384]u8 = undefined;
    var req = client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
    }) catch {
        return .{ .err = .{ .message = "could not open request" } };
    };
    defer req.deinit();

    req.send() catch {
        return .{ .err = .{ .message = "send failed" } };
    };
    req.finish() catch {
        return .{ .err = .{ .message = "request failed" } };
    };
    req.wait() catch {
        return .{ .err = .{ .message = "no response" } };
    };

    const body = req.reader().readAllAlloc(alloc, max_body) catch {
        return .{ .err = .{ .message = "could not read response body" } };
    };
    return .{ .ok = body };
}

// ── POST ──

pub fn post(url: []const u8, body: []const u8, content_type: []const u8) OrhonResult([]const u8) {
    const uri = std.Uri.parse(url) catch {
        return .{ .err = .{ .message = "invalid URL" } };
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
        return .{ .err = .{ .message = "could not open request" } };
    };
    defer req.deinit();

    req.send() catch {
        return .{ .err = .{ .message = "send failed" } };
    };
    req.writer().writeAll(body) catch {
        return .{ .err = .{ .message = "could not write body" } };
    };
    req.finish() catch {
        return .{ .err = .{ .message = "request failed" } };
    };
    req.wait() catch {
        return .{ .err = .{ .message = "no response" } };
    };

    const resp_body = req.reader().readAllAlloc(alloc, max_body) catch {
        return .{ .err = .{ .message = "could not read response body" } };
    };
    return .{ .ok = resp_body };
}

// Note: HTTP tests are omitted because they require external network access.
// The module is tested via integration tests (orhon run with a local server).
