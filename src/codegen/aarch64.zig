pub const abi = @import("aarch64/abi.zig");
pub const Assemble = @import("aarch64/Assemble.zig");
pub const Disassemble = @import("aarch64/Disassemble.zig");
pub const encoding = @import("aarch64/encoding.zig");
pub const Mir = @import("aarch64/Mir.zig");
pub const Select = @import("aarch64/Select.zig");

pub fn legalizeFeatures(_: *const std.Target) *const Air.Legalize.Features {
    return comptime &.initMany(&.{
        .scalarize_add,
        .scalarize_add_safe,
        .scalarize_add_optimized,
        .scalarize_add_wrap,
        .scalarize_sub,
        .scalarize_sub_safe,
        .scalarize_sub_optimized,
        .scalarize_sub_wrap,
        .scalarize_not,
        .scalarize_add_sat,
        .scalarize_sub_sat,
        .scalarize_mul,
        .scalarize_mul_safe,
        .scalarize_mul_optimized,
        .scalarize_mul_wrap,
        .scalarize_mul_sat,
        .scalarize_div_float,
        .scalarize_div_float_optimized,
        .scalarize_div_trunc,
        .scalarize_div_trunc_optimized,
        .scalarize_div_floor,
        .scalarize_div_floor_optimized,
        .scalarize_div_ceil,
        .scalarize_div_ceil_optimized,
        .scalarize_div_exact,
        .scalarize_div_exact_optimized,
        .scalarize_rem,
        .scalarize_rem_optimized,
        .scalarize_mod,
        .scalarize_mod_optimized,
        .scalarize_max,
        .scalarize_min,
        .scalarize_add_with_overflow,
        .scalarize_sub_with_overflow,
        .scalarize_mul_with_overflow,
        .scalarize_shl_with_overflow,
        .scalarize_shr,
        .scalarize_shr_exact,
        .scalarize_shl,
        .scalarize_shl_exact,
        .scalarize_shl_sat,
        .scalarize_clz,
        .scalarize_ctz,
        .scalarize_popcount,
        .scalarize_byte_swap,
        .scalarize_bit_reverse,
        .scalarize_sqrt,
        .scalarize_sin,
        .scalarize_cos,
        .scalarize_tan,
        .scalarize_exp,
        .scalarize_exp2,
        .scalarize_log,
        .scalarize_log2,
        .scalarize_log10,
        .scalarize_abs,
        .scalarize_floor,
        .scalarize_ceil,
        .scalarize_round,
        .scalarize_trunc_float,
        .scalarize_neg,
        .scalarize_neg_optimized,
        .scalarize_fptrunc,
        .scalarize_fpext,
        .scalarize_int_cast_safe,
        .scalarize_trunc,
        .scalarize_int_from_float,
        .scalarize_int_from_float_optimized,
        .scalarize_float_from_int,
        .scalarize_cmp_vector,
        .scalarize_cmp_vector_optimized,
        .scalarize_reduce,
        .scalarize_reduce_optimized,
        .scalarize_shuffle_one,
        .scalarize_shuffle_two,
        .scalarize_select,
        .scalarize_mul_add,
        .scalarize_bit_cast_padded_elems,
        .reduce_one_elem_to_bit_cast,
        .expand_bit_cast_safe,
        .expand_int_from_float_safe,
        .expand_int_from_float_optimized_safe,
        .expand_array_splat,
        .expand_array_to_vector,
        .soft_big_int,
    });
}

pub fn generate(
    _: *link.File,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    air: *const Air,
    liveness: *const ?Air.Liveness,
) !Mir {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);
    const func_zir = func.zir_body_inst.resolveFull(ip).?;
    const file = zcu.fileByIndex(func_zir.file);
    const named_params_len = file.zir.?.getParamBody(func_zir.inst).len;
    const func_type = ip.indexToKey(func.ty).func_type;
    assert(liveness.* == null);

    const mod = zcu.navFileScope(func.owner_nav).mod.?;
    var isel: Select = .{
        .pt = pt,
        .target = &mod.resolved_target.result,
        .optimize_mode = mod.optimize_mode,
        .air = air.*,
        .nav_index = zcu.funcInfo(func_index).owner_nav,
        .debug_func = func_index,

        .def_order = .empty,
        .blocks = .empty,
        .loops = .empty,
        .active_loops = .empty,
        .loop_live = .{
            .set = .empty,
            .list = .empty,
        },
        .dom_start = 0,
        .dom_len = 0,
        .dom = .empty,

        .saved_registers = .empty,
        .instructions = .empty,
        .debug_events = .empty,
        .literals = .empty,
        .nav_relocs = .empty,
        .uav_relocs = .empty,
        .lazy_relocs = .empty,
        .global_relocs = .empty,
        .literal_relocs = .empty,

        .returns = false,
        .va_list = undefined,
        .stack_size = 0,
        .stack_align = .@"16",

        .live_registers = comptime .initFill(.free),
        .live_values = .empty,
        .values = .empty,
    };
    defer isel.deinit();
    const is_sysv = !isel.target.os.tag.isDarwin() and isel.target.os.tag != .windows;
    const is_sysv_var_args = is_sysv and func_type.is_var_args;

    try isel.checkSoftF128CallConv(func_type);
    try isel.checkVectorCallConv(func_type);
    const air_main_body = air.getMainBody();
    var param_it: Select.CallAbiIterator = .init;
    const air_args = for (air_main_body, 0..) |air_inst_index, body_index| {
        if (air.instructions.items(.tag)[@backingInt(air_inst_index)] != .arg) break air_main_body[0..body_index];
        const arg = air.instructions.items(.data)[@backingInt(air_inst_index)].arg;
        const param_ty = arg.ty;
        const param_vi = param_vi: {
            if (arg.zir_param_index >= named_params_len) {
                assert(func_type.is_var_args);
                if (!is_sysv) break :param_vi try param_it.nonSysvVarArg(&isel, param_ty);
            }
            break :param_vi try param_it.param(&isel, param_ty);
        };
        tracking_log.debug("${d} <- %{d}", .{ @backingInt(param_vi.?), @backingInt(air_inst_index) });
        try isel.live_values.putNoClobber(gpa, air_inst_index, param_vi.?);
    } else unreachable;

    // Register arguments are not homed to the save area: no debug info refers
    // to it, and a use would reload from it instead of using the register.
    const saved_gra_start = param_it.ngrn;
    const saved_gra_end = if (is_sysv_var_args) Select.CallAbiIterator.ngrn_end else param_it.ngrn;
    const saved_gra_len = @backingInt(saved_gra_end) - @backingInt(saved_gra_start);

    const saved_vra_start = param_it.nsrn;
    const saved_vra_end = if (is_sysv_var_args) Select.CallAbiIterator.nsrn_end else param_it.nsrn;
    const saved_vra_len = @backingInt(saved_vra_end) - @backingInt(saved_vra_start);

    const frame_record = 2;
    const named_stack_args: Select.Value.Indirect = .{
        .base = .fp,
        .offset = 8 * std.mem.alignForward(u7, frame_record + saved_gra_len, 2),
    };
    isel.incoming_stack_args = named_stack_args;
    isel.incoming_stack_size = param_it.stackSize();
    const stack_var_args = named_stack_args.withOffset(param_it.stackSize());
    const gr_top = named_stack_args;
    const vr_top: Select.Value.Indirect = .{ .base = .fp, .offset = 0 };
    isel.va_list = if (is_sysv) .{ .sysv = .{
        .__stack = stack_var_args,
        .__gr_top = gr_top,
        .__vr_top = vr_top,
        .__gr_offs = @as(i32, @backingInt(Select.CallAbiIterator.ngrn_end) - @backingInt(param_it.ngrn)) * -8,
        .__vr_offs = @as(i32, @backingInt(Select.CallAbiIterator.nsrn_end) - @backingInt(param_it.nsrn)) * -16,
    } } else .{ .other = stack_var_args };

    // translate arg locations from caller-based to callee-based
    for (air_args) |air_inst_index| {
        assert(air.instructions.items(.tag)[@backingInt(air_inst_index)] == .arg);
        const arg_vi = isel.live_values.get(air_inst_index).?;
        const passed_vi = switch (arg_vi.parent(&isel)) {
            .unallocated, .stack_slot => arg_vi,
            .value, .constant, .stack_address => unreachable,
            .address => |address_vi| address_vi,
        };
        switch (passed_vi.parent(&isel)) {
            .unallocated => {},
            .stack_slot => |stack_slot| {
                assert(stack_slot.base == .sp);
                passed_vi.changeStackSlot(&isel, named_stack_args.withOffset(stack_slot.offset));
            },
            .address, .value, .constant, .stack_address => unreachable,
        }
    }

    ret: {
        var ret_it: Select.CallAbiIterator = .init;
        const ret_vi = try ret_it.ret(&isel, .fromInterned(func_type.return_type)) orelse break :ret;
        tracking_log.debug("${d} <- %main", .{@backingInt(ret_vi)});
        try isel.live_values.putNoClobber(gpa, Select.Block.main, ret_vi);
    }

    assert(!(try isel.blocks.getOrPut(gpa, Select.Block.main)).found_existing);
    try isel.analyze(air_main_body);
    try isel.finishAnalysis();
    isel.verify(false);

    isel.blocks.values()[0] = .{
        .live_registers = isel.live_registers,
        .target_label = @intCast(isel.instructions.items.len),
    };
    try isel.body(air_main_body, null);
    if (isel.live_values.fetchRemove(Select.Block.main)) |ret_vi| {
        switch (ret_vi.value.parent(&isel)) {
            .unallocated, .stack_slot => {},
            .value, .constant, .stack_address => unreachable,
            .address => |address_vi| try address_vi.defLiveIn(
                &isel,
                address_vi.hint(&isel).?,
                comptime &.initFill(.free),
            ),
        }
        ret_vi.value.deref(&isel);
    }
    isel.verify(true);

    const prologue = isel.instructions.items.len;
    const epilogue = try isel.layout(param_it, is_sysv_var_args, saved_gra_len, saved_vra_len, mod, func_type.cc.eql(.naked));

    for (isel.debug_events.items) |*event| {
        event.offset = @intCast(4 * switch (event.section) {
            .body => epilogue - event.offset,
            .prologue => event.offset - prologue,
            .epilogue => epilogue + isel.instructions.items.len - event.offset,
        });
    }
    std.mem.sortUnstable(Mir.Debug, isel.debug_events.items, {}, Mir.Debug.lessThan);
    try isel.debug_events.shrinkToLen(gpa);

    try isel.instructions.shrinkToLen(gpa);
    try isel.literals.shrinkToLen(gpa);
    try isel.nav_relocs.shrinkToLen(gpa);
    try isel.uav_relocs.shrinkToLen(gpa);
    try isel.lazy_relocs.shrinkToLen(gpa);
    try isel.global_relocs.shrinkToLen(gpa);
    try isel.literal_relocs.shrinkToLen(gpa);

    const instructions = isel.instructions.toOwnedSliceAssert();

    return .{
        .prologue = instructions[prologue..epilogue],
        .body = instructions[0..prologue],
        .epilogue = instructions[epilogue..],
        .literals = isel.literals.toOwnedSliceAssert(),
        .debug_events = isel.debug_events.toOwnedSliceAssert(),
        .nav_relocs = isel.nav_relocs.toOwnedSliceAssert(),
        .uav_relocs = isel.uav_relocs.toOwnedSliceAssert(),
        .lazy_relocs = isel.lazy_relocs.toOwnedSliceAssert(),
        .global_relocs = isel.global_relocs.toOwnedSliceAssert(),
        .literal_relocs = isel.literal_relocs.toOwnedSliceAssert(),
    };
}

test {
    _ = Assemble;
    _ = Disassemble;
}

const Air = @import("../Air.zig");
const assert = std.debug.assert;
const InternPool = @import("../InternPool.zig");
const link = @import("../link.zig");
const std = @import("std");
const tracking_log = std.log.scoped(.tracking);
const Zcu = @import("../Zcu.zig");
