const helper = @import("helper.zig");

pub export fn helper_add(a: i32, b: i32) i32 {
    return helper.add(a, b);
}
