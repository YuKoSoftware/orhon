// net.zig — TCP networking sidecar for std::net
// Wraps Zig's std.net for TCP client/server.

const std = @import("std");
const allocator = @import("allocator.zig");

const alloc = allocator.default;

// ── Connection ──

/// A TCP connection that wraps a network stream for sending and receiving data.
pub const Connection = struct {
    stream: std.net.Stream,

    /// Send data over the connection.
    pub fn send(self: *Connection, data: []const u8) anyerror!void {
        self.stream.writeAll(data) catch {
            return error.send_failed;
        };
    }

    /// Receive up to n bytes from the connection.
    pub fn recv(self: *Connection, n: i32) anyerror![]const u8 {
        const count: usize = @intCast(@max(0, n));
        const buf = alloc.alloc(u8, count) catch {
            return error.out_of_memory;
        };
        const bytes_read = self.stream.read(buf) catch {
            alloc.free(buf);
            return error.recv_failed;
        };
        if (bytes_read == 0) {
            alloc.free(buf);
            return "";
        }
        return buf[0..bytes_read];
    }

    /// Close the connection.
    pub fn close(self: *Connection) void {
        self.stream.close();
    }
};

// ── Listener ──

/// A TCP server listener that accepts incoming connections.
pub const Listener = struct {
    server: std.net.Server,

    /// Accept an incoming connection and return it.
    pub fn accept(self: *Listener) anyerror!Connection {
        const conn = self.server.accept() catch {
            return error.accept_failed;
        };
        return .{ .stream = conn.stream };
    }

    /// Stop listening and release the server socket.
    pub fn close(self: *Listener) void {
        self.server.deinit();
    }
};

// ── TCP Connect ──

/// Open a TCP connection to the given host and port.
pub fn tcpConnect(host: []const u8, port: i32) anyerror!Connection {
    const p: u16 = std.math.cast(u16, port) orelse return error.invalid_port;
    const stream = std.net.tcpConnectToHost(alloc, host, p) catch {
        return error.connection_failed;
    };
    return .{ .stream = stream };
}

// ── TCP Listen ──

/// Start a TCP listener on the given host and port.
pub fn tcpListen(host: []const u8, port: i32) anyerror!Listener {
    const p: u16 = std.math.cast(u16, port) orelse return error.invalid_port;
    const address = std.net.Address.resolveIp(host, p) catch {
        return error.could_not_resolve_address;
    };
    const server = address.listen(.{ .reuse_address = true }) catch {
        return error.listen_failed;
    };
    return .{ .server = server };
}

// ── Tests ──
// Network tests use loopback to avoid external dependencies.

test "listen and connect" {
    // Start a listener on a random high port
    var listener = try tcpListen("127.0.0.1", 0);
    defer listener.close();

    // Get the actual port assigned
    const addr = listener.server.listen_address;
    const port = addr.getPort();

    // Connect to it
    var client = try tcpConnect("127.0.0.1", @intCast(port));
    defer client.close();

    // Accept the connection
    var server_conn = try listener.accept();
    defer server_conn.close();

    // Send and receive
    try client.send("hello");

    const recv_result = try server_conn.recv(1024);
    try std.testing.expect(std.mem.eql(u8, recv_result, "hello"));
}
