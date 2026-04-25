// src/error_codes.zig
const std = @import("std");

pub const ErrorCode = enum(u16) {

    // ── E0xxx  Parse / syntax ────────────────────────────────────────────────
    parse_failure          = 101,

    // ── E1xxx  Module / import ───────────────────────────────────────────────
    no_anchor_file         = 1001,
    multiple_anchors       = 1002,
    missing_module_decl    = 1003,
    module_name_reserved   = 1004,
    module_not_found       = 1005,
    circular_import        = 1006,
    c_import_not_supported = 1007,
    unknown_import_scope   = 1008,
    std_module_not_found   = 1009,
    metadata_in_non_anchor = 1010,
    unknown_build_type     = 1011,
    multiple_exe_modules   = 1012,
    module_file_dir_mismatch = 1013,

    // ── E2xxx  Type / resolver ───────────────────────────────────────────────
    // Declarations (2001–2019)
    module_level_var           = 2001,
    default_before_required    = 2002,
    duplicate_function         = 2003,
    duplicate_struct           = 2004,
    var_in_struct              = 2005,
    field_name_conflicts_type  = 2006,
    duplicate_field            = 2007,
    duplicate_blueprint        = 2008,
    duplicate_union_type       = 2009,
    duplicate_enum_variant     = 2010,
    duplicate_enum             = 2011,
    duplicate_handle           = 2012,
    duplicate_variable         = 2013,

    // Resolver — statements (2020–2038)
    already_declared           = 2020,
    shadowing_not_allowed      = 2021,
    reference_type_in_var      = 2022,
    numeric_literal_needs_type = 2023,
    any_not_valid_field_type   = 2024,
    any_return_without_param   = 2025,
    compound_is_not_supported  = 2026,
    condition_not_bool         = 2027,
    return_type_mismatch       = 2028,
    mixed_numeric_assignment   = 2029,
    match_duplicate_else       = 2030,
    match_else_not_last        = 2031,
    match_guards_need_else     = 2032,
    for_capture_count_mismatch = 2033,
    for_tuple_not_struct       = 2034,
    for_iterable_mismatch      = 2035,
    break_outside_loop         = 2036,
    continue_outside_loop      = 2037,
    unreachable_code           = 2038,

    // Resolver — expressions (2040–2061)
    unknown_identifier         = 2040,
    str_equality               = 2041,
    str_arithmetic             = 2042,
    concat_on_numeric          = 2043,
    mixed_numeric_types        = 2044,
    negate_unsigned            = 2045,
    struct_constructor_syntax  = 2046,
    named_args_not_struct      = 2047,
    not_callable               = 2048,
    arg_count_mismatch         = 2049,
    compt_type_arg_required    = 2050,
    compt_runtime_arg          = 2051,
    tuple_literal_context      = 2052,
    instance_method_on_type    = 2053,
    static_method_on_value     = 2054,
    cannot_index               = 2055,
    unknown_compiler_func      = 2056,
    compiler_func_needs_type   = 2057,
    compiler_func_arg_count    = 2058,
    compiler_func_needs_string = 2059,
    wrap_op_not_supported      = 2060,
    array_elem_type_mismatch   = 2061,

    // Resolver — validation (2070–2086)
    match_non_exhaustive       = 2070,
    match_non_enum_needs_else  = 2071,
    match_arm_not_member       = 2072,
    this_outside_struct        = 2073,
    unknown_type               = 2074,
    unknown_generic_type       = 2075,
    anonymous_tuple_not_allowed = 2076,
    type_mismatch              = 2077,
    bytes_str_implicit         = 2078,
    str_bytes_implicit         = 2079,
    duplicate_blueprint_impl   = 2080,
    unknown_blueprint          = 2081,
    blueprint_not_implemented  = 2082,
    blueprint_param_count      = 2083,
    blueprint_param_type       = 2084,
    blueprint_return_type      = 2085,
    self_deprecated            = 2086,

    // ── E3xxx  Ownership / borrow ─────────────────────────────────────────────
    use_of_moved_value   = 3001,
    cannot_move_field    = 3002,
    cannot_return_ref    = 3003,
    use_while_borrowed   = 3004,
    borrow_conflict      = 3005,

    // ── E4xxx  Propagation / union ────────────────────────────────────────────
    discarded_union_return = 4001,
    unsafe_unwrap          = 4002,
    unhandled_union        = 4003,

    // ── E5xxx  Build / pipeline ───────────────────────────────────────────────
    main_in_non_exe    = 5001,
    main_name_reserved = 5002,
    missing_main_func  = 5003,
    unused_import      = 5004,
    zig_compile_error  = 5005,

    // ── E9xxx  Internal compiler errors ───────────────────────────────────────
    internal_grammar_load = 9001,
    internal_ast_build    = 9002,
    internal_ast_conv     = 9003,
    internal_ast_conv_p4  = 9004,
    internal_zig_codegen  = 9005,

    pub fn value(self: ErrorCode) u16 {
        return @intFromEnum(self);
    }

    pub fn toCode(self: ErrorCode, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "E{d:0>4}", .{self.value()}) catch buf[0..0];
    }
};

test "ErrorCode numeric values are stable" {
    try std.testing.expectEqual(@as(u16, 101), ErrorCode.parse_failure.value());
    try std.testing.expectEqual(@as(u16, 2040), ErrorCode.unknown_identifier.value());
    try std.testing.expectEqual(@as(u16, 9001), ErrorCode.internal_grammar_load.value());
}

test "ErrorCode format produces E-prefixed zero-padded string" {
    var buf: [8]u8 = undefined;
    const s = ErrorCode.unknown_identifier.toCode(&buf);
    try std.testing.expectEqualStrings("E2040", s);
    const s2 = ErrorCode.parse_failure.toCode(&buf);
    try std.testing.expectEqualStrings("E0101", s2);
}

test "ErrorCode toCode returns empty slice on buffer too small" {
    var tiny: [2]u8 = undefined;
    const empty = ErrorCode.unknown_identifier.toCode(&tiny);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
