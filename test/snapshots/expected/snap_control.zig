// generated from module snap_control — do not edit
const std = @import("std");
const str = @import("_orhon_str");

fn _OrhonHandle(comptime T: type) type { return struct { thread: std.Thread, state: *SharedState, pub const SharedState = struct { result: T = undefined, completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false) }; const Self = @This(); pub fn getValue(self_h: *Self) T { self_h.thread.join(); const result = self_h.state.result; std.heap.page_allocator.destroy(self_h.state); return result; } pub fn wait(self_h: *Self) void { self_h.thread.join(); } pub fn done(self_h: *const Self) bool { return self_h.state.completed.load(.acquire); } pub fn join(self_h: *Self) void { self_h.thread.join(); std.heap.page_allocator.destroy(self_h.state); } }; }

pub fn classify(n: i32) i32 {
    if ((n < 0)) {
        return (0 - 1);
    } else if ((n == 0)) {
        return 0;
    } else {
        return 1;
    }
}

pub fn day_name(d: i32) i32 {
    switch (d) {
        1 => {
            return 10;
        },
        2 => {
            return 20;
        },
        3 => {
            return 30;
        },
        else => {},
    }
    return 0;
}

pub fn sum_slice(arr: []i32) i32 {
    var total: i32 = 0; _ = &total;
    for (arr) |val| {
        total += val;
    }
    return total;
}

pub fn first_positive(limit: i32) i32 {
    var i: i32 = 0; _ = &i;
    while ((i < limit)) {
        i += 1;
        if ((i > 0)) {
            break;
        }
    }
    return i;
}

pub fn with_defer() i32 {
    var x: i32 = 0; _ = &x;
    defer {
        x = 0;
    }
    x = 42;
    return x;
}

