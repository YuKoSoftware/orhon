// sort.zig — extern func sidecar for std::sort module

const std = @import("std");

pub fn sort(arr: anytype) void {
    std.mem.sort(@TypeOf(arr[0]), arr, {}, std.sort.asc(@TypeOf(arr[0])));
}

pub fn sortDesc(arr: anytype) void {
    std.mem.sort(@TypeOf(arr[0]), arr, {}, std.sort.desc(@TypeOf(arr[0])));
}

pub fn isSorted(arr: anytype) bool {
    if (arr.len < 2) return true;
    for (0..arr.len - 1) |i| {
        if (arr[i] > arr[i + 1]) return false;
    }
    return true;
}

pub fn reverse(arr: anytype) void {
    std.mem.reverse(@TypeOf(arr[0]), arr);
}

pub fn min(arr: anytype) @TypeOf(arr[0]) {
    if (arr.len == 0) @panic("min of empty slice");
    var result = arr[0];
    for (arr[1..]) |v| {
        if (v < result) result = v;
    }
    return result;
}

pub fn max(arr: anytype) @TypeOf(arr[0]) {
    if (arr.len == 0) @panic("max of empty slice");
    var result = arr[0];
    for (arr[1..]) |v| {
        if (v > result) result = v;
    }
    return result;
}
