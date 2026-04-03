// generated from module snap_errors — do not edit
const std = @import("std");

const ErrNotFound: anyerror = error.not_found;

const ErrInvalid: anyerror = error.invalid;

pub fn safe_get(id: i32) anyerror!i32 {
    if ((id < 0)) {
        return ErrInvalid;
    }
    return (id * 10);
}

pub fn maybe_value(flag: bool) ?i32 {
    if (flag) {
        return 42;
    }
    return null;
}

pub fn get_or_throw(id: i32) anyerror!i32 {
    const result: anyerror!i32 = safe_get(id); _ = &result;
    if ((if (result) |_| false else |_| true)) {
        if (result) |_| {} else |_err| return _err;
    }
    return result catch unreachable;
}

pub fn check_null(val: ?i32) i32 {
    if ((val == null)) {
        return 0;
    }
    return val.?;
}

