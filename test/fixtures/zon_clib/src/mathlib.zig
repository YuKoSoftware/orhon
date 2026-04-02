const c = @cImport(@cInclude("native_add.h"));

pub fn add(a: i32, b: i32) i32 {
    return c.native_add(a, b);
}
