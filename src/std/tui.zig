// tui.zig — terminal UI toolkit sidecar for std::tui
// Raw mode, cursor control, key input, screen buffer, drawing helpers.

const std = @import("std");

const posix = std.posix;
const alloc = std.heap.smp_allocator;

const stdout = std.fs.File{ .handle = posix.STDOUT_FILENO };
const stdin = std.fs.File{ .handle = posix.STDIN_FILENO };

// ── Raw Mode ──

var original_termios: ?posix.termios = null;

pub fn enableRawMode() anyerror!void {
    const term = posix.tcgetattr(posix.STDIN_FILENO) catch {
        return error.could_not_get_terminal_attributes;
    };
    original_termios = term;

    var raw = term;
    raw.lflag = raw.lflag.fromInt(raw.lflag.toInt() & ~@as(
        std.posix.system.tc_lflag_t.IntType,
        posix.system.ECHO | posix.system.ICANON | posix.system.ISIG | posix.system.IEXTEN,
    ));
    raw.iflag = raw.iflag.fromInt(raw.iflag.toInt() & ~@as(
        std.posix.system.tc_iflag_t.IntType,
        posix.system.IXON | posix.system.ICRNL,
    ));
    raw.cc[@intFromEnum(posix.system.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.system.V.TIME)] = 0;

    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch {
        return error.could_not_set_terminal_attributes;
    };
}

pub fn disableRawMode() void {
    if (original_termios) |term| {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, term) catch {}; // fire-and-forget: terminal I/O in void fn
        original_termios = null;
    }
}

// ── Alternate Screen ──

pub fn enterAltScreen() void {
    writeEsc("\x1b[?1049h");
}

pub fn exitAltScreen() void {
    writeEsc("\x1b[?1049l");
}

// ── Terminal Size ──

pub const Size = struct {
    row_count: i32,
    col_count: i32,

    pub fn rows(self: *Size) i32 {
        return self.row_count;
    }

    pub fn cols(self: *Size) i32 {
        return self.col_count;
    }
};

pub fn terminalSize() Size {
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.system.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0) {
        return .{ .row_count = @intCast(ws.col), .col_count = @intCast(ws.row) };
    }
    return .{ .row_count = 24, .col_count = 80 };
}

// ── Cursor ──

pub fn moveTo(row: i32, col: i32) void {
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row, col }) catch return;
    writeEsc(seq);
}

pub fn moveUp(n: i32) void {
    var buf: [16]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}A", .{n}) catch return;
    writeEsc(seq);
}

pub fn moveDown(n: i32) void {
    var buf: [16]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}B", .{n}) catch return;
    writeEsc(seq);
}

pub fn moveLeft(n: i32) void {
    var buf: [16]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}D", .{n}) catch return;
    writeEsc(seq);
}

pub fn moveRight(n: i32) void {
    var buf: [16]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}C", .{n}) catch return;
    writeEsc(seq);
}

pub fn hideCursor() void {
    writeEsc("\x1b[?25l");
}

pub fn showCursor() void {
    writeEsc("\x1b[?25h");
}

pub fn saveCursor() void {
    writeEsc("\x1b7");
}

pub fn restoreCursor() void {
    writeEsc("\x1b8");
}

// ── Screen Clear ──

pub fn clearScreen() void {
    writeEsc("\x1b[2J\x1b[H");
}

pub fn clearLine() void {
    writeEsc("\x1b[2K");
}

pub fn clearToEnd() void {
    writeEsc("\x1b[K");
}

// ── Style ──

pub const NO_COLOR: i32 = -1;

pub const FG_BLACK: i32 = 0;
pub const FG_RED: i32 = 1;
pub const FG_GREEN: i32 = 2;
pub const FG_YELLOW: i32 = 3;
pub const FG_BLUE: i32 = 4;
pub const FG_MAGENTA: i32 = 5;
pub const FG_CYAN: i32 = 6;
pub const FG_WHITE: i32 = 7;

pub const BG_BLACK: i32 = 0;
pub const BG_RED: i32 = 1;
pub const BG_GREEN: i32 = 2;
pub const BG_YELLOW: i32 = 3;
pub const BG_BLUE: i32 = 4;
pub const BG_MAGENTA: i32 = 5;
pub const BG_CYAN: i32 = 6;
pub const BG_WHITE: i32 = 7;

pub fn style(fg: i32, bg: i32, bold: bool, text: []const u8) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    buf.appendSlice(alloc, "\x1b[") catch return text;

    var need_sep = false;

    if (bold) {
        buf.appendSlice(alloc, "1") catch return text;
        need_sep = true;
    }

    if (fg >= 0 and fg <= 7) {
        if (need_sep) buf.append(alloc, ';') catch return text;
        var num_buf: [4]u8 = undefined;
        const code = std.fmt.bufPrint(&num_buf, "{d}", .{30 + fg}) catch return text;
        buf.appendSlice(alloc, code) catch return text;
        need_sep = true;
    }

    if (bg >= 0 and bg <= 7) {
        if (need_sep) buf.append(alloc, ';') catch return text;
        var num_buf: [4]u8 = undefined;
        const code = std.fmt.bufPrint(&num_buf, "{d}", .{40 + bg}) catch return text;
        buf.appendSlice(alloc, code) catch return text;
    }

    buf.append(alloc, 'm') catch return text;
    buf.appendSlice(alloc, text) catch return text;
    buf.appendSlice(alloc, "\x1b[0m") catch return text;

    return if (buf.items.len > 0) buf.items else text;
}

// ── Key Input ──

pub const KEY_CHAR: i32 = 0;
pub const KEY_ENTER: i32 = 1;
pub const KEY_ESCAPE: i32 = 2;
pub const KEY_BACKSPACE: i32 = 3;
pub const KEY_TAB: i32 = 4;
pub const KEY_ARROW_UP: i32 = 5;
pub const KEY_ARROW_DOWN: i32 = 6;
pub const KEY_ARROW_LEFT: i32 = 7;
pub const KEY_ARROW_RIGHT: i32 = 8;
pub const KEY_HOME: i32 = 9;
pub const KEY_END: i32 = 10;
pub const KEY_PAGE_UP: i32 = 11;
pub const KEY_PAGE_DOWN: i32 = 12;
pub const KEY_DELETE: i32 = 13;
pub const KEY_F1: i32 = 14;
pub const KEY_F2: i32 = 15;
pub const KEY_F3: i32 = 16;
pub const KEY_F4: i32 = 17;
pub const KEY_F5: i32 = 18;
pub const KEY_F6: i32 = 19;
pub const KEY_F7: i32 = 20;
pub const KEY_F8: i32 = 21;
pub const KEY_F9: i32 = 22;
pub const KEY_F10: i32 = 23;
pub const KEY_F11: i32 = 24;
pub const KEY_F12: i32 = 25;

pub const Key = struct {
    key_kind: i32,
    key_char: []const u8,
    is_ctrl: bool,

    pub fn kind(self: *Key) i32 {
        return self.key_kind;
    }

    pub fn char(self: *Key) []const u8 {
        return self.key_char;
    }

    pub fn ctrl(self: *Key) bool {
        return self.is_ctrl;
    }
};

pub fn readKey() anyerror!Key {
    var buf: [8]u8 = undefined;
    const n = stdin.read(&buf) catch {
        return error.read_failed;
    };
    if (n == 0) return error.end_of_input;

    const b = buf[0];

    // Enter
    if (b == '\r' or b == '\n') {
        return .{ .key_kind = KEY_ENTER, .key_char = "", .is_ctrl = false };
    }

    // Tab
    if (b == '\t') {
        return .{ .key_kind = KEY_TAB, .key_char = "", .is_ctrl = false };
    }

    // Backspace
    if (b == 127 or b == 8) {
        return .{ .key_kind = KEY_BACKSPACE, .key_char = "", .is_ctrl = false };
    }

    // Escape sequences
    if (b == 0x1b) {
        if (n == 1) {
            return .{ .key_kind = KEY_ESCAPE, .key_char = "", .is_ctrl = false };
        }
        if (n >= 3 and buf[1] == '[') {
            return parseCSI(buf[2..n]);
        }
        if (n >= 3 and buf[1] == 'O') {
            return parseSS3(buf[2]);
        }
        return .{ .key_kind = KEY_ESCAPE, .key_char = "", .is_ctrl = false };
    }

    // Ctrl + letter (bytes 1-26, excluding tab/enter/backspace handled above)
    if (b < 32) {
        const ch_buf = alloc.alloc(u8, 1) catch return error.out_of_memory;
        ch_buf[0] = b + 'a' - 1;
        return .{ .key_kind = KEY_CHAR, .key_char = ch_buf, .is_ctrl = true };
    }

    // Regular printable character
    const ch_buf = alloc.dupe(u8, buf[0..n]) catch return error.out_of_memory;
    return .{ .key_kind = KEY_CHAR, .key_char = ch_buf, .is_ctrl = false };
}

fn parseCSI(seq: []const u8) Key {
    if (seq.len == 0) return .{ .key_kind = KEY_ESCAPE, .key_char = "", .is_ctrl = false };

    // Single-char CSI: \x1b[A through \x1b[H
    return switch (seq[0]) {
        'A' => .{ .key_kind = KEY_ARROW_UP, .key_char = "", .is_ctrl = false },
        'B' => .{ .key_kind = KEY_ARROW_DOWN, .key_char = "", .is_ctrl = false },
        'C' => .{ .key_kind = KEY_ARROW_RIGHT, .key_char = "", .is_ctrl = false },
        'D' => .{ .key_kind = KEY_ARROW_LEFT, .key_char = "", .is_ctrl = false },
        'H' => .{ .key_kind = KEY_HOME, .key_char = "", .is_ctrl = false },
        'F' => .{ .key_kind = KEY_END, .key_char = "", .is_ctrl = false },
        else => blk: {
            // Tilde sequences: \x1b[N~ where N is a digit
            if (seq.len >= 2 and seq[seq.len - 1] == '~') {
                const code = seq[0] - '0';
                break :blk switch (code) {
                    3 => Key{ .key_kind = KEY_DELETE, .key_char = "", .is_ctrl = false },
                    5 => Key{ .key_kind = KEY_PAGE_UP, .key_char = "", .is_ctrl = false },
                    6 => Key{ .key_kind = KEY_PAGE_DOWN, .key_char = "", .is_ctrl = false },
                    else => blk2: {
                        // F5-F12: \x1b[15~ through \x1b[24~
                        if (seq.len >= 3 and seq[seq.len - 1] == '~') {
                            const tens = seq[0] - '0';
                            const ones = seq[1] - '0';
                            const num = tens * 10 + ones;
                            break :blk2 switch (num) {
                                15 => Key{ .key_kind = KEY_F5, .key_char = "", .is_ctrl = false },
                                17 => Key{ .key_kind = KEY_F6, .key_char = "", .is_ctrl = false },
                                18 => Key{ .key_kind = KEY_F7, .key_char = "", .is_ctrl = false },
                                19 => Key{ .key_kind = KEY_F8, .key_char = "", .is_ctrl = false },
                                20 => Key{ .key_kind = KEY_F9, .key_char = "", .is_ctrl = false },
                                21 => Key{ .key_kind = KEY_F10, .key_char = "", .is_ctrl = false },
                                23 => Key{ .key_kind = KEY_F11, .key_char = "", .is_ctrl = false },
                                24 => Key{ .key_kind = KEY_F12, .key_char = "", .is_ctrl = false },
                                else => Key{ .key_kind = KEY_ESCAPE, .key_char = "", .is_ctrl = false },
                            };
                        }
                        break :blk2 Key{ .key_kind = KEY_ESCAPE, .key_char = "", .is_ctrl = false };
                    },
                };
            }
            break :blk Key{ .key_kind = KEY_ESCAPE, .key_char = "", .is_ctrl = false };
        },
    };
}

fn parseSS3(ch: u8) Key {
    return switch (ch) {
        'P' => .{ .key_kind = KEY_F1, .key_char = "", .is_ctrl = false },
        'Q' => .{ .key_kind = KEY_F2, .key_char = "", .is_ctrl = false },
        'R' => .{ .key_kind = KEY_F3, .key_char = "", .is_ctrl = false },
        'S' => .{ .key_kind = KEY_F4, .key_char = "", .is_ctrl = false },
        else => .{ .key_kind = KEY_ESCAPE, .key_char = "", .is_ctrl = false },
    };
}

// ── Screen Buffer ──

const Cell = struct {
    ch: u8 = ' ',
    fg: i32 = NO_COLOR,
    bg: i32 = NO_COLOR,
    bold: bool = false,
};

pub const Screen = struct {
    row_count: i32,
    col_count: i32,
    front: []Cell,
    back: []Cell,

    pub fn create(row_count: i32, col_count: i32) Screen {
        const total: usize = @intCast(@max(1, row_count) * @max(1, col_count));
        const front = alloc.alloc(Cell, total) catch &.{};
        const back = alloc.alloc(Cell, total) catch &.{};
        @memset(front, Cell{});
        @memset(back, Cell{});
        return .{ .row_count = row_count, .col_count = col_count, .front = front, .back = back };
    }

    pub fn set(self: *Screen, row: i32, col: i32, ch: []const u8) void {
        const idx = cellIndex(self, row, col) orelse return;
        self.back[idx].ch = if (ch.len > 0) ch[0] else ' ';
        self.back[idx].fg = NO_COLOR;
        self.back[idx].bg = NO_COLOR;
        self.back[idx].bold = false;
    }

    pub fn setStyled(self: *Screen, row: i32, col: i32, ch: []const u8, fg: i32, bg: i32, bold: bool) void {
        const idx = cellIndex(self, row, col) orelse return;
        self.back[idx].ch = if (ch.len > 0) ch[0] else ' ';
        self.back[idx].fg = fg;
        self.back[idx].bg = bg;
        self.back[idx].bold = bold;
    }

    pub fn render(self: *Screen) void {
        var out_buf_local: [4096]u8 = undefined;
        var w = stdout.writer(&out_buf_local);

        const total: usize = @intCast(@max(1, self.row_count) * @max(1, self.col_count));
        for (0..total) |i| {
            if (!cellEq(self.front[i], self.back[i])) {
                const r: i32 = @intCast(i / @as(usize, @intCast(self.col_count)));
                const c: i32 = @intCast(i % @as(usize, @intCast(self.col_count)));
                // Move cursor (1-based)
                var pos_buf: [32]u8 = undefined;
                const pos = std.fmt.bufPrint(&pos_buf, "\x1b[{d};{d}H", .{ r + 1, c + 1 }) catch continue;
                w.interface.writeAll(pos) catch {}; // fire-and-forget: terminal I/O in void fn

                const cell = self.back[i];
                if (cell.fg != NO_COLOR or cell.bg != NO_COLOR or cell.bold) {
                    var style_buf: [32]u8 = undefined;
                    var style_len: usize = 0;
                    style_buf[style_len] = 0x1b;
                    style_len += 1;
                    style_buf[style_len] = '[';
                    style_len += 1;
                    var need_sep = false;
                    if (cell.bold) {
                        style_buf[style_len] = '1';
                        style_len += 1;
                        need_sep = true;
                    }
                    if (cell.fg >= 0 and cell.fg <= 7) {
                        if (need_sep) {
                            style_buf[style_len] = ';';
                            style_len += 1;
                        }
                        var num: [4]u8 = undefined;
                        const s = std.fmt.bufPrint(&num, "{d}", .{30 + cell.fg}) catch continue;
                        @memcpy(style_buf[style_len .. style_len + s.len], s);
                        style_len += s.len;
                        need_sep = true;
                    }
                    if (cell.bg >= 0 and cell.bg <= 7) {
                        if (need_sep) {
                            style_buf[style_len] = ';';
                            style_len += 1;
                        }
                        var num: [4]u8 = undefined;
                        const s = std.fmt.bufPrint(&num, "{d}", .{40 + cell.bg}) catch continue;
                        @memcpy(style_buf[style_len .. style_len + s.len], s);
                        style_len += s.len;
                    }
                    style_buf[style_len] = 'm';
                    style_len += 1;
                    w.interface.writeAll(style_buf[0..style_len]) catch {}; // fire-and-forget: terminal I/O in void fn
                    w.interface.writeAll(&.{cell.ch}) catch {};
                    w.interface.writeAll("\x1b[0m") catch {};
                } else {
                    w.interface.writeAll(&.{cell.ch}) catch {};
                }

                self.front[i] = self.back[i];
            }
        }
        w.interface.flush() catch {}; // fire-and-forget: terminal I/O in void fn
    }

    pub fn clear(self: *Screen) void {
        @memset(self.back, Cell{});
    }

    pub fn resize(self: *Screen, row_count: i32, col_count: i32) void {
        const total: usize = @intCast(@max(1, row_count) * @max(1, col_count));
        alloc.free(self.front);
        alloc.free(self.back);
        self.front = alloc.alloc(Cell, total) catch &.{};
        self.back = alloc.alloc(Cell, total) catch &.{};
        @memset(self.front, Cell{});
        @memset(self.back, Cell{});
        self.row_count = row_count;
        self.col_count = col_count;
    }

    pub fn destroy(self: *Screen) void {
        alloc.free(self.front);
        alloc.free(self.back);
    }

    fn cellIndex(self: *Screen, row: i32, col: i32) ?usize {
        if (row < 1 or col < 1 or row > self.row_count or col > self.col_count) return null;
        return @intCast((@as(usize, @intCast(row - 1))) * @as(usize, @intCast(self.col_count)) + @as(usize, @intCast(col - 1)));
    }
};

fn cellEq(a: Cell, b: Cell) bool {
    return a.ch == b.ch and a.fg == b.fg and a.bg == b.bg and a.bold == b.bold;
}

// ── Drawing Helpers ──

pub fn drawBox(row: i32, col: i32, width: i32, height: i32) void {
    if (width < 2 or height < 2) return;

    // Top border
    moveTo(row, col);
    writeEsc("\xe2\x94\x8c"); // ┌
    var i: i32 = 0;
    while (i < width - 2) : (i += 1) {
        writeEsc("\xe2\x94\x80"); // ─
    }
    writeEsc("\xe2\x94\x90"); // ┐

    // Sides
    var r: i32 = 1;
    while (r < height - 1) : (r += 1) {
        moveTo(row + r, col);
        writeEsc("\xe2\x94\x82"); // │
        moveTo(row + r, col + width - 1);
        writeEsc("\xe2\x94\x82"); // │
    }

    // Bottom border
    moveTo(row + height - 1, col);
    writeEsc("\xe2\x94\x94"); // └
    i = 0;
    while (i < width - 2) : (i += 1) {
        writeEsc("\xe2\x94\x80"); // ─
    }
    writeEsc("\xe2\x94\x98"); // ┘

    flushOutput();
}

pub fn drawHLine(row: i32, col: i32, length: i32) void {
    moveTo(row, col);
    var i: i32 = 0;
    while (i < length) : (i += 1) {
        writeEsc("\xe2\x94\x80"); // ─
    }
    flushOutput();
}

pub fn drawVLine(row: i32, col: i32, length: i32) void {
    var i: i32 = 0;
    while (i < length) : (i += 1) {
        moveTo(row + i, col);
        writeEsc("\xe2\x94\x82"); // │
    }
    flushOutput();
}

pub fn drawText(row: i32, col: i32, text: []const u8) void {
    moveTo(row, col);
    writeEsc(text);
    flushOutput();
}

// ── Internal Helpers ──

var out_buf: [4096]u8 = undefined;

fn writeEsc(seq: []const u8) void {
    var w = stdout.writer(&out_buf);
    w.interface.writeAll(seq) catch {}; // fire-and-forget: terminal I/O in void fn
}

fn flushOutput() void {
    var w = stdout.writer(&out_buf);
    w.interface.flush() catch {}; // fire-and-forget: terminal I/O in void fn
}

// ── Tests ──

test "style with fg only" {
    const result = style(FG_RED, NO_COLOR, false, "hello");
    try std.testing.expect(std.mem.startsWith(u8, result, "\x1b["));
    try std.testing.expect(std.mem.indexOf(u8, result, "31") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "\x1b[0m"));
}

test "style with fg + bg + bold" {
    const result = style(FG_GREEN, BG_BLACK, true, "test");
    try std.testing.expect(std.mem.startsWith(u8, result, "\x1b[1;32;40m"));
    try std.testing.expect(std.mem.endsWith(u8, result, "\x1b[0m"));
}

test "style NO_COLOR returns plain" {
    const result = style(NO_COLOR, NO_COLOR, false, "plain");
    try std.testing.expect(std.mem.indexOf(u8, result, "plain") != null);
}

test "key constants are unique" {
    try std.testing.expect(KEY_CHAR != KEY_ENTER);
    try std.testing.expect(KEY_ENTER != KEY_ESCAPE);
    try std.testing.expect(KEY_ARROW_UP != KEY_ARROW_DOWN);
    try std.testing.expect(KEY_F1 != KEY_F12);
}

test "parseCSI arrow keys" {
    const up = parseCSI("A");
    try std.testing.expectEqual(KEY_ARROW_UP, up.key_kind);
    const down = parseCSI("B");
    try std.testing.expectEqual(KEY_ARROW_DOWN, down.key_kind);
    const right = parseCSI("C");
    try std.testing.expectEqual(KEY_ARROW_RIGHT, right.key_kind);
    const left = parseCSI("D");
    try std.testing.expectEqual(KEY_ARROW_LEFT, left.key_kind);
}

test "parseCSI tilde keys" {
    const del = parseCSI("3~");
    try std.testing.expectEqual(KEY_DELETE, del.key_kind);
    const pgup = parseCSI("5~");
    try std.testing.expectEqual(KEY_PAGE_UP, pgup.key_kind);
    const pgdn = parseCSI("6~");
    try std.testing.expectEqual(KEY_PAGE_DOWN, pgdn.key_kind);
}

test "parseCSI F-keys" {
    const f5 = parseCSI("15~");
    try std.testing.expectEqual(KEY_F5, f5.key_kind);
    const f12 = parseCSI("24~");
    try std.testing.expectEqual(KEY_F12, f12.key_kind);
}

test "parseSS3 F1-F4" {
    try std.testing.expectEqual(KEY_F1, parseSS3('P').key_kind);
    try std.testing.expectEqual(KEY_F2, parseSS3('Q').key_kind);
    try std.testing.expectEqual(KEY_F3, parseSS3('R').key_kind);
    try std.testing.expectEqual(KEY_F4, parseSS3('S').key_kind);
}

test "screen buffer create and set" {
    var screen = Screen.create(3, 5);
    defer screen.destroy();
    screen.set(1, 1, "A");
    try std.testing.expectEqual(@as(u8, 'A'), screen.back[0].ch);
    screen.set(2, 3, "X");
    try std.testing.expectEqual(@as(u8, 'X'), screen.back[7].ch);
}

test "screen buffer out of bounds" {
    var screen = Screen.create(2, 2);
    defer screen.destroy();
    screen.set(0, 0, "X"); // should be no-op (1-based)
    screen.set(3, 1, "X"); // should be no-op (out of range)
    try std.testing.expectEqual(@as(u8, ' '), screen.back[0].ch);
}

test "screen buffer clear" {
    var screen = Screen.create(2, 2);
    defer screen.destroy();
    screen.set(1, 1, "Z");
    screen.clear();
    try std.testing.expectEqual(@as(u8, ' '), screen.back[0].ch);
}
