// net.zig — TCP networking sidecar for std::net
// Wraps Zig's std.net for TCP client/server.

const std = @import("std");
const _rt = @import("_orhon_rt");

const alloc = std.heap.page_allocator;
const OrhonResult = _rt.OrhonResult;

// ── Connection ──

pub const Connection = struct {
    stream: std.net.Stream,

    pub fn send(self: *Connection, data: []const u8) OrhonResult(void) {
        self.stream.writeAll(data) catch {
            return .{ .err = .{ .message = "send failed" } };
        };
        return .{ .ok = {} };
    }

    pub fn recv(self: *Connection, n: i32) OrhonResult([]const u8) {
        const count: usize = @intCast(@max(0, n));
        const buf = alloc.alloc(u8, count) catch {
            return .{ .err = .{ .message = "out of memory" } };
        };
        const bytes_read = self.stream.read(buf) catch {
            alloc.free(buf);
            return .{ .err = .{ .message = "recv failed" } };
        };
        if (bytes_read == 0) {
            alloc.free(buf);
            return .{ .ok = "" };
        }
        return .{ .ok = buf[0..bytes_read] };
    }

    pub fn close(self: *Connection) void {
        self.stream.close();
    }
};

// ── Listener ──

pub const Listener = struct {
    server: std.net.Server,

    pub fn accept(self: *Listener) OrhonResult(Connection) {
        const conn = self.server.accept() catch {
            return .{ .err = .{ .message = "accept failed" } };
        };
        return .{ .ok = .{ .stream = conn.stream } };
    }

    pub fn close(self: *Listener) void {
        self.server.deinit();
    }
};

// ── TCP Connect ──

pub fn tcpConnect(host: []const u8, port: i32) OrhonResult(Connection) {
    const p: u16 = std.math.cast(u16, port) orelse return .{ .err = .{ .message = "invalid port" } };
    const stream = std.net.tcpConnectToHost(alloc, host, p) catch {
        return .{ .err = .{ .message = "connection failed" } };
    };
    return .{ .ok = .{ .stream = stream } };
}

// ── TCP Listen ──

pub fn tcpListen(host: []const u8, port: i32) OrhonResult(Listener) {
    const p: u16 = std.math.cast(u16, port) orelse return .{ .err = .{ .message = "invalid port" } };
    const address = std.net.Address.resolveIp(host, p) catch {
        return .{ .err = .{ .message = "could not resolve address" } };
    };
    const server = address.listen(.{ .reuse_address = true }) catch {
        return .{ .err = .{ .message = "listen failed" } };
    };
    return .{ .ok = .{ .server = server } };
}

// ── Tests ──
// Network tests use loopback to avoid external dependencies.

test "listen and connect" {
    // Start a listener on a random high port
    const listen_result = tcpListen("127.0.0.1", 0);
    try std.testing.expect(listen_result == .ok);
    var listener = listen_result.ok;
    defer listener.close();

    // Get the actual port assigned
    const addr = listener.server.listen_address;
    const port = addr.getPort();

    // Connect to it
    const conn_result = tcpConnect("127.0.0.1", @intCast(port));
    try std.testing.expect(conn_result == .ok);
    var client = conn_result.ok;
    defer client.close();

    // Accept the connection
    const accept_result = listener.accept();
    try std.testing.expect(accept_result == .ok);
    var server_conn = accept_result.ok;
    defer server_conn.close();

    // Send and receive
    const send_result = client.send("hello");
    try std.testing.expect(send_result == .ok);

    const recv_result = server_conn.recv(1024);
    try std.testing.expect(recv_result == .ok);
    try std.testing.expect(std.mem.eql(u8, recv_result.ok, "hello"));
}
