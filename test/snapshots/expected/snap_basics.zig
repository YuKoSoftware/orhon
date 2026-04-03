// generated from module snap_basics — do not edit
const std = @import("std");

const _orhon_async = @import("_orhon_async");
const MAX_COUNT: i32 = 100;

const APP_NAME: []const u8 = "orhon";

const RETRY_COUNT: i32 = 3;

const Speed = i32;

pub fn add(a: i32, b: i32) i32 {
    return (a + b);
}

pub fn greet(name: []const u8) []const u8 {
    return (("hello" ++ " ") ++ name);
}

pub inline fn doubled(n: i32) i32 {
    return (n * 2);
}

