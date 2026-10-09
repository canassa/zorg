pt: Zcu.PerThread,
target: *const std.Target,
optimize_mode: std.lang.Optimize,
air: Air,
nav_index: InternPool.Nav.Index,
/// The function whose code is being selected, for debug info: the inlined
/// callee within a `dbg_inline_block`, which sets it around its body.
debug_func: InternPool.Index,

// Blocks
def_order: std.array_hash_map.Auto(Air.Inst.Index, void),
blocks: std.array_hash_map.Auto(Air.Inst.Index, Block),
loops: std.array_hash_map.Auto(Air.Inst.Index, Loop),
active_loops: std.ArrayList(Loop.Index),
loop_live: struct {
    set: std.array_hash_map.Auto(struct { Loop.Index, Air.Inst.Index }, void),
    list: std.ArrayList(Air.Inst.Index),
},
dom_start: u32,
dom_len: u32,
dom: std.ArrayList(DomInt),
promotion: Promotion = .{},

// Wip Mir
saved_registers: std.enums.EnumSet(Register.Alias),
instructions: std.ArrayList(codegen.aarch64.encoding.Instruction),
debug_events: std.ArrayList(codegen.aarch64.Mir.Debug),
/// The section that debug events belong to: the body during selection, then
/// the prologue and the epilogue as `layout` emits them.
debug_section: @FieldType(codegen.aarch64.Mir.Debug, "section") = .body,
literals: std.ArrayList(u32),
nav_relocs: std.ArrayList(codegen.aarch64.Mir.Reloc.Nav),
uav_relocs: std.ArrayList(codegen.aarch64.Mir.Reloc.Uav),
lazy_relocs: std.ArrayList(codegen.aarch64.Mir.Reloc.Lazy),
global_relocs: std.ArrayList(codegen.aarch64.Mir.Reloc.Global),
literal_relocs: std.ArrayList(codegen.aarch64.Mir.Reloc.Literal),

// Stack Frame
returns: bool,
tail_branches: std.ArrayList(u32) = .empty,
/// The label of the newest unconditional branch that is a placeholder: a
/// loop repeat until the loop is finished (`Loop.branch`), or a tail call's
/// branch to the epilogue until `layout`.
branch_placeholder: ?u32 = null,
/// Where the stack arguments passed to this function start, once known.
incoming_stack_args: ?Value.Indirect = null,
incoming_stack_size: u24 = 0,
va_list: union(enum) {
    other: Value.Indirect,
    sysv: struct {
        __stack: Value.Indirect,
        __gr_top: Value.Indirect,
        __vr_top: Value.Indirect,
        __gr_offs: i32,
        __vr_offs: i32,
    },
},
stack_size: u24,
stack_align: InternPool.Alignment,

// Value Tracking
live_registers: LiveRegisters,
live_values: std.AutoHashMapUnmanaged(Air.Inst.Index, Value.Index),
values: std.ArrayList(Value),

pub const LiveRegisters = std.enums.EnumArray(Register.Alias, Value.Index);

pub const Error = codegen.Error || error{
    /// Registers reserved for promoted locals and pinned values got in the
    /// way of selecting the function; nothing was reported. `generate` selects
    /// it again without promotion.
    RetryWithoutPromotion,
};

pub const Promotion = @import("Promotion.zig");

pub const Block = struct {
    live_registers: LiveRegisters,
    target_label: u32,

    pub const main: Air.Inst.Index = @fromBackingInt(@intCast(
        std.math.maxInt(@typeInfo(Air.Inst.Index).@"enum".tag_type),
    ));

    fn branch(target_block: *const Block, isel: *Select) !void {
        if (isel.instructions.items.len > target_block.target_label) {
            try isel.emit(.b(@intCast((isel.instructions.items.len + 1 - target_block.target_label) << 2)));
        }
        try isel.merge(&target_block.live_registers, .{});
    }
};

pub const Loop = struct {
    def_order: u32,
    dom: u32,
    depth: u32,
    live: u32,
    live_registers: LiveRegisters,
    repeat_list: u32,

    pub const invalid: Air.Inst.Index = @fromBackingInt(@intCast(
        std.math.maxInt(@typeInfo(Air.Inst.Index).@"enum".tag_type),
    ));

    pub const Index = enum(u32) {
        _,

        fn inst(li: Loop.Index, isel: *Select) Air.Inst.Index {
            return isel.loops.keys()[@backingInt(li)];
        }

        fn get(li: Loop.Index, isel: *Select) *Loop {
            return &isel.loops.values()[@backingInt(li)];
        }
    };

    pub const empty_list: u32 = std.math.maxInt(u32);

    fn branch(target_loop: *Loop, isel: *Select) !void {
        try isel.instructions.ensureUnusedCapacity(isel.pt.zcu.gpa, 1);
        const repeat_list_tail = target_loop.repeat_list;
        target_loop.repeat_list = @intCast(isel.instructions.items.len);
        isel.branch_placeholder = target_loop.repeat_list;
        isel.instructions.appendAssumeCapacity(@bitCast(repeat_list_tail));
        try isel.merge(&target_loop.live_registers, .{});
    }

    /// Points the branches collected by `branch` at the loop's start, the
    /// next instruction to be emitted.
    fn patchRepeats(loop: *const Loop, isel: *Select) void {
        var repeat_label = loop.repeat_list;
        while (repeat_label != empty_list) {
            const instruction = &isel.instructions.items[repeat_label];
            const next_repeat_label = instruction.*;
            instruction.* = .b(-@as(i28, @intCast((isel.instructions.items.len - 1 - repeat_label) << 2)));
            repeat_label = @bitCast(next_repeat_label);
        }
    }
};

pub fn deinit(isel: *Select) void {
    const gpa = isel.pt.zcu.gpa;

    isel.def_order.deinit(gpa);
    isel.blocks.deinit(gpa);
    isel.loops.deinit(gpa);
    isel.active_loops.deinit(gpa);
    isel.loop_live.set.deinit(gpa);
    isel.loop_live.list.deinit(gpa);
    isel.dom.deinit(gpa);
    isel.promotion.deinit(gpa);

    isel.tail_branches.deinit(gpa);
    isel.instructions.deinit(gpa);
    isel.debug_events.deinit(gpa);
    isel.literals.deinit(gpa);
    isel.nav_relocs.deinit(gpa);
    isel.uav_relocs.deinit(gpa);
    isel.lazy_relocs.deinit(gpa);
    isel.global_relocs.deinit(gpa);
    isel.literal_relocs.deinit(gpa);

    isel.live_values.deinit(gpa);
    isel.values.deinit(gpa);

    isel.* = undefined;
}

/// Analyzes `air_body`, the function's body when `outermost`, else a body
/// nested in it.
pub fn analyze(isel: *Select, air_body: []const Air.Inst.Index, outermost: bool) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = zcu.gpa;
    const air_tags = isel.air.instructions.items(.tag);
    const air_data = isel.air.instructions.items(.data);
    var air_body_index: usize = 0;
    var air_inst_index = air_body[air_body_index];
    const initial_def_order_len = isel.def_order.count();
    air_tag: switch (air_tags[@backingInt(air_inst_index)]) {
        .arg,
        .ret_addr,
        .frame_addr,
        .err_return_trace,
        .save_err_return_trace_index,
        .runtime_nav_ptr,
        .c_va_start,
        => {
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .add,
        .add_safe,
        .add_optimized,
        .add_wrap,
        .add_sat,
        .sub,
        .sub_safe,
        .sub_optimized,
        .sub_wrap,
        .sub_sat,
        .mul,
        .mul_safe,
        .mul_optimized,
        .mul_wrap,
        .mul_sat,
        .div_float,
        .div_float_optimized,
        .div_trunc,
        .div_trunc_optimized,
        .div_floor,
        .div_floor_optimized,
        .div_ceil,
        .div_ceil_optimized,
        .div_exact,
        .div_exact_optimized,
        .rem,
        .rem_optimized,
        .mod,
        .mod_optimized,
        .max,
        .min,
        .bit_and,
        .bit_or,
        .shr,
        .shr_exact,
        .shl,
        .shl_exact,
        .shl_sat,
        .xor,
        .cmp_lt,
        .cmp_lt_optimized,
        .cmp_lte,
        .cmp_lte_optimized,
        .cmp_eq,
        .cmp_eq_optimized,
        .cmp_gte,
        .cmp_gte_optimized,
        .cmp_gt,
        .cmp_gt_optimized,
        .cmp_neq,
        .cmp_neq_optimized,
        .array_elem_val,
        .legalize_vec_elem_val,
        .slice_elem_val,
        .ptr_elem_val,
        => {
            const bin_op = air_data[@backingInt(air_inst_index)].bin_op;

            try isel.analyzeUse(bin_op.lhs);
            try isel.analyzeUse(bin_op.rhs);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .ptr_add,
        .ptr_sub,
        .add_with_overflow,
        .sub_with_overflow,
        .mul_with_overflow,
        .shl_with_overflow,
        .slice,
        .slice_elem_ptr,
        .ptr_elem_ptr,
        => {
            const ty_pl = air_data[@backingInt(air_inst_index)].ty_pl;
            const bin_op = isel.air.extraData(Air.Bin, ty_pl.payload).data;

            try isel.analyzeUse(bin_op.lhs);
            try isel.analyzeUse(bin_op.rhs);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .legalize_vec_store_elem => {
            const pl_op = air_data[@backingInt(air_inst_index)].pl_op;
            const bin_op = isel.air.extraData(Air.Bin, pl_op.payload).data;
            try isel.analyzeUse(pl_op.operand);
            try isel.analyzeUse(bin_op.lhs);
            try isel.analyzeUse(bin_op.rhs);
            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .alloc => {
            const ty = air_data[@backingInt(air_inst_index)].ty;

            isel.stack_align = isel.stack_align.maxStrict(ty.ptrAlignment(zcu));
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});
            if (ty.childType(zcu).abiSize(zcu) <= 16) {
                try isel.promotion.stored_once.putNoClobber(gpa, air_inst_index, .{ .value = null, .valid = true });
                try isel.promotion.stored_once_ptrs.putNoClobber(gpa, air_inst_index, .{ .local = @intCast(isel.promotion.stored_once.count() - 1), .offset = 0 });
            }
            if (isel.promotableType(ty.childType(zcu))) |is_vector| try isel.promotion.locals.putNoClobber(gpa, air_inst_index, .{
                .weight = 0,
                .epoch = 0,
                .escaped = false,
                .in_loop = false,
                .is_vector = is_vector,
                .ra = .zr,
            });

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .inferred_alloc,
        .inferred_alloc_comptime,
        .wasm_memory_size,
        .wasm_memory_grow,
        .work_item_id,
        .work_group_size,
        .work_group_id,
        .spirv_runtime_array_len,
        .array_to_vector,
        => unreachable,
        .ret_ptr => {
            const ty = air_data[@backingInt(air_inst_index)].ty;

            if (isel.live_values.get(Block.main)) |ret_vi| switch (ret_vi.parent(isel)) {
                .unallocated, .stack_slot => isel.stack_align = isel.stack_align.maxStrict(ty.ptrAlignment(zcu)),
                .value, .constant, .stack_address => unreachable,
                .address => |address_vi| try isel.live_values.putNoClobber(gpa, air_inst_index, address_vi.ref(isel)),
            };
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .assembly => {
            const ty_pl = air_data[@backingInt(air_inst_index)].ty_pl;
            try isel.analyzeAsmRegisters(air_inst_index);

            const unwrapped_asm = isel.air.unwrapAsm(air_inst_index);
            for (unwrapped_asm.inputs) |operand| try isel.analyzeUse(operand);
            for (unwrapped_asm.outputs) |operand| if (operand != .none) try isel.analyzeUse(operand);
            if (ty_pl.ty.ip_index != .void_type) try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .not,
        .clz,
        .ctz,
        .popcount,
        .byte_swap,
        .bit_reverse,
        .abs,
        .fptrunc,
        .fpext,
        .int_cast,
        .int_cast_safe,
        .trunc,
        .optional_payload,
        .optional_payload_ptr,
        .optional_payload_ptr_set,
        .wrap_optional,
        .unwrap_errunion_payload,
        .unwrap_errunion_err,
        .unwrap_errunion_payload_ptr,
        .unwrap_errunion_err_ptr,
        .errunion_payload_ptr_set,
        .wrap_errunion_payload,
        .wrap_errunion_err,
        .struct_field_ptr_index_0,
        .struct_field_ptr_index_1,
        .struct_field_ptr_index_2,
        .struct_field_ptr_index_3,
        .get_union_tag,
        .ptr_slice_len_ptr,
        .ptr_slice_ptr_ptr,
        .array_to_slice,
        .int_from_float,
        .int_from_float_optimized,
        .int_from_float_safe,
        .int_from_float_optimized_safe,
        .float_from_int,
        .splat,
        .error_set_has_value,
        .addrspace_cast,
        .c_va_arg,
        .c_va_copy,
        => {
            const ty_op = air_data[@backingInt(air_inst_index)].ty_op;

            try isel.analyzeDerivedUse(air_inst_index, ty_op.operand);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .load => {
            const ty_op = air_data[@backingInt(air_inst_index)].ty_op;

            const stored_once_load = try isel.analyzeStoredOnceLoad(air_inst_index, ty_op.operand);
            if (isel.promotableLocalIndex(ty_op.operand)) |local_index| {
                const local = &isel.promotion.locals.values()[local_index];
                local.weight +|= Promotion.useWeight(isel.active_loops.items.len);
                if (isel.active_loops.items.len > 0) local.in_loop = true;
                try isel.promotion.local_loads.putNoClobber(gpa, air_inst_index, .{
                    .local = @intCast(local_index),
                    .epoch = local.epoch,
                    .aliasable = true,
                });
                _ = try isel.analyzeLiveness(ty_op.operand);
            } else if (stored_once_load) {
                _ = try isel.analyzeLiveness(ty_op.operand);
            } else try isel.analyzeUse(ty_op.operand);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .store, .store_safe => {
            const bin_op = air_data[@backingInt(air_inst_index)].bin_op;

            try isel.analyzeUse(bin_op.rhs);
            const stored_once_store = isel.analyzeStoredOnceStore(bin_op.lhs, bin_op.rhs, outermost);
            if (isel.promotableLocalIndex(bin_op.lhs)) |local_index| {
                const local = &isel.promotion.locals.values()[local_index];
                local.weight +|= Promotion.useWeight(isel.active_loops.items.len);
                if (isel.active_loops.items.len > 0) local.in_loop = true;
                // Loads before this store can no longer stand for the local.
                local.epoch += 1;
                _ = try isel.analyzeLiveness(bin_op.lhs);
            } else if (stored_once_store) {
                _ = try isel.analyzeLiveness(bin_op.lhs);
            } else try isel.analyzeUse(bin_op.lhs);

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .bit_cast,
        .ptr_cast,
        .ptr_from_int,
        .int_from_ptr,
        .error_cast,
        .error_from_int,
        .int_from_error,
        .union_from_enum,
        => {
            const ty_op = air_data[@backingInt(air_inst_index)].ty_op;
            maybe_noop: {
                if (ty_op.ty.ip_index != isel.air.typeOf(ty_op.operand, ip).toIntern()) break :maybe_noop;
                if (true) break :maybe_noop;
                if (ty_op.operand.toIndex()) |src_air_inst_index| {
                    if (isel.hints.get(src_air_inst_index)) |hint_vpsi| {
                        try isel.hints.putNoClobber(gpa, air_inst_index, hint_vpsi);
                    }
                }
            }
            try isel.analyzeDerivedUse(air_inst_index, ty_op.operand);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});
            // A bit cast between integers of the same size (`usize` to `u64`
            // in `for` loops) is the same value: it shares its operand's.
            if (air_tags[@backingInt(air_inst_index)] == .bit_cast) if (ty_op.operand.toIndex()) |operand_inst| {
                const operand_ty = isel.air.typeOf(ty_op.operand, ip);
                // Other widths are extended by signedness.
                if (ty_op.ty.isAbiInt(zcu) and operand_ty.isAbiInt(zcu) and
                    ty_op.ty.intInfo(zcu).bits == operand_ty.intInfo(zcu).bits and
                    (ty_op.ty.intInfo(zcu).bits == 32 or ty_op.ty.intInfo(zcu).bits == 64))
                    try isel.promotion.casts.putNoClobber(gpa, air_inst_index, isel.promotion.casts.get(operand_inst) orelse operand_inst);
            };

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .bit_cast_safe => unreachable, // legalized
        inline .block, .dbg_inline_block => |air_tag| {
            const air_body_block = switch (air_tag) {
                else => comptime unreachable,
                .block => isel.air.unwrapBlock(air_inst_index),
                .dbg_inline_block => isel.air.unwrapDbgBlock(air_inst_index),
            };

            const result_ty = air_body_block.ty.toIntern();

            if (result_ty == .noreturn_type) {
                try isel.analyze(air_body_block.body, false);

                air_body_index += 1;
                break :air_tag;
            }

            assert(!(try isel.blocks.getOrPut(gpa, air_inst_index)).found_existing);
            try isel.analyze(air_body_block.body, false);
            const block_entry = isel.blocks.pop().?;
            assert(block_entry.key == air_inst_index);

            if (result_ty != .void_type) try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .loop => {
            const air_body_block = isel.air.unwrapBlock(air_inst_index);

            const initial_dom_start = isel.dom_start;
            const initial_dom_len = isel.dom_len;
            isel.dom_start = @intCast(isel.dom.items.len);
            isel.dom_len = @intCast(isel.blocks.count());
            try isel.active_loops.append(gpa, @fromBackingInt(@intCast(isel.loops.count())));
            try isel.loops.putNoClobber(gpa, air_inst_index, .{
                .def_order = @intCast(isel.def_order.count()),
                .dom = isel.dom_start,
                .depth = isel.dom_len,
                .live = 0,
                .live_registers = undefined,
                .repeat_list = undefined,
            });
            try isel.dom.appendNTimes(gpa, 0, @divCeil(isel.dom_len, @bitSizeOf(DomInt)));
            try isel.analyze(air_body_block.body, false);
            for (
                isel.dom.items[initial_dom_start..].ptr,
                isel.dom.items[isel.dom_start..][0..@divCeil(initial_dom_len, @bitSizeOf(DomInt))],
            ) |*initial_dom, loop_dom| initial_dom.* |= loop_dom;
            isel.dom_start = initial_dom_start;
            isel.dom_len = initial_dom_len;
            assert(isel.active_loops.pop().?.inst(isel) == air_inst_index);

            air_body_index += 1;
        },
        .repeat, .trap, .unreach => air_body_index += 1,
        .br => {
            const br = air_data[@backingInt(air_inst_index)].br;
            const block_index = isel.blocks.getIndex(br.block_inst).?;
            if (block_index < isel.dom_len) isel.dom.items[isel.dom_start + block_index / @bitSizeOf(DomInt)] |= @as(DomInt, 1) << @truncate(block_index);
            try isel.analyzeUse(br.operand);

            air_body_index += 1;
        },
        // The backend emits no variable locations, so `dbg_var_ptr` is not a
        // use of the pointer: a stored-once local's store is dropped and a
        // promoted local has no memory at all (`selectStore`). Emitting
        // locations requires treating it as an escaping use first.
        .breakpoint, .dbg_stmt, .dbg_empty_stmt, .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline, .c_va_end => {
            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .call,
        .call_always_tail,
        .call_never_tail,
        .call_never_inline,
        .legalize_compiler_rt_call,
        => {
            const call_info = isel.callInfo(air_inst_index);
            const args = call_info.args;
            isel.saved_registers.insert(.lr);
            switch (call_info.callee) {
                .value => |callee| {
                    try isel.checkSoftF128CallConv(call_info.func_type.?);
                    try isel.checkVectorCallConv(call_info.func_type.?);
                    try isel.analyzeUse(callee);
                },
                .global => {},
            }
            var param_it: CallAbiIterator = .init;
            for (args, 0..) |arg, arg_index| {
                const restore_values_len = isel.values.items.len;
                defer isel.values.shrinkRetainingCapacity(restore_values_len);
                const param_vi = param_vi: {
                    const param_ty = isel.air.typeOf(arg, ip);
                    if (call_info.isVarArg(arg_index)) {
                        switch (isel.va_list) {
                            .other => break :param_vi try param_it.nonSysvVarArg(isel, param_ty),
                            .sysv => {},
                        }
                    }
                    break :param_vi try param_it.param(isel, param_ty);
                } orelse continue;
                defer param_vi.deref(isel);
                const passed_vi = switch (param_vi.parent(isel)) {
                    .unallocated, .stack_slot => param_vi,
                    .value, .constant, .stack_address => unreachable,
                    .address => |address_vi| address_vi,
                };
                switch (passed_vi.parent(isel)) {
                    .unallocated => {},
                    .stack_slot => |stack_slot| {
                        assert(stack_slot.base == .sp);
                        isel.stack_size = @max(
                            isel.stack_size,
                            stack_slot.offset + @as(u24, @intCast(passed_vi.size(isel))),
                        );
                    },
                    .value, .constant, .address, .stack_address => unreachable,
                }

                try isel.analyzeUse(arg);
            }

            var ret_it: CallAbiIterator = .init;
            if (try ret_it.ret(isel, isel.air.typeOfIndex(air_inst_index, ip))) |ret_vi| {
                tracking_log.debug("${d} <- %{d}", .{ @backingInt(ret_vi), @backingInt(air_inst_index) });
                switch (ret_vi.parent(isel)) {
                    .unallocated, .stack_slot => {},
                    .value, .constant, .stack_address => unreachable,
                    .address => |address_vi| {
                        defer address_vi.deref(isel);
                        const ret_value = ret_vi.get(isel);
                        ret_value.flags.parent_tag = .unallocated;
                        ret_value.parent_payload = .{ .unallocated = {} };
                    },
                }
                try isel.live_values.putNoClobber(gpa, air_inst_index, ret_vi);

                try isel.def_order.putNoClobber(gpa, air_inst_index, {});
            }

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .sqrt,
        .sin,
        .cos,
        .tan,
        .exp,
        .exp2,
        .log,
        .log2,
        .log10,
        .floor,
        .ceil,
        .round,
        .trunc_float,
        .neg,
        .neg_optimized,
        .is_null,
        .is_non_null,
        .is_null_ptr,
        .is_non_null_ptr,
        .is_err,
        .is_non_err,
        .is_err_ptr,
        .is_non_err_ptr,
        .is_named_enum_value,
        .tag_name,
        .error_name,
        .cmp_lte_errors_len,
        => {
            const un_op = air_data[@backingInt(air_inst_index)].un_op;

            try isel.analyzeUse(un_op);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .cmp_vector, .cmp_vector_optimized => {
            const ty_pl = air_data[@backingInt(air_inst_index)].ty_pl;
            const extra = isel.air.extraData(Air.VectorCmp, ty_pl.payload).data;

            try isel.analyzeUse(extra.lhs);
            try isel.analyzeUse(extra.rhs);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .cond_br => {
            const cond_br = isel.air.unwrapCondBr(air_inst_index);

            try isel.analyzeUse(cond_br.condition);

            try isel.analyze(cond_br.then_body, false);
            try isel.analyze(cond_br.else_body, false);

            air_body_index += 1;
        },
        .switch_br => {
            const switch_br = isel.air.unwrapSwitch(air_inst_index);

            try isel.analyzeUse(switch_br.operand);

            var cases_it = switch_br.iterateCases();
            while (cases_it.next()) |case| try isel.analyze(case.body, false);
            if (switch_br.else_body_len > 0) try isel.analyze(cases_it.elseBody(), false);

            air_body_index += 1;
        },
        .loop_switch_br => {
            const switch_br = isel.air.unwrapSwitch(air_inst_index);

            try isel.analyzeUse(switch_br.operand);

            const initial_dom_start = isel.dom_start;
            const initial_dom_len = isel.dom_len;
            isel.dom_start = @intCast(isel.dom.items.len);
            isel.dom_len = @intCast(isel.blocks.count());
            try isel.active_loops.append(gpa, @fromBackingInt(@intCast(isel.loops.count())));
            try isel.loops.putNoClobber(gpa, air_inst_index, .{
                .def_order = @intCast(isel.def_order.count()),
                .dom = isel.dom_start,
                .depth = isel.dom_len,
                .live = 0,
                .live_registers = undefined,
                .repeat_list = undefined,
            });
            try isel.dom.appendNTimes(gpa, 0, @divCeil(isel.dom_len, @bitSizeOf(DomInt)));

            var cases_it = switch_br.iterateCases();
            while (cases_it.next()) |case| try isel.analyze(case.body, false);
            if (switch_br.else_body_len > 0) try isel.analyze(cases_it.elseBody(), false);

            for (
                isel.dom.items[initial_dom_start..].ptr,
                isel.dom.items[isel.dom_start..][0..@divCeil(initial_dom_len, @bitSizeOf(DomInt))],
            ) |*initial_dom, loop_dom| initial_dom.* |= loop_dom;
            isel.dom_start = initial_dom_start;
            isel.dom_len = initial_dom_len;
            assert(isel.active_loops.pop().?.inst(isel) == air_inst_index);

            air_body_index += 1;
        },
        .switch_dispatch => {
            const br = air_data[@backingInt(air_inst_index)].br;

            try isel.analyzeUse(br.operand);

            air_body_index += 1;
        },
        .@"try", .try_cold => {
            const unwrapped_try = isel.air.unwrapTry(air_inst_index);

            try isel.analyzeUse(unwrapped_try.error_union);
            try isel.analyze(unwrapped_try.else_body, false);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .try_ptr, .try_ptr_cold => {
            const unwrapped_try = isel.air.unwrapTryPtr(air_inst_index);

            try isel.analyzeUse(unwrapped_try.error_union_ptr);
            try isel.analyze(unwrapped_try.else_body, false);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .ret, .ret_safe, .ret_load => {
            const un_op = air_data[@backingInt(air_inst_index)].un_op;
            isel.returns = true;

            const block_index = 0;
            assert(isel.blocks.keys()[block_index] == Block.main);
            if (isel.dom_len > 0) isel.dom.items[isel.dom_start] |= 1 << block_index;

            // A tail call without a runtime result defines no value to return.
            const void_tail_call = if (un_op.toIndex()) |operand_inst|
                air_tags[@backingInt(operand_inst)] == .call_always_tail and
                    !isel.def_order.contains(operand_inst)
            else
                false;
            if (!void_tail_call) try isel.analyzeUse(un_op);

            air_body_index += 1;
        },
        .set_union_tag,
        .memset,
        .memset_safe,
        .memcpy,
        .memmove,
        .atomic_store_unordered,
        .atomic_store_monotonic,
        .atomic_store_release,
        .atomic_store_seq_cst,
        => {
            const bin_op = air_data[@backingInt(air_inst_index)].bin_op;

            try isel.analyzeUse(bin_op.lhs);
            try isel.analyzeUse(bin_op.rhs);

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .struct_field_ptr, .agg_field_val => {
            const ty_pl = air_data[@backingInt(air_inst_index)].ty_pl;
            const extra = isel.air.extraData(Air.StructField, ty_pl.payload).data;

            try isel.analyzeDerivedUse(air_inst_index, extra.struct_operand);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .slice_len => {
            const ty_op = air_data[@backingInt(air_inst_index)].ty_op;

            try isel.analyzeUse(ty_op.operand);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            if (ty_op.operand.toIndex()) |operand_inst| if (isel.promotion.stored_once_loads.contains(operand_inst)) {
                // The operand's value is decided at the end of analysis.
                try isel.promotion.slice_fields.append(gpa, .{ air_inst_index, 8 });
            } else {
                const slice_vi = try isel.use(ty_op.operand);
                var len_part_it = slice_vi.field(isel.air.typeOf(ty_op.operand, ip), 8, 8);
                if (try len_part_it.only(isel)) |len_part_vi|
                    try isel.live_values.putNoClobber(gpa, air_inst_index, len_part_vi.ref(isel));
            };

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .slice_ptr => {
            const ty_op = air_data[@backingInt(air_inst_index)].ty_op;

            try isel.analyzeUse(ty_op.operand);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            if (ty_op.operand.toIndex()) |operand_inst| if (isel.promotion.stored_once_loads.contains(operand_inst)) {
                try isel.promotion.slice_fields.append(gpa, .{ air_inst_index, 0 });
            } else {
                const slice_vi = try isel.use(ty_op.operand);
                var ptr_part_it = slice_vi.field(isel.air.typeOf(ty_op.operand, ip), 0, 8);
                if (try ptr_part_it.only(isel)) |ptr_part_vi|
                    try isel.live_values.putNoClobber(gpa, air_inst_index, ptr_part_vi.ref(isel));
            };

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .reduce, .reduce_optimized => {
            const reduce = air_data[@backingInt(air_inst_index)].reduce;

            try isel.analyzeUse(reduce.operand);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .shuffle_one => {
            const extra = isel.air.unwrapShuffleOne(zcu, air_inst_index);

            try isel.analyzeUse(extra.operand);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .shuffle_two => {
            const extra = isel.air.unwrapShuffleTwo(zcu, air_inst_index);

            try isel.analyzeUse(extra.operand_a);
            try isel.analyzeUse(extra.operand_b);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .select, .mul_add => {
            const pl_op = air_data[@backingInt(air_inst_index)].pl_op;
            const bin_op = isel.air.extraData(Air.Bin, pl_op.payload).data;

            try isel.analyzeUse(pl_op.operand);
            try isel.analyzeUse(bin_op.lhs);
            try isel.analyzeUse(bin_op.rhs);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .cmpxchg_weak, .cmpxchg_strong => {
            const ty_pl = air_data[@backingInt(air_inst_index)].ty_pl;
            const extra = isel.air.extraData(Air.Cmpxchg, ty_pl.payload).data;

            try isel.analyzeUse(extra.ptr);
            try isel.analyzeUse(extra.expected_value);
            try isel.analyzeUse(extra.new_value);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .atomic_load => {
            const atomic_load = air_data[@backingInt(air_inst_index)].atomic_load;

            try isel.analyzeUse(atomic_load.ptr);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .atomic_rmw => {
            const pl_op = air_data[@backingInt(air_inst_index)].pl_op;
            const extra = isel.air.extraData(Air.AtomicRmw, pl_op.payload).data;

            try isel.analyzeUse(pl_op.operand);
            try isel.analyzeUse(extra.operand);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .aggregate_init => {
            const ty_pl = air_data[@backingInt(air_inst_index)].ty_pl;
            const elements: []const Air.Inst.Ref = @ptrCast(isel.air.extra.items[ty_pl.payload..][0..@intCast(ty_pl.ty.arrayLen(zcu))]);

            for (elements) |element| try isel.analyzeUse(element);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .union_init => {
            const ty_pl = air_data[@backingInt(air_inst_index)].ty_pl;
            const extra = isel.air.extraData(Air.UnionInit, ty_pl.payload).data;

            try isel.analyzeUse(extra.init);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .prefetch => {
            const prefetch = air_data[@backingInt(air_inst_index)].prefetch;

            try isel.analyzeUse(prefetch.ptr);

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .field_parent_ptr => {
            const ty_pl = air_data[@backingInt(air_inst_index)].ty_pl;
            const extra = isel.air.extraData(Air.FieldParentPtr, ty_pl.payload).data;

            try isel.analyzeUse(extra.field_ptr);
            try isel.def_order.putNoClobber(gpa, air_inst_index, {});

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
        .set_err_return_trace => {
            const un_op = air_data[@backingInt(air_inst_index)].un_op;

            try isel.analyzeUse(un_op);

            air_body_index += 1;
            air_inst_index = air_body[air_body_index];
            continue :air_tag air_tags[@backingInt(air_inst_index)];
        },
    }
    assert(air_body_index == air_body.len);
    isel.def_order.shrinkRetainingCapacity(initial_def_order_len);
}

/// Records the registers that the inline assembly `inst` names in its
/// constraints or clobbers. Invalid ones are reported when it is selected.
fn analyzeAsmRegisters(isel: *Select, inst: Air.Inst.Index) !void {
    const unwrapped_asm = isel.air.unwrapAsm(inst);
    var it = unwrapped_asm.iterateOutputs();
    while (it.next()) |output| {
        if (!std.mem.startsWith(u8, output.constraint, "=")) continue;
        const reg = asmConstraintRegister(asmConstraintAlternative(output.constraint["=".len..])) orelse continue;
        isel.promotion.asm_registers.insert((reg orelse continue).alias);
    }
    it = unwrapped_asm.iterateInputs();
    while (it.next()) |input| {
        const reg = asmConstraintRegister(asmConstraintAlternative(input.constraint)) orelse continue;
        isel.promotion.asm_registers.insert((reg orelse continue).alias);
    }
    var clobbers_bigint_buf: Constant.BigIntSpace = undefined;
    var clobber_it = isel.asmClobbers(unwrapped_asm.clobbers, &clobbers_bigint_buf);
    while (try clobber_it.next()) |clobber| isel.promotion.asm_registers.insert(clobber.ra);
}

fn analyzeUse(isel: *Select, air_ref: Air.Inst.Ref) !void {
    const use_inst = air_ref.toIndex() orelse return;
    // A pointer into a stored-once local escapes, unless it is used by a
    // load (`analyzeStoredOnceLoad`) or derives another such pointer
    // (`analyzeDerivedUse`).
    if (isel.promotion.stored_once_ptrs.get(use_inst)) |ptr| isel.promotion.stored_once.values()[ptr.local].valid = false;
    return isel.analyzeNonEscapingUse(use_inst);
}

/// A use of `use_inst` that does not make it escape if it is a pointer into
/// a stored-once local.
fn analyzeNonEscapingUse(isel: *Select, use_inst: Air.Inst.Index) !void {
    const crosses_loop = try isel.analyzeLiveness(use_inst.toRef());
    // A cast that shares its operand's value is a use of the operand, and so
    // is a load of a stored-once local a use of the stored value.
    const air_inst_index = switch (isel.air.instructions.items(.tag)[@backingInt(use_inst)]) {
        else => use_inst,
        .bit_cast => isel.promotion.casts.get(use_inst) orelse use_inst,
        .load => if (isel.promotion.stored_once_loads.get(use_inst)) |ptr|
            isel.promotion.stored_once.values()[ptr.local].value.?
        else
            use_inst,
    };

    // Promoted locals
    switch (isel.air.instructions.items(.tag)[@backingInt(air_inst_index)]) {
        else => {},
        // Any use other than as the pointer of a load or store escapes.
        .alloc => if (isel.promotion.locals.getPtr(air_inst_index)) |local| {
            local.escaped = true;
        },
        .load => isel.analyzePromotedLoadUse(air_inst_index, crosses_loop),
    }
    // A later store can still show that the local is not stored once, and
    // then this load is selected as a load whose result is used here.
    if (air_inst_index != use_inst and isel.air.instructions.items(.tag)[@backingInt(use_inst)] == .load)
        isel.analyzePromotedLoadUse(use_inst, crosses_loop);
    if (crosses_loop) try isel.analyzePinnedValue(air_inst_index);
}

/// A use of the result of `load_inst`, which may load a promoted local.
fn analyzePromotedLoadUse(isel: *Select, load_inst: Air.Inst.Index, crosses_loop: bool) void {
    const load = isel.promotion.local_loads.getPtr(load_inst) orelse return;
    if (crosses_loop or load.epoch != isel.promotion.locals.values()[load.local].epoch)
        load.aliasable = false;
}

/// Counts a use in a loop of a value defined outside it.
fn analyzePinnedValue(isel: *Select, inst: Air.Inst.Index) !void {
    const zcu = isel.pt.zcu;
    const gop = try isel.promotion.pinned_values.getOrPut(zcu.gpa, inst);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .weight = 0, .is_vector = false, .pair = false, .ra = .zr, .ra2 = .zr };
        const class: enum { ineligible, general, vector } = class: switch (isel.air.instructions.items(.tag)[@backingInt(inst)]) {
            // Addresses of locals are rematerialized; these alias parts of
            // other values; this one lives in a stack slot.
            .alloc, .ret_ptr, .slice_len, .slice_ptr, .loop_switch_br => .ineligible,
            else => {
                // A constant offset from a local is a stack address too.
                var root = inst;
                while (isel.constantOffsetPointer(root)) |base| {
                    root = base[0].toIndex() orelse break;
                    switch (isel.air.instructions.items(.tag)[@backingInt(root)]) {
                        else => {},
                        .alloc, .ret_ptr => break :class .ineligible,
                    }
                }
                const ty = isel.air.typeOfIndex(inst, &zcu.intern_pool);
                if (ty.isSlice(zcu)) {
                    gop.value_ptr.pair = true;
                    break :class .general;
                }
                const is_vector = isel.promotableType(ty) orelse break :class .ineligible;
                break :class if (is_vector) .vector else .general;
            },
        };
        switch (class) {
            .ineligible => {
                gop.value_ptr.weight = std.math.maxInt(u32);
                return;
            },
            .general => {},
            .vector => gop.value_ptr.is_vector = true,
        }
    }
    if (gop.value_ptr.weight == std.math.maxInt(u32)) return;
    gop.value_ptr.weight = @min(gop.value_ptr.weight +| Promotion.useWeight(isel.active_loops.items.len), std.math.maxInt(u32) - 1);
}

/// Records loop liveness of a use; returns whether the use is in a loop
/// that does not contain the definition.
fn analyzeLiveness(isel: *Select, air_ref: Air.Inst.Ref) !bool {
    const air_inst_index = air_ref.toIndex() orelse return false;
    const def_order_index = isel.def_order.getIndex(air_inst_index).?;

    // Loop liveness
    var active_loop_index = isel.active_loops.items.len;
    while (active_loop_index > 0) {
        const prev_active_loop_index = active_loop_index - 1;
        const active_loop = isel.active_loops.items[prev_active_loop_index];
        if (def_order_index >= active_loop.get(isel).def_order) break;
        active_loop_index = prev_active_loop_index;
    }
    if (active_loop_index < isel.active_loops.items.len) {
        const active_loop = isel.active_loops.items[active_loop_index];
        const loop_live_gop =
            try isel.loop_live.set.getOrPut(isel.pt.zcu.gpa, .{ active_loop, air_inst_index });
        if (!loop_live_gop.found_existing) active_loop.get(isel).live += 1;
        return true;
    }
    return false;
}

/// The use of `operand` by `inst`, which may derive a constant offset
/// pointer into a stored-once local.
fn analyzeDerivedUse(isel: *Select, inst: Air.Inst.Index, operand: Air.Inst.Ref) !void {
    const operand_inst = operand.toIndex() orelse return;
    const ptr = isel.promotion.stored_once_ptrs.get(operand_inst) orelse return isel.analyzeUse(operand);
    derive: {
        if (!isel.promotion.stored_once.values()[ptr.local].valid) break :derive;
        if (isel.promotion.stored_once.values()[ptr.local].value == null) break :derive;
        switch (isel.air.instructions.items(.tag)[@backingInt(inst)]) {
            else => break :derive,
            .bit_cast,
            .ptr_cast,
            .struct_field_ptr,
            .struct_field_ptr_index_0,
            .struct_field_ptr_index_1,
            .struct_field_ptr_index_2,
            .struct_field_ptr_index_3,
            .ptr_slice_len_ptr,
            .ptr_slice_ptr_ptr,
            => {},
        }
        const base, const offset = isel.constantOffsetPointer(inst) orelse break :derive;
        assert(base.toIndex() == operand_inst);
        try isel.promotion.stored_once_ptrs.putNoClobber(isel.pt.zcu.gpa, inst, .{ .local = ptr.local, .offset = ptr.offset + offset });
        return isel.analyzeNonEscapingUse(operand_inst);
    }
    return isel.analyzeUse(operand);
}

/// Records a load through a pointer into a stored-once local; returns whether
/// it is one, so that the pointer does not escape.
fn analyzeStoredOnceLoad(isel: *Select, inst: Air.Inst.Index, ptr_ref: Air.Inst.Ref) !bool {
    const zcu = isel.pt.zcu;
    const ptr_inst = ptr_ref.toIndex() orelse return false;
    const ptr = isel.promotion.stored_once_ptrs.get(ptr_inst) orelse return false;
    const local = &isel.promotion.stored_once.values()[ptr.local];
    const ptr_info = isel.air.typeOf(ptr_ref, &zcu.intern_pool).ptrInfo(zcu);
    if (!local.valid or local.value == null or ptr_info.flags.is_volatile or
        ptr_info.flags.vector_index != .none or ptr_info.packed_offset.host_size > 0)
    {
        local.valid = false;
        return false;
    }
    try isel.promotion.stored_once_loads.putNoClobber(zcu.gpa, inst, ptr);
    // The load is a use of the stored value here.
    if (try isel.analyzeLiveness(local.value.?.toRef())) try isel.analyzePinnedValue(local.value.?);
    return true;
}

/// Records a store to a stored-once local, in the function's outermost body
/// if `outermost`; returns whether it is the store that makes it one, so that
/// the pointer does not escape.
fn analyzeStoredOnceStore(isel: *Select, ptr_ref: Air.Inst.Ref, src_ref: Air.Inst.Ref, outermost: bool) bool {
    const ptr_inst = ptr_ref.toIndex() orelse return false;
    const local_index = isel.promotion.stored_once.getIndex(ptr_inst) orelse return false;
    const local = &isel.promotion.stored_once.values()[local_index];
    // The store must come first and dominate every load: the function's
    // outermost body.
    if (local.valid and local.value == null and outermost) {
        if (src_ref.toIndex()) |src_inst| {
            local.value = src_inst;
            return true;
        }
    }
    local.valid = false;
    return false;
}

/// The value of `inst` after analysis: shared with another instruction's if
/// it is a load of a stored-once local, a cast or a field of a slice.
fn sharedValue(isel: *Select, inst: Air.Inst.Index) !Value.Index {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = zcu.gpa;
    if (isel.live_values.get(inst)) |vi| return vi;
    const air_data = isel.air.instructions.items(.data)[@backingInt(inst)];
    const shared_vi: Value.Index = shared: switch (isel.air.instructions.items(.tag)[@backingInt(inst)]) {
        else => return isel.use(inst.toRef()),
        .bit_cast => if (isel.promotion.casts.get(inst)) |operand_inst|
            break :shared try isel.sharedValue(operand_inst)
        else
            return isel.use(inst.toRef()),
        .slice_len, .slice_ptr => |tag| {
            const operand = air_data.ty_op.operand;
            const slice_vi = try isel.sharedValue(operand.toIndex() orelse return isel.use(inst.toRef()));
            var part_it = slice_vi.field(isel.air.typeOf(operand, ip), if (tag == .slice_len) 8 else 0, 8);
            break :shared try part_it.only(isel) orelse return isel.use(inst.toRef());
        },
        .load => {
            const ptr = isel.promotion.stored_once_loads.get(inst) orelse return isel.use(inst.toRef());
            const local = &isel.promotion.stored_once.values()[ptr.local];
            if (!local.valid) return isel.use(inst.toRef());
            const value_inst = local.value.?;
            const load_size = isel.air.typeOfIndex(inst, ip).abiSize(zcu);
            if (load_size == 0) return isel.use(inst.toRef());
            const value_vi = try isel.sharedValue(value_inst);
            const load_ty = isel.air.typeOfIndex(inst, ip);
            if (ptr.offset == 0 and load_ty.toIntern() == isel.air.typeOfIndex(value_inst, ip).toIntern())
                break :shared value_vi;
            // Narrower parts carry signedness of their own.
            if (load_size == 4 or load_size == 8) {
                var part_it = value_vi.field(isel.air.typeOfIndex(value_inst, ip), ptr.offset, load_size);
                // A float field of a value in general registers is a general
                // register part, but users of a float take a vector register.
                const load_is_vector = Value.isVectorSize(load_size) and
                    CallAbiIterator.homogeneousAggregateBaseType(zcu, load_ty.toIntern()) != null;
                if (try part_it.only(isel)) |part_vi| if (part_vi.position(isel)[1] == load_size and
                    part_vi.isVector(isel) == load_is_vector)
                    break :shared part_vi;
            }
            // The store stays: this load reads memory.
            local.valid = false;
            return isel.use(inst.toRef());
        },
    };
    if (isel.air.instructions.items(.tag)[@backingInt(inst)] == .load and
        !isel.promotion.shared_loads.contains(inst)) try isel.promotion.shared_loads.putNoClobber(gpa, inst, {});
    try isel.live_values.putNoClobber(gpa, inst, shared_vi.ref(isel));
    return shared_vi;
}

fn promotableLocalIndex(isel: *Select, ptr_ref: Air.Inst.Ref) ?usize {
    const ptr_inst = ptr_ref.toIndex() orelse return null;
    if (isel.air.instructions.items(.tag)[@backingInt(ptr_inst)] != .alloc) return null;
    return isel.promotion.locals.getIndex(ptr_inst);
}

/// The register of the promoted local that `ptr_ref` points to, if any.
fn promotedLocalRegister(isel: *Select, ptr_ref: Air.Inst.Ref) ?Register.Alias {
    if (!isel.promotion.enabled) return null;
    const local = isel.promotion.locals.get(ptr_ref.toIndex() orelse return null) orelse return null;
    return switch (local.ra) {
        .zr => null,
        else => |ra| ra,
    };
}

/// Whether a local of type `ty` can be promoted to a register, and if so
/// whether it is a vector register.
fn promotableType(isel: *Select, ty: ZigType) ?bool {
    const zcu = isel.pt.zcu;
    const size = ty.abiSize(zcu);
    if (size == 0 or size > 8) return null;
    // The same register class `use` gives the loaded value.
    const is_vector = Value.isVectorSize(size) and
        CallAbiIterator.homogeneousAggregateBaseType(zcu, ty.toIntern()) != null;
    switch (ty.zigTypeTag(zcu)) {
        else => return null,
        .int, .bool, .@"enum", .error_set => {},
        .pointer => if (ty.isSlice(zcu)) return null,
        .optional => if (!ty.optionalReprIsPayload(zcu)) return null,
        .float => switch (ty.floatBits(isel.target)) {
            else => return null,
            16, 32, 64 => if (!is_vector) return null,
        },
    }
    if (is_vector and ty.zigTypeTag(zcu) != .float) return null;
    return is_vector;
}

/// Copies a promoted local between its register and another of the same class.
pub fn pinnedMove(isel: *Select, dst_ra: Register.Alias, src_ra: Register.Alias, size: u64) !void {
    if (dst_ra == src_ra) return;
    // A value can be live in either register class.
    try isel.emit(if (dst_ra.isVector()) if (src_ra.isVector()) switch (size) {
        else => unreachable,
        2 => if (isel.target.cpu.has(.aarch64, .fullfp16))
            .fmov(dst_ra.h(), .{ .register = src_ra.h() })
        else
            .dup(dst_ra.h(), src_ra.@"h[]"(0)),
        4 => .fmov(dst_ra.s(), .{ .register = src_ra.s() }),
        8 => .fmov(dst_ra.d(), .{ .register = src_ra.d() }),
    } else size: switch (size) {
        else => unreachable,
        2 => if (isel.target.cpu.has(.aarch64, .fullfp16))
            .fmov(dst_ra.h(), .{ .register = src_ra.w() })
        else
            continue :size 4,
        4 => .fmov(dst_ra.s(), .{ .register = src_ra.w() }),
        8 => .fmov(dst_ra.d(), .{ .register = src_ra.x() }),
    } else if (src_ra.isVector()) switch (size) {
        else => unreachable,
        1 => .umov(dst_ra.w(), src_ra.@"b[]"(0)),
        2 => .umov(dst_ra.w(), src_ra.@"h[]"(0)),
        4 => .fmov(dst_ra.w(), .{ .register = src_ra.s() }),
        8 => .fmov(dst_ra.x(), .{ .register = src_ra.d() }),
    } else switch (size) {
        else => unreachable,
        1...4 => .orr(dst_ra.w(), .wzr, .{ .register = src_ra.w() }),
        5...8 => .orr(dst_ra.x(), .xzr, .{ .register = src_ra.x() }),
    });
}

/// Whether the value stored by the instruction after `preceding` is defined
/// right before it, so that defining it in a promoted local's register does
/// not hide the local from anything in between.
fn pinnedStoreSourceAdjacent(isel: *Select, preceding: []const Air.Inst.Index, src_ref: Air.Inst.Ref) bool {
    const src_inst = src_ref.toIndex() orelse return false;
    const air_tags = isel.air.instructions.items(.tag);
    var index = preceding.len;
    while (index > 0) {
        index -= 1;
        const inst = preceding[index];
        switch (air_tags[@backingInt(inst)]) {
            else => {},
            .dbg_stmt, .dbg_empty_stmt, .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline, .alloc => continue,
        }
        if (inst != src_inst) return false;
        // A value shared with an earlier instruction (`sharedValue`) is
        // defined there, not here.
        if (isel.promotion.casts.contains(inst) or isel.promotion.shared_loads.contains(inst)) return false;
        // A result defined by a nested body is written where that body
        // leaves, which may be anywhere in it.
        return switch (air_tags[@backingInt(inst)]) {
            else => true,
            // These share the part of the slice they read when it is one,
            // which is then defined with the slice.
            .slice_len, .slice_ptr => if (isel.live_values.get(inst)) |vi| vi.parent(isel) != .value else true,
            .block,
            .dbg_inline_block,
            .loop,
            .loop_switch_br,
            .@"try",
            .try_cold,
            .try_ptr,
            .try_ptr_cold,
            => false,
        };
    }
    return false;
}

/// Completes the analysis of the function. With `promote`, locals and loop
/// invariants may be promoted to registers; naked functions, which save no
/// registers, and the fallback after `error.RetryWithoutPromotion` select
/// without it.
pub fn finishAnalysis(isel: *Select, promote: bool) !void {
    const gpa = isel.pt.zcu.gpa;

    // Loop Liveness
    if (isel.loops.count() > 0) {
        try isel.loops.ensureUnusedCapacity(gpa, 1);

        const loop_live_len: u32 = @intCast(isel.loop_live.set.count());
        if (loop_live_len > 0) {
            try isel.loop_live.list.resize(gpa, loop_live_len);

            const loops = isel.loops.values();
            for (loops[1..], loops[0 .. loops.len - 1]) |*loop, prev_loop| loop.live += prev_loop.live;
            assert(loops[loops.len - 1].live == loop_live_len);

            for (isel.loop_live.set.keys()) |entry| {
                const loop, const inst = entry;
                const loop_live = &loop.get(isel).live;
                loop_live.* -= 1;
                isel.loop_live.list.items[loop_live.*] = inst;
            }
            assert(loops[0].live == 0);
        }

        const invalid_gop = isel.loops.getOrPutAssumeCapacity(Loop.invalid);
        assert(!invalid_gop.found_existing);
        invalid_gop.value_ptr.live = loop_live_len;
    }

    // Loads of stored-once locals share the stored value, or the part of it
    // they load; casts share their operand's value; `slice_len`/`slice_ptr`
    // of those loads a part of it. Each is resolved on demand, since one can
    // be the operand of another. This comes first: a local one of whose loads
    // cannot share is not stored-once after all, and may be promoted.
    for (isel.promotion.stored_once_loads.keys()) |load_inst| _ = try isel.sharedValue(load_inst);
    var cast_it = isel.promotion.casts.keyIterator();
    while (cast_it.next()) |cast_inst| _ = try isel.sharedValue(cast_inst.*);
    for (isel.promotion.slice_fields.items) |slice_field| _ = try isel.sharedValue(slice_field[0]);

    if (promote) {
        isel.promotion.enabled = true;
        Promotion.promoteLocals(isel);
        // A load of a promoted local whose value analysis or sharing created
        // already prefers the local's register, as `use` makes the others.
        var load_it = isel.promotion.local_loads.iterator();
        while (load_it.next()) |load_entry| {
            const load_inst = load_entry.key_ptr.*;
            const load = load_entry.value_ptr;
            if (!load.aliasable or isel.promotion.shared_loads.contains(load_inst)) continue;
            const local = isel.promotion.locals.values()[load.local];
            if (local.ra == .zr) continue;
            const vi = isel.live_values.get(load_inst) orelse continue;
            if (vi.hint(isel) == null) vi.setHint(isel, local.ra);
        }
    }
}

/// Selects `air_body`. For the body of a `block`, `block_pred` is the
/// instruction before the block (debug statements skipped): a safety check is
/// a comparison followed by a block whose body is the conditional branch on it.
pub fn body(isel: *Select, air_body: []const Air.Inst.Index, block_pred: ?Air.Inst.Index) Error!void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = zcu.gpa;

    {
        var live_reg_it = isel.live_registers.iterator();
        while (live_reg_it.next()) |live_reg_entry| switch (live_reg_entry.value.*) {
            _ => {
                const ra = &live_reg_entry.value.get(isel).location_payload.small.register;
                assert(ra.* == live_reg_entry.key);
                ra.* = .zr;
                live_reg_entry.value.* = .free;
            },
            .allocating => live_reg_entry.value.* = .free,
            .free => {},
        };
    }

    var air: struct {
        isel: *Select,
        tag_items: []const Air.Inst.Tag,
        data_items: []const Air.Inst.Data,
        body: []const Air.Inst.Index,
        body_index: u32,
        inst_index: Air.Inst.Index,

        fn tag(it: *@This(), inst_index: Air.Inst.Index) Air.Inst.Tag {
            return it.tag_items[@backingInt(inst_index)];
        }

        fn data(it: *@This(), inst_index: Air.Inst.Index) Air.Inst.Data {
            return it.data_items[@backingInt(inst_index)];
        }

        fn next(it: *@This()) ?Air.Inst.Tag {
            if (it.body_index == 0) {
                @branchHint(.unlikely);
                return null;
            }
            it.body_index -= 1;
            it.inst_index = it.body[it.body_index];
            wip_mir_log.debug("{f}", .{it.fmtAir(it.inst_index)});
            return it.tag(it.inst_index);
        }

        fn fmtAir(it: @This(), inst: Air.Inst.Index) struct {
            isel: *Select,
            inst: Air.Inst.Index,
            pub fn format(fmt_air: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                fmt_air.isel.air.writeInst(writer, fmt_air.inst, fmt_air.isel.pt.zcu, null);
            }
        } {
            return .{ .isel = it.isel, .inst = inst };
        }
    } = .{
        .isel = isel,
        .tag_items = isel.air.instructions.items(.tag),
        .data_items = isel.air.instructions.items(.data),
        .body = air_body,
        .body_index = @intCast(air_body.len),
        .inst_index = undefined,
    };
    air_tag: switch (air.next().?) {
        else => |air_tag| return isel.fail("unimplemented {t}", .{air_tag}),

        .legalize_vec_elem_val => {
            if (isel.live_values.fetchRemove(air.inst_index)) |elem_vi| {
                defer elem_vi.value.deref(isel);
                const bin_op = air.data(air.inst_index).bin_op;
                try isel.vectorMemoryDynamic(elem_vi.value, bin_op.lhs, bin_op.rhs, false);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .legalize_vec_store_elem => {
            const pl_op = air.data(air.inst_index).pl_op;
            const bin_op = isel.air.extraData(Air.Bin, pl_op.payload).data;
            try isel.vectorMemoryDynamic(try isel.use(bin_op.rhs), pl_op.operand, bin_op.lhs, true);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },

        .arg => {
            const arg_vi = isel.live_values.fetchRemove(air.inst_index).?.value;
            defer arg_vi.deref(isel);
            if (isel.vectorAbi(isel.air.typeOfIndex(air.inst_index, ip))) |info| {
                try isel.vectorAbiArgument(arg_vi, info);
                if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
                break :air_tag;
            }
            switch (arg_vi.parent(isel)) {
                .unallocated, .stack_slot => if (arg_vi.hint(isel)) |arg_ra| {
                    try arg_vi.defLiveIn(isel, arg_ra, comptime &.initFill(.free));
                } else {
                    var arg_part_it = arg_vi.parts(isel);
                    while (arg_part_it.next()) |arg_part| {
                        if (arg_part.hint(isel)) |arg_ra|
                            try arg_part.defLiveIn(isel, arg_ra, comptime &.initFill(.free));
                    }
                },
                .value, .constant, .stack_address => unreachable,
                .address => |address_vi| if (address_vi.hint(isel)) |arg_ra| {
                    try address_vi.defLiveIn(isel, arg_ra, comptime &.initFill(.free));
                },
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .add, .add_safe, .add_optimized, .add_wrap, .sub, .sub_safe, .sub_optimized, .sub_wrap => |air_tag| {
            try isel.selectAddSub(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .add_sat, .sub_sat => |air_tag| {
            try isel.selectAddSubSat(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .mul, .mul_optimized, .mul_wrap => |air_tag| {
            try isel.selectMul(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .mul_safe => {
            if (try isel.checkedDef(air.inst_index)) |res_vi| {
                defer res_vi.deref(isel);
                const bin_op = air.data(air.inst_index).bin_op;
                const ty = isel.air.typeOf(bin_op.lhs, ip);
                if (ty.isAbiInt(zcu) and ty.intInfo(zcu).bits > 128) return isel.fail("too big {t} {f}", .{ air.tag(air.inst_index), isel.fmtType(ty) });
                const overflow_ra = try isel.allocIntReg();
                defer isel.freeReg(overflow_ra);
                const skip_label = isel.instructions.items.len;
                try isel.emitPanic(.integer_overflow);
                try isel.emit(.cbz(overflow_ra.w(), @intCast((isel.instructions.items.len + 1 - skip_label) << 2)));
                try isel.multiplyWithOverflow(res_vi, overflow_ra, ty, bin_op.lhs, bin_op.rhs);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .mul_sat => |air_tag| {
            try isel.selectMulSat(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .div_float, .div_float_optimized => {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| unused: {
                defer res_vi.value.deref(isel);

                const bin_op = air.data(air.inst_index).bin_op;
                const ty = isel.air.typeOf(bin_op.lhs, ip);
                switch (ty.floatBits(isel.target)) {
                    else => unreachable,
                    16, 32, 64 => |bits| {
                        const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                        const need_fcvt = switch (bits) {
                            else => unreachable,
                            16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                            32, 64 => false,
                        };
                        if (need_fcvt) try isel.emit(.fcvt(res_ra.h(), res_ra.s()));
                        const lhs_vi = try isel.use(bin_op.lhs);
                        const rhs_vi = try isel.use(bin_op.rhs);
                        const lhs_mat = try lhs_vi.matReg(isel);
                        const rhs_mat = try rhs_vi.matReg(isel);
                        const lhs_ra = if (need_fcvt) try isel.allocVecReg() else lhs_mat.ra;
                        defer if (need_fcvt) isel.freeReg(lhs_ra);
                        const rhs_ra = if (need_fcvt) try isel.allocVecReg() else rhs_mat.ra;
                        defer if (need_fcvt) isel.freeReg(rhs_ra);
                        try isel.emit(bits: switch (bits) {
                            else => unreachable,
                            16 => if (need_fcvt)
                                continue :bits 32
                            else
                                .fdiv(res_ra.h(), lhs_ra.h(), rhs_ra.h()),
                            32 => .fdiv(res_ra.s(), lhs_ra.s(), rhs_ra.s()),
                            64 => .fdiv(res_ra.d(), lhs_ra.d(), rhs_ra.d()),
                        });
                        if (need_fcvt) {
                            try isel.emit(.fcvt(rhs_ra.s(), rhs_mat.ra.h()));
                            try isel.emit(.fcvt(lhs_ra.s(), lhs_mat.ra.h()));
                        }
                        try rhs_mat.finish(isel);
                        try lhs_mat.finish(isel);
                    },
                    80, 128 => |bits| {
                        try call.compilerRt(isel, switch (bits) {
                            else => unreachable,
                            16 => "__divhf3",
                            32 => "__divsf3",
                            64 => "__divdf3",
                            80 => "__divxf3",
                            128 => "__divtf3",
                        }, res_vi.value, ty, &.{ bin_op.lhs, bin_op.rhs });
                    },
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .div_trunc,
        .div_trunc_optimized,
        .div_floor,
        .div_floor_optimized,
        .div_ceil,
        .div_ceil_optimized,
        .div_exact,
        .div_exact_optimized,
        => |air_tag| {
            try isel.selectDiv(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .rem, .rem_optimized, .mod, .mod_optimized => |air_tag| {
            try isel.selectRemMod(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .ptr_add, .ptr_sub => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| unused: {
                defer res_vi.value.deref(isel);
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const ptr_result_lock = isel.tryLockReg(res_ra);
                defer ptr_result_lock.unlock(isel);

                const ty_pl = air.data(air.inst_index).ty_pl;
                const bin_op = isel.air.extraData(Air.Bin, ty_pl.payload).data;
                const elem_size = ty_pl.ty.childType(zcu).abiSize(zcu);

                const base_vi = try isel.use(bin_op.lhs);
                var base_part_it = base_vi.field(ty_pl.ty, 0, 8);
                const base_part_vi = try base_part_it.only(isel);
                const base_part_mat = try base_part_vi.?.matReg(isel);
                const index_vi = try isel.use(bin_op.rhs);
                try isel.elemPtr(res_ra, base_part_mat.ra, switch (air_tag) {
                    else => unreachable,
                    .ptr_add => .add,
                    .ptr_sub => .sub,
                }, elem_size, index_vi);
                try base_part_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .max, .min => |air_tag| {
            try isel.selectMinMax(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .mul_with_overflow, .shl_with_overflow => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| {
                defer res_vi.value.deref(isel);
                const ty_pl = air.data(air.inst_index).ty_pl;
                const bin_op = isel.air.extraData(Air.Bin, ty_pl.payload).data;
                const ty = isel.air.typeOf(bin_op.lhs, ip);
                const ty_size = ty.abiSize(zcu);
                var overflow_it = res_vi.value.field(ty_pl.ty, ty_size, 1);
                const overflow_vi = try overflow_it.only(isel);
                if (ty.isAbiInt(zcu)) {
                    const bits = ty.intInfo(zcu).bits;
                    if (bits > 128 or (air_tag == .shl_with_overflow and bits > 64)) return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) });
                }
                const maybe_overflow_ra = try overflow_vi.?.defReg(isel);
                const overflow_ra = maybe_overflow_ra orelse try isel.allocIntReg();
                defer if (maybe_overflow_ra == null) isel.freeReg(overflow_ra);
                const overflow_lock = isel.tryLockReg(overflow_ra);
                defer overflow_lock.unlock(isel);
                var wrapped_it = res_vi.value.field(ty_pl.ty, 0, ty_size);
                const wrapped_vi = try wrapped_it.only(isel);
                switch (air_tag) {
                    .mul_with_overflow => try isel.multiplyWithOverflow(wrapped_vi.?, overflow_ra, ty, bin_op.lhs, bin_op.rhs),
                    .shl_with_overflow => try isel.shiftWithOverflow(wrapped_vi.?, overflow_ra, ty, bin_op.lhs, bin_op.rhs),
                    else => unreachable,
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .add_with_overflow, .sub_with_overflow => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| {
                defer res_vi.value.deref(isel);

                const ty_pl = air.data(air.inst_index).ty_pl;
                const bin_op = isel.air.extraData(Air.Bin, ty_pl.payload).data;
                const ty = isel.air.typeOf(bin_op.lhs, ip);
                const lhs_vi = try isel.use(bin_op.lhs);
                const rhs_vi = try isel.use(bin_op.rhs);
                const ty_size = lhs_vi.size(isel);
                var overflow_it = res_vi.value.field(ty_pl.ty, ty_size, 1);
                const overflow_vi = try overflow_it.only(isel);
                var wrapped_it = res_vi.value.field(ty_pl.ty, 0, ty_size);
                const wrapped_vi = try wrapped_it.only(isel);
                try wrapped_vi.?.addOrSubtract(isel, ty, lhs_vi, switch (air_tag) {
                    else => unreachable,
                    .add_with_overflow => .add,
                    .sub_with_overflow => .sub,
                }, rhs_vi, .{
                    .overflow = if (try overflow_vi.?.defReg(isel)) |overflow_ra| .{ .ra = overflow_ra } else .wrap,
                });
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .alloc, .ret_ptr => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |ptr_vi| unused: {
                defer ptr_vi.value.deref(isel);
                // Every use already rematerialized the address.
                if (ptr_vi.value.parent(isel) == .stack_address) break :unused;
                switch (air_tag) {
                    else => unreachable,
                    .alloc => {},
                    .ret_ptr => if (isel.live_values.get(Block.main)) |ret_vi| switch (ret_vi.parent(isel)) {
                        .unallocated, .stack_slot => {},
                        .value, .constant, .stack_address => unreachable,
                        .address => break :unused,
                    },
                }
                const ptr_ra = try ptr_vi.value.defReg(isel) orelse break :unused;

                const ty = air.data(air.inst_index).ty;
                const slot_size = ty.childType(zcu).abiSize(zcu);
                const slot_align = ty.ptrAlignment(zcu);
                const slot_offset = slot_align.forward(isel.stack_size);
                isel.stack_size = @intCast(slot_offset + slot_size);
                try isel.addSubImmediate(.add, ptr_ra.x(), .sp, slot_offset, .{ .scratch = ptr_ra.x() });
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .inferred_alloc, .inferred_alloc_comptime => unreachable,
        .assembly => {
            try isel.selectAsm(air.inst_index);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .bit_and, .bit_or, .xor => |air_tag| {
            try isel.selectBitwise(air.inst_index, air_tag, air.body[0..air.body_index]);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .shl_sat => {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| {
                defer res_vi.value.deref(isel);
                const bin_op = air.data(air.inst_index).bin_op;
                try isel.shiftSaturating(res_vi.value, isel.air.typeOf(bin_op.lhs, ip), bin_op.lhs, bin_op.rhs);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .shr, .shr_exact, .shl, .shl_exact => |air_tag| {
            try isel.selectShift(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .not => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| unused: {
                defer res_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const ty = ty_op.ty;
                if (ty.isVector(zcu)) {
                    const arrangement = isel.simdIntArrangement(ty) orelse
                        return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
                    const bytes: Register.Arrangement = switch (arrangement.size()) {
                        .double => .@"8b",
                        .quad => .@"16b",
                    };
                    const res_def = try isel.defVector(res_vi.value) orelse break :unused;
                    defer res_def.finish(isel);
                    const src_mat = try (try isel.use(ty_op.operand)).matReg(isel);
                    try isel.emit(.not(res_def.ra.vector(bytes), src_mat.ra.vector(bytes)));
                    try src_mat.finish(isel);
                    break :unused;
                }
                const int_info: std.lang.Type.Int = int_info: {
                    if (ty_op.ty.ip_index == .bool_type) break :int_info .{ .signedness = .unsigned, .bits = 1 };
                    if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
                    break :int_info ty.intInfo(zcu);
                };
                if (int_info.bits > 128) return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) });

                const src_vi = try isel.use(ty_op.operand);
                var offset = res_vi.value.size(isel);
                while (offset > 0) {
                    const size = @min(offset, 8);
                    offset -= size;
                    var res_part_it = res_vi.value.field(ty, offset, size);
                    const res_part_vi = try res_part_it.only(isel);
                    const res_part_ra = try res_part_vi.?.defReg(isel) orelse continue;
                    var src_part_it = src_vi.field(ty, offset, size);
                    const src_part_vi = try src_part_it.only(isel);
                    const src_part_mat = try src_part_vi.?.matReg(isel);
                    try isel.emit(switch (int_info.signedness) {
                        .signed => switch (size) {
                            else => unreachable,
                            1, 2, 4 => .orn(res_part_ra.w(), .wzr, .{ .register = src_part_mat.ra.w() }),
                            8 => .orn(res_part_ra.x(), .xzr, .{ .register = src_part_mat.ra.x() }),
                        },
                        .unsigned => switch (@min(int_info.bits - 8 * offset, 64)) {
                            else => unreachable,
                            1...31 => |bits| .eor(res_part_ra.w(), src_part_mat.ra.w(), .{ .immediate = .{
                                .N = .word,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            } }),
                            32 => .orn(res_part_ra.w(), .wzr, .{ .register = src_part_mat.ra.w() }),
                            33...63 => |bits| .eor(res_part_ra.x(), src_part_mat.ra.x(), .{ .immediate = .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            } }),
                            64 => .orn(res_part_ra.x(), .xzr, .{ .register = src_part_mat.ra.x() }),
                        },
                    });
                    try src_part_mat.finish(isel);
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .bit_cast,
        .bit_cast_safe, // TODO safety check
        .ptr_cast,
        .ptr_from_int,
        .int_from_ptr,
        .error_cast,
        .error_from_int,
        .int_from_error,
        .union_from_enum,
        => |air_tag| {
            try isel.selectBitCast(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .block => {
            const unwrapped_block = isel.air.unwrapBlock(air.inst_index);
            try isel.block(air.inst_index, unwrapped_block.ty, unwrapped_block.body, pred: {
                var body_index = air.body_index;
                while (body_index > 0) {
                    body_index -= 1;
                    const body_inst = air.body[body_index];
                    switch (air.tag(body_inst)) {
                        else => break :pred body_inst,
                        .dbg_stmt, .dbg_empty_stmt => {},
                    }
                }
                break :pred null;
            });
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .loop => {
            const unwrapped_block = isel.air.unwrapBlock(air.inst_index);
            const loops = isel.loops.values();
            const loop_index = isel.loops.getIndex(air.inst_index).?;
            const loop = &loops[loop_index];

            tracking_log.debug("{f}", .{
                isel.fmtDom(air.inst_index, loop.dom, @intCast(isel.blocks.count())),
            });
            tracking_log.debug("{f}", .{isel.fmtLoopLive(air.inst_index)});
            assert(loop.depth == isel.blocks.count());

            if (false) {
                // loops are dumb...
                for (isel.loop_live.list.items[loop.live..loops[loop_index + 1].live]) |live_inst| {
                    const live_vi = try isel.use(live_inst.toRef());
                    try live_vi.mat(isel);
                }

                // IT'S DOM TIME!!!
                for (isel.blocks.values(), 0..) |*dom_block, dom_index| {
                    if (@as(u1, @truncate(isel.dom.items[
                        loop.dom + dom_index / @bitSizeOf(DomInt)
                    ] >> @truncate(dom_index))) == 0) continue;
                    var live_reg_it = dom_block.live_registers.iterator();
                    while (live_reg_it.next()) |live_reg_entry| switch (live_reg_entry.value.*) {
                        _ => |live_vi| try live_vi.mat(isel),
                        .allocating => unreachable,
                        .free => {},
                    };
                }
            }

            loop.live_registers = isel.live_registers;
            loop.repeat_list = Loop.empty_list;
            try isel.body(unwrapped_block.body, null);
            try isel.merge(&loop.live_registers, .{ .fill_extra = true });

            assert(loop.repeat_list != Loop.empty_list);
            loop.patchRepeats(isel);

            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .repeat => {
            const repeat = air.data(air.inst_index).repeat;
            try isel.loops.getPtr(repeat.loop_inst).?.branch(isel);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .switch_dispatch => {
            const br = air.data(air.inst_index).br;
            try isel.loops.getPtr(br.block_inst).?.branch(isel);
            const cond_vi = isel.live_values.get(br.block_inst).?;
            const slot = cond_vi.parent(isel).stack_slot;
            const cond_ty = isel.air.typeOf(isel.air.unwrapSwitch(br.block_inst).operand, ip);
            const operand_vi = try isel.use(br.operand);
            try operand_vi.store(isel, cond_ty, slot.base, .{ .offset = @intCast(slot.offset) });
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .br => {
            const br = air.data(air.inst_index).br;
            try isel.blocks.getPtr(br.block_inst).?.branch(isel);
            if (isel.live_values.get(br.block_inst)) |dst_vi| try dst_vi.move(isel, br.operand);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .trap => {
            try isel.emit(.brk(0x1));
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .breakpoint => {
            try isel.emit(.brk(0xf000));
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .ret_addr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |addr_vi| unused: {
                defer addr_vi.value.deref(isel);
                const addr_ra = try addr_vi.value.defReg(isel) orelse break :unused;
                try isel.emit(.ldr(addr_ra.x(), .{ .unsigned_offset = .{ .base = .fp, .offset = 8 } }));
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .frame_addr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |addr_vi| unused: {
                defer addr_vi.value.deref(isel);
                const addr_ra = try addr_vi.value.defReg(isel) orelse break :unused;
                try isel.emit(.orr(addr_ra.x(), .xzr, .{ .register = .fp }));
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .call_always_tail => {
            try isel.tailCall(air.inst_index);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .call, .call_never_tail, .call_never_inline, .legalize_compiler_rt_call => {
            const call_info = isel.callInfo(air.inst_index);

            try call.prepareReturn(isel);
            const maybe_def_ret_vi = isel.live_values.fetchRemove(air.inst_index);
            var maybe_ret_addr_vi: ?Value.Index = null;
            if (maybe_def_ret_vi) |def_ret_vi| {
                defer def_ret_vi.value.deref(isel);

                var ret_it: CallAbiIterator = .init;
                const ret_vi = try ret_it.ret(isel, isel.air.typeOfIndex(air.inst_index, ip));
                defer ret_vi.?.deref(isel);
                switch (ret_vi.?.parent(isel)) {
                    .unallocated, .stack_slot => if (ret_vi.?.hint(isel)) |ret_ra| {
                        try call.returnLiveIn(isel, def_ret_vi.value, ret_ra);
                        if (isel.vectorAbi(isel.air.typeOfIndex(air.inst_index, ip))) |info|
                            try isel.vectorAbiAdapt(info, ret_ra, true);
                    } else {
                        var def_ret_part_it = def_ret_vi.value.parts(isel);
                        var ret_part_it = ret_vi.?.parts(isel);
                        if (def_ret_part_it.only()) |_| {
                            try isel.values.ensureUnusedCapacity(gpa, ret_part_it.remaining);
                            def_ret_vi.value.setParts(isel, ret_part_it.remaining);
                            while (ret_part_it.next()) |ret_part_vi| {
                                const def_ret_part_vi = def_ret_vi.value.addPart(
                                    isel,
                                    ret_part_vi.get(isel).offset_from_parent,
                                    ret_part_vi.size(isel),
                                );
                                if (ret_part_vi.isVector(isel)) def_ret_part_vi.setIsVector(isel);
                                if (ret_part_vi.signedness(isel) == .signed) def_ret_part_vi.setSignedness(isel, .signed);
                            }
                            def_ret_part_it = def_ret_vi.value.parts(isel);
                            ret_part_it = ret_vi.?.parts(isel);
                        }
                        while (def_ret_part_it.next()) |ret_part_vi| {
                            try call.returnLiveIn(isel, ret_part_vi, ret_part_it.next().?.hint(isel).?);
                        }
                    },
                    .value, .constant, .stack_address => unreachable,
                    .address => |address_vi| {
                        maybe_ret_addr_vi = address_vi;
                        _ = try def_ret_vi.value.defAddr(isel, isel.air.typeOfIndex(air.inst_index, ip), .{
                            .expected_live_registers = &call.caller_saved_regs,
                        });
                    },
                }
            }
            try call.finishReturn(isel);

            try call.prepareCallee(isel);
            if (call_info.callee == .global) {
                try call.global(isel, call_info.callee.global);
            } else if (call_info.callee.value.toInterned()) |ct_callee| {
                const callee_reloc: codegen.aarch64.Mir.Reloc.Nav = switch (ip.indexToKey(ct_callee)) {
                    else => unreachable,
                    inline .@"extern", .func => |func| .{
                        .nav = func.owner_nav,
                        .reloc = .{ .label = @intCast(isel.instructions.items.len) },
                    },
                    .ptr => |ptr| .{
                        .nav = ptr.base_addr.nav,
                        .reloc = .{
                            .label = @intCast(isel.instructions.items.len),
                            .addend = ptr.byte_offset,
                        },
                    },
                };
                if (zcu.comp.config.any_non_single_threaded and ip.getNav(callee_reloc.nav).resolved.?.@"threadlocal")
                    return isel.fail("thread-local function call", .{});
                try isel.nav_relocs.append(gpa, callee_reloc);
                try isel.emit(.bl(0));
            } else {
                const callee_vi = try isel.use(call_info.callee.value);
                const callee_mat = try callee_vi.matReg(isel);
                try isel.emit(.blr(callee_mat.ra.x()));
                try callee_mat.finish(isel);
            }
            try call.finishCallee(isel);

            try call.prepareParams(isel);
            if (maybe_ret_addr_vi) |ret_addr_vi| try call.paramAddress(
                isel,
                maybe_def_ret_vi.?.value,
                ret_addr_vi.hint(isel).?,
            );
            _ = try isel.callArguments(call_info, false);
            try call.finishParams(isel);

            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .clz => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| unused: {
                defer res_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const ty = isel.air.typeOf(ty_op.operand, ip);
                if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
                const int_info = ty.intInfo(zcu);
                switch (int_info.bits) {
                    0 => unreachable,
                    1...64 => {
                        const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(ty_op.operand);
                        const src_mat = try src_vi.matReg(isel);
                        try isel.clzLimb(res_ra, int_info, src_mat.ra);
                        try src_mat.finish(isel);
                    },
                    65...128 => |bits| {
                        const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(ty_op.operand);
                        var src_hi64_it = src_vi.field(ty, 8, 8);
                        const src_hi64_vi = try src_hi64_it.only(isel);
                        const src_hi64_mat = try src_hi64_vi.?.matReg(isel);
                        var src_lo64_it = src_vi.field(ty, 0, 8);
                        const src_lo64_vi = try src_lo64_it.only(isel);
                        const src_lo64_mat = try src_lo64_vi.?.matReg(isel);
                        const lo64_ra = try isel.allocIntReg();
                        defer isel.freeReg(lo64_ra);
                        const hi64_ra = try isel.allocIntReg();
                        defer isel.freeReg(hi64_ra);
                        try isel.emit(.csel(res_ra.w(), lo64_ra.w(), hi64_ra.w(), .eq));
                        try isel.emit(.add(lo64_ra.w(), lo64_ra.w(), .{ .immediate = @intCast(bits - 64) }));
                        try isel.emit(.subs(.xzr, src_hi64_mat.ra.x(), .{ .immediate = 0 }));
                        try isel.clzLimb(hi64_ra, .{ .signedness = int_info.signedness, .bits = bits - 64 }, src_hi64_mat.ra);
                        try isel.clzLimb(lo64_ra, .{ .signedness = .unsigned, .bits = 64 }, src_lo64_mat.ra);
                        try src_hi64_mat.finish(isel);
                        try src_lo64_mat.finish(isel);
                    },
                    else => return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) }),
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .ctz => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| unused: {
                defer res_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const ty = isel.air.typeOf(ty_op.operand, ip);
                if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
                const int_info = ty.intInfo(zcu);
                switch (int_info.bits) {
                    0 => unreachable,
                    1...64 => {
                        const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(ty_op.operand);
                        const src_mat = try src_vi.matReg(isel);
                        try isel.ctzLimb(res_ra, int_info, src_mat.ra);
                        try src_mat.finish(isel);
                    },
                    65...128 => |bits| {
                        const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(ty_op.operand);
                        var src_hi64_it = src_vi.field(ty, 8, 8);
                        const src_hi64_vi = try src_hi64_it.only(isel);
                        const src_hi64_mat = try src_hi64_vi.?.matReg(isel);
                        var src_lo64_it = src_vi.field(ty, 0, 8);
                        const src_lo64_vi = try src_lo64_it.only(isel);
                        const src_lo64_mat = try src_lo64_vi.?.matReg(isel);
                        const lo64_ra = try isel.allocIntReg();
                        defer isel.freeReg(lo64_ra);
                        const hi64_ra = try isel.allocIntReg();
                        defer isel.freeReg(hi64_ra);
                        try isel.emit(.csel(res_ra.w(), lo64_ra.w(), hi64_ra.w(), .ne));
                        try isel.emit(.add(hi64_ra.w(), hi64_ra.w(), .{ .immediate = 64 }));
                        try isel.emit(.subs(.xzr, src_lo64_mat.ra.x(), .{ .immediate = 0 }));
                        try isel.ctzLimb(hi64_ra, .{ .signedness = int_info.signedness, .bits = bits - 64 }, src_hi64_mat.ra);
                        try isel.ctzLimb(lo64_ra, .{ .signedness = .unsigned, .bits = 64 }, src_lo64_mat.ra);
                        try src_hi64_mat.finish(isel);
                        try src_lo64_mat.finish(isel);
                    },
                    else => return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) }),
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .popcount => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| unused: {
                defer res_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const ty = isel.air.typeOf(ty_op.operand, ip);
                if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
                const int_info = ty.intInfo(zcu);
                if (int_info.bits > 128) return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) });
                if (int_info.bits > 64) {
                    const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    var src_hi_it = src_vi.field(ty, 8, 8);
                    const src_hi_mat = try (try src_hi_it.only(isel)).?.matReg(isel);
                    var src_lo_it = src_vi.field(ty, 0, 8);
                    const src_lo_mat = try (try src_lo_it.only(isel)).?.matReg(isel);
                    const vec_ra = try isel.allocVecReg();
                    defer isel.freeReg(vec_ra);
                    const hi_ra = if (int_info.bits < 128) try isel.allocIntReg() else src_hi_mat.ra;
                    defer if (int_info.bits < 128) isel.freeReg(hi_ra);
                    try isel.emit(.umov(res_ra.w(), vec_ra.@"b[]"(0)));
                    try isel.emit(.addv(vec_ra.b(), vec_ra.@"16b"()));
                    try isel.emit(.cnt(vec_ra.@"16b"(), vec_ra.@"16b"()));
                    try isel.emit(.fmov(vec_ra.@"d[]"(1), .{ .register = hi_ra.x() }));
                    try isel.emit(.fmov(vec_ra.d(), .{ .register = src_lo_mat.ra.x() }));
                    // Signed integers are sign-extended past their bits.
                    if (int_info.bits < 128) try isel.normalizeIntReg(hi_ra, src_hi_mat.ra, .{
                        .signedness = .unsigned,
                        .bits = int_info.bits - 64,
                    });
                    try src_lo_mat.finish(isel);
                    try src_hi_mat.finish(isel);
                    break :unused;
                }

                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = try src_vi.matReg(isel);
                const vec_ra = try isel.allocVecReg();
                defer isel.freeReg(vec_ra);
                try isel.emit(.umov(res_ra.w(), vec_ra.@"b[]"(0)));
                switch (int_info.bits) {
                    else => unreachable,
                    1...8 => {},
                    9...16 => try isel.emit(.addp(vec_ra.@"8b"(), vec_ra.@"8b"(), .{ .vector = vec_ra.@"8b"() })),
                    17...64 => try isel.emit(.addv(vec_ra.b(), vec_ra.@"8b"())),
                }
                try isel.emit(.cnt(vec_ra.@"8b"(), vec_ra.@"8b"()));
                switch (int_info.bits) {
                    else => unreachable,
                    1...31 => |bits| switch (int_info.signedness) {
                        .signed => {
                            try isel.emit(.fmov(vec_ra.s(), .{ .register = res_ra.w() }));
                            try isel.emit(.ubfm(res_ra.w(), src_mat.ra.w(), .{
                                .N = .word,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            }));
                        },
                        .unsigned => try isel.emit(.fmov(vec_ra.s(), .{ .register = src_mat.ra.w() })),
                    },
                    32 => try isel.emit(.fmov(vec_ra.s(), .{ .register = src_mat.ra.w() })),
                    33...63 => |bits| switch (int_info.signedness) {
                        .signed => {
                            try isel.emit(.fmov(vec_ra.d(), .{ .register = res_ra.x() }));
                            try isel.emit(.ubfm(res_ra.x(), src_mat.ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            }));
                        },
                        .unsigned => try isel.emit(.fmov(vec_ra.d(), .{ .register = src_mat.ra.x() })),
                    },
                    64 => try isel.emit(.fmov(vec_ra.d(), .{ .register = src_mat.ra.x() })),
                }
                try src_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .byte_swap => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| unused: {
                defer res_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const ty = ty_op.ty;
                if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
                const int_info = ty.intInfo(zcu);
                if (int_info.bits > 128) return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) });
                if (int_info.bits > 64) {
                    const high_bits: u7 = @intCast(int_info.bits - 64);
                    const res_pair: DefPair = try .init(isel, res_vi.value, ty);
                    defer res_pair.deinit(isel);
                    if (res_pair.unused()) break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    var src_lo_it = src_vi.field(ty, 0, 8);
                    const src_lo_mat = try (try src_lo_it.only(isel)).?.matReg(isel);
                    var src_hi_it = src_vi.field(ty, 8, 8);
                    const src_hi_mat = try (try src_hi_it.only(isel)).?.matReg(isel);
                    const rev_lo_ra = try isel.allocIntReg();
                    defer isel.freeReg(rev_lo_ra);
                    const rev_hi_ra = try isel.allocIntReg();
                    defer isel.freeReg(rev_hi_ra);
                    if (res_pair.hi) |ra| try isel.emit(switch (int_info.signedness) {
                        .signed => .sbfm(ra.x(), rev_lo_ra.x(), .{ .N = .doubleword, .immr = @intCast(64 - high_bits), .imms = 63 }),
                        .unsigned => .ubfm(ra.x(), rev_lo_ra.x(), .{ .N = .doubleword, .immr = @intCast(64 - high_bits), .imms = 63 }),
                    });
                    if (res_pair.lo) |ra| {
                        if (high_bits < 64) try isel.emit(.orr(
                            ra.x(),
                            ra.x(),
                            .{ .shifted_register = .{ .register = rev_lo_ra.x(), .shift = .{ .lsl = @intCast(high_bits) } } },
                        ));
                        try isel.emit(.ubfm(ra.x(), rev_hi_ra.x(), .{ .N = .doubleword, .immr = @intCast(64 - high_bits), .imms = 63 }));
                    }
                    try isel.emit(.rev(rev_hi_ra.x(), src_hi_mat.ra.x()));
                    try isel.emit(.rev(rev_lo_ra.x(), src_lo_mat.ra.x()));
                    try src_hi_mat.finish(isel);
                    try src_lo_mat.finish(isel);
                    break :unused;
                }

                if (int_info.bits == 8) break :unused try res_vi.value.move(isel, ty_op.operand);
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = try src_vi.matReg(isel);
                switch (int_info.bits) {
                    else => unreachable,
                    16 => switch (int_info.signedness) {
                        .signed => {
                            try isel.emit(.sbfm(res_ra.w(), res_ra.w(), .{
                                .N = .word,
                                .immr = 32 - 16,
                                .imms = 32 - 1,
                            }));
                            try isel.emit(.rev(res_ra.w(), src_mat.ra.w()));
                        },
                        .unsigned => try isel.emit(.rev16(res_ra.w(), src_mat.ra.w())),
                    },
                    24 => {
                        switch (int_info.signedness) {
                            .signed => try isel.emit(.sbfm(res_ra.w(), res_ra.w(), .{
                                .N = .word,
                                .immr = 32 - 24,
                                .imms = 32 - 1,
                            })),
                            .unsigned => try isel.emit(.ubfm(res_ra.w(), res_ra.w(), .{
                                .N = .word,
                                .immr = 32 - 24,
                                .imms = 32 - 1,
                            })),
                        }
                        try isel.emit(.rev(res_ra.w(), src_mat.ra.w()));
                    },
                    32 => try isel.emit(.rev(res_ra.w(), src_mat.ra.w())),
                    40, 48, 56 => |bits| {
                        switch (int_info.signedness) {
                            .signed => try isel.emit(.sbfm(res_ra.x(), res_ra.x(), .{
                                .N = .doubleword,
                                .immr = @intCast(64 - bits),
                                .imms = 64 - 1,
                            })),
                            .unsigned => try isel.emit(.ubfm(res_ra.x(), res_ra.x(), .{
                                .N = .doubleword,
                                .immr = @intCast(64 - bits),
                                .imms = 64 - 1,
                            })),
                        }
                        try isel.emit(.rev(res_ra.x(), src_mat.ra.x()));
                    },
                    64 => try isel.emit(.rev(res_ra.x(), src_mat.ra.x())),
                }
                try src_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .bit_reverse => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| unused: {
                defer res_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const ty = ty_op.ty;
                if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
                const int_info = ty.intInfo(zcu);
                if (int_info.bits > 128) return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) });
                if (int_info.bits > 64) {
                    const res_pair: DefPair = try .init(isel, res_vi.value, ty);
                    defer res_pair.deinit(isel);
                    if (res_pair.unused()) break :unused;
                    const rev_hi_ra = try isel.allocIntReg();
                    defer isel.freeReg(rev_hi_ra);
                    const rev_lo_ra = try isel.allocIntReg();
                    defer isel.freeReg(rev_lo_ra);
                    const src_vi = try isel.use(ty_op.operand);
                    var src_hi_it = src_vi.field(ty, 8, 8);
                    const src_hi_mat = try (try src_hi_it.only(isel)).?.matReg(isel);
                    var src_lo_it = src_vi.field(ty, 0, 8);
                    const src_lo_mat = try (try src_lo_it.only(isel)).?.matReg(isel);
                    // Reverse all 128 bits, then shift the padding back out.
                    const shift: u6 = @intCast(128 - int_info.bits);
                    if (res_pair.hi) |ra| try isel.emit(if (shift == 0)
                        .orr(ra.x(), .xzr, .{ .register = rev_hi_ra.x() })
                    else switch (int_info.signedness) {
                        .signed => .sbfm(ra.x(), rev_hi_ra.x(), .{ .N = .doubleword, .immr = shift, .imms = 63 }),
                        .unsigned => .ubfm(ra.x(), rev_hi_ra.x(), .{ .N = .doubleword, .immr = shift, .imms = 63 }),
                    });
                    if (res_pair.lo) |ra| try isel.emit(if (shift == 0)
                        .orr(ra.x(), .xzr, .{ .register = rev_lo_ra.x() })
                    else
                        .extr(ra.x(), rev_hi_ra.x(), rev_lo_ra.x(), shift));
                    try isel.emit(.rbit(rev_lo_ra.x(), src_hi_mat.ra.x()));
                    try isel.emit(.rbit(rev_hi_ra.x(), src_lo_mat.ra.x()));
                    try src_lo_mat.finish(isel);
                    try src_hi_mat.finish(isel);
                    break :unused;
                }

                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = try src_vi.matReg(isel);
                switch (int_info.bits) {
                    else => unreachable,
                    1...31 => |bits| {
                        switch (int_info.signedness) {
                            .signed => try isel.emit(.sbfm(res_ra.w(), res_ra.w(), .{
                                .N = .word,
                                .immr = @intCast(32 - bits),
                                .imms = 32 - 1,
                            })),
                            .unsigned => try isel.emit(.ubfm(res_ra.w(), res_ra.w(), .{
                                .N = .word,
                                .immr = @intCast(32 - bits),
                                .imms = 32 - 1,
                            })),
                        }
                        try isel.emit(.rbit(res_ra.w(), src_mat.ra.w()));
                    },
                    32 => try isel.emit(.rbit(res_ra.w(), src_mat.ra.w())),
                    33...63 => |bits| {
                        switch (int_info.signedness) {
                            .signed => try isel.emit(.sbfm(res_ra.x(), res_ra.x(), .{
                                .N = .doubleword,
                                .immr = @intCast(64 - bits),
                                .imms = 64 - 1,
                            })),
                            .unsigned => try isel.emit(.ubfm(res_ra.x(), res_ra.x(), .{
                                .N = .doubleword,
                                .immr = @intCast(64 - bits),
                                .imms = 64 - 1,
                            })),
                        }
                        try isel.emit(.rbit(res_ra.x(), src_mat.ra.x()));
                    },
                    64 => try isel.emit(.rbit(res_ra.x(), src_mat.ra.x())),
                }
                try src_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .sqrt, .floor, .ceil, .round, .trunc_float => |air_tag| {
            try isel.selectFloatRounding(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10 => |air_tag| {
            try isel.selectFloatLibCall(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .abs => |air_tag| {
            try isel.selectAbs(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .neg, .neg_optimized => {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| unused: {
                defer res_vi.value.deref(isel);

                const un_op = air.data(air.inst_index).un_op;
                const ty = isel.air.typeOf(un_op, ip);
                switch (ty.floatBits(isel.target)) {
                    else => unreachable,
                    16 => {
                        const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(un_op);
                        const src_mat = try src_vi.matReg(isel);
                        if (isel.target.cpu.has(.aarch64, .fullfp16)) {
                            try isel.emit(.fneg(res_ra.h(), src_mat.ra.h()));
                        } else {
                            const neg_zero_ra = try isel.allocVecReg();
                            defer isel.freeReg(neg_zero_ra);
                            try isel.emit(.eor(res_ra.@"8b"(), src_mat.ra.@"8b"(), .{ .register = neg_zero_ra.@"8b"() }));
                            try isel.emit(.movi(neg_zero_ra.@"4h"(), 0b10000000, .{ .lsl = 8 }));
                        }
                        try src_mat.finish(isel);
                    },
                    32 => {
                        const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(un_op);
                        const src_mat = try src_vi.matReg(isel);
                        try isel.emit(.fneg(res_ra.s(), src_mat.ra.s()));
                        try src_mat.finish(isel);
                    },
                    64 => {
                        const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(un_op);
                        const src_mat = try src_vi.matReg(isel);
                        try isel.emit(.fneg(res_ra.d(), src_mat.ra.d()));
                        try src_mat.finish(isel);
                    },
                    80 => {
                        const src_vi = try isel.use(un_op);
                        var res_hi16_it = res_vi.value.field(ty, 8, 8);
                        const res_hi16_vi = try res_hi16_it.only(isel);
                        if (try res_hi16_vi.?.defReg(isel)) |res_hi16_ra| {
                            var src_hi16_it = src_vi.field(ty, 8, 8);
                            const src_hi16_vi = try src_hi16_it.only(isel);
                            const src_hi16_mat = try src_hi16_vi.?.matReg(isel);
                            try isel.emit(.eor(res_hi16_ra.w(), src_hi16_mat.ra.w(), .{ .immediate = .{
                                .N = .word,
                                .immr = 32 - 15,
                                .imms = 1 - 1,
                            } }));
                            try src_hi16_mat.finish(isel);
                        }
                        var res_lo64_it = res_vi.value.field(ty, 0, 8);
                        const res_lo64_vi = try res_lo64_it.only(isel);
                        if (try res_lo64_vi.?.defReg(isel)) |res_lo64_ra| {
                            var src_lo64_it = src_vi.field(ty, 0, 8);
                            const src_lo64_vi = try src_lo64_it.only(isel);
                            try src_lo64_vi.?.liveOut(isel, res_lo64_ra);
                        }
                    },
                    128 => {
                        const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(un_op);
                        const src_mat = try src_vi.matReg(isel);
                        const neg_zero_ra = try isel.allocVecReg();
                        defer isel.freeReg(neg_zero_ra);
                        try isel.emit(.eor(res_ra.@"16b"(), src_mat.ra.@"16b"(), .{ .register = neg_zero_ra.@"16b"() }));
                        try isel.literals.appendNTimes(gpa, 0, -%isel.literals.items.len % 4);
                        try isel.literal_relocs.append(gpa, .{
                            .label = @intCast(isel.instructions.items.len),
                        });
                        try isel.emit(.ldr(neg_zero_ra.q(), .{
                            .literal = @intCast((isel.instructions.items.len + 1 + isel.literals.items.len) << 2),
                        }));
                        try isel.emitLiteral(&(@as([15]u8, @splat(0)) ++ .{0x80}));
                        try src_mat.finish(isel);
                    },
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |res_vi| unused: {
                defer res_vi.value.deref(isel);

                const bin_op = air.data(air.inst_index).bin_op;
                const ty = isel.air.typeOf(bin_op.lhs, ip);
                switch (ip.indexToKey(ty.toIntern())) {
                    else => {},
                    .opt_type => |payload_ty| switch (air_tag) {
                        else => unreachable,
                        .cmp_eq, .cmp_neq => if (!ty.optionalReprIsPayload(zcu)) {
                            const lhs_vi = try isel.use(bin_op.lhs);
                            const rhs_vi = try isel.use(bin_op.rhs);
                            const payload_size = ZigType.abiSize(.fromInterned(payload_ty), zcu);
                            if (payload_size == 0) {
                                var lhs_has_value_part_it = lhs_vi.field(ty, 0, 1);
                                var rhs_has_value_part_it = rhs_vi.field(ty, 0, 1);
                                try isel.cmp(
                                    try res_vi.value.defReg(isel) orelse break :unused,
                                    .fromInterned(.bool_type),
                                    (try lhs_has_value_part_it.only(isel)).?,
                                    air_tag.toCmpOp().?,
                                    (try rhs_has_value_part_it.only(isel)).?,
                                );
                                break :unused;
                            }
                            var lhs_payload_part_it = lhs_vi.field(ty, 0, payload_size);
                            const lhs_payload_part_vi = try lhs_payload_part_it.only(isel);
                            var rhs_payload_part_it = rhs_vi.field(ty, 0, payload_size);
                            const rhs_payload_part_vi = try rhs_payload_part_it.only(isel);
                            var cset_label: usize = undefined;
                            try isel.cmpUse(.{ .reg_labeled = .{
                                .ra = try res_vi.value.defReg(isel) orelse break :unused,
                                .label = &cset_label,
                            } }, .fromInterned(payload_ty), lhs_payload_part_vi.?, air_tag.toCmpOp().?, rhs_payload_part_vi.?);
                            try isel.emit(.@"b."(
                                .vc,
                                @intCast((isel.instructions.items.len + 1 - cset_label) << 2),
                            ));
                            var lhs_has_value_part_it = lhs_vi.field(ty, payload_size, 1);
                            const lhs_has_value_part_vi = try lhs_has_value_part_it.only(isel);
                            const lhs_has_value_part_mat = try lhs_has_value_part_vi.?.matReg(isel);
                            var rhs_has_value_part_it = rhs_vi.field(ty, payload_size, 1);
                            const rhs_has_value_part_vi = try rhs_has_value_part_it.only(isel);
                            const rhs_has_value_part_mat = try rhs_has_value_part_vi.?.matReg(isel);
                            try isel.emit(.ccmp(
                                lhs_has_value_part_mat.ra.w(),
                                .{ .register = rhs_has_value_part_mat.ra.w() },
                                .{ .n = false, .z = false, .c = false, .v = true },
                                .eq,
                            ));
                            try isel.emit(.ands(
                                .wzr,
                                lhs_has_value_part_mat.ra.w(),
                                .{ .register = rhs_has_value_part_mat.ra.w() },
                            ));
                            try rhs_has_value_part_mat.finish(isel);
                            try lhs_has_value_part_mat.finish(isel);
                            break :unused;
                        },
                    },
                }
                try isel.cmp(
                    try res_vi.value.defReg(isel) orelse break :unused,
                    ty,
                    try isel.use(bin_op.lhs),
                    air_tag.toCmpOp().?,
                    try isel.use(bin_op.rhs),
                );
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .cond_br => {
            try isel.selectCondBr(air.inst_index, air.body[0..air.body_index], block_pred);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .switch_br, .loop_switch_br => |air_tag| {
            try isel.switchBr(air.inst_index, air_tag == .loop_switch_br);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .@"try", .try_cold => {
            try isel.selectTry(air.inst_index);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .try_ptr, .try_ptr_cold => {
            try isel.selectTryPtr(air.inst_index);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .dbg_stmt => {
            const stmt = air.data(air.inst_index).dbg_stmt;
            try isel.emitDebug(.{ .line_column = .{ .line = stmt.line, .column = stmt.column } });
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .dbg_empty_stmt => {
            // The `nop` only gives a debugger an instruction to stop at. Outside
            // Debug builds emit nothing, as the LLVM backend always does.
            if (isel.optimize_mode == .debug) try isel.emit(.nop());
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .dbg_inline_block => {
            const dbg_block = isel.air.unwrapDbgBlock(air.inst_index);
            const parent_func = isel.debug_func;
            try isel.emitDebug(.{ .leave_inline_func = parent_func });
            isel.debug_func = dbg_block.func;
            try isel.block(air.inst_index, dbg_block.ty, dbg_block.body, null);
            isel.debug_func = parent_func;
            try isel.emitDebug(.{ .enter_inline_func = dbg_block.func });
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        // Variable locations are not emitted. `analyze` relies on that for
        // `dbg_var_ptr`, whose local may have no memory.
        .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline => {
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .is_null, .is_non_null => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |is_vi| unused: {
                defer is_vi.value.deref(isel);
                const is_ra = try is_vi.value.defReg(isel) orelse break :unused;
                try isel.isNullUse(.{ .reg = is_ra }, air_tag, air.data(air.inst_index).un_op);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .is_null_ptr, .is_non_null_ptr => |air_tag| {
            const un_op = air.data(air.inst_index).un_op;
            const opt_ty = isel.air.typeOf(un_op, ip).childType(zcu);
            const payload_ty = opt_ty.optionalChild(zcu);
            const payload_size = payload_ty.abiSize(zcu);
            const offset, const size = if (!opt_ty.optionalReprIsPayload(zcu))
                .{ payload_size, 1 }
            else if (payload_ty.isSlice(zcu))
                .{ 0, 8 }
            else
                .{ 0, payload_size };
            if (isel.live_values.fetchRemove(air.inst_index)) |is_vi| unused: {
                defer is_vi.value.deref(isel);
                const is_ra = try is_vi.value.defReg(isel) orelse break :unused;
                const is_lock = isel.tryLockReg(is_ra);
                defer is_lock.unlock(isel);
                const value_ra = try isel.allocIntReg();
                defer isel.freeReg(value_ra);
                const ptr_mat = try (try isel.use(un_op)).matReg(isel);
                try isel.emit(.csinc(is_ra.w(), .wzr, .wzr, .invert(switch (air_tag) {
                    else => unreachable,
                    .is_null_ptr => .eq,
                    .is_non_null_ptr => .ne,
                })));
                try isel.emit(switch (size) {
                    else => unreachable,
                    1...4 => .subs(.wzr, value_ra.w(), .{ .immediate = 0 }),
                    5...8 => .subs(.xzr, value_ra.x(), .{ .immediate = 0 }),
                });
                try isel.loadReg(value_ra, size, .unsigned, ptr_mat.ra, offset);
                try ptr_mat.finish(isel);
            } else if (isel.air.typeOf(un_op, ip).isVolatilePtr(zcu)) {
                const ptr_mat = try (try isel.use(un_op)).matReg(isel);
                try isel.loadReg(.zr, size, .unsigned, ptr_mat.ra, offset);
                try ptr_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .is_err, .is_non_err => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |is_vi| unused: {
                defer is_vi.value.deref(isel);
                const is_ra = try is_vi.value.defReg(isel) orelse break :unused;
                try isel.isErrUse(.{ .reg = is_ra }, air_tag, air.data(air.inst_index).un_op);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .load => {
            const ty_op = air.data(air.inst_index).ty_op;
            if (isel.promotion.shared_loads.contains(air.inst_index)) {
                if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| dst_vi.value.deref(isel);
                if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
                break :air_tag;
            }
            if (isel.promotedLocalRegister(ty_op.operand)) |pin_ra| {
                if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| unused: {
                    defer dst_vi.value.deref(isel);
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    try isel.pinnedMove(dst_ra, pin_ra, dst_vi.value.size(isel));
                }
                if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
                break :air_tag;
            }
            const ptr_ty = isel.air.typeOf(ty_op.operand, ip);
            const ptr_info = ptr_ty.ptrInfo(zcu);

            if (ptr_info.flags.is_volatile) _ = try isel.use(air.inst_index.toRef());
            if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| unused: {
                defer dst_vi.value.deref(isel);
                const size = dst_vi.value.size(isel);
                if (ptr_info.flags.vector_index != .none) {
                    const ptr_vi = try isel.use(ty_op.operand);
                    const ptr_mat = try ptr_vi.matReg(isel);
                    try isel.vectorMemory(dst_vi.value, ty_op.ty, ptr_mat.ra, ptr_info, false);
                    try ptr_mat.finish(isel);
                } else if (ptr_info.packed_offset.host_size > 0) {
                    const ptr_vi = try isel.use(ty_op.operand);
                    const ptr_mat = try ptr_vi.matReg(isel);
                    try isel.packedMemory(dst_vi.value, ty_op.ty, ptr_mat.ra, ptr_info.packed_offset.bit_offset, false);
                    try ptr_mat.finish(isel);
                } else if (size <= Value.max_parts and ip.zigTypeTag(ptr_info.child) != .@"union") {
                    const ptr_vi = try isel.use(ty_op.operand);
                    const ptr_base: MemoryBase = try .init(isel, ptr_vi);
                    // Bits above an integer's width are undefined in memory (for example
                    // after an undefined store and a packed field store), so normalize.
                    _ = try dst_vi.value.load(isel, ty_op.ty, ptr_base.ra, .{
                        .offset = ptr_base.offset,
                        .@"volatile" = ptr_info.flags.is_volatile,
                        .wrap = if (ty_op.ty.isAbiInt(zcu)) ty_op.ty.intInfo(zcu) else null,
                    });
                    try ptr_base.finish(isel);
                } else if (dst_vi.value.parent(isel) == .unallocated and !ptr_info.flags.is_volatile and
                    ip.zigTypeTag(ptr_info.child) != .@"union")
                {
                    // No use needs the value's memory, only parts in registers: load
                    // those from the pointer instead of copying the value to a stack
                    // slot first.
                    const ptr_vi = try isel.use(ty_op.operand);
                    const ptr_base: MemoryBase = try .init(isel, ptr_vi);
                    _ = try dst_vi.value.load(isel, ty_op.ty, ptr_base.ra, .{
                        .offset = ptr_base.offset,
                        .split = false,
                        .wrap = if (ty_op.ty.isAbiInt(zcu)) ty_op.ty.intInfo(zcu) else null,
                    });
                    try ptr_base.finish(isel);
                } else {
                    try dst_vi.value.defAddr(isel, .fromInterned(ptr_info.child), .{}) orelse break :unused;

                    if (!ptr_info.flags.is_volatile and try isel.copyInline(
                        .{ .value = .{ .vi = dst_vi.value } },
                        .{ .ptr = try isel.use(ty_op.operand) },
                        size,
                        false,
                    )) break :unused;

                    try call.prepareVoidGlobal(isel, "memcpy");
                    const ptr_vi = try isel.use(ty_op.operand);
                    try isel.movImmediate(.x2, size);
                    try call.paramLiveOut(isel, ptr_vi, .r1);
                    try call.paramAddress(isel, dst_vi.value, .r0);
                    try call.finishParams(isel);
                }
            }

            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .ret, .ret_safe => {
            if (air.data(air.inst_index).un_op.toIndex()) |operand_inst| {
                if (air.tag(operand_inst) == .call_always_tail) {
                    if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
                    break :air_tag;
                }
            }
            assert(isel.blocks.keys()[0] == Block.main);
            try isel.blocks.values()[0].branch(isel);
            if (isel.live_values.get(Block.main)) |ret_vi| {
                const un_op = air.data(air.inst_index).un_op;
                const src_vi = try isel.use(un_op);
                switch (ret_vi.parent(isel)) {
                    .unallocated, .stack_slot => if (ret_vi.hint(isel)) |ret_ra| {
                        if (isel.vectorAbi(isel.air.typeOf(un_op, ip))) |info|
                            try isel.vectorAbiAdapt(info, ret_ra, false);
                        try src_vi.liveOut(isel, ret_ra);
                    } else {
                        var ret_part_it = ret_vi.parts(isel);
                        var src_part_it = src_vi.parts(isel);
                        if (src_part_it.only()) |_| {
                            try isel.values.ensureUnusedCapacity(gpa, ret_part_it.remaining);
                            src_vi.setParts(isel, ret_part_it.remaining);
                            while (ret_part_it.next()) |ret_part_vi| {
                                const src_part_vi = src_vi.addPart(
                                    isel,
                                    ret_part_vi.get(isel).offset_from_parent,
                                    ret_part_vi.size(isel),
                                );
                                switch (ret_part_vi.signedness(isel)) {
                                    .signed => src_part_vi.setSignedness(isel, .signed),
                                    .unsigned => {},
                                }
                                if (ret_part_vi.isVector(isel)) src_part_vi.setIsVector(isel);
                            }
                            ret_part_it = ret_vi.parts(isel);
                            src_part_it = src_vi.parts(isel);
                        }
                        while (ret_part_it.next()) |ret_part_vi| {
                            const src_part_vi = src_part_it.next().?;
                            assert(ret_part_vi.get(isel).offset_from_parent == src_part_vi.get(isel).offset_from_parent);
                            assert(ret_part_vi.size(isel) == src_part_vi.size(isel));
                            try src_part_vi.liveOut(isel, ret_part_vi.hint(isel).?);
                        }
                    },
                    .value, .constant, .stack_address => unreachable,
                    .address => |address_vi| {
                        const ptr_mat = try address_vi.matReg(isel);
                        try src_vi.store(isel, isel.air.typeOf(un_op, ip), ptr_mat.ra, .{});
                        try ptr_mat.finish(isel);
                    },
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .ret_load => {
            const un_op = air.data(air.inst_index).un_op;
            const ptr_ty = isel.air.typeOf(un_op, ip);
            const ptr_info = ptr_ty.ptrInfo(zcu);

            assert(isel.blocks.keys()[0] == Block.main);
            try isel.blocks.values()[0].branch(isel);
            if (isel.live_values.get(Block.main)) |ret_vi| switch (ret_vi.parent(isel)) {
                .unallocated, .stack_slot => {
                    var ret_part_it: Value.PartIterator = if (ret_vi.hint(isel)) |_| .initOne(ret_vi) else ret_vi.parts(isel);
                    if (isel.vectorAbi(.fromInterned(ptr_info.child))) |info|
                        try isel.vectorAbiAdapt(info, ret_vi.hint(isel).?, false);
                    while (ret_part_it.next()) |ret_part_vi| try ret_part_vi.liveOut(isel, ret_part_vi.hint(isel).?);
                    const ptr_vi = try isel.use(un_op);
                    const ptr_mat = try ptr_vi.matReg(isel);
                    if (ptr_info.packed_offset.host_size > 0) {
                        try isel.packedMemory(ret_vi, .fromInterned(ptr_info.child), ptr_mat.ra, ptr_info.packed_offset.bit_offset, false);
                    } else _ = try ret_vi.load(isel, .fromInterned(ptr_info.child), ptr_mat.ra, .{});
                    try ptr_mat.finish(isel);
                },
                .value, .constant, .stack_address => unreachable,
                .address => {},
            };
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .atomic_store_unordered, .atomic_store_monotonic, .atomic_store_release, .atomic_store_seq_cst => |air_tag| {
            const bin_op = air.data(air.inst_index).bin_op;
            const ptr_ty = isel.air.typeOf(bin_op.lhs, ip);
            const ptr_info = ptr_ty.ptrInfo(zcu);
            assert(ptr_info.packed_offset.host_size == 0);
            const src_ty = isel.air.typeOf(bin_op.rhs, ip);
            const size = src_ty.abiSize(zcu);
            switch (size) {
                1, 2, 4, 8 => {},
                else => return isel.fail("bad atomic store size of {d} from {f}", .{ size, isel.fmtType(ptr_ty) }),
            }
            const int_info = try isel.atomicIntInfo(src_ty);
            const ptr_vi = try isel.use(bin_op.lhs);
            const ptr_mat = try ptr_vi.matReg(isel);
            const src_vi = try isel.use(bin_op.rhs);
            const src_mat = try src_vi.matReg(isel);
            const wrap_src = if (int_info) |info| info.bits < 8 * size else false;
            const src_ra = if (wrap_src) try isel.allocIntReg() else src_mat.ra;
            defer if (wrap_src) isel.freeReg(src_ra);
            // Full barriers preserve release and sequential consistency with
            // the existing scalar load/store encodings on all AArch64 CPUs.
            if (air_tag == .atomic_store_seq_cst) try isel.emit(.dmb(.ish));
            try isel.emit(switch (size) {
                1 => .strb(src_ra.w(), .{ .base = ptr_mat.ra.x() }),
                2 => if (src_ra.isVector())
                    .str(src_ra.h(), .{ .base = ptr_mat.ra.x() })
                else
                    .strh(src_ra.w(), .{ .base = ptr_mat.ra.x() }),
                4 => .str(if (src_ra.isVector()) src_ra.s() else src_ra.w(), .{ .base = ptr_mat.ra.x() }),
                8 => .str(if (src_ra.isVector()) src_ra.d() else src_ra.x(), .{ .base = ptr_mat.ra.x() }),
                else => unreachable,
            });
            if (air_tag == .atomic_store_release or air_tag == .atomic_store_seq_cst)
                try isel.emit(.dmb(.ish));
            if (wrap_src) try isel.normalizeAtomic(
                if (size == 8) src_ra.x() else src_ra.w(),
                if (size == 8) src_mat.ra.x() else src_mat.ra.w(),
                .{
                    .signedness = .unsigned,
                    .bits = int_info.?.bits,
                },
            );
            try src_mat.finish(isel);
            try ptr_mat.finish(isel);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .store, .store_safe => |air_tag| {
            try isel.selectStore(air.data(air.inst_index).bin_op, air_tag == .store_safe, air.body[0..air.body_index]);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .unreach => if (air.next()) |next_air_tag| continue :air_tag next_air_tag,
        .fptrunc, .fpext => {
            if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| unused: {
                defer dst_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const dst_ty = ty_op.ty;
                const dst_bits = dst_ty.floatBits(isel.target);
                const src_ty = isel.air.typeOf(ty_op.operand, ip);
                const src_bits = src_ty.floatBits(isel.target);
                assert(dst_bits != src_bits);
                switch (@max(dst_bits, src_bits)) {
                    else => unreachable,
                    16, 32, 64 => {
                        const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(ty_op.operand);
                        const src_mat = try src_vi.matReg(isel);
                        try isel.emit(.fcvt(switch (dst_bits) {
                            else => unreachable,
                            16 => dst_ra.h(),
                            32 => dst_ra.s(),
                            64 => dst_ra.d(),
                        }, switch (src_bits) {
                            else => unreachable,
                            16 => src_mat.ra.h(),
                            32 => src_mat.ra.s(),
                            64 => src_mat.ra.d(),
                        }));
                        try src_mat.finish(isel);
                    },
                    80, 128 => {
                        try call.compilerRt(isel, switch (dst_bits) {
                            else => unreachable,
                            16 => switch (src_bits) {
                                else => unreachable,
                                32 => "__truncsfhf2",
                                64 => "__truncdfhf2",
                                80 => "__truncxfhf2",
                                128 => "__trunctfhf2",
                            },
                            32 => switch (src_bits) {
                                else => unreachable,
                                16 => "__extendhfsf2",
                                64 => "__truncdfsf2",
                                80 => "__truncxfsf2",
                                128 => "__trunctfsf2",
                            },
                            64 => switch (src_bits) {
                                else => unreachable,
                                16 => "__extendhfdf2",
                                32 => "__extendsfdf2",
                                80 => "__truncxfdf2",
                                128 => "__trunctfdf2",
                            },
                            80 => switch (src_bits) {
                                else => unreachable,
                                16 => "__extendhfxf2",
                                32 => "__extendsfxf2",
                                64 => "__extenddfxf2",
                                128 => "__trunctfxf2",
                            },
                            128 => switch (src_bits) {
                                else => unreachable,
                                16 => "__extendhftf2",
                                32 => "__extendsftf2",
                                64 => "__extenddftf2",
                                80 => "__extendxftf2",
                            },
                        }, dst_vi.value, dst_ty, &.{ty_op.operand});
                    },
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .is_err_ptr, .is_non_err_ptr => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |is_vi| unused: {
                defer is_vi.value.deref(isel);
                const result_ra = try is_vi.value.defReg(isel) orelse break :unused;
                const result_lock = isel.tryLockReg(result_ra);
                defer result_lock.unlock(isel);
                const operand = air.data(air.inst_index).un_op;
                const error_union_ty = isel.air.typeOf(operand, ip).childType(zcu);
                const error_union_info = ip.indexToKey(error_union_ty.toIntern()).error_union_type;
                const error_set_ty: ZigType = .fromInterned(error_union_info.error_set_type);
                const payload_ty: ZigType = .fromInterned(error_union_info.payload_type);
                const error_size = error_set_ty.abiSize(zcu);
                if (error_size == 0) {
                    try isel.movImmediate(result_ra.w(), @intFromBool(air_tag == .is_non_err_ptr));
                    break :unused;
                }
                const error_ra = try isel.allocIntReg();
                defer isel.freeReg(error_ra);
                const pointer_mat = try (try isel.use(operand)).matReg(isel);
                try isel.emit(.csinc(result_ra.w(), .wzr, .wzr, if (air_tag == .is_err_ptr) .eq else .ne));
                try isel.emit(.subs(.xzr, error_ra.x(), .{ .immediate = 0 }));
                try isel.loadReg(error_ra, error_size, .unsigned, pointer_mat.ra, codegen.errUnionErrorOffset(payload_ty, zcu));
                try pointer_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .int_cast => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| unused: {
                defer dst_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const dst_ty = ty_op.ty;
                if (dst_ty.isVector(zcu)) {
                    try isel.vectorIntCast(dst_vi.value, dst_ty, ty_op.operand);
                    break :unused;
                }
                const dst_int_info = dst_ty.intInfo(zcu);
                const src_ty = isel.air.typeOf(ty_op.operand, ip);
                const src_int_info = src_ty.intInfo(zcu);
                const can_be_negative = dst_int_info.signedness == .signed and
                    src_int_info.signedness == .signed;
                if ((dst_int_info.bits <= 8 and src_int_info.bits <= 8) or
                    (dst_int_info.bits > 8 and dst_int_info.bits <= 16 and
                        src_int_info.bits > 8 and src_int_info.bits <= 16) or
                    (dst_int_info.bits > 16 and dst_int_info.bits <= 32 and
                        src_int_info.bits > 16 and src_int_info.bits <= 32) or
                    (dst_int_info.bits > 32 and dst_int_info.bits <= 64 and
                        src_int_info.bits > 32 and src_int_info.bits <= 64) or
                    (dst_int_info.bits > 64 and src_int_info.bits > 64 and
                        (dst_int_info.bits - 1) / 64 == (src_int_info.bits - 1) / 64))
                {
                    // Canonical limbs are extended within the top limb.
                    try dst_vi.value.move(isel, ty_op.operand);
                } else if (dst_int_info.bits > 128 or src_int_info.bits > 128) {
                    try isel.castIntWide(dst_vi.value, dst_ty, src_ty, ty_op.operand, null);
                } else if (dst_int_info.bits <= 32 and src_int_info.bits <= 64) {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    try isel.moveInt32(dst_ra, src_mat.ra);
                    try src_mat.finish(isel);
                } else if (dst_int_info.bits <= 64 and src_int_info.bits <= 32) {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    if (can_be_negative) try isel.emit(.sbfm(dst_ra.x(), src_mat.ra.x(), .{
                        .N = .doubleword,
                        .immr = 0,
                        .imms = @intCast(src_int_info.bits - 1),
                    })) else if (dst_int_info.bits <= 32)
                        try isel.moveInt32(dst_ra, src_mat.ra)
                    else
                        try isel.emit(.orr(dst_ra.w(), .wzr, .{ .register = src_mat.ra.w() }));
                    try src_mat.finish(isel);
                } else if (dst_int_info.bits <= 32 and src_int_info.bits <= 128) {
                    assert(src_int_info.bits > 64);
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);

                    var src_lo64_it = src_vi.field(src_ty, 0, 8);
                    const src_lo64_vi = try src_lo64_it.only(isel);
                    const src_lo64_mat = try src_lo64_vi.?.matReg(isel);
                    try isel.emit(.orr(dst_ra.w(), .wzr, .{ .register = src_lo64_mat.ra.w() }));
                    try src_lo64_mat.finish(isel);
                } else if (dst_int_info.bits <= 64 and src_int_info.bits <= 128) {
                    assert(dst_int_info.bits > 32 and src_int_info.bits > 64);
                    const src_vi = try isel.use(ty_op.operand);

                    var src_lo64_it = src_vi.field(src_ty, 0, 8);
                    const src_lo64_vi = try src_lo64_it.only(isel);
                    try dst_vi.value.copy(isel, dst_ty, src_lo64_vi.?);
                } else if (dst_int_info.bits <= 128 and src_int_info.bits <= 64) {
                    assert(dst_int_info.bits > 64);
                    const src_vi = try isel.use(ty_op.operand);

                    var dst_lo64_it = dst_vi.value.field(dst_ty, 0, 8);
                    const dst_lo64_vi = try dst_lo64_it.only(isel);
                    if (src_int_info.bits <= 32) unused_lo64: {
                        const dst_lo64_ra = try dst_lo64_vi.?.defReg(isel) orelse break :unused_lo64;
                        const src_mat = try src_vi.matReg(isel);
                        try isel.emit(if (can_be_negative) .sbfm(dst_lo64_ra.x(), src_mat.ra.x(), .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = @intCast(src_int_info.bits - 1),
                        }) else .orr(dst_lo64_ra.w(), .wzr, .{ .register = src_mat.ra.w() }));
                        try src_mat.finish(isel);
                    } else try dst_lo64_vi.?.copy(isel, src_ty, src_vi);

                    var dst_hi64_it = dst_vi.value.field(dst_ty, 8, 8);
                    const dst_hi64_vi = try dst_hi64_it.only(isel);
                    const dst_hi64_ra = try dst_hi64_vi.?.defReg(isel);
                    if (dst_hi64_ra) |dst_ra| switch (can_be_negative) {
                        false => try isel.emit(.orr(dst_ra.x(), .xzr, .{ .register = .xzr })),
                        true => {
                            const src_mat = try src_vi.matReg(isel);
                            try isel.emit(.sbfm(dst_ra.x(), src_mat.ra.x(), .{
                                .N = .doubleword,
                                .immr = @intCast(src_int_info.bits - 1),
                                .imms = @intCast(src_int_info.bits - 1),
                            }));
                            try src_mat.finish(isel);
                        },
                    };
                } else return isel.fail("too big {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) });
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .int_cast_safe => |air_tag| {
            try isel.selectIntCastSafe(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .trunc => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| unused: {
                defer dst_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const dst_ty = ty_op.ty;
                const src_ty = isel.air.typeOf(ty_op.operand, ip);
                if (!dst_ty.isAbiInt(zcu) or !src_ty.isAbiInt(zcu)) return isel.fail("bad {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) });
                const dst_int_info = dst_ty.intInfo(zcu);
                switch (dst_int_info.bits) {
                    0 => unreachable,
                    1...64 => |dst_bits| {
                        const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(ty_op.operand);
                        var src_part_it = src_vi.field(src_ty, 0, @min(src_vi.size(isel), 8));
                        const src_part_vi = try src_part_it.only(isel);
                        const src_part_mat = try src_part_vi.?.matReg(isel);
                        if (dst_bits == 32) try isel.moveInt32(dst_ra, src_part_mat.ra) else try isel.emit(switch (dst_bits) {
                            else => unreachable,
                            1...31 => |bits| switch (dst_int_info.signedness) {
                                .signed => .sbfm(dst_ra.w(), src_part_mat.ra.w(), .{
                                    .N = .word,
                                    .immr = 0,
                                    .imms = @intCast(bits - 1),
                                }),
                                .unsigned => .ubfm(dst_ra.w(), src_part_mat.ra.w(), .{
                                    .N = .word,
                                    .immr = 0,
                                    .imms = @intCast(bits - 1),
                                }),
                            },
                            33...63 => |bits| switch (dst_int_info.signedness) {
                                .signed => .sbfm(dst_ra.x(), src_part_mat.ra.x(), .{
                                    .N = .doubleword,
                                    .immr = 0,
                                    .imms = @intCast(bits - 1),
                                }),
                                .unsigned => .ubfm(dst_ra.x(), src_part_mat.ra.x(), .{
                                    .N = .doubleword,
                                    .immr = 0,
                                    .imms = @intCast(bits - 1),
                                }),
                            },
                            64 => .orr(dst_ra.x(), .xzr, .{ .register = src_part_mat.ra.x() }),
                        });
                        try src_part_mat.finish(isel);
                    },
                    65...128 => |dst_bits| switch (src_ty.intInfo(zcu).bits) {
                        0 => unreachable,
                        65...128 => {
                            const src_vi = try isel.use(ty_op.operand);
                            var dst_hi64_it = dst_vi.value.field(dst_ty, 8, 8);
                            const dst_hi64_vi = try dst_hi64_it.only(isel);
                            if (try dst_hi64_vi.?.defReg(isel)) |dst_hi64_ra| {
                                var src_hi64_it = src_vi.field(src_ty, 8, 8);
                                const src_hi64_vi = try src_hi64_it.only(isel);
                                const src_hi64_mat = try src_hi64_vi.?.matReg(isel);
                                try isel.emit(switch (dst_int_info.signedness) {
                                    .signed => .sbfm(dst_hi64_ra.x(), src_hi64_mat.ra.x(), .{
                                        .N = .doubleword,
                                        .immr = 0,
                                        .imms = @intCast(dst_bits - 64 - 1),
                                    }),
                                    .unsigned => .ubfm(dst_hi64_ra.x(), src_hi64_mat.ra.x(), .{
                                        .N = .doubleword,
                                        .immr = 0,
                                        .imms = @intCast(dst_bits - 64 - 1),
                                    }),
                                });
                                try src_hi64_mat.finish(isel);
                            }
                            var dst_lo64_it = dst_vi.value.field(dst_ty, 0, 8);
                            const dst_lo64_vi = try dst_lo64_it.only(isel);
                            if (try dst_lo64_vi.?.defReg(isel)) |dst_lo64_ra| {
                                var src_lo64_it = src_vi.field(src_ty, 0, 8);
                                const src_lo64_vi = try src_lo64_it.only(isel);
                                try src_lo64_vi.?.liveOut(isel, dst_lo64_ra);
                            }
                        },
                        else => try isel.castIntWide(dst_vi.value, dst_ty, src_ty, ty_op.operand, null),
                    },
                    else => try isel.castIntWide(dst_vi.value, dst_ty, src_ty, ty_op.operand, null),
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .optional_payload => {
            if (isel.live_values.fetchRemove(air.inst_index)) |payload_vi| unused: {
                defer payload_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const opt_ty = isel.air.typeOf(ty_op.operand, ip);
                if (opt_ty.optionalReprIsPayload(zcu)) {
                    try payload_vi.value.move(isel, ty_op.operand);
                    break :unused;
                }

                const opt_vi = try isel.use(ty_op.operand);
                try payload_vi.value.copyField(
                    isel,
                    ty_op.ty,
                    0,
                    opt_vi,
                    opt_ty,
                    0,
                    payload_vi.value.size(isel),
                );
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .optional_payload_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |payload_ptr_vi| {
                defer payload_ptr_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                try payload_ptr_vi.value.move(isel, ty_op.operand);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .optional_payload_ptr_set => {
            const ty_op = air.data(air.inst_index).ty_op;
            const opt_ty = isel.air.typeOf(ty_op.operand, ip).childType(zcu);
            if (!opt_ty.optionalReprIsPayload(zcu)) {
                const opt_ptr_vi = try isel.use(ty_op.operand);
                const opt_ptr_mat = try opt_ptr_vi.matReg(isel);
                const has_value_ra = try isel.allocIntReg();
                defer isel.freeReg(has_value_ra);
                try isel.storeReg(
                    has_value_ra,
                    1,
                    opt_ptr_mat.ra,
                    opt_ty.optionalChild(zcu).abiSize(zcu),
                );
                try opt_ptr_mat.finish(isel);
                try isel.emit(.movz(has_value_ra.w(), 1, .{ .lsl = .@"0" }));
            }
            if (isel.live_values.fetchRemove(air.inst_index)) |payload_ptr_vi| {
                defer payload_ptr_vi.value.deref(isel);
                try payload_ptr_vi.value.move(isel, ty_op.operand);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .wrap_optional => {
            if (isel.live_values.fetchRemove(air.inst_index)) |opt_vi| unused: {
                defer opt_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                if (ty_op.ty.optionalReprIsPayload(zcu)) {
                    try opt_vi.value.move(isel, ty_op.operand);
                    break :unused;
                }

                const payload_ty = isel.air.typeOf(ty_op.operand, ip);
                const payload_size = payload_ty.abiSize(zcu);
                if (payload_size > 0) try opt_vi.value.copyField(
                    isel,
                    ty_op.ty,
                    0,
                    try isel.use(ty_op.operand),
                    payload_ty,
                    0,
                    payload_size,
                );
                var has_value_part_it = opt_vi.value.field(ty_op.ty, payload_size, 1);
                const has_value_part_vi = try has_value_part_it.only(isel);
                const has_value_part_ra = try has_value_part_vi.?.defReg(isel) orelse break :unused;
                try isel.emit(.movz(has_value_part_ra.w(), 1, .{ .lsl = .@"0" }));
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .unwrap_errunion_payload => {
            if (isel.live_values.fetchRemove(air.inst_index)) |payload_vi| {
                defer payload_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const error_union_ty = isel.air.typeOf(ty_op.operand, ip);

                const error_union_vi = try isel.use(ty_op.operand);
                try payload_vi.value.copyField(
                    isel,
                    ty_op.ty,
                    0,
                    error_union_vi,
                    error_union_ty,
                    codegen.errUnionPayloadOffset(ty_op.ty, zcu),
                    payload_vi.value.size(isel),
                );
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .unwrap_errunion_err => {
            if (isel.live_values.fetchRemove(air.inst_index)) |error_set_vi| {
                defer error_set_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const error_union_ty = isel.air.typeOf(ty_op.operand, ip);

                const error_union_vi = try isel.use(ty_op.operand);
                var error_set_part_it = error_union_vi.field(
                    error_union_ty,
                    codegen.errUnionErrorOffset(error_union_ty.errorUnionPayload(zcu), zcu),
                    error_set_vi.value.size(isel),
                );
                const error_set_part_vi = try error_set_part_it.only(isel);
                try error_set_vi.value.copy(isel, ty_op.ty, error_set_part_vi.?);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .unwrap_errunion_payload_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |payload_ptr_vi| unused: {
                defer payload_ptr_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                switch (codegen.errUnionPayloadOffset(ty_op.ty.childType(zcu), zcu)) {
                    0 => try payload_ptr_vi.value.move(isel, ty_op.operand),
                    else => |payload_offset| {
                        const payload_ptr_ra = try payload_ptr_vi.value.defReg(isel) orelse break :unused;
                        const error_union_ptr_vi = try isel.use(ty_op.operand);
                        const error_union_ptr_mat = try error_union_ptr_vi.matReg(isel);
                        try isel.addSubImmediate(.add, payload_ptr_ra.x(), error_union_ptr_mat.ra.x(), payload_offset, .{ .scratch = payload_ptr_ra.x() });
                        try error_union_ptr_mat.finish(isel);
                    },
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .unwrap_errunion_err_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |error_vi| {
                defer error_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                const error_union_ptr_ty = isel.air.typeOf(ty_op.operand, ip);
                const error_union_ptr_info = error_union_ptr_ty.ptrInfo(zcu);
                const error_union_ptr_vi = try isel.use(ty_op.operand);
                const error_union_ptr_mat = try error_union_ptr_vi.matReg(isel);
                _ = try error_vi.value.load(isel, ty_op.ty, error_union_ptr_mat.ra, .{
                    .offset = codegen.errUnionErrorOffset(
                        ZigType.fromInterned(error_union_ptr_info.child).errorUnionPayload(zcu),
                        zcu,
                    ),
                    .@"volatile" = error_union_ptr_info.flags.is_volatile,
                });
                try error_union_ptr_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .errunion_payload_ptr_set => {
            const ty_op = air.data(air.inst_index).ty_op;
            const payload_ty = ty_op.ty.childType(zcu);
            const error_union_ty = isel.air.typeOf(ty_op.operand, ip).childType(zcu);
            const error_set_size = error_union_ty.errorUnionSet(zcu).abiSize(zcu);
            const error_union_ptr_vi = try isel.use(ty_op.operand);
            const error_union_ptr_mat = try error_union_ptr_vi.matReg(isel);
            if (error_set_size > 0) try isel.storeReg(
                .zr,
                error_set_size,
                error_union_ptr_mat.ra,
                codegen.errUnionErrorOffset(payload_ty, zcu),
            );
            if (isel.live_values.fetchRemove(air.inst_index)) |payload_ptr_vi| unused: {
                defer payload_ptr_vi.value.deref(isel);
                switch (codegen.errUnionPayloadOffset(payload_ty, zcu)) {
                    0 => {
                        try error_union_ptr_mat.finish(isel);
                        try payload_ptr_vi.value.move(isel, ty_op.operand);
                    },
                    else => |payload_offset| {
                        const payload_ptr_ra = try payload_ptr_vi.value.defReg(isel) orelse {
                            try error_union_ptr_mat.finish(isel);
                            break :unused;
                        };
                        try isel.addSubImmediate(.add, payload_ptr_ra.x(), error_union_ptr_mat.ra.x(), payload_offset, .{ .scratch = payload_ptr_ra.x() });
                        try error_union_ptr_mat.finish(isel);
                    },
                }
            } else try error_union_ptr_mat.finish(isel);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .wrap_errunion_payload => {
            if (isel.live_values.fetchRemove(air.inst_index)) |error_union_vi| {
                defer error_union_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const error_union_ty = ty_op.ty;
                const error_union_info = ip.indexToKey(error_union_ty.toIntern()).error_union_type;
                const error_set_ty: ZigType = .fromInterned(error_union_info.error_set_type);
                const payload_ty: ZigType = .fromInterned(error_union_info.payload_type);
                const error_set_offset = codegen.errUnionErrorOffset(payload_ty, zcu);
                const payload_offset = codegen.errUnionPayloadOffset(payload_ty, zcu);
                const error_set_size = error_set_ty.abiSize(zcu);
                const payload_size = payload_ty.abiSize(zcu);

                try error_union_vi.value.copyField(
                    isel,
                    error_union_ty,
                    payload_offset,
                    try isel.use(ty_op.operand),
                    payload_ty,
                    0,
                    payload_size,
                );
                var error_set_part_it = error_union_vi.value.field(error_union_ty, error_set_offset, error_set_size);
                const error_set_part_vi = try error_set_part_it.only(isel);
                if (try error_set_part_vi.?.defReg(isel)) |error_set_part_ra| try isel.emit(switch (error_set_size) {
                    else => unreachable,
                    1...4 => .orr(error_set_part_ra.w(), .wzr, .{ .register = .wzr }),
                    5...8 => .orr(error_set_part_ra.x(), .xzr, .{ .register = .xzr }),
                });
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .wrap_errunion_err => {
            if (isel.live_values.fetchRemove(air.inst_index)) |error_union_vi| {
                defer error_union_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const error_union_ty = ty_op.ty;
                const error_union_info = ip.indexToKey(error_union_ty.toIntern()).error_union_type;
                const error_set_ty: ZigType = .fromInterned(error_union_info.error_set_type);
                const payload_ty: ZigType = .fromInterned(error_union_info.payload_type);
                const error_set_offset = codegen.errUnionErrorOffset(payload_ty, zcu);
                const payload_offset = codegen.errUnionPayloadOffset(payload_ty, zcu);
                const error_set_size = error_set_ty.abiSize(zcu);
                const payload_size = payload_ty.abiSize(zcu);

                var error_set_part_it = error_union_vi.value.field(error_union_ty, error_set_offset, error_set_size);
                const error_set_part_vi = try error_set_part_it.only(isel);
                try error_set_part_vi.?.move(isel, ty_op.operand);
                if (payload_size > 0) {
                    var payload_part_it = error_union_vi.value.field(error_union_ty, payload_offset, payload_size);
                    while (try payload_part_it.next(isel)) |payload_part| try payload_part.vi.defUndef(isel, error_union_ty, .{
                        .root = .{ .vi = error_union_vi.value, .offset = payload_offset + payload_part.offset },
                    });
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .struct_field_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| unused: {
                defer dst_vi.value.deref(isel);
                const ty_pl = air.data(air.inst_index).ty_pl;
                const extra = isel.air.extraData(Air.StructField, ty_pl.payload).data;
                switch (codegen.fieldOffset(
                    isel.air.typeOf(extra.struct_operand, ip),
                    ty_pl.ty,
                    extra.field_index,
                    zcu,
                )) {
                    0 => try dst_vi.value.move(isel, extra.struct_operand),
                    else => |field_offset| {
                        const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(extra.struct_operand);
                        const src_mat = try src_vi.matReg(isel);
                        try isel.addSubImmediate(.add, dst_ra.x(), src_mat.ra.x(), field_offset, .{ .scratch = dst_ra.x() });
                        try src_mat.finish(isel);
                    },
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .struct_field_ptr_index_0,
        .struct_field_ptr_index_1,
        .struct_field_ptr_index_2,
        .struct_field_ptr_index_3,
        => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| unused: {
                defer dst_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                switch (codegen.fieldOffset(
                    isel.air.typeOf(ty_op.operand, ip),
                    ty_op.ty,
                    switch (air_tag) {
                        else => unreachable,
                        .struct_field_ptr_index_0 => 0,
                        .struct_field_ptr_index_1 => 1,
                        .struct_field_ptr_index_2 => 2,
                        .struct_field_ptr_index_3 => 3,
                    },
                    zcu,
                )) {
                    0 => try dst_vi.value.move(isel, ty_op.operand),
                    else => |field_offset| {
                        const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(ty_op.operand);
                        const src_mat = try src_vi.matReg(isel);
                        try isel.addSubImmediate(.add, dst_ra.x(), src_mat.ra.x(), field_offset, .{ .scratch = dst_ra.x() });
                        try src_mat.finish(isel);
                    },
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .agg_field_val => {
            if (isel.live_values.fetchRemove(air.inst_index)) |field_vi| unused: {
                defer field_vi.value.deref(isel);

                const ty_pl = air.data(air.inst_index).ty_pl;
                const extra = isel.air.extraData(Air.StructField, ty_pl.payload).data;
                const agg_ty = isel.air.typeOf(extra.struct_operand, ip);
                const field_ty = ty_pl.ty;
                const field_bit_offset, const field_bit_size, const is_packed = switch (agg_ty.containerLayout(zcu)) {
                    .auto, .@"extern" => .{
                        8 * agg_ty.structFieldOffset(extra.field_index, zcu),
                        8 * field_ty.abiSize(zcu),
                        false,
                    },
                    .@"packed" => .{
                        if (zcu.typeToPackedStruct(agg_ty)) |loaded_struct|
                            zcu.structPackedFieldBitOffset(loaded_struct, extra.field_index)
                        else
                            0,
                        field_ty.bitSize(zcu),
                        true,
                    },
                };
                if (is_packed) return isel.fail("packed field of {f}", .{
                    isel.fmtType(agg_ty),
                });

                const agg_vi = try isel.use(extra.struct_operand);
                switch (agg_ty.zigTypeTag(zcu)) {
                    else => unreachable,
                    .@"struct" => {
                        var agg_part_it = agg_vi.field(agg_ty, @divExact(field_bit_offset, 8), @divExact(field_bit_size, 8));
                        while (try agg_part_it.next(isel)) |agg_part| {
                            var field_part_it = field_vi.value.field(ty_pl.ty, agg_part.offset, agg_part.vi.size(isel));
                            const field_part_vi = try field_part_it.only(isel);
                            try field_part_vi.?.copy(isel, field_ty, agg_part.vi);
                        }
                    },
                    .@"union" => {
                        // No use needs the payload's memory, only parts in registers:
                        // load those from the union's stack slot instead of copying
                        // the payload to a slot of its own first.
                        if (field_vi.value.parent(isel) == .unallocated) direct: {
                            const union_slot: Value.Indirect = switch (agg_vi.parent(isel)) {
                                .unallocated => slot: {
                                    const new_slot = agg_vi.allocStackSlot(isel);
                                    agg_vi.setParent(isel, .{ .stack_slot = new_slot });
                                    break :slot new_slot;
                                },
                                .stack_slot => |stack_slot| stack_slot,
                                else => break :direct,
                            };
                            switch (union_slot.base) {
                                .sp, .fp => {},
                                else => break :direct,
                            }
                            _ = try field_vi.value.load(isel, field_ty, union_slot.base, .{
                                .offset = std.math.cast(u64, @as(i65, union_slot.offset) + agg_ty.unionGetLayout(zcu).payloadOffset()) orelse break :direct,
                                .split = false,
                            });
                            break :unused;
                        }

                        try field_vi.value.defAddr(isel, field_ty, .{}) orelse break :unused;

                        if (try isel.copyInline(
                            .{ .value = .{ .vi = field_vi.value } },
                            .{ .value = .{ .vi = agg_vi, .offset = agg_ty.unionGetLayout(zcu).payloadOffset() } },
                            field_vi.value.size(isel),
                            false,
                        )) break :unused;

                        try call.prepareVoidGlobal(isel, "memcpy");
                        const union_layout = agg_ty.unionGetLayout(zcu);
                        const payload_offset = union_layout.payloadOffset();
                        try isel.movImmediate(.x2, field_vi.value.size(isel));
                        // x2 only receives the size afterwards, so it is free as a scratch here.
                        try isel.addSubImmediate(.add, .x1, .x1, payload_offset, .{ .scratch = .x2 });
                        try call.paramAddress(isel, agg_vi, .r1);
                        try call.paramAddress(isel, field_vi.value, .r0);
                        try call.finishParams(isel);
                    },
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .set_union_tag => {
            const bin_op = air.data(air.inst_index).bin_op;
            const union_ty = isel.air.typeOf(bin_op.lhs, ip).childType(zcu);
            const union_layout = union_ty.unionGetLayout(zcu);
            if (union_layout.tag_size > 0) {
                const tag_vi = try isel.use(bin_op.rhs);
                const union_ptr_vi = try isel.use(bin_op.lhs);
                const union_ptr_mat = try union_ptr_vi.matReg(isel);
                try tag_vi.store(isel, isel.air.typeOf(bin_op.rhs, ip), union_ptr_mat.ra, .{
                    .offset = union_layout.tagOffset(),
                });
                try union_ptr_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .get_union_tag => {
            if (isel.live_values.fetchRemove(air.inst_index)) |tag_vi| {
                defer tag_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                const union_ty = isel.air.typeOf(ty_op.operand, ip);
                const union_layout = union_ty.unionGetLayout(zcu);
                const union_vi = try isel.use(ty_op.operand);
                var tag_part_it = union_vi.field(union_ty, union_layout.tagOffset(), union_layout.tag_size);
                const tag_part_vi = try tag_part_it.only(isel);
                try tag_vi.value.copy(isel, ty_op.ty, tag_part_vi.?);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .slice => {
            if (isel.live_values.fetchRemove(air.inst_index)) |slice_vi| {
                defer slice_vi.value.deref(isel);
                const ty_pl = air.data(air.inst_index).ty_pl;
                const bin_op = isel.air.extraData(Air.Bin, ty_pl.payload).data;
                var ptr_part_it = slice_vi.value.field(ty_pl.ty, 0, 8);
                const ptr_part_vi = try ptr_part_it.only(isel);
                try ptr_part_vi.?.move(isel, bin_op.lhs);
                var len_part_it = slice_vi.value.field(ty_pl.ty, 8, 8);
                const len_part_vi = try len_part_it.only(isel);
                try len_part_vi.?.move(isel, bin_op.rhs);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .slice_len => {
            if (isel.live_values.fetchRemove(air.inst_index)) |len_vi| {
                defer len_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                const slice_vi = try isel.use(ty_op.operand);
                var len_part_it = slice_vi.field(isel.air.typeOf(ty_op.operand, ip), 8, 8);
                const len_part_vi = try len_part_it.only(isel);
                try len_vi.value.copy(isel, ty_op.ty, len_part_vi.?);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .slice_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |ptr_vi| {
                defer ptr_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                const slice_vi = try isel.use(ty_op.operand);
                var ptr_part_it = slice_vi.field(isel.air.typeOf(ty_op.operand, ip), 0, 8);
                const ptr_part_vi = try ptr_part_it.only(isel);
                try ptr_vi.value.copy(isel, ty_op.ty, ptr_part_vi.?);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .ptr_slice_len_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| unused: {
                defer dst_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = try src_vi.matReg(isel);
                try isel.emit(.add(dst_ra.x(), src_mat.ra.x(), .{ .immediate = 8 }));
                try src_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .ptr_slice_ptr_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| {
                defer dst_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                try dst_vi.value.move(isel, ty_op.operand);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .array_elem_val => {
            if (isel.live_values.fetchRemove(air.inst_index)) |elem_vi| unused: {
                defer elem_vi.value.deref(isel);

                const bin_op = air.data(air.inst_index).bin_op;
                const array_ty = isel.air.typeOf(bin_op.lhs, ip);
                const elem_ty = array_ty.childType(zcu);
                const elem_size = elem_ty.abiSize(zcu);
                if (array_ty.zigTypeTag(zcu) == .vector and isel.vectorLaneBits(elem_ty) != 8 * elem_size) {
                    // Packed vector lanes do not start at multiples of the element ABI size.
                    if (bin_op.rhs.toInterned()) |index_val| {
                        const index = Constant.fromInterned(index_val).toUnsignedInt(zcu);
                        const base_ra = try isel.allocIntReg();
                        defer if (isel.live_registers.get(base_ra) == .allocating) isel.freeReg(base_ra);
                        try isel.vectorMemoryOffset(elem_vi.value, elem_ty, base_ra, index, false, false);
                        const vector_vi = try isel.use(bin_op.lhs);
                        isel.freeReg(base_ra);
                        try vector_vi.address(isel, 0, base_ra);
                    } else try isel.vectorMemoryDynamic(elem_vi.value, bin_op.lhs, bin_op.rhs, false);
                    break :unused;
                }
                if (elem_size <= 16 and array_ty.arrayLenIncludingSentinel(zcu) <= Value.max_parts) if (bin_op.rhs.toInterned()) |index_val| {
                    const elem_offset = elem_size * Constant.fromInterned(index_val).toUnsignedInt(zcu);
                    const array_vi = try isel.use(bin_op.lhs);
                    var elem_part_it = array_vi.field(array_ty, elem_offset, elem_size);
                    if (try elem_part_it.only(isel)) |elem_part_vi| {
                        try elem_vi.value.copy(isel, elem_ty, elem_part_vi);
                        break :unused;
                    }
                };
                switch (elem_size) {
                    0 => unreachable,
                    1, 2, 4, 8 => scalar: {
                        if (elem_vi.value.parts(isel).only() == null) break :scalar;
                        const elem_ra = try elem_vi.value.defReg(isel) orelse break :unused;
                        const array_ptr_ra = try isel.allocIntReg();
                        defer if (isel.live_registers.get(array_ptr_ra) == .allocating)
                            isel.freeReg(array_ptr_ra);
                        const index_vi = try isel.use(bin_op.rhs);
                        const index_mat = try index_vi.matReg(isel);
                        try isel.emit(switch (elem_size) {
                            else => unreachable,
                            1 => if (elem_ra.isVector()) .ldr(elem_ra.b(), .{ .extended_register = .{
                                .base = array_ptr_ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 0 },
                            } }) else switch (elem_vi.value.signedness(isel)) {
                                .signed => .ldrsb(elem_ra.w(), .{ .extended_register = .{
                                    .base = array_ptr_ra.x(),
                                    .index = index_mat.ra.x(),
                                    .extend = .{ .lsl = 0 },
                                } }),
                                .unsigned => .ldrb(elem_ra.w(), .{ .extended_register = .{
                                    .base = array_ptr_ra.x(),
                                    .index = index_mat.ra.x(),
                                    .extend = .{ .lsl = 0 },
                                } }),
                            },
                            2 => if (elem_ra.isVector()) .ldr(elem_ra.h(), .{ .extended_register = .{
                                .base = array_ptr_ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 1 },
                            } }) else switch (elem_vi.value.signedness(isel)) {
                                .signed => .ldrsh(elem_ra.w(), .{ .extended_register = .{
                                    .base = array_ptr_ra.x(),
                                    .index = index_mat.ra.x(),
                                    .extend = .{ .lsl = 1 },
                                } }),
                                .unsigned => .ldrh(elem_ra.w(), .{ .extended_register = .{
                                    .base = array_ptr_ra.x(),
                                    .index = index_mat.ra.x(),
                                    .extend = .{ .lsl = 1 },
                                } }),
                            },
                            4 => .ldr(if (elem_ra.isVector()) elem_ra.s() else elem_ra.w(), .{ .extended_register = .{
                                .base = array_ptr_ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 2 },
                            } }),
                            8 => .ldr(if (elem_ra.isVector()) elem_ra.d() else elem_ra.x(), .{ .extended_register = .{
                                .base = array_ptr_ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 3 },
                            } }),
                            16 => .ldr(elem_ra.q(), .{ .extended_register = .{
                                .base = array_ptr_ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 4 },
                            } }),
                        });
                        try index_mat.finish(isel);
                        const array_vi = try isel.use(bin_op.lhs);
                        isel.freeReg(array_ptr_ra);
                        try array_vi.address(isel, 0, array_ptr_ra);
                        break :unused;
                    },
                    else => {},
                }
                const ptr_ra = try isel.allocIntReg();
                defer if (isel.live_registers.get(ptr_ra) == .allocating) isel.freeReg(ptr_ra);
                if (!try elem_vi.value.load(isel, elem_ty, ptr_ra, .{})) break :unused;
                const index_vi = try isel.use(bin_op.rhs);
                try isel.elemPtr(ptr_ra, ptr_ra, .add, elem_size, index_vi);
                const array_vi = try isel.use(bin_op.lhs);
                isel.freeReg(ptr_ra);
                try array_vi.address(isel, 0, ptr_ra);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .slice_elem_val => {
            if (isel.live_values.fetchRemove(air.inst_index)) |elem_vi| unused: {
                defer elem_vi.value.deref(isel);

                const bin_op = air.data(air.inst_index).bin_op;
                const slice_ty = isel.air.typeOf(bin_op.lhs, ip);
                const ptr_info = slice_ty.ptrInfo(zcu);
                const elem_size = elem_vi.value.size(isel);
                const elem_is_vector = elem_vi.value.isVector(isel);
                if (switch (elem_size) {
                    0 => unreachable,
                    1, 2, 4, 8 => true,
                    16 => elem_is_vector,
                    else => false,
                } and elem_vi.value.parts(isel).only() != null) {
                    const elem_ra = try elem_vi.value.defReg(isel) orelse break :unused;
                    const slice_vi = try isel.use(bin_op.lhs);
                    const index_vi = try isel.use(bin_op.rhs);
                    var ptr_part_it = slice_vi.field(slice_ty, 0, 8);
                    const ptr_part_vi = try ptr_part_it.only(isel);
                    const base_mat = try ptr_part_vi.?.matReg(isel);
                    const index_mat = try index_vi.matReg(isel);
                    try isel.emit(switch (elem_size) {
                        else => unreachable,
                        1 => if (elem_ra.isVector()) .ldr(elem_ra.b(), .{ .extended_register = .{
                            .base = base_mat.ra.x(),
                            .index = index_mat.ra.x(),
                            .extend = .{ .lsl = 0 },
                        } }) else switch (elem_vi.value.signedness(isel)) {
                            .signed => .ldrsb(elem_ra.w(), .{ .extended_register = .{
                                .base = base_mat.ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 0 },
                            } }),
                            .unsigned => .ldrb(elem_ra.w(), .{ .extended_register = .{
                                .base = base_mat.ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 0 },
                            } }),
                        },
                        2 => if (elem_ra.isVector()) .ldr(elem_ra.h(), .{ .extended_register = .{
                            .base = base_mat.ra.x(),
                            .index = index_mat.ra.x(),
                            .extend = .{ .lsl = 1 },
                        } }) else switch (elem_vi.value.signedness(isel)) {
                            .signed => .ldrsh(elem_ra.w(), .{ .extended_register = .{
                                .base = base_mat.ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 1 },
                            } }),
                            .unsigned => .ldrh(elem_ra.w(), .{ .extended_register = .{
                                .base = base_mat.ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 1 },
                            } }),
                        },
                        4 => .ldr(if (elem_ra.isVector()) elem_ra.s() else elem_ra.w(), .{ .extended_register = .{
                            .base = base_mat.ra.x(),
                            .index = index_mat.ra.x(),
                            .extend = .{ .lsl = 2 },
                        } }),
                        8 => .ldr(if (elem_ra.isVector()) elem_ra.d() else elem_ra.x(), .{ .extended_register = .{
                            .base = base_mat.ra.x(),
                            .index = index_mat.ra.x(),
                            .extend = .{ .lsl = 3 },
                        } }),
                        16 => if (elem_is_vector) .ldr(elem_ra.q(), .{ .extended_register = .{
                            .base = base_mat.ra.x(),
                            .index = index_mat.ra.x(),
                            .extend = .{ .lsl = 4 },
                        } }) else unreachable,
                    });
                    try index_mat.finish(isel);
                    try base_mat.finish(isel);
                } else {
                    const elem_ptr_ra = try isel.allocIntReg();
                    defer isel.freeReg(elem_ptr_ra);
                    if (!try elem_vi.value.load(isel, slice_ty.childType(zcu), elem_ptr_ra, .{
                        .@"volatile" = ptr_info.flags.is_volatile,
                    })) break :unused;
                    const slice_vi = try isel.use(bin_op.lhs);
                    var ptr_part_it = slice_vi.field(slice_ty, 0, 8);
                    const ptr_part_vi = try ptr_part_it.only(isel);
                    const ptr_part_mat = try ptr_part_vi.?.matReg(isel);
                    const index_vi = try isel.use(bin_op.rhs);
                    try isel.elemPtr(elem_ptr_ra, ptr_part_mat.ra, .add, elem_size, index_vi);
                    try ptr_part_mat.finish(isel);
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .slice_elem_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |elem_ptr_vi| unused: {
                defer elem_ptr_vi.value.deref(isel);
                const elem_ptr_ra = try elem_ptr_vi.value.defReg(isel) orelse break :unused;
                const ptr_result_lock = isel.tryLockReg(elem_ptr_ra);
                defer ptr_result_lock.unlock(isel);

                const ty_pl = air.data(air.inst_index).ty_pl;
                const bin_op = isel.air.extraData(Air.Bin, ty_pl.payload).data;
                const elem_size = ty_pl.ty.childType(zcu).abiSize(zcu);

                const slice_vi = try isel.use(bin_op.lhs);
                var ptr_part_it = slice_vi.field(isel.air.typeOf(bin_op.lhs, ip), 0, 8);
                const ptr_part_vi = try ptr_part_it.only(isel);
                const ptr_part_mat = try ptr_part_vi.?.matReg(isel);
                const index_vi = try isel.use(bin_op.rhs);
                try isel.elemPtr(elem_ptr_ra, ptr_part_mat.ra, .add, elem_size, index_vi);
                try ptr_part_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .ptr_elem_val => {
            if (isel.live_values.fetchRemove(air.inst_index)) |elem_vi| unused: {
                defer elem_vi.value.deref(isel);

                const bin_op = air.data(air.inst_index).bin_op;
                const ptr_ty = isel.air.typeOf(bin_op.lhs, ip);
                const ptr_info = ptr_ty.ptrInfo(zcu);
                const elem_size = elem_vi.value.size(isel);
                const elem_is_vector = elem_vi.value.isVector(isel);
                if (switch (elem_size) {
                    0 => unreachable,
                    1, 2, 4, 8 => true,
                    16 => elem_is_vector,
                    else => false,
                } and elem_vi.value.parts(isel).only() != null) {
                    const elem_ra = try elem_vi.value.defReg(isel) orelse break :unused;
                    const base_vi = try isel.use(bin_op.lhs);
                    const index_vi = try isel.use(bin_op.rhs);
                    const base_mat = try base_vi.matReg(isel);
                    const index_mat = try index_vi.matReg(isel);
                    try isel.emit(switch (elem_size) {
                        else => unreachable,
                        1 => if (elem_ra.isVector()) .ldr(elem_ra.b(), .{ .extended_register = .{
                            .base = base_mat.ra.x(),
                            .index = index_mat.ra.x(),
                            .extend = .{ .lsl = 0 },
                        } }) else switch (elem_vi.value.signedness(isel)) {
                            .signed => .ldrsb(elem_ra.w(), .{ .extended_register = .{
                                .base = base_mat.ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 0 },
                            } }),
                            .unsigned => .ldrb(elem_ra.w(), .{ .extended_register = .{
                                .base = base_mat.ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 0 },
                            } }),
                        },
                        2 => if (elem_ra.isVector()) .ldr(elem_ra.h(), .{ .extended_register = .{
                            .base = base_mat.ra.x(),
                            .index = index_mat.ra.x(),
                            .extend = .{ .lsl = 1 },
                        } }) else switch (elem_vi.value.signedness(isel)) {
                            .signed => .ldrsh(elem_ra.w(), .{ .extended_register = .{
                                .base = base_mat.ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 1 },
                            } }),
                            .unsigned => .ldrh(elem_ra.w(), .{ .extended_register = .{
                                .base = base_mat.ra.x(),
                                .index = index_mat.ra.x(),
                                .extend = .{ .lsl = 1 },
                            } }),
                        },
                        4 => .ldr(if (elem_ra.isVector()) elem_ra.s() else elem_ra.w(), .{ .extended_register = .{
                            .base = base_mat.ra.x(),
                            .index = index_mat.ra.x(),
                            .extend = .{ .lsl = 2 },
                        } }),
                        8 => .ldr(if (elem_ra.isVector()) elem_ra.d() else elem_ra.x(), .{ .extended_register = .{
                            .base = base_mat.ra.x(),
                            .index = index_mat.ra.x(),
                            .extend = .{ .lsl = 3 },
                        } }),
                        16 => if (elem_is_vector) .ldr(elem_ra.q(), .{ .extended_register = .{
                            .base = base_mat.ra.x(),
                            .index = index_mat.ra.x(),
                            .extend = .{ .lsl = 4 },
                        } }) else unreachable,
                    });
                    try index_mat.finish(isel);
                    try base_mat.finish(isel);
                } else {
                    const elem_ptr_ra = try isel.allocIntReg();
                    defer isel.freeReg(elem_ptr_ra);
                    if (!try elem_vi.value.load(isel, ptr_ty.childType(zcu), elem_ptr_ra, .{
                        .@"volatile" = ptr_info.flags.is_volatile,
                    })) break :unused;
                    const base_vi = try isel.use(bin_op.lhs);
                    const base_mat = try base_vi.matReg(isel);
                    const index_vi = try isel.use(bin_op.rhs);
                    try isel.elemPtr(elem_ptr_ra, base_mat.ra, .add, elem_size, index_vi);
                    try base_mat.finish(isel);
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .ptr_elem_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |elem_ptr_vi| unused: {
                defer elem_ptr_vi.value.deref(isel);
                const elem_ptr_ra = try elem_ptr_vi.value.defReg(isel) orelse break :unused;
                const ptr_result_lock = isel.tryLockReg(elem_ptr_ra);
                defer ptr_result_lock.unlock(isel);

                const ty_pl = air.data(air.inst_index).ty_pl;
                const bin_op = isel.air.extraData(Air.Bin, ty_pl.payload).data;
                const elem_size = ty_pl.ty.childType(zcu).abiSize(zcu);

                const base_vi = try isel.use(bin_op.lhs);
                const base_mat = try base_vi.matReg(isel);
                const index_vi = try isel.use(bin_op.rhs);
                try isel.elemPtr(elem_ptr_ra, base_mat.ra, .add, elem_size, index_vi);
                try base_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .array_to_vector => unreachable, // legalize .expand_array_to_vector
        .array_to_slice => {
            if (isel.live_values.fetchRemove(air.inst_index)) |slice_vi| {
                defer slice_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                var ptr_part_it = slice_vi.value.field(ty_op.ty, 0, 8);
                const ptr_part_vi = try ptr_part_it.only(isel);
                try ptr_part_vi.?.move(isel, ty_op.operand);
                var len_part_it = slice_vi.value.field(ty_op.ty, 8, 8);
                const len_part_vi = try len_part_it.only(isel);
                if (try len_part_vi.?.defReg(isel)) |len_ra| try isel.movImmediate(
                    len_ra.x(),
                    isel.air.typeOf(ty_op.operand, ip).childType(zcu).arrayLen(zcu),
                );
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .int_from_float, .int_from_float_optimized => |air_tag| {
            try isel.selectIntFromFloat(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .float_from_int => |air_tag| {
            try isel.selectFloatFromInt(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .memset, .memset_safe => |air_tag| {
            try isel.selectMemset(air.inst_index, air_tag);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .memcpy, .memmove => |air_tag| {
            const bin_op = air.data(air.inst_index).bin_op;
            const dst_ty = isel.air.typeOf(bin_op.lhs, ip);
            const dst_info = dst_ty.ptrInfo(zcu);

            if (dst_info.flags.size == .one and !dst_info.flags.is_volatile) {
                const src_ty = isel.air.typeOf(bin_op.rhs, ip);
                if (src_ty.ptrSize(zcu) != .slice and !src_ty.isVolatilePtr(zcu) and try isel.copyInline(
                    .{ .ptr = try isel.use(bin_op.lhs) },
                    .{ .ptr = try isel.use(bin_op.rhs) },
                    ZigType.fromInterned(dst_info.child).abiSize(zcu),
                    air_tag == .memmove,
                )) break :air_tag if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
            }

            try call.prepareReturn(isel);
            try call.finishReturn(isel);

            try call.prepareCallee(isel);
            try call.global(isel, @tagName(air_tag));
            try call.finishCallee(isel);

            try call.prepareParams(isel);
            const src_ty = isel.air.typeOf(bin_op.rhs, ip);
            const src_vi = try isel.use(bin_op.rhs);
            const src_ptr_vi = if (src_ty.ptrSize(zcu) == .slice) src_ptr: {
                var src_ptr_it = src_vi.field(src_ty, 0, 8);
                break :src_ptr (try src_ptr_it.only(isel)).?;
            } else src_vi;
            switch (dst_info.flags.size) {
                .one => {
                    const dst_vi = try isel.use(bin_op.lhs);
                    try isel.movImmediate(.x2, ZigType.fromInterned(dst_info.child).abiSize(zcu));
                    try call.paramLiveOut(isel, src_ptr_vi, .r1);
                    try call.paramLiveOut(isel, dst_vi, .r0);
                },
                .many => unreachable,
                .slice => {
                    const dst_vi = try isel.use(bin_op.lhs);
                    var dst_ptr_it = dst_vi.field(dst_ty, 0, 8);
                    const dst_ptr_vi = try dst_ptr_it.only(isel);
                    var dst_len_it = dst_vi.field(dst_ty, 8, 8);
                    const dst_len_vi = try dst_len_it.only(isel);
                    try isel.elemPtr(.r2, .zr, .add, ZigType.fromInterned(dst_info.child).abiSize(zcu), dst_len_vi.?);
                    try call.paramLiveOut(isel, src_ptr_vi, .r1);
                    try call.paramLiveOut(isel, dst_ptr_vi.?, .r0);
                },
                .c => unreachable,
            }
            try call.finishParams(isel);

            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .cmpxchg_weak, .cmpxchg_strong => |air_tag| {
            const ty_pl = air.data(air.inst_index).ty_pl;
            const extra = isel.air.extraData(Air.Cmpxchg, ty_pl.payload).data;
            const dst = isel.live_values.fetchRemove(air.inst_index);
            defer if (dst) |entry| entry.value.deref(isel);
            try isel.atomicCmpxchg(ty_pl.ty, extra, if (dst) |entry| entry.value else null, air_tag == .cmpxchg_strong);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .atomic_rmw => {
            const pl_op = air.data(air.inst_index).pl_op;
            const extra = isel.air.extraData(Air.AtomicRmw, pl_op.payload).data;
            const dst = isel.live_values.fetchRemove(air.inst_index);
            defer if (dst) |entry| entry.value.deref(isel);
            try isel.atomicRmw(pl_op.operand, extra, if (dst) |entry| entry.value else null);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .atomic_load => {
            const atomic_load = air.data(air.inst_index).atomic_load;
            const ptr_ty = isel.air.typeOf(atomic_load.ptr, ip);
            const ptr_info = ptr_ty.ptrInfo(zcu);
            if (ptr_info.packed_offset.host_size > 0) return isel.fail("packed atomic load", .{});
            const elem_ty: ZigType = .fromInterned(ptr_info.child);
            const elem_size = elem_ty.abiSize(zcu);
            switch (elem_size) {
                1, 2, 4, 8 => {},
                else => |size| return isel.fail("bad atomic load size of {d} from {f}", .{ size, isel.fmtType(ptr_ty) }),
            }
            const int_info = try isel.atomicIntInfo(elem_ty);

            const acquire = switch (atomic_load.order) {
                .unordered, .monotonic => false,
                .acquire, .seq_cst => true,
                else => unreachable,
            };
            if (acquire) try isel.emit(.dmb(.ish));

            if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| {
                defer dst_vi.value.deref(isel);
                var ptr_mat: ?Value.Materialize = null;
                var dst_part_it = dst_vi.value.parts(isel);
                while (dst_part_it.next()) |dst_part_vi| {
                    const dst_ra = try dst_part_vi.defReg(isel) orelse continue;
                    if (ptr_mat == null) {
                        const ptr_vi = try isel.use(atomic_load.ptr);
                        ptr_mat = try ptr_vi.matReg(isel);
                    }
                    if (int_info) |info| try isel.normalizeAtomic(
                        if (elem_size == 8) dst_ra.x() else dst_ra.w(),
                        if (elem_size == 8) dst_ra.x() else dst_ra.w(),
                        info,
                    );
                    try isel.emit(switch (dst_part_vi.size(isel)) {
                        else => unreachable,
                        1 => switch (dst_part_vi.signedness(isel)) {
                            .signed => .ldrsb(dst_ra.w(), .{ .unsigned_offset = .{
                                .base = ptr_mat.?.ra.x(),
                                .offset = @intCast(dst_part_vi.get(isel).offset_from_parent),
                            } }),
                            .unsigned => .ldrb(dst_ra.w(), .{ .unsigned_offset = .{
                                .base = ptr_mat.?.ra.x(),
                                .offset = @intCast(dst_part_vi.get(isel).offset_from_parent),
                            } }),
                        },
                        // Aligned floating-point loads of up to 64 bits are
                        // single-copy atomic, like the general register ones.
                        2 => if (dst_ra.isVector()) .ldr(dst_ra.h(), .{ .unsigned_offset = .{
                            .base = ptr_mat.?.ra.x(),
                            .offset = @intCast(dst_part_vi.get(isel).offset_from_parent),
                        } }) else switch (dst_part_vi.signedness(isel)) {
                            .signed => .ldrsh(dst_ra.w(), .{ .unsigned_offset = .{
                                .base = ptr_mat.?.ra.x(),
                                .offset = @intCast(dst_part_vi.get(isel).offset_from_parent),
                            } }),
                            .unsigned => .ldrh(dst_ra.w(), .{ .unsigned_offset = .{
                                .base = ptr_mat.?.ra.x(),
                                .offset = @intCast(dst_part_vi.get(isel).offset_from_parent),
                            } }),
                        },
                        4 => .ldr(if (dst_ra.isVector()) dst_ra.s() else dst_ra.w(), .{ .unsigned_offset = .{
                            .base = ptr_mat.?.ra.x(),
                            .offset = @intCast(dst_part_vi.get(isel).offset_from_parent),
                        } }),
                        8 => .ldr(if (dst_ra.isVector()) dst_ra.d() else dst_ra.x(), .{ .unsigned_offset = .{
                            .base = ptr_mat.?.ra.x(),
                            .offset = @intCast(dst_part_vi.get(isel).offset_from_parent),
                        } }),
                    });
                }
                if (ptr_mat) |mat| try mat.finish(isel);
            } else if (ptr_info.flags.is_volatile or acquire) {
                const ptr_vi = try isel.use(atomic_load.ptr);
                const ptr_mat = try ptr_vi.matReg(isel);
                try isel.emit(switch (ZigType.fromInterned(ptr_info.child).abiSize(zcu)) {
                    1 => .ldrb(Register.wzr, .{ .base = ptr_mat.ra.x() }),
                    2 => .ldrh(Register.wzr, .{ .base = ptr_mat.ra.x() }),
                    4 => .ldr(Register.wzr, .{ .base = ptr_mat.ra.x() }),
                    8 => .ldr(Register.xzr, .{ .base = ptr_mat.ra.x() }),
                    else => unreachable,
                });
                try ptr_mat.finish(isel);
            }
            if (atomic_load.order == .seq_cst) try isel.emit(.dmb(.ish));

            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .is_named_enum_value => {
            if (isel.live_values.fetchRemove(air.inst_index)) |named_vi| unused: {
                defer named_vi.value.deref(isel);
                const named_ra = try named_vi.value.defReg(isel) orelse break :unused;
                const named_lock = isel.tryLockReg(named_ra);
                defer named_lock.unlock(isel);
                const un_op = air.data(air.inst_index).un_op;
                const enum_ty = isel.air.typeOf(un_op, ip);
                const enum_vi = try isel.use(un_op);
                const tag_int_info = enum_ty.backingIntType(zcu).intInfo(zcu);
                if (tag_int_info.bits <= 64) {
                    const enum_mat = try enum_vi.matReg(isel);
                    try isel.isNamedEnumValue(named_ra, enum_ty, switch (tag_int_info.bits) {
                        else => unreachable,
                        0...32 => enum_mat.ra.w(),
                        33...64 => enum_mat.ra.x(),
                    }, tag_int_info);
                    try enum_mat.finish(isel);
                    break :unused;
                }
                const cmp_ra = try isel.allocIntReg();
                defer isel.freeReg(cmp_ra);
                const end_label = isel.instructions.items.len;
                try isel.movImmediate(named_ra.w(), 0);
                for (0..enum_ty.enumFields(zcu).len) |tag_index| {
                    const next_label = isel.instructions.items.len;
                    try isel.emit(.b(@intCast((isel.instructions.items.len + 1 - end_label) << 2)));
                    try isel.movImmediate(named_ra.w(), 1);
                    try isel.emit(.cbz(cmp_ra.w(), @intCast((isel.instructions.items.len + 1 - next_label) << 2)));
                    const tag_value = try isel.pt.enumValueFieldIndex(enum_ty, @intCast(tag_index));
                    const tag_vi = try isel.use(.fromIntern(tag_value.toIntern()));
                    try isel.cmp(cmp_ra, enum_ty, enum_vi, .eq, tag_vi);
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .tag_name => {
            if (isel.live_values.fetchRemove(air.inst_index)) |name_vi| unused: {
                defer name_vi.value.deref(isel);
                var ptr_part_it = name_vi.value.field(.slice_const_u8_sentinel_0, 0, 8);
                const ptr_part_vi = try ptr_part_it.only(isel);
                const ptr_part_ra = try ptr_part_vi.?.defReg(isel);
                const ptr_lock: RegLock = if (ptr_part_ra) |ra| isel.tryLockReg(ra) else .empty;
                defer ptr_lock.unlock(isel);
                var len_part_it = name_vi.value.field(.slice_const_u8_sentinel_0, 8, 8);
                const len_part_vi = try len_part_it.only(isel);
                const len_part_ra = try len_part_vi.?.defReg(isel);
                const len_lock: RegLock = if (len_part_ra) |ra| isel.tryLockReg(ra) else .empty;
                defer len_lock.unlock(isel);
                if (ptr_part_ra == null and len_part_ra == null) break :unused;

                const un_op = air.data(air.inst_index).un_op;
                const enum_ty = isel.air.typeOf(un_op, ip);
                const enum_vi = try isel.use(un_op);
                const cmp_ra = try isel.allocIntReg();
                defer isel.freeReg(cmp_ra);
                const end_label = isel.instructions.items.len;
                if (ptr_part_ra) |ra| try isel.movImmediate(ra.x(), 0);
                if (len_part_ra) |ra| try isel.movImmediate(ra.x(), 0);

                var data_offset: u64 = 0;
                const tag_names = enum_ty.enumFields(zcu);
                for (0..tag_names.len) |tag_index| {
                    const next_label = isel.instructions.items.len;
                    try isel.emit(.b(@intCast((isel.instructions.items.len + 1 - end_label) << 2)));
                    const tag_name_len = tag_names.get(ip)[tag_index].length(ip);
                    if (len_part_ra) |ra| try isel.movImmediate(ra.x(), tag_name_len);
                    if (ptr_part_ra) |ra| {
                        try isel.lazy_relocs.append(gpa, .{
                            .symbol = .{ .kind = .const_data, .ty = enum_ty.toIntern() },
                            .reloc = .{ .label = @intCast(isel.instructions.items.len), .addend = data_offset },
                        });
                        try isel.emit(.add(ra.x(), ra.x(), .{ .immediate = 0 }));
                        try isel.lazy_relocs.append(gpa, .{
                            .symbol = .{ .kind = .const_data, .ty = enum_ty.toIntern() },
                            .reloc = .{ .label = @intCast(isel.instructions.items.len), .addend = data_offset },
                        });
                        try isel.emit(.adrp(ra.x(), 0));
                    }
                    try isel.emit(.cbz(cmp_ra.w(), @intCast((isel.instructions.items.len + 1 - next_label) << 2)));
                    const tag_value = try isel.pt.enumValueFieldIndex(enum_ty, @intCast(tag_index));
                    const tag_vi = try isel.use(.fromIntern(tag_value.toIntern()));
                    try isel.cmp(cmp_ra, enum_ty, enum_vi, .eq, tag_vi);
                    data_offset += tag_name_len + 1;
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .error_name => {
            if (isel.live_values.fetchRemove(air.inst_index)) |name_vi| unused: {
                defer name_vi.value.deref(isel);
                var ptr_part_it = name_vi.value.field(.slice_const_u8_sentinel_0, 0, 8);
                const ptr_part_vi = try ptr_part_it.only(isel);
                const ptr_def_ra = try ptr_part_vi.?.defReg(isel);
                var len_part_it = name_vi.value.field(.slice_const_u8_sentinel_0, 8, 8);
                const len_part_vi = try len_part_it.only(isel);
                const len_def_ra = try len_part_vi.?.defReg(isel);
                if (ptr_def_ra == null and len_def_ra == null) break :unused;
                // A part of an aggregate that also holds floats can be defined
                // in a vector register: compute it in a general register.
                const ptr_part_ra: ?Register.Alias, const len_part_ra: ?Register.Alias = int_ras: {
                    const ptr_lock: RegLock = if (ptr_def_ra) |ra| isel.tryLockReg(ra) else .empty;
                    defer ptr_lock.unlock(isel);
                    const len_lock: RegLock = if (len_def_ra) |ra| isel.tryLockReg(ra) else .empty;
                    defer len_lock.unlock(isel);
                    break :int_ras .{
                        if (ptr_def_ra) |ra| if (ra.isVector()) try isel.allocIntReg() else ra else null,
                        if (len_def_ra) |ra| if (ra.isVector()) try isel.allocIntReg() else ra else null,
                    };
                };
                defer if (ptr_def_ra) |ra| if (ra.isVector()) isel.freeReg(ptr_part_ra.?);
                defer if (len_def_ra) |ra| if (ra.isVector()) isel.freeReg(len_part_ra.?);
                if (len_def_ra) |ra| if (ra.isVector()) try isel.emit(.fmov(ra.d(), .{ .register = len_part_ra.?.x() }));
                if (ptr_def_ra) |ra| if (ra.isVector()) try isel.emit(.fmov(ra.d(), .{ .register = ptr_part_ra.?.x() }));

                const un_op = air.data(air.inst_index).un_op;
                const error_vi = try isel.use(un_op);
                const error_mat = try error_vi.matReg(isel);
                const ptr_ra = try isel.allocIntReg();
                defer isel.freeReg(ptr_ra);
                const start_ra, const end_ra = range_ras: {
                    const name_lock: RegLock = if (len_part_ra != null) if (ptr_part_ra) |name_ptr_ra|
                        isel.tryLockReg(name_ptr_ra)
                    else
                        .empty else .empty;
                    defer name_lock.unlock(isel);
                    break :range_ras .{ try isel.allocIntReg(), try isel.allocIntReg() };
                };
                defer {
                    isel.freeReg(start_ra);
                    isel.freeReg(end_ra);
                }
                if (len_part_ra) |name_len_ra| try isel.emit(.sub(
                    name_len_ra.w(),
                    end_ra.w(),
                    .{ .register = start_ra.w() },
                ));
                if (ptr_part_ra) |name_ptr_ra| try isel.emit(.add(
                    name_ptr_ra.x(),
                    ptr_ra.x(),
                    .{ .extended_register = .{
                        .register = start_ra.w(),
                        .extend = .{ .uxtw = 0 },
                    } },
                ));
                if (len_part_ra) |_| try isel.emit(.sub(end_ra.w(), end_ra.w(), .{ .immediate = 1 }));
                try isel.emit(.ldp(start_ra.w(), end_ra.w(), .{ .base = start_ra.x() }));
                try isel.emit(.add(start_ra.x(), ptr_ra.x(), .{ .extended_register = .{
                    .register = error_mat.ra.w(),
                    .extend = switch (zcu.errorSetBits()) {
                        else => unreachable,
                        1...8 => .{ .uxtb = 2 },
                        9...16 => .{ .uxth = 2 },
                        17...32 => .{ .uxtw = 2 },
                    },
                } }));
                try isel.lazy_relocs.append(gpa, .{
                    .symbol = .{ .kind = .const_data, .ty = .anyerror_type },
                    .reloc = .{ .label = @intCast(isel.instructions.items.len) },
                });
                try isel.emit(.add(ptr_ra.x(), ptr_ra.x(), .{ .immediate = 0 }));
                try isel.lazy_relocs.append(gpa, .{
                    .symbol = .{ .kind = .const_data, .ty = .anyerror_type },
                    .reloc = .{ .label = @intCast(isel.instructions.items.len) },
                });
                try isel.emit(.adrp(ptr_ra.x(), 0));
                try error_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .aggregate_init => {
            try isel.selectAggregateInit(air.inst_index);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .splat => {
            if (isel.live_values.fetchRemove(air.inst_index)) |vector_vi| unused: {
                defer vector_vi.value.deref(isel);

                const ty_op = air.data(air.inst_index).ty_op;
                const vector_ty = ty_op.ty;
                const elem_ty = vector_ty.childType(zcu);
                if (elem_ty.bitSize(zcu) == 0) break :unused;
                if (isel.simdIntArrangement(vector_ty)) |arrangement| {
                    const vector_def = try isel.defVector(vector_vi.value) orelse break :unused;
                    defer vector_def.finish(isel);
                    const vector_ra = vector_def.ra;
                    const elem_mat = try (try isel.use(ty_op.operand)).matReg(isel);
                    try isel.emit(.dup(vector_ra.vector(arrangement), switch (arrangement.elemSize()) {
                        .byte, .half, .single => elem_mat.ra.w(),
                        .double => elem_mat.ra.x(),
                    }));
                    try elem_mat.finish(isel);
                    break :unused;
                }
                try vector_vi.value.defAddr(isel, vector_ty, .{}) orelse break :unused;
                const ptr_ra = try isel.allocIntReg();
                defer if (isel.live_registers.get(ptr_ra) == .allocating) isel.freeReg(ptr_ra);
                for (0..vector_ty.vectorLen(zcu)) |index| {
                    try isel.vectorMemoryOffset(try isel.use(ty_op.operand), elem_ty, ptr_ra, index, false, true);
                }
                isel.freeReg(ptr_ra);
                try vector_vi.value.address(isel, 0, ptr_ra);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .union_init => |air_tag| {
            if (isel.live_values.fetchRemove(air.inst_index)) |union_vi| unused: {
                defer union_vi.value.deref(isel);

                const ty_pl = air.data(air.inst_index).ty_pl;
                const extra = isel.air.extraData(Air.UnionInit, ty_pl.payload).data;
                const union_ty = ty_pl.ty;
                assert(union_ty.containerLayout(zcu) != .@"packed");
                const loaded_union = ip.loadUnionType(union_ty.toIntern());
                const union_layout = ZigType.getUnionLayout(loaded_union, zcu);

                if (union_layout.tag_size > 0) unused_tag: {
                    const loaded_tag = ip.loadEnumType(loaded_union.enum_tag_type);
                    var tag_it = union_vi.value.field(union_ty, union_layout.tagOffset(), union_layout.tag_size);
                    const tag_vi = try tag_it.only(isel);
                    const tag_ra = try tag_vi.?.defReg(isel) orelse break :unused_tag;
                    switch (union_layout.tag_size) {
                        0 => unreachable,
                        1...4 => try isel.movImmediate(tag_ra.w(), @as(u32, switch (loaded_tag.field_values.len) {
                            0 => extra.field_index,
                            else => switch (ip.indexToKey(loaded_tag.field_values.get(ip)[extra.field_index]).int.storage) {
                                .u64 => |imm| @intCast(imm),
                                .i64 => |imm| @bitCast(@as(i32, @intCast(imm))),
                                else => unreachable,
                            },
                        })),
                        5...8 => try isel.movImmediate(tag_ra.x(), switch (loaded_tag.field_values.len) {
                            0 => extra.field_index,
                            else => switch (ip.indexToKey(loaded_tag.field_values.get(ip)[extra.field_index]).int.storage) {
                                .u64 => |imm| imm,
                                .i64 => |imm| @bitCast(imm),
                                else => unreachable,
                            },
                        }),
                        else => return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(union_ty) }),
                    }
                }
                const init_ty = isel.air.typeOf(extra.init, ip);
                if (init_ty.abiSize(zcu) == 0) break :unused;
                try union_vi.value.defAddr(isel, union_ty, .{}) orelse break :unused;

                if (try isel.copyInline(
                    .{ .value = .{ .vi = union_vi.value, .offset = union_layout.payloadOffset() } },
                    .{ .value = .{ .vi = try isel.use(extra.init) } },
                    init_ty.abiSize(zcu),
                    false,
                )) break :unused;

                try call.prepareVoidGlobal(isel, "memcpy");
                const init_vi = try isel.use(extra.init);
                try isel.movImmediate(.x2, init_vi.size(isel));
                const payload_offset = union_layout.payloadOffset();
                // x2 only receives the size afterwards, so it is free as a scratch here.
                try isel.addSubImmediate(.add, .x0, .x0, payload_offset, .{ .scratch = .x2 });
                try call.paramAddress(isel, init_vi, .r1);
                try call.paramAddress(isel, union_vi.value, .r0);
                try call.finishParams(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .prefetch => {
            const prefetch = air.data(air.inst_index).prefetch;
            if (!(prefetch.rw == .write and prefetch.cache == .instruction)) {
                const maybe_slice_ty = isel.air.typeOf(prefetch.ptr, ip);
                const maybe_slice_vi = try isel.use(prefetch.ptr);
                const ptr_vi = if (maybe_slice_ty.isSlice(zcu)) ptr_vi: {
                    var ptr_part_it = maybe_slice_vi.field(maybe_slice_ty, 0, 8);
                    const ptr_part_vi = try ptr_part_it.only(isel);
                    break :ptr_vi ptr_part_vi.?;
                } else maybe_slice_vi;
                const ptr_mat = try ptr_vi.matReg(isel);
                try isel.emit(.prfm(.{
                    .policy = switch (prefetch.locality) {
                        1, 2, 3 => .keep,
                        0 => .strm,
                    },
                    .target = switch (prefetch.locality) {
                        0, 3 => .l1,
                        2 => .l2,
                        1 => .l3,
                    },
                    .type = switch (prefetch.rw) {
                        .read => switch (prefetch.cache) {
                            .data => .pld,
                            .instruction => .pli,
                        },
                        .write => switch (prefetch.cache) {
                            .data => .pst,
                            .instruction => unreachable,
                        },
                    },
                }, .{ .base = ptr_mat.ra.x() }));
                try ptr_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .mul_add => {
            try isel.selectMulAdd(air.inst_index);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .field_parent_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |dst_vi| unused: {
                defer dst_vi.value.deref(isel);
                const ty_pl = air.data(air.inst_index).ty_pl;
                const extra = isel.air.extraData(Air.FieldParentPtr, ty_pl.payload).data;
                switch (codegen.fieldOffset(
                    ty_pl.ty,
                    isel.air.typeOf(extra.field_ptr, ip),
                    extra.field_index,
                    zcu,
                )) {
                    0 => try dst_vi.value.move(isel, extra.field_ptr),
                    else => |field_offset| {
                        const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                        const src_vi = try isel.use(extra.field_ptr);
                        const src_mat = try src_vi.matReg(isel);
                        try isel.addSubImmediate(.sub, dst_ra.x(), src_mat.ra.x(), field_offset, .{ .scratch = dst_ra.x() });
                        try src_mat.finish(isel);
                    },
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .wasm_memory_size, .wasm_memory_grow => unreachable,
        .cmp_lte_errors_len => {
            if (isel.live_values.fetchRemove(air.inst_index)) |is_vi| unused: {
                defer is_vi.value.deref(isel);
                const is_ra = try is_vi.value.defReg(isel) orelse break :unused;
                try isel.emit(.csinc(is_ra.w(), .wzr, .wzr, .invert(.ls)));

                const un_op = air.data(air.inst_index).un_op;
                const error_vi = try isel.use(un_op);
                const error_mat = try error_vi.matReg(isel);
                const ptr_ra = try isel.allocIntReg();
                defer isel.freeReg(ptr_ra);
                try isel.emit(.subs(.wzr, error_mat.ra.w(), .{ .register = ptr_ra.w() }));
                try isel.lazy_relocs.append(gpa, .{
                    .symbol = .{ .kind = .const_data, .ty = .anyerror_type },
                    .reloc = .{ .label = @intCast(isel.instructions.items.len) },
                });
                try isel.emit(.ldr(ptr_ra.w(), .{ .base = ptr_ra.x() }));
                try isel.lazy_relocs.append(gpa, .{
                    .symbol = .{ .kind = .const_data, .ty = .anyerror_type },
                    .reloc = .{ .label = @intCast(isel.instructions.items.len) },
                });
                try isel.emit(.adrp(ptr_ra.x(), 0));
                try error_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .runtime_nav_ptr => {
            if (isel.live_values.fetchRemove(air.inst_index)) |ptr_vi| unused: {
                defer ptr_vi.value.deref(isel);
                const ptr_ra = try ptr_vi.value.defReg(isel) orelse break :unused;

                const ty_nav = air.data(air.inst_index).ty_nav;
                const nav = ip.getNav(ty_nav.nav);
                if (zcu.comp.config.any_non_single_threaded and nav.resolved.?.@"threadlocal") {
                    try isel.tlsNavAddress(ptr_ra, ty_nav.nav, 0);
                } else if (nav.getExtern(ip) != null or
                    ZigType.fromInterned(nav.resolved.?.type).isRuntimeFnOrHasRuntimeBits(zcu)) switch (true) {
                    false => {
                        try isel.nav_relocs.append(gpa, .{
                            .nav = ty_nav.nav,
                            .reloc = .{ .label = @intCast(isel.instructions.items.len) },
                        });
                        try isel.emit(.adr(ptr_ra.x(), 0));
                    },
                    true => {
                        try isel.nav_relocs.append(gpa, .{
                            .nav = ty_nav.nav,
                            .reloc = .{ .label = @intCast(isel.instructions.items.len) },
                        });
                        if (nav.getExtern(ip)) |_|
                            try isel.emit(.ldr(ptr_ra.x(), .{ .unsigned_offset = .{ .base = ptr_ra.x(), .offset = 0 } }))
                        else
                            try isel.emit(.add(ptr_ra.x(), ptr_ra.x(), .{ .immediate = 0 }));
                        try isel.nav_relocs.append(gpa, .{
                            .nav = ty_nav.nav,
                            .reloc = .{ .label = @intCast(isel.instructions.items.len) },
                        });
                        try isel.emit(.adrp(ptr_ra.x(), 0));
                    },
                } else try isel.movImmediate(ptr_ra.x(), zcu.navAlignment(ty_nav.nav).forward(0xaaaaaaaaaaaaaaaa));
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .c_va_arg => {
            try isel.selectVaArg(air.inst_index);
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .c_va_copy => {
            if (isel.live_values.fetchRemove(air.inst_index)) |va_list_vi| {
                defer va_list_vi.value.deref(isel);
                const ty_op = air.data(air.inst_index).ty_op;
                const va_list_ptr_vi = try isel.use(ty_op.operand);
                const va_list_ptr_mat = try va_list_ptr_vi.matReg(isel);
                _ = try va_list_vi.value.load(isel, ty_op.ty, va_list_ptr_mat.ra, .{});
                try va_list_ptr_mat.finish(isel);
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .c_va_end => if (air.next()) |next_air_tag| continue :air_tag next_air_tag,
        .c_va_start => {
            if (isel.live_values.fetchRemove(air.inst_index)) |va_list_vi| {
                defer va_list_vi.value.deref(isel);
                const ty = air.data(air.inst_index).ty;
                switch (isel.va_list) {
                    .other => |va_list| if (try va_list_vi.value.defReg(isel)) |va_list_ra| try isel.emit(.add(
                        va_list_ra.x(),
                        va_list.base.x(),
                        .{ .immediate = @intCast(va_list.offset) },
                    )),
                    .sysv => |va_list| {
                        var vr_offs_it = va_list_vi.value.field(ty, 28, 4);
                        const vr_offs_vi = try vr_offs_it.only(isel);
                        if (try vr_offs_vi.?.defReg(isel)) |vr_offs_ra| try isel.movImmediate(
                            vr_offs_ra.w(),
                            @as(u32, @bitCast(va_list.__vr_offs)),
                        );
                        var gr_offs_it = va_list_vi.value.field(ty, 24, 4);
                        const gr_offs_vi = try gr_offs_it.only(isel);
                        if (try gr_offs_vi.?.defReg(isel)) |gr_offs_ra| try isel.movImmediate(
                            gr_offs_ra.w(),
                            @as(u32, @bitCast(va_list.__gr_offs)),
                        );
                        var vr_top_it = va_list_vi.value.field(ty, 16, 8);
                        const vr_top_vi = try vr_top_it.only(isel);
                        if (try vr_top_vi.?.defReg(isel)) |vr_top_ra| try isel.emit(.add(
                            vr_top_ra.x(),
                            va_list.__vr_top.base.x(),
                            .{ .immediate = @intCast(va_list.__vr_top.offset) },
                        ));
                        var gr_top_it = va_list_vi.value.field(ty, 8, 8);
                        const gr_top_vi = try gr_top_it.only(isel);
                        if (try gr_top_vi.?.defReg(isel)) |gr_top_ra| try isel.emit(.add(
                            gr_top_ra.x(),
                            va_list.__gr_top.base.x(),
                            .{ .immediate = @intCast(va_list.__gr_top.offset) },
                        ));
                        var stack_it = va_list_vi.value.field(ty, 0, 8);
                        const stack_vi = try stack_it.only(isel);
                        if (try stack_vi.?.defReg(isel)) |stack_ra| try isel.emit(.add(
                            stack_ra.x(),
                            va_list.__stack.base.x(),
                            .{ .immediate = @intCast(va_list.__stack.offset) },
                        ));
                    },
                }
            }
            if (air.next()) |next_air_tag| continue :air_tag next_air_tag;
        },
        .work_item_id, .work_group_size, .work_group_id, .spirv_runtime_array_len => unreachable,
    }
    assert(air.body_index == 0);
}

pub fn verify(isel: *Select, check_values: bool) void {
    if (!std.debug.runtime_safety) return;
    assert(isel.blocks.count() == 1 and isel.blocks.keys()[0] == Select.Block.main);
    assert(isel.active_loops.items.len == 0);
    assert(isel.dom_start == 0 and isel.dom_len == 0);
    var live_reg_it = isel.live_registers.iterator();
    while (live_reg_it.next()) |live_reg_entry| switch (live_reg_entry.value.*) {
        _ => {
            isel.dumpValues(.all);
            unreachable;
        },
        .allocating, .free => {},
    };
    if (check_values) for (isel.values.items) |value| if (value.refs != 0) {
        isel.dumpValues(.only_referenced);
        unreachable;
    };
}

///           Stack Frame Layout
/// +-+-----------------------------------+
/// |R| allocated stack                   |
/// +-+-----------------------------------+
/// |S| caller frame record               |   +---------------+
/// +-+-----------------------------------+ <-| entry/exit FP |
/// |R| caller frame                      |   +---------------+
/// +-+-----------------------------------+
/// |R| variable incoming stack arguments |   +---------------+
/// +-+-----------------------------------+ <-| __stack       |
/// |S| named incoming stack arguments    |   +---------------+
/// +-+-----------------------------------+ <-| entry/exit SP |
/// |S| incoming gr arguments             |   | __gr_top      |
/// +-+-----------------------------------+   +---------------+
/// |S| alignment gap                     |
/// +-+-----------------------------------+
/// |S| frame record                      |   +----------+
/// +-+-----------------------------------+ <-| FP       |
/// |S| incoming vr arguments             |   | __vr_top |
/// +-+-----------------------------------+   +----------+
/// |L| alignment gap                     |
/// +-+-----------------------------------+
/// |L| callee saved vr area              |
/// +-+-----------------------------------+
/// |L| callee saved gr area              |   +----------------------+
/// +-+-----------------------------------+ <-| prologue/epilogue SP |
/// |R| realignment gap                   |   +----------------------+
/// +-+-----------------------------------+
/// |L| locals                            |
/// +-+-----------------------------------+
/// |S| outgoing stack arguments          |   +----+
/// +-+-----------------------------------+ <-| SP |
/// |R| unallocated stack                 |   +----+
/// +-+-----------------------------------+
/// [S] Size computed by `analyze`, can be used by the body.
/// [L] Size computed by `layout`, can be used by the prologue/epilogue.
/// [R] Size unknown until runtime, can vary from one call to the next.
///
/// Constraints that led to this layout:
///  * FP to __stack/__gr_top/__vr_top must only pass through [S]
///  * SP to outgoing stack arguments/locals must only pass through [S]
///  * entry/exit SP to prologue/epilogue SP must only pass through [S/L]
///  * all save areas must be at a positive offset from prologue/epilogue SP
///  * the entry/exit SP to prologue/epilogue SP distance must
///   - be a multiple of 16 due to hardware restrictions on the value of SP
///   - conform to the limit from the first matching condition in the
///     following list due to instruction encoding limitations
///    1. callee saved gr count >= 2: multiple of 8 of at most 504 bytes
///    2. callee saved vr count >= 2: multiple of 8 of at most 504 bytes
///    3. callee saved gr count >= 1: at most 255 bytes
///    4. callee saved vr count >= 1: at most 255 bytes
///    5. variable incoming vr argument count >= 2: multiple of 16 of at most 1008 bytes
///    6. variable incoming vr argument count >= 1: at most 255 bytes
///    7. have frame record: multiple of 8 of at most 504 bytes
pub fn layout(
    isel: *Select,
    incoming: CallAbiIterator,
    is_sysv_var_args: bool,
    saved_gra_len: u7,
    saved_vra_len: u7,
    mod: *const Module,
    naked: bool,
) !usize {
    if (naked) {
        assert(isel.stack_size == 0);
        assert(!isel.returns);
        return isel.instructions.items.len;
    }
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(isel.nav_index);
    wip_mir_log.debug("{f}<body>:\n", .{nav.fqn.fmt(ip)});

    const stack_size: u24 = @intCast(InternPool.Alignment.@"16".forward(isel.stack_size));

    var saves_buf: [10 + 8 + 8 + 2 + 8]struct {
        class: enum { integer, vector },
        needs_restore: bool,
        register: Register,
        offset: u10,
        size: u5,
    } = undefined;
    const saves, const saves_size, const frame_record_offset = saves: {
        var saves_len: usize = 0;
        var saves_size: u10 = 0;
        var save_ra: Register.Alias = undefined;

        // callee saved gr area
        save_ra = .r19;
        while (save_ra != .r29) : (save_ra = @fromBackingInt(@intCast(@backingInt(save_ra) + 1))) {
            if (!isel.saved_registers.contains(save_ra)) continue;
            saves_size = std.mem.alignForward(u10, saves_size, 8);
            saves_buf[saves_len] = .{
                .class = .integer,
                .needs_restore = true,
                .register = save_ra.x(),
                .offset = saves_size,
                .size = 8,
            };
            saves_len += 1;
            saves_size += 8;
        }
        var deferred_gr = if (saves_size == 8 or (saves_size % 16 != 0 and saved_gra_len % 2 != 0)) gr: {
            saves_len -= 1;
            saves_size -= 8;
            break :gr saves_buf[saves_len].register;
        } else null;
        defer assert(deferred_gr == null);

        // callee saved vr area
        save_ra = .v8;
        while (save_ra != .v16) : (save_ra = @fromBackingInt(@intCast(@backingInt(save_ra) + 1))) {
            if (!isel.saved_registers.contains(save_ra)) continue;
            saves_size = std.mem.alignForward(u10, saves_size, 8);
            saves_buf[saves_len] = .{
                .class = .vector,
                .needs_restore = true,
                .register = save_ra.d(),
                .offset = saves_size,
                .size = 8,
            };
            saves_len += 1;
            saves_size += 8;
        }
        if (deferred_gr != null and saved_gra_len % 2 == 0) {
            saves_size = std.mem.alignForward(u10, saves_size, 8);
            saves_buf[saves_len] = .{
                .class = .integer,
                .needs_restore = true,
                .register = deferred_gr.?,
                .offset = saves_size,
                .size = 8,
            };
            saves_len += 1;
            saves_size += 8;
            deferred_gr = null;
        }
        if (saves_size % 16 != 0 and saved_vra_len % 2 != 0) {
            const prev_save = &saves_buf[saves_len - 1];
            switch (prev_save.class) {
                .integer => {},
                .vector => {
                    prev_save.register = prev_save.register.alias.q();
                    prev_save.size = 16;
                    saves_size += 8;
                },
            }
        }

        // incoming vr arguments
        save_ra = incoming.nsrn;
        while (save_ra != if (is_sysv_var_args) CallAbiIterator.nsrn_end else incoming.nsrn) : (save_ra = @fromBackingInt(@intCast(@backingInt(save_ra) + 1))) {
            saves_size = std.mem.alignForward(u10, saves_size, 16);
            saves_buf[saves_len] = .{
                .class = .vector,
                .needs_restore = false,
                .register = save_ra.q(),
                .offset = saves_size,
                .size = 16,
            };
            saves_len += 1;
            saves_size += 16;
        }

        // frame record
        saves_size = std.mem.alignForward(u10, saves_size, 16);
        const frame_record_offset = saves_size;
        saves_buf[saves_len] = .{
            .class = .integer,
            .needs_restore = true,
            .register = .fp,
            .offset = saves_size,
            .size = 8,
        };
        saves_len += 1;
        saves_size += 8;

        saves_size = std.mem.alignForward(u10, saves_size, 8);
        saves_buf[saves_len] = .{
            .class = .integer,
            .needs_restore = true,
            .register = .lr,
            .offset = saves_size,
            .size = 8,
        };
        saves_len += 1;
        saves_size += 8;

        // incoming gr arguments
        if (deferred_gr) |gr| {
            saves_size = std.mem.alignForward(u10, saves_size, 8);
            saves_buf[saves_len] = .{
                .class = .integer,
                .needs_restore = true,
                .register = gr,
                .offset = saves_size,
                .size = 8,
            };
            saves_len += 1;
            saves_size += 8;
            deferred_gr = null;
        } else switch (@as(u1, @truncate(saved_gra_len))) {
            0 => {},
            1 => saves_size += 8,
        }
        save_ra = incoming.ngrn;
        while (save_ra != if (is_sysv_var_args) CallAbiIterator.ngrn_end else incoming.ngrn) : (save_ra = @fromBackingInt(@intCast(@backingInt(save_ra) + 1))) {
            saves_size = std.mem.alignForward(u10, saves_size, 8);
            saves_buf[saves_len] = .{
                .class = .integer,
                .needs_restore = false,
                .register = save_ra.x(),
                .offset = saves_size,
                .size = 8,
            };
            saves_len += 1;
            saves_size += 8;
        }

        assert(InternPool.Alignment.@"16".check(saves_size));
        break :saves .{ saves_buf[0..saves_len], saves_size, frame_record_offset };
    };

    {
        wip_mir_log.debug("{f}<prologue>:", .{nav.fqn.fmt(ip)});
        isel.debug_section = .prologue;

        for (0..mod.patchable_function_entry) |_| {
            try isel.emit(.nop());
        }

        var save_index: usize = 0;
        while (save_index < saves.len) if (save_index + 2 <= saves.len and
            saves[save_index + 0].class == saves[save_index + 1].class and
            saves[save_index + 0].size == saves[save_index + 1].size and
            saves[save_index + 0].offset + saves[save_index + 0].size == saves[save_index + 1].offset)
        {
            try isel.emit(.stp(
                saves[save_index + 0].register,
                saves[save_index + 1].register,
                switch (saves[save_index + 0].offset) {
                    0 => .{ .pre_index = .{
                        .base = .sp,
                        .index = @intCast(-@as(i11, saves_size)),
                    } },
                    else => |offset| .{ .signed_offset = .{
                        .base = .sp,
                        .offset = @intCast(offset),
                    } },
                },
            ));
            if (save_index == 0) try isel.emitDebug(.{ .cfi = .{ .def_cfa_offset = saves_size } });
            for (saves[save_index..][0..2]) |save| if (save.needs_restore) try isel.emitDebug(.{ .cfi = .{ .offset = .{
                .reg = save.register.alias.dwarfNum(),
                .off = @as(i64, save.offset) - saves_size,
            } } });
            save_index += 2;
        } else {
            try isel.emit(.str(
                saves[save_index].register,
                switch (saves[save_index].offset) {
                    0 => .{ .pre_index = .{
                        .base = .sp,
                        .index = @intCast(-@as(i11, saves_size)),
                    } },
                    else => |offset| .{ .unsigned_offset = .{
                        .base = .sp,
                        .offset = @intCast(offset),
                    } },
                },
            ));
            if (save_index == 0) try isel.emitDebug(.{ .cfi = .{ .def_cfa_offset = saves_size } });
            const save = saves[save_index];
            if (save.needs_restore) try isel.emitDebug(.{ .cfi = .{ .offset = .{
                .reg = save.register.alias.dwarfNum(),
                .off = @as(i64, save.offset) - saves_size,
            } } });
            save_index += 1;
        };

        try isel.emit(.add(.fp, .sp, .{ .immediate = frame_record_offset }));
        try isel.emitDebug(.{ .cfi = .{ .def_cfa = .{ .reg = 29, .off = saves_size - frame_record_offset } } });
        const scratch_reg: Register = if (isel.stack_align == .@"16")
            .sp
        else if (stack_size == 0 and frame_record_offset == 0)
            .fp
        else
            .ip0;
        const stack_size_lo: u12 = @truncate(stack_size >> 0);
        const stack_size_hi: u12 = @truncate(stack_size >> 12);
        if (mod.stack_check) {
            if (stack_size_hi > 2) {
                try isel.movImmediate(.ip1, stack_size_hi);
                const loop_label = isel.instructions.items.len;
                try isel.emit(.sub(.sp, .sp, .{
                    .shifted_immediate = .{ .immediate = 1, .lsl = .@"12" },
                }));
                try isel.emit(.sub(.ip1, .ip1, .{ .immediate = 1 }));
                try isel.emit(.ldr(.xzr, .{ .base = .sp }));
                try isel.emit(.cbnz(.ip1, -@as(i21, @intCast(
                    (isel.instructions.items.len - loop_label) << 2,
                ))));
            } else for (0..stack_size_hi) |_| {
                try isel.emit(.sub(.sp, .sp, .{
                    .shifted_immediate = .{ .immediate = 1, .lsl = .@"12" },
                }));
                try isel.emit(.ldr(.xzr, .{ .base = .sp }));
            }
            if (stack_size_lo > 0) try isel.emit(.sub(
                scratch_reg,
                .sp,
                .{ .immediate = stack_size_lo },
            )) else if (scratch_reg.alias == Register.Alias.ip0)
                try isel.emit(.add(scratch_reg, .sp, .{ .immediate = 0 }));
        } else {
            if (stack_size_hi > 0) try isel.emit(.sub(scratch_reg, .sp, .{
                .shifted_immediate = .{ .immediate = stack_size_hi, .lsl = .@"12" },
            }));
            if (stack_size_lo > 0) try isel.emit(.sub(
                scratch_reg,
                if (stack_size_hi > 0) scratch_reg else .sp,
                .{ .immediate = stack_size_lo },
            )) else if (scratch_reg.alias == Register.Alias.ip0 and stack_size_hi == 0)
                try isel.emit(.add(scratch_reg, .sp, .{ .immediate = 0 }));
        }
        if (isel.stack_align != .@"16") try isel.emit(.@"and"(.sp, scratch_reg, .{ .immediate = .{
            .N = .doubleword,
            .immr = -%isel.stack_align.toLog2Units(),
            .imms = ~isel.stack_align.toLog2Units(),
        } }));
        wip_mir_log.debug("", .{});
    }

    try isel.emitDebug(.prologue_end);
    const epilogue = isel.instructions.items.len;
    isel.debug_section = .epilogue;
    if (isel.returns) {
        try isel.emit(.ret(.lr));
        var save_index: usize = 0;
        var first_offset: ?u10 = null;
        while (save_index < saves.len) {
            if (save_index + 2 <= saves.len and saves[save_index + 1].needs_restore and
                saves[save_index + 0].class == saves[save_index + 1].class and
                saves[save_index + 0].size == saves[save_index + 1].size and
                saves[save_index + 0].offset + saves[save_index + 0].size == saves[save_index + 1].offset)
            {
                if (first_offset == null) try isel.emitDebug(
                    .{ .cfi = .{ .def_cfa = .{ .reg = Register.Alias.sp.dwarfNum(), .off = 0 } } },
                );
                for (saves[save_index..][0..2]) |save| try isel.emitDebug(.{ .cfi = .{ .restore = save.register.alias.dwarfNum() } });
                try isel.emit(.ldp(
                    saves[save_index + 0].register,
                    saves[save_index + 1].register,
                    if (first_offset) |offset| .{ .signed_offset = .{
                        .base = .sp,
                        .offset = @intCast(saves[save_index + 0].offset - offset),
                    } } else form: {
                        first_offset = @intCast(saves[save_index + 0].offset);
                        break :form .{ .post_index = .{
                            .base = .sp,
                            .index = @intCast(saves_size - first_offset.?),
                        } };
                    },
                ));
                save_index += 2;
            } else if (saves[save_index].needs_restore) {
                if (first_offset == null) try isel.emitDebug(
                    .{ .cfi = .{ .def_cfa = .{ .reg = Register.Alias.sp.dwarfNum(), .off = 0 } } },
                );
                try isel.emitDebug(.{ .cfi = .{ .restore = saves[save_index].register.alias.dwarfNum() } });
                try isel.emit(.ldr(
                    saves[save_index].register,
                    if (first_offset) |offset| .{ .unsigned_offset = .{
                        .base = .sp,
                        .offset = saves[save_index + 0].offset - offset,
                    } } else form: {
                        const offset = saves[save_index + 0].offset;
                        first_offset = offset;
                        break :form .{ .post_index = .{
                            .base = .sp,
                            .index = @intCast(saves_size - offset),
                        } };
                    },
                ));
                save_index += 1;
            } else save_index += 1;
        }
        try isel.emitDebug(.{ .cfi = .{ .def_cfa = .{ .reg = Register.Alias.sp.dwarfNum(), .off = saves_size - first_offset.? } } });
        const offset = stack_size + first_offset.?;
        const offset_lo: u12 = @truncate(offset >> 0);
        const offset_hi: u12 = @truncate(offset >> 12);
        if (isel.stack_align != .@"16" or (offset_lo > 0 and offset_hi > 0)) {
            const fp_offset = @as(i11, first_offset.?) - frame_record_offset;
            try isel.emit(if (fp_offset >= 0)
                .add(.sp, .fp, .{ .immediate = @intCast(fp_offset) })
            else
                .sub(.sp, .fp, .{ .immediate = @intCast(-fp_offset) }));
        } else {
            if (offset_hi > 0) try isel.emit(.add(.sp, .sp, .{
                .shifted_immediate = .{ .immediate = offset_hi, .lsl = .@"12" },
            }));
            if (offset_lo > 0) try isel.emit(.add(.sp, .sp, .{
                .immediate = offset_lo,
            }));
        }
        try isel.emitDebug(.epilogue_begin);
        wip_mir_log.debug("{f}<epilogue>:\n", .{nav.fqn.fmt(ip)});
    }
    if (isel.tail_branches.items.len > 0) {
        assert(isel.returns);
        const normal_end = isel.instructions.items.len;
        const normal_len = normal_end - epilogue;
        const tail_epilogue = try zcu.gpa.dupe(codegen.aarch64.encoding.Instruction, isel.instructions.items[epilogue..]);
        defer zcu.gpa.free(tail_epilogue);
        tail_epilogue[0] = .br(Register.Alias.r16.x());
        // Epilogues are emitted backwards. Inserting the tail copy here leaves
        // the ordinary RET at the body boundary and puts the tail BR after it.
        try isel.instructions.insertSlice(zcu.gpa, epilogue, tail_epilogue);
        const debug_len = isel.debug_events.items.len;
        for (0..debug_len) |event_index| {
            const event = isel.debug_events.items[event_index];
            if (event.section != .epilogue) continue;
            isel.debug_events.items[event_index].offset += @intCast(normal_len);
            try isel.debug_events.append(zcu.gpa, event);
        }
        try isel.debug_events.append(zcu.gpa, .{
            .section = .epilogue,
            .offset = @intCast(normal_end + normal_len),
            .seq = @intCast(isel.debug_events.items.len),
            .info = .{ .cfi = .remember_state },
        });
        try isel.debug_events.append(zcu.gpa, .{
            .section = .epilogue,
            .offset = @intCast(normal_end),
            .seq = @intCast(isel.debug_events.items.len),
            .info = .{ .cfi = .restore_state },
        });
        for (isel.tail_branches.items) |label| {
            const offset = std.math.cast(i28, (@as(usize, label) + 1 + normal_len) << 2) orelse
                return isel.fail("tail epilogue branch too large", .{});
            isel.instructions.items[label] = .b(offset);
        }
    }
    return epilogue;
}

fn fmtDom(isel: *Select, inst: Air.Inst.Index, start: u32, len: u32) struct {
    isel: *Select,
    inst: Air.Inst.Index,
    start: u32,
    len: u32,
    pub fn format(data: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("%{d} -> {{", .{@backingInt(data.inst)});
        var first = true;
        for (data.isel.blocks.keys()[0..data.len], 0..) |block_inst_index, dom_index| {
            if (@as(u1, @truncate(data.isel.dom.items[
                data.start + dom_index / @bitSizeOf(DomInt)
            ] >> @truncate(dom_index))) == 0) continue;
            if (first) {
                first = false;
            } else {
                try writer.writeByte(',');
            }
            switch (block_inst_index) {
                Block.main => try writer.writeAll(" %main"),
                else => try writer.print(" %{d}", .{@backingInt(block_inst_index)}),
            }
        }
        if (!first) try writer.writeByte(' ');
        try writer.writeByte('}');
    }
} {
    return .{ .isel = isel, .inst = inst, .start = start, .len = len };
}

fn fmtLoopLive(isel: *Select, loop_inst: Air.Inst.Index) struct {
    isel: *Select,
    inst: Air.Inst.Index,
    pub fn format(data: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const loops = data.isel.loops.values();
        const loop_index = data.isel.loops.getIndex(data.inst).?;
        const live_insts =
            data.isel.loop_live.list.items[loops[loop_index].live..loops[loop_index + 1].live];

        try writer.print("%{d} <- {{", .{@backingInt(data.inst)});
        var first = true;
        for (live_insts) |live_inst| {
            if (first) {
                first = false;
            } else {
                try writer.writeByte(',');
            }
            try writer.print(" %{d}", .{@backingInt(live_inst)});
        }
        if (!first) try writer.writeByte(' ');
        try writer.writeByte('}');
    }
} {
    return .{ .isel = isel, .inst = loop_inst };
}

pub fn fmtType(isel: *Select, ty: ZigType) ZigType.Formatter {
    return ty.fmt(isel.pt.zcu);
}

fn fmtConstant(isel: *Select, constant: Constant) @typeInfo(@TypeOf(Constant.fmtValue)).@"fn".return_type.? {
    return constant.fmtValue(isel.pt.zcu);
}

fn block(
    isel: *Select,
    air_inst_index: Air.Inst.Index,
    res_ty: ZigType,
    air_body: []const Air.Inst.Index,
    pred: ?Air.Inst.Index,
) !void {
    if (res_ty.toIntern() != .noreturn_type) {
        isel.blocks.putAssumeCapacityNoClobber(air_inst_index, .{
            .live_registers = isel.live_registers,
            .target_label = @intCast(isel.instructions.items.len),
        });
    }
    try isel.body(air_body, pred);
    if (res_ty.toIntern() != .noreturn_type) {
        const block_entry = isel.blocks.pop().?;
        assert(block_entry.key == air_inst_index);
        if (isel.live_values.fetchRemove(air_inst_index)) |result_vi| result_vi.value.deref(isel);
    }
}

/// `try` and `try_cold`: the payload is a field of the error union, and
/// the error path is taken when the error set part is nonzero.
fn selectTry(isel: *Select, inst: Air.Inst.Index) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const unwrapped_try = isel.air.unwrapTry(inst);
    const error_union_ty = isel.air.typeOf(unwrapped_try.error_union, ip);
    const error_union_info = ip.indexToKey(error_union_ty.toIntern()).error_union_type;
    const payload_ty: ZigType = .fromInterned(error_union_info.payload_type);

    const error_union_vi = try isel.use(unwrapped_try.error_union);
    if (isel.live_values.fetchRemove(inst)) |payload_vi| {
        defer payload_vi.value.deref(isel);
        try payload_vi.value.copyField(
            isel,
            payload_ty,
            0,
            error_union_vi,
            error_union_ty,
            codegen.errUnionPayloadOffset(payload_ty, zcu),
            payload_vi.value.size(isel),
        );
    }

    var error_set_part_it = error_union_vi.field(
        error_union_ty,
        codegen.errUnionErrorOffset(payload_ty, zcu),
        ZigType.fromInterned(error_union_info.error_set_type).abiSize(zcu),
    );
    const error_set_part_vi = (try error_set_part_it.only(isel)).?;
    const error_set_part_mat = try error_set_part_vi.matReg(isel);
    // The test is the only use of the register, before the branch at
    // runtime, so the error path may use it too; a value it evicts there is
    // restored on both paths.
    isel.freeReg(error_set_part_mat.ra);

    const cont_label = isel.instructions.items.len;
    const cont_live_registers = isel.live_registers;
    try isel.body(unwrapped_try.else_body, null);
    // As at a `cond_br`, values the error path uses stay where it expects
    // them before the branch.
    try isel.merge(&cont_live_registers, .{});

    // An error path that wants the error set in a register tests that one,
    // and the materialization above is not used.
    if (error_set_part_vi.register(isel)) |error_set_ra| if (!error_set_ra.isVector()) {
        assert(isel.live_registers.get(error_set_ra) == error_set_part_vi);
        assert(isel.live_registers.get(error_set_part_mat.ra) != .allocating);
        return isel.emitBranch(.{ .zero = error_set_ra.w() }, cont_label);
    };
    // Error-path values left in the register are moved by the error path,
    // the only one that uses them.
    try isel.vacateBranchReg(error_set_part_mat.ra);
    isel.reserveReg(error_set_part_mat.ra);
    try isel.emitBranch(.{ .zero = error_set_part_mat.ra.w() }, cont_label);
    try error_set_part_mat.finish(isel);
}

/// `try_ptr` and `try_ptr_cold`, as `try` through the error union's pointer.
fn selectTryPtr(isel: *Select, inst: Air.Inst.Index) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const unwrapped_try = isel.air.unwrapTryPtr(inst);
    const error_union_ty = isel.air.typeOf(unwrapped_try.error_union_ptr, ip).childType(zcu);
    const error_union_info = ip.indexToKey(error_union_ty.toIntern()).error_union_type;
    const payload_ty: ZigType = .fromInterned(error_union_info.payload_type);

    const error_union_ptr_vi = try isel.use(unwrapped_try.error_union_ptr);
    if (isel.live_values.fetchRemove(inst)) |payload_ptr_vi| unused: {
        defer payload_ptr_vi.value.deref(isel);
        switch (codegen.errUnionPayloadOffset(unwrapped_try.error_union_payload_ptr_ty.childType(zcu), zcu)) {
            0 => try payload_ptr_vi.value.move(isel, unwrapped_try.error_union_ptr),
            else => |payload_offset| {
                const payload_ptr_ra = try payload_ptr_vi.value.defReg(isel) orelse break :unused;
                const payload_ptr_lock = isel.tryLockReg(payload_ptr_ra);
                defer payload_ptr_lock.unlock(isel);
                const error_union_ptr_mat = try error_union_ptr_vi.matReg(isel);
                try isel.addSubImmediate(.add, payload_ptr_ra.x(), error_union_ptr_mat.ra.x(), payload_offset, .{ .scratch = payload_ptr_ra.x() });
                try error_union_ptr_mat.finish(isel);
            },
        }
    }

    const error_set_ra = try isel.allocIntReg();
    const error_union_ptr_mat = try error_union_ptr_vi.matReg(isel);
    isel.freeReg(error_union_ptr_mat.ra);
    isel.freeReg(error_set_ra);

    const cont_label = isel.instructions.items.len;
    const cont_live_registers = isel.live_registers;
    try isel.body(unwrapped_try.else_body, null);
    // As for `try`: error-path values stay in registers, and only the
    // registers taken by the test are vacated, on the error path.
    try isel.merge(&cont_live_registers, .{});

    try isel.vacateBranchReg(error_set_ra);
    const error_set_lock = isel.lockReg(error_set_ra);
    defer error_set_lock.unlock(isel);
    try isel.vacateBranchReg(error_union_ptr_mat.ra);
    isel.reserveReg(error_union_ptr_mat.ra);
    try isel.emitBranch(.{ .zero = error_set_ra.w() }, cont_label);
    try isel.loadReg(
        error_set_ra,
        ZigType.fromInterned(error_union_info.error_set_type).abiSize(zcu),
        .unsigned,
        error_union_ptr_mat.ra,
        codegen.errUnionErrorOffset(payload_ty, zcu),
    );
    try error_union_ptr_mat.finish(isel);
}

/// `assembly`. Operands are bound to registers, the source is assembled in
/// execution order, and named and clobbered registers are reserved around it.
fn selectAsm(isel: *Select, inst: Air.Inst.Index) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = zcu.gpa;
    const unwrapped_asm = isel.air.unwrapAsm(inst);
    const inputs = unwrapped_asm.inputs;

    var as: codegen.aarch64.Assemble = .{
        .source = undefined,
        .operands = .empty,
    };
    defer as.operands.deinit(gpa);

    // The output registers hold the outputs right after the assembly, where the
    // moves that refill the pinned input registers also go: they stay reserved
    // until those moves are selected, so that none of them goes through an
    // output register.
    var output_regs: std.ArrayList(Register.Alias) = .empty;
    defer output_regs.deinit(gpa);
    try output_regs.ensureTotalCapacity(gpa, unwrapped_asm.outputs.len);

    var it = unwrapped_asm.iterateOutputs();
    while (it.next()) |output| {
        const constraint = output.constraint;
        if (!std.mem.startsWith(u8, constraint, "="))
            return isel.fail("invalid constraint: '{s}'", .{constraint});
        const alternative = asmConstraintAlternative(constraint["=".len..]);
        const output_ty = switch (output.operand) {
            .none => isel.air.instructions.items(.data)[@backingInt(inst)].ty_pl.ty,
            else => isel.air.typeOf(output.operand, ip).childType(zcu),
        };
        const output_ra: Register.Alias = if (asmConstraintRegister(alternative)) |parsed| output_ra: {
            const output_ra = (parsed orelse return isel.fail("invalid constraint: '{s}'", .{constraint})).alias;
            isel.saved_registers.insert(output_ra);
            if (output.operand == .none) if (isel.live_values.fetchRemove(inst)) |output_vi| {
                defer output_vi.value.deref(isel);
                try output_vi.value.defLiveIn(isel, output_ra, comptime &.initFill(.free));
                output_regs.appendAssumeCapacity(output_ra);
                break :output_ra output_ra;
            };
            // The assembly overwrites this register, so evict any value live in it.
            if (!try isel.fill(output_ra)) return isel.fail("unable to clobber: '{s}'", .{constraint});
            if (output.operand != .none) isel.reserveReg(output_ra);
            break :output_ra output_ra;
        } else if (std.mem.eql(u8, alternative, "r")) output_ra: {
            if (output.operand == .none) if (isel.live_values.fetchRemove(inst)) |output_vi| {
                defer output_vi.value.deref(isel);
                if (try output_vi.value.defReg(isel)) |output_ra| {
                    isel.reserveReg(output_ra);
                    output_regs.appendAssumeCapacity(output_ra);
                    break :output_ra output_ra;
                }
            };
            const output_ra = try isel.allocIntReg();
            if (output.operand == .none) isel.freeReg(output_ra);
            break :output_ra output_ra;
        } else return isel.fail("invalid constraint: '{s}'", .{constraint});
        const output_reg = try isel.asmOperandRegister(output_ra, output_ty);
        if (output.operand != .none) {
            // Store the register output through its pointer after the assembly.
            const ptr_mat = try (try isel.use(output.operand)).matReg(isel);
            if (output_ra.isVector()) return isel.fail("invalid constraint: '{s}'", .{constraint});
            try isel.storeReg(output_ra, output_ty.abiSize(zcu), ptr_mat.ra, 0);
            try ptr_mat.finish(isel);
            output_regs.appendAssumeCapacity(output_ra);
        }
        try isel.addAsmOperand(&as, output.name, .{ .register = output_reg });
    }

    // Reserve every pinned input register first, so no other operand is allocated to it.
    it = unwrapped_asm.iterateInputs();
    while (it.next()) |input| {
        const parsed = asmConstraintRegister(asmConstraintAlternative(input.constraint)) orelse continue;
        const input_reg = parsed orelse return isel.fail("invalid constraint: '{s}'", .{input.constraint});
        isel.saved_registers.insert(input_reg.alias);
        // An output register is free before the assembly: it now serves the input.
        if (std.mem.findScalar(Register.Alias, output_regs.items, input_reg.alias)) |output_index| {
            _ = output_regs.swapRemove(output_index);
            continue;
        }
        if (!try isel.fill(input_reg.alias))
            return isel.fail("unable to use input register: '{s}'", .{input.constraint});
        isel.reserveReg(input_reg.alias);
    }
    for (output_regs.items) |output_ra| isel.freeReg(output_ra);

    const input_mats = try gpa.alloc(Value.Materialize, inputs.len);
    defer gpa.free(input_mats);
    var index: u32 = 0;
    it = unwrapped_asm.iterateInputs();
    while (it.next()) |input| : (index += 1) {
        const constraint = asmConstraintAlternative(input.constraint);
        const name = input.name;
        const input_ty = isel.air.typeOf(input.operand, ip);
        if (asmConstraintRegister(constraint)) |parsed| {
            const input_ra = parsed.?.alias;
            input_mats[index] = .{ .vi = try isel.use(input.operand), .ra = input_ra };
            try isel.addAsmRegisterOperand(&as, name, input_ra, input_ty);
        } else if (std.mem.eql(u8, constraint, "r") or (std.mem.eql(u8, constraint, "X") and input.operand.toInterned() == null)) {
            input_mats[index] = try (try isel.use(input.operand)).matReg(isel);
            try isel.addAsmRegisterOperand(&as, name, input_mats[index].ra, input_ty);
        } else if (std.mem.eql(u8, constraint, "i") or std.mem.eql(u8, constraint, "n") or std.mem.eql(u8, constraint, "X")) {
            const constant = input.operand.toInterned() orelse
                return isel.fail("immediate operand requires comptime value: '{s}'", .{constraint});
            try isel.addAsmOperand(&as, name, switch (ip.indexToKey(constant)) {
                .int => imm: {
                    var bigint_buf: Constant.BigIntSpace = undefined;
                    const bigint = Constant.fromInterned(constant).toBigInt(&bigint_buf, zcu);
                    break :imm .{ .immediate = bigint.toInt(i128) catch
                        return isel.fail("inline asm immediate is too large", .{}) };
                },
                .ptr => |ptr| symbol: {
                    if (!std.mem.eql(u8, constraint, "X"))
                        return isel.fail("unsupported symbolic constraint: '{s}'", .{constraint});
                    switch (ptr.base_addr) {
                        .nav, .uav => {},
                        else => return isel.fail("unsupported inline asm symbol", .{}),
                    }
                    break :symbol .{ .symbol = index };
                },
                inline .func, .@"extern" => .{ .symbol = index },
                else => return isel.fail("unsupported inline asm constant: '{f}'", .{
                    isel.fmtConstant(.fromInterned(constant)),
                }),
            });
        } else if (std.mem.eql(u8, name, "_")) {
            input_mats[index].vi = try isel.use(input.operand);
        } else return isel.fail("invalid constraint: '{s}'", .{constraint});
    }

    var clobbers_bigint_buf: Constant.BigIntSpace = undefined;
    var clobber_it = isel.asmClobbers(unwrapped_asm.clobbers, &clobbers_bigint_buf);
    while (try clobber_it.next()) |clobber| {
        isel.saved_registers.insert(clobber.ra);
        switch (isel.live_registers.get(clobber.ra)) {
            _ => {},
            .allocating => return isel.fail("clobbered twice: '{s}'", .{clobber.name}),
            .free => isel.reserveReg(clobber.ra),
        }
    }
    clobber_it.reset();
    while (try clobber_it.next()) |clobber| {
        switch (isel.live_registers.get(clobber.ra)) {
            _ => {
                if (!try isel.fill(clobber.ra))
                    return isel.fail("unable to clobber: '{s}'", .{clobber.name});
                isel.reserveReg(clobber.ra);
            },
            .allocating => {},
            .free => unreachable,
        }
    }

    as.source = unwrapped_asm.source;
    try isel.assemble(&as, inputs);

    it = unwrapped_asm.iterateInputs();
    index = 0;
    while (it.next()) |input| : (index += 1) {
        const constraint = asmConstraintAlternative(input.constraint);
        if (asmConstraintRegister(constraint) != null) {
            isel.freeReg(input_mats[index].ra);
            try input_mats[index].vi.liveOut(isel, input_mats[index].ra);
        } else if (std.mem.eql(u8, constraint, "r")) {
            try input_mats[index].finish(isel);
        } else if (std.mem.eql(u8, constraint, "i") or std.mem.eql(u8, constraint, "n")) {
            // An immediate.
        } else if (std.mem.eql(u8, constraint, "X")) {
            if (input.operand.toInterned() == null) try input_mats[index].finish(isel);
        } else if (std.mem.eql(u8, input.name, "_")) {
            try input_mats[index].vi.mat(isel);
        } else unreachable;
    }

    clobber_it.reset();
    while (try clobber_it.next()) |clobber| isel.freeReg(clobber.ra);
}

/// The register of an `{reg}` asm constraint: null for another constraint,
/// and an inner null when the register does not parse.
fn asmConstraintRegister(constraint: []const u8) ??Register {
    if (!std.mem.startsWith(u8, constraint, "{") or !std.mem.endsWith(u8, constraint, "}")) return null;
    return Register.parse(constraint["{".len .. constraint.len - "}".len]);
}

/// The view of `ra` that an asm operand of `ty` names.
fn asmOperandRegister(isel: *Select, ra: Register.Alias, ty: ZigType) !Register {
    return switch (ty.abiSize(isel.pt.zcu)) {
        0 => unreachable,
        1...4 => ra.w(),
        5...8 => ra.x(),
        else => isel.fail("too big asm operand type: '{f}'", .{isel.fmtType(ty)}),
    };
}

/// Binds `name` in the assembly to the view of `ra` for `ty`, unless it is `_`.
fn addAsmRegisterOperand(
    isel: *Select,
    as: *codegen.aarch64.Assemble,
    name: []const u8,
    ra: Register.Alias,
    ty: ZigType,
) !void {
    if (std.mem.eql(u8, name, "_")) return;
    try isel.addAsmOperand(as, name, .{ .register = try isel.asmOperandRegister(ra, ty) });
}

/// Binds `name` in the assembly to `operand`, unless it is `_`.
fn addAsmOperand(
    isel: *Select,
    as: *codegen.aarch64.Assemble,
    name: []const u8,
    operand: codegen.aarch64.Assemble.Operand,
) !void {
    if (std.mem.eql(u8, name, "_")) return;
    const operand_gop = try as.operands.getOrPut(isel.pt.zcu.gpa, name);
    if (operand_gop.found_existing) return isel.fail("duplicate asm operand name: '{s}'", .{name});
    operand_gop.value_ptr.* = operand;
}

/// The registers that an `assembly` instruction's clobbers name; the
/// `memory` and `nzcv` clobbers name none.
const AsmClobberIterator = struct {
    isel: *Select,
    ty: ZigType,
    bigint: std.math.big.int.Const,
    field_index: usize,

    fn next(it: *AsmClobberIterator) !?struct { name: []const u8, ra: Register.Alias } {
        const zcu = it.isel.pt.zcu;
        const limb_bits = @bitSizeOf(std.math.big.Limb);
        while (it.field_index < it.ty.structFieldCount(zcu)) {
            const field_index = it.field_index;
            it.field_index += 1;
            assert(it.ty.fieldType(field_index, zcu).toIntern() == .bool_type);
            if (field_index / limb_bits >= it.bigint.limbs.len) continue; // field is false
            if (@as(u1, @truncate(it.bigint.limbs[field_index / limb_bits] >> @intCast(field_index % limb_bits))) == 0)
                continue; // field is false
            const name = it.ty.structFieldName(field_index, zcu).toSlice(&zcu.intern_pool).?;
            if (std.mem.eql(u8, name, "memory") or std.mem.eql(u8, name, "nzcv")) continue;
            const reg = Register.parse(name) orelse return it.isel.fail("unable to parse clobber: '{s}'", .{name});
            return .{ .name = name, .ra = reg.alias };
        }
        return null;
    }

    fn reset(it: *AsmClobberIterator) void {
        it.field_index = 0;
    }
};

fn asmClobbers(isel: *Select, clobbers: InternPool.Index, bigint_buf: *Constant.BigIntSpace) AsmClobberIterator {
    const clobbers_val: Constant = .fromInterned(clobbers);
    return .{
        .isel = isel,
        .ty = clobbers_val.typeOf(isel.pt.zcu),
        .bigint = clobbers_val.toBigInt(bigint_buf, isel.pt.zcu),
        .field_index = 0,
    };
}

/// Assembles `as.source` in execution order, with relocations for its
/// symbol operands, which are `inputs`.
fn assemble(isel: *Select, as: *codegen.aarch64.Assemble, inputs: []const Air.Inst.Ref) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = zcu.gpa;
    const segment: ForwardSegment = .begin(isel);
    while (true) {
        if (as.nextDirective() catch return isel.fail("invalid inline asm CFI directive", .{})) |reg| {
            try isel.emitDebug(.{ .cfi = .{ .undefined = reg.alias.dwarfNum() } });
            continue;
        }
        const instruction = (as.nextInstruction() catch |err| switch (err) {
            error.InvalidSyntax => {
                const remaining_source = std.mem.span(as.source);
                return isel.fail("unable to assemble: '{s}'", .{std.mem.trim(
                    u8,
                    as.source[0 .. std.mem.findScalar(u8, remaining_source, '\n') orelse remaining_source.len],
                    &std.ascii.whitespace,
                )});
            },
        }) orelse break;
        if (as.reloc) |input_index| {
            switch (instruction.decode()) {
                .branch_exception_generating_system => |branch| switch (branch.decode()) {
                    .unconditional_branch_immediate => {},
                    else => return isel.fail("unsupported inline asm symbol relocation", .{}),
                },
                else => return isel.fail("unsupported inline asm symbol relocation", .{}),
            }
            const reloc: codegen.aarch64.Mir.Reloc = .{ .label = @intCast(isel.instructions.items.len) };
            switch (ip.indexToKey(inputs[input_index].toInterned().?)) {
                inline .func, .@"extern" => |func| {
                    if (zcu.comp.config.any_non_single_threaded and ip.getNav(func.owner_nav).resolved.?.@"threadlocal")
                        return isel.fail("thread-local inline assembly symbol relocation", .{});
                    try isel.nav_relocs.append(gpa, .{
                        .nav = func.owner_nav,
                        .reloc = reloc,
                    });
                },
                .ptr => |ptr| switch (ptr.base_addr) {
                    .nav => |nav| {
                        if (zcu.comp.config.any_non_single_threaded and ip.getNav(nav).resolved.?.@"threadlocal")
                            return isel.fail("thread-local inline assembly symbol relocation", .{});
                        try isel.nav_relocs.append(gpa, .{
                            .nav = nav,
                            .reloc = .{ .label = reloc.label, .addend = ptr.byte_offset },
                        });
                    },
                    .uav => |uav| try isel.uav_relocs.append(gpa, .{
                        .uav = uav,
                        .reloc = .{ .label = reloc.label, .addend = ptr.byte_offset },
                    }),
                    else => unreachable,
                },
                else => unreachable,
            }
        }
        try isel.emit(instruction);
    }
    segment.end(isel);
}

/// The value that `inst` defines, or `null` if nothing uses it. An unused
/// instruction that is still lowered for its safety check (`Air.mustLower`)
/// defines a temporary that nothing reads, in a scratch register when it fits
/// one, so that selecting it emits the check. The caller derefs the value.
fn checkedDef(isel: *Select, inst: Air.Inst.Index) !?Value.Index {
    if (isel.live_values.fetchRemove(inst)) |live| return live.value;
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (!isel.air.mustLower(inst, ip)) return null;
    try isel.values.ensureUnusedCapacity(zcu.gpa, 1);
    const vi = isel.initValue(isel.air.typeOfIndex(inst, ip)).ref(isel);
    errdefer vi.deref(isel);
    if (vi.size(isel) <= 8) {
        const ra = try isel.allocIntReg();
        isel.freeReg(ra);
        try vi.liveOut(isel, ra);
    }
    return vi;
}

/// `add` and `sub`, wrapping, safety-checked and of floats.
fn selectAddSub(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (try isel.checkedDef(inst)) |res_vi| unused: {
        defer res_vi.deref(isel);

        const bin_op = isel.air.instructions.items(.data)[@backingInt(inst)].bin_op;
        const ty = isel.air.typeOf(bin_op.lhs, ip);
        if (ty.isVector(zcu)) {
            const arrangement = isel.simdIntArrangement(ty) orelse
                return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
            const res_def = try isel.defVector(res_vi) orelse break :unused;
            defer res_def.finish(isel);
            const res_ra = res_def.ra;
            const lhs_mat = try (try isel.use(bin_op.lhs)).matReg(isel);
            const rhs_mat = try (try isel.use(bin_op.rhs)).matReg(isel);
            const res_reg = res_ra.vector(arrangement);
            const lhs_reg = lhs_mat.ra.vector(arrangement);
            const rhs_reg = rhs_mat.ra.vector(arrangement);
            try isel.emit(switch (air_tag) {
                else => unreachable,
                .add, .add_wrap => .add(res_reg, lhs_reg, .{ .register = rhs_reg }),
                .sub, .sub_wrap => .sub(res_reg, lhs_reg, .{ .register = rhs_reg }),
            });
            try rhs_mat.finish(isel);
            try lhs_mat.finish(isel);
            break :unused;
        }
        if (!ty.isRuntimeFloat()) try res_vi.addOrSubtract(isel, ty, try isel.use(bin_op.lhs), switch (air_tag) {
            else => unreachable,
            .add, .add_safe, .add_wrap => .add,
            .sub, .sub_safe, .sub_wrap => .sub,
        }, try isel.use(bin_op.rhs), .{
            .overflow = switch (air_tag) {
                else => unreachable,
                .add, .sub => .@"unreachable",
                .add_safe, .sub_safe => .{ .panic = .integer_overflow },
                .add_wrap, .sub_wrap => .wrap,
            },
        }) else switch (ty.floatBits(isel.target)) {
            else => unreachable,
            16, 32, 64 => |bits| {
                const res_ra = try res_vi.defReg(isel) orelse break :unused;
                const need_fcvt = switch (bits) {
                    else => unreachable,
                    16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                    32, 64 => false,
                };
                if (need_fcvt) try isel.emit(.fcvt(res_ra.h(), res_ra.s()));
                const lhs_vi = try isel.use(bin_op.lhs);
                const rhs_vi = try isel.use(bin_op.rhs);
                const lhs_mat = try lhs_vi.matReg(isel);
                const rhs_mat = try rhs_vi.matReg(isel);
                const lhs_ra = if (need_fcvt) try isel.allocVecReg() else lhs_mat.ra;
                defer if (need_fcvt) isel.freeReg(lhs_ra);
                const rhs_ra = if (need_fcvt) try isel.allocVecReg() else rhs_mat.ra;
                defer if (need_fcvt) isel.freeReg(rhs_ra);
                try isel.emit(bits: switch (bits) {
                    else => unreachable,
                    16 => if (need_fcvt) continue :bits 32 else switch (air_tag) {
                        else => unreachable,
                        .add, .add_optimized => .fadd(res_ra.h(), lhs_ra.h(), rhs_ra.h()),
                        .sub, .sub_optimized => .fsub(res_ra.h(), lhs_ra.h(), rhs_ra.h()),
                    },
                    32 => switch (air_tag) {
                        else => unreachable,
                        .add, .add_optimized => .fadd(res_ra.s(), lhs_ra.s(), rhs_ra.s()),
                        .sub, .sub_optimized => .fsub(res_ra.s(), lhs_ra.s(), rhs_ra.s()),
                    },
                    64 => switch (air_tag) {
                        else => unreachable,
                        .add, .add_optimized => .fadd(res_ra.d(), lhs_ra.d(), rhs_ra.d()),
                        .sub, .sub_optimized => .fsub(res_ra.d(), lhs_ra.d(), rhs_ra.d()),
                    },
                });
                if (need_fcvt) {
                    try isel.emit(.fcvt(rhs_ra.s(), rhs_mat.ra.h()));
                    try isel.emit(.fcvt(lhs_ra.s(), lhs_mat.ra.h()));
                }
                try rhs_mat.finish(isel);
                try lhs_mat.finish(isel);
            },
            80, 128 => |bits| {
                try call.compilerRt(isel, switch (air_tag) {
                    else => unreachable,
                    .add, .add_optimized => switch (bits) {
                        else => unreachable,
                        16 => "__addhf3",
                        32 => "__addsf3",
                        64 => "__adddf3",
                        80 => "__addxf3",
                        128 => "__addtf3",
                    },
                    .sub, .sub_optimized => switch (bits) {
                        else => unreachable,
                        16 => "__subhf3",
                        32 => "__subsf3",
                        64 => "__subdf3",
                        80 => "__subxf3",
                        128 => "__subtf3",
                    },
                }, res_vi, ty, &.{ bin_op.lhs, bin_op.rhs });
            },
        }
    }
}

/// `add_sat` and `sub_sat` of integers of at most 128 bits.
fn selectAddSubSat(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const bin_op = isel.air.instructions.items(.data)[@backingInt(inst)].bin_op;
        const ty = isel.air.typeOf(bin_op.lhs, ip);
        if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
        const int_info = ty.intInfo(zcu);
        switch (int_info.bits) {
            0 => unreachable,
            1...64 => |bits| switch (int_info.signedness) {
                .signed => {
                    const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                    const result_lock = isel.tryLockReg(res_ra);
                    defer result_lock.unlock(isel);
                    const lhs_vi = try isel.use(bin_op.lhs);
                    const rhs_vi = try isel.use(bin_op.rhs);
                    const lhs_mat = try lhs_vi.matReg(isel);
                    const rhs_mat = try rhs_vi.matReg(isel);
                    const unsat_res_ra = try isel.allocIntReg();
                    defer isel.freeReg(unsat_res_ra);
                    const limit_ra = try isel.allocIntReg();
                    defer isel.freeReg(limit_ra);
                    switch (bits) {
                        else => unreachable,
                        1...63 => {
                            // The exact result of sign-extended operands fits in 64 bits;
                            // clamp it to the range of the type.
                            const lhs_ra = try isel.allocIntReg();
                            defer isel.freeReg(lhs_ra);
                            const rhs_ra = try isel.allocIntReg();
                            defer isel.freeReg(rhs_ra);
                            try isel.emit(.csel(res_ra.x(), res_ra.x(), limit_ra.x(), .ge));
                            try isel.emit(.subs(.xzr, res_ra.x(), .{ .register = limit_ra.x() }));
                            try isel.movImmediate(limit_ra.x(), @bitCast(-(@as(i64, 1) << @intCast(bits - 1))));
                            try isel.emit(.csel(res_ra.x(), unsat_res_ra.x(), limit_ra.x(), .le));
                            try isel.emit(.subs(.xzr, unsat_res_ra.x(), .{ .register = limit_ra.x() }));
                            try isel.movImmediate(limit_ra.x(), (@as(u64, 1) << @intCast(bits - 1)) - 1);
                            try isel.emit(switch (air_tag) {
                                else => unreachable,
                                .add_sat => .add(unsat_res_ra.x(), lhs_ra.x(), .{ .register = rhs_ra.x() }),
                                .sub_sat => .sub(unsat_res_ra.x(), lhs_ra.x(), .{ .register = rhs_ra.x() }),
                            });
                            try isel.emit(.sbfm(rhs_ra.x(), rhs_mat.ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            }));
                            try isel.emit(.sbfm(lhs_ra.x(), lhs_mat.ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            }));
                        },
                        64 => {
                            // On overflow the exact result has the sign of lhs.
                            try isel.emit(.csel(res_ra.x(), unsat_res_ra.x(), limit_ra.x(), .vc));
                            try isel.emit(.eor(limit_ra.x(), limit_ra.x(), .{ .shifted_register = .{
                                .register = lhs_mat.ra.x(),
                                .shift = .{ .asr = 63 },
                            } }));
                            try isel.movImmediate(limit_ra.x(), std.math.maxInt(i64));
                            try isel.emit(switch (air_tag) {
                                else => unreachable,
                                .add_sat => .adds(unsat_res_ra.x(), lhs_mat.ra.x(), .{ .register = rhs_mat.ra.x() }),
                                .sub_sat => .subs(unsat_res_ra.x(), lhs_mat.ra.x(), .{ .register = rhs_mat.ra.x() }),
                            });
                        },
                    }
                    try rhs_mat.finish(isel);
                    try lhs_mat.finish(isel);
                },
                .unsigned => {
                    const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                    const result_lock = isel.tryLockReg(res_ra);
                    defer result_lock.unlock(isel);
                    const lhs_vi = try isel.use(bin_op.lhs);
                    const rhs_vi = try isel.use(bin_op.rhs);
                    const lhs_mat = try lhs_vi.matReg(isel);
                    const rhs_mat = try rhs_vi.matReg(isel);
                    const unsat_res_ra = try isel.allocIntReg();
                    defer isel.freeReg(unsat_res_ra);
                    switch (air_tag) {
                        else => unreachable,
                        .add_sat => switch (bits) {
                            else => unreachable,
                            1...31, 33...63 => {
                                const max_ra = try isel.allocIntReg();
                                defer isel.freeReg(max_ra);
                                try isel.emit(.csel(res_ra.x(), unsat_res_ra.x(), max_ra.x(), .ls));
                                try isel.emit(.subs(.xzr, unsat_res_ra.x(), .{ .register = max_ra.x() }));
                                try isel.emit(.add(unsat_res_ra.x(), lhs_mat.ra.x(), .{ .register = rhs_mat.ra.x() }));
                                try isel.movImmediate(max_ra.x(), (@as(u64, 1) << @intCast(bits)) - 1);
                            },
                            32 => {
                                try isel.emit(.csinv(res_ra.w(), unsat_res_ra.w(), .wzr, .invert(.cs)));
                                try isel.emit(.adds(unsat_res_ra.w(), lhs_mat.ra.w(), .{ .register = rhs_mat.ra.w() }));
                            },
                            64 => {
                                try isel.emit(.csinv(res_ra.x(), unsat_res_ra.x(), .xzr, .invert(.cs)));
                                try isel.emit(.adds(unsat_res_ra.x(), lhs_mat.ra.x(), .{ .register = rhs_mat.ra.x() }));
                            },
                        },
                        .sub_sat => switch (bits) {
                            else => unreachable,
                            1...32 => {
                                try isel.emit(.csel(res_ra.w(), unsat_res_ra.w(), .wzr, .invert(.cc)));
                                try isel.emit(.subs(unsat_res_ra.w(), lhs_mat.ra.w(), .{ .register = rhs_mat.ra.w() }));
                            },
                            33...64 => {
                                try isel.emit(.csel(res_ra.x(), unsat_res_ra.x(), .xzr, .invert(.cc)));
                                try isel.emit(.subs(unsat_res_ra.x(), lhs_mat.ra.x(), .{ .register = rhs_mat.ra.x() }));
                            },
                        },
                    }
                    try rhs_mat.finish(isel);
                    try lhs_mat.finish(isel);
                },
            },
            // Legalize calls compiler-rt up to 65535 bits (`soft_big_int`).
            else => return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) }),
        }
    }
}

/// `mul` and `mul_wrap` of integers of at most 128 bits, and `mul` of floats.
fn selectMul(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const bin_op = isel.air.instructions.items(.data)[@backingInt(inst)].bin_op;
        const ty = isel.air.typeOf(bin_op.lhs, ip);
        if (!ty.isRuntimeFloat()) {
            if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
            const int_info = ty.intInfo(zcu);
            switch (int_info.bits) {
                0 => unreachable,
                1 => {
                    const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                    switch (int_info.signedness) {
                        .signed => switch (air_tag) {
                            else => unreachable,
                            .mul, .mul_optimized => break :unused try isel.emit(.orr(res_ra.w(), .wzr, .{ .register = .wzr })),
                            .mul_wrap => {},
                        },
                        .unsigned => {},
                    }
                    const lhs_vi = try isel.use(bin_op.lhs);
                    const rhs_vi = try isel.use(bin_op.rhs);
                    const lhs_mat = try lhs_vi.matReg(isel);
                    const rhs_mat = try rhs_vi.matReg(isel);
                    try isel.emit(.@"and"(res_ra.w(), lhs_mat.ra.w(), .{ .register = rhs_mat.ra.w() }));
                    try rhs_mat.finish(isel);
                    try lhs_mat.finish(isel);
                },
                2...32 => |bits| {
                    const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                    switch (air_tag) {
                        else => unreachable,
                        .mul, .mul_optimized => {},
                        .mul_wrap => switch (bits) {
                            else => unreachable,
                            1...31 => try isel.emit(switch (int_info.signedness) {
                                .signed => .sbfm(res_ra.w(), res_ra.w(), .{
                                    .N = .word,
                                    .immr = 0,
                                    .imms = @intCast(bits - 1),
                                }),
                                .unsigned => .ubfm(res_ra.w(), res_ra.w(), .{
                                    .N = .word,
                                    .immr = 0,
                                    .imms = @intCast(bits - 1),
                                }),
                            }),
                            32 => {},
                        },
                    }
                    const lhs_vi = try isel.use(bin_op.lhs);
                    const rhs_vi = try isel.use(bin_op.rhs);
                    const lhs_mat = try lhs_vi.matReg(isel);
                    const rhs_mat = try rhs_vi.matReg(isel);
                    try isel.emit(.madd(res_ra.w(), lhs_mat.ra.w(), rhs_mat.ra.w(), .wzr));
                    try rhs_mat.finish(isel);
                    try lhs_mat.finish(isel);
                },
                33...64 => |bits| {
                    const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                    switch (air_tag) {
                        else => unreachable,
                        .mul, .mul_optimized => {},
                        .mul_wrap => switch (bits) {
                            else => unreachable,
                            33...63 => try isel.emit(switch (int_info.signedness) {
                                .signed => .sbfm(res_ra.x(), res_ra.x(), .{
                                    .N = .doubleword,
                                    .immr = 0,
                                    .imms = @intCast(bits - 1),
                                }),
                                .unsigned => .ubfm(res_ra.x(), res_ra.x(), .{
                                    .N = .doubleword,
                                    .immr = 0,
                                    .imms = @intCast(bits - 1),
                                }),
                            }),
                            64 => {},
                        },
                    }
                    const lhs_vi = try isel.use(bin_op.lhs);
                    const rhs_vi = try isel.use(bin_op.rhs);
                    const lhs_mat = try lhs_vi.matReg(isel);
                    const rhs_mat = try rhs_vi.matReg(isel);
                    try isel.emit(.madd(res_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x(), .xzr));
                    try rhs_mat.finish(isel);
                    try lhs_mat.finish(isel);
                },
                65...128 => |bits| {
                    const res_pair: DefPair = try .init(isel, res_vi.value, ty);
                    defer res_pair.deinit(isel);
                    if (res_pair.unused()) break :unused;
                    if (res_pair.hi) |res_ra| switch (air_tag) {
                        else => unreachable,
                        .mul, .mul_optimized => {},
                        .mul_wrap => switch (bits) {
                            else => unreachable,
                            65...127 => try isel.emit(switch (int_info.signedness) {
                                .signed => .sbfm(res_ra.x(), res_ra.x(), .{
                                    .N = .doubleword,
                                    .immr = 0,
                                    .imms = @intCast(bits - 65),
                                }),
                                .unsigned => .ubfm(res_ra.x(), res_ra.x(), .{
                                    .N = .doubleword,
                                    .immr = 0,
                                    .imms = @intCast(bits - 65),
                                }),
                            }),
                            128 => {},
                        },
                    };
                    const lhs_vi = try isel.use(bin_op.lhs);
                    const rhs_vi = try isel.use(bin_op.rhs);
                    const lhs_lo64_mat, const rhs_lo64_mat = lo64_mat: {
                        var rhs_lo64_it = rhs_vi.field(ty, 0, 8);
                        const rhs_lo64_vi = try rhs_lo64_it.only(isel);
                        const rhs_lo64_mat = try rhs_lo64_vi.?.matReg(isel);
                        var lhs_lo64_it = lhs_vi.field(ty, 0, 8);
                        const lhs_lo64_vi = try lhs_lo64_it.only(isel);
                        const lhs_lo64_mat = try lhs_lo64_vi.?.matReg(isel);
                        break :lo64_mat .{ lhs_lo64_mat, rhs_lo64_mat };
                    };
                    if (res_pair.lo) |res_ra| try isel.emit(.madd(res_ra.x(), lhs_lo64_mat.ra.x(), rhs_lo64_mat.ra.x(), .xzr));
                    if (res_pair.hi) |res_ra| {
                        var rhs_hi64_it = rhs_vi.field(ty, 8, 8);
                        const rhs_hi64_vi = try rhs_hi64_it.only(isel);
                        const rhs_hi64_mat = try rhs_hi64_vi.?.matReg(isel);
                        var lhs_hi64_it = lhs_vi.field(ty, 8, 8);
                        const lhs_hi64_vi = try lhs_hi64_it.only(isel);
                        const lhs_hi64_mat = try lhs_hi64_vi.?.matReg(isel);
                        const acc_ra = try isel.allocIntReg();
                        defer isel.freeReg(acc_ra);
                        try isel.emit(.madd(res_ra.x(), lhs_hi64_mat.ra.x(), rhs_lo64_mat.ra.x(), acc_ra.x()));
                        try isel.emit(.madd(acc_ra.x(), lhs_lo64_mat.ra.x(), rhs_hi64_mat.ra.x(), acc_ra.x()));
                        try isel.emit(.umulh(acc_ra.x(), lhs_lo64_mat.ra.x(), rhs_lo64_mat.ra.x()));
                        try rhs_hi64_mat.finish(isel);
                        try lhs_hi64_mat.finish(isel);
                    }
                    try rhs_lo64_mat.finish(isel);
                    try lhs_lo64_mat.finish(isel);
                },
                else => return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) }),
            }
        } else switch (ty.floatBits(isel.target)) {
            else => unreachable,
            16, 32, 64 => |bits| {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const need_fcvt = switch (bits) {
                    else => unreachable,
                    16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                    32, 64 => false,
                };
                if (need_fcvt) try isel.emit(.fcvt(res_ra.h(), res_ra.s()));
                const lhs_vi = try isel.use(bin_op.lhs);
                const rhs_vi = try isel.use(bin_op.rhs);
                const lhs_mat = try lhs_vi.matReg(isel);
                const rhs_mat = try rhs_vi.matReg(isel);
                const lhs_ra = if (need_fcvt) try isel.allocVecReg() else lhs_mat.ra;
                defer if (need_fcvt) isel.freeReg(lhs_ra);
                const rhs_ra = if (need_fcvt) try isel.allocVecReg() else rhs_mat.ra;
                defer if (need_fcvt) isel.freeReg(rhs_ra);
                try isel.emit(bits: switch (bits) {
                    else => unreachable,
                    16 => if (need_fcvt)
                        continue :bits 32
                    else
                        .fmul(res_ra.h(), lhs_ra.h(), rhs_ra.h()),
                    32 => .fmul(res_ra.s(), lhs_ra.s(), rhs_ra.s()),
                    64 => .fmul(res_ra.d(), lhs_ra.d(), rhs_ra.d()),
                });
                if (need_fcvt) {
                    try isel.emit(.fcvt(rhs_ra.s(), rhs_mat.ra.h()));
                    try isel.emit(.fcvt(lhs_ra.s(), lhs_mat.ra.h()));
                }
                try rhs_mat.finish(isel);
                try lhs_mat.finish(isel);
            },
            80, 128 => |bits| {
                try call.compilerRt(isel, switch (bits) {
                    else => unreachable,
                    16 => "__mulhf3",
                    32 => "__mulsf3",
                    64 => "__muldf3",
                    80 => "__mulxf3",
                    128 => "__multf3",
                }, res_vi.value, ty, &.{ bin_op.lhs, bin_op.rhs });
            },
        }
    }
}

/// `mul_sat` of integers of at most 64 bits.
fn selectMulSat(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const bin_op = isel.air.instructions.items(.data)[@backingInt(inst)].bin_op;
        const ty = isel.air.typeOf(bin_op.lhs, ip);
        if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
        const int_info = ty.intInfo(zcu);
        switch (int_info.bits) {
            0 => unreachable,
            1 => {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                switch (int_info.signedness) {
                    .signed => try isel.emit(.orr(res_ra.w(), .wzr, .{ .register = .wzr })),
                    .unsigned => {
                        const lhs_vi = try isel.use(bin_op.lhs);
                        const rhs_vi = try isel.use(bin_op.rhs);
                        const lhs_mat = try lhs_vi.matReg(isel);
                        const rhs_mat = try rhs_vi.matReg(isel);
                        try isel.emit(.@"and"(res_ra.w(), lhs_mat.ra.w(), .{ .register = rhs_mat.ra.w() }));
                        try rhs_mat.finish(isel);
                        try lhs_mat.finish(isel);
                    },
                }
            },
            2...32 => |bits| {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const saturated_ra = switch (int_info.signedness) {
                    .signed => try isel.allocIntReg(),
                    .unsigned => switch (bits) {
                        else => unreachable,
                        2...31 => try isel.allocIntReg(),
                        32 => .zr,
                    },
                };
                defer if (saturated_ra != .zr) isel.freeReg(saturated_ra);
                const unwrapped_ra = try isel.allocIntReg();
                defer isel.freeReg(unwrapped_ra);
                try isel.emit(switch (saturated_ra) {
                    else => .csel(res_ra.w(), unwrapped_ra.w(), saturated_ra.w(), .eq),
                    .zr => .csinv(res_ra.w(), unwrapped_ra.w(), saturated_ra.w(), .eq),
                });
                switch (bits) {
                    else => unreachable,
                    2...7, 9...15, 17...31 => switch (int_info.signedness) {
                        .signed => {
                            const wrapped_ra = try isel.allocIntReg();
                            defer isel.freeReg(wrapped_ra);
                            switch (bits) {
                                else => unreachable,
                                1...7, 9...15 => {
                                    try isel.emit(.subs(.wzr, unwrapped_ra.w(), .{ .register = wrapped_ra.w() }));
                                    try isel.emit(.sbfm(wrapped_ra.w(), unwrapped_ra.w(), .{
                                        .N = .word,
                                        .immr = 0,
                                        .imms = @intCast(bits - 1),
                                    }));
                                },
                                17...31 => {
                                    try isel.emit(.subs(.xzr, unwrapped_ra.x(), .{ .register = wrapped_ra.x() }));
                                    try isel.emit(.sbfm(wrapped_ra.x(), unwrapped_ra.x(), .{
                                        .N = .doubleword,
                                        .immr = 0,
                                        .imms = @intCast(bits - 1),
                                    }));
                                },
                            }
                        },
                        .unsigned => switch (bits) {
                            else => unreachable,
                            1...7, 9...15 => try isel.emit(.ands(.wzr, unwrapped_ra.w(), .{ .immediate = .{
                                .N = .word,
                                .immr = @intCast(32 - bits),
                                .imms = @intCast(32 - bits - 1),
                            } })),
                            17...31 => try isel.emit(.ands(.xzr, unwrapped_ra.x(), .{ .immediate = .{
                                .N = .doubleword,
                                .immr = @intCast(64 - bits),
                                .imms = @intCast(64 - bits - 1),
                            } })),
                        },
                    },
                    8 => try isel.emit(.subs(.wzr, unwrapped_ra.w(), .{ .extended_register = .{
                        .register = unwrapped_ra.w(),
                        .extend = switch (int_info.signedness) {
                            .signed => .{ .sxtb = 0 },
                            .unsigned => .{ .uxtb = 0 },
                        },
                    } })),
                    16 => try isel.emit(.subs(.wzr, unwrapped_ra.w(), .{ .extended_register = .{
                        .register = unwrapped_ra.w(),
                        .extend = switch (int_info.signedness) {
                            .signed => .{ .sxth = 0 },
                            .unsigned => .{ .uxth = 0 },
                        },
                    } })),
                    32 => try isel.emit(.subs(.xzr, unwrapped_ra.x(), .{ .extended_register = .{
                        .register = unwrapped_ra.w(),
                        .extend = switch (int_info.signedness) {
                            .signed => .{ .sxtw = 0 },
                            .unsigned => .{ .uxtw = 0 },
                        },
                    } })),
                }
                const lhs_vi = try isel.use(bin_op.lhs);
                const rhs_vi = try isel.use(bin_op.rhs);
                const lhs_mat = try lhs_vi.matReg(isel);
                const rhs_mat = try rhs_vi.matReg(isel);
                switch (int_info.signedness) {
                    .signed => {
                        try isel.emit(.eor(saturated_ra.w(), saturated_ra.w(), .{ .immediate = .{
                            .N = .word,
                            .immr = 0,
                            .imms = @intCast(bits - 1 - 1),
                        } }));
                        try isel.emit(.sbfm(saturated_ra.w(), saturated_ra.w(), .{
                            .N = .word,
                            .immr = @intCast(bits - 1),
                            .imms = @intCast(bits - 1 + 1 - 1),
                        }));
                        try isel.emit(.eor(saturated_ra.w(), lhs_mat.ra.w(), .{ .register = rhs_mat.ra.w() }));
                    },
                    .unsigned => switch (bits) {
                        else => unreachable,
                        2...31 => try isel.movImmediate(saturated_ra.w(), @as(u32, std.math.maxInt(u32)) >> @intCast(32 - bits)),
                        32 => {},
                    },
                }
                switch (bits) {
                    else => unreachable,
                    2...16 => try isel.emit(.madd(unwrapped_ra.w(), lhs_mat.ra.w(), rhs_mat.ra.w(), .wzr)),
                    17...32 => switch (int_info.signedness) {
                        .signed => try isel.emit(.smaddl(unwrapped_ra.x(), lhs_mat.ra.w(), rhs_mat.ra.w(), .xzr)),
                        .unsigned => try isel.emit(.umaddl(unwrapped_ra.x(), lhs_mat.ra.w(), rhs_mat.ra.w(), .xzr)),
                    },
                }
                try rhs_mat.finish(isel);
                try lhs_mat.finish(isel);
            },
            33...64 => |bits| {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const saturated_ra = switch (int_info.signedness) {
                    .signed => try isel.allocIntReg(),
                    .unsigned => switch (bits) {
                        else => unreachable,
                        33...63 => try isel.allocIntReg(),
                        64 => .zr,
                    },
                };
                defer if (saturated_ra != .zr) isel.freeReg(saturated_ra);
                const unwrapped_lo64_ra = try isel.allocIntReg();
                defer isel.freeReg(unwrapped_lo64_ra);
                const unwrapped_hi64_ra = try isel.allocIntReg();
                defer isel.freeReg(unwrapped_hi64_ra);
                try isel.emit(switch (saturated_ra) {
                    else => .csel(res_ra.x(), unwrapped_lo64_ra.x(), saturated_ra.x(), .eq),
                    .zr => .csinv(res_ra.x(), unwrapped_lo64_ra.x(), saturated_ra.x(), .eq),
                });
                switch (int_info.signedness) {
                    .signed => switch (bits) {
                        else => unreachable,
                        32...63 => {
                            const wrapped_lo64_ra = try isel.allocIntReg();
                            defer isel.freeReg(wrapped_lo64_ra);
                            try isel.emit(.ccmp(
                                unwrapped_lo64_ra.x(),
                                .{ .register = wrapped_lo64_ra.x() },
                                .{ .n = false, .z = false, .c = false, .v = false },
                                .eq,
                            ));
                            try isel.emit(.subs(.xzr, unwrapped_hi64_ra.x(), .{ .shifted_register = .{
                                .register = unwrapped_lo64_ra.x(),
                                .shift = .{ .asr = 63 },
                            } }));
                            try isel.emit(.sbfm(wrapped_lo64_ra.x(), unwrapped_lo64_ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            }));
                        },
                        64 => try isel.emit(.subs(.xzr, unwrapped_hi64_ra.x(), .{ .shifted_register = .{
                            .register = unwrapped_lo64_ra.x(),
                            .shift = .{ .asr = @intCast(bits - 1) },
                        } })),
                    },
                    .unsigned => switch (bits) {
                        else => unreachable,
                        32...63 => {
                            const overflow_ra = try isel.allocIntReg();
                            defer isel.freeReg(overflow_ra);
                            try isel.emit(.subs(.xzr, overflow_ra.x(), .{ .immediate = 0 }));
                            try isel.emit(.orr(overflow_ra.x(), unwrapped_hi64_ra.x(), .{ .shifted_register = .{
                                .register = unwrapped_lo64_ra.x(),
                                .shift = .{ .lsr = @intCast(bits) },
                            } }));
                        },
                        64 => try isel.emit(.subs(.xzr, unwrapped_hi64_ra.x(), .{ .immediate = 0 })),
                    },
                }
                const lhs_vi = try isel.use(bin_op.lhs);
                const rhs_vi = try isel.use(bin_op.rhs);
                const lhs_mat = try lhs_vi.matReg(isel);
                const rhs_mat = try rhs_vi.matReg(isel);
                switch (int_info.signedness) {
                    .signed => {
                        try isel.emit(.eor(saturated_ra.x(), saturated_ra.x(), .{ .immediate = .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = @intCast(bits - 1 - 1),
                        } }));
                        try isel.emit(.sbfm(saturated_ra.x(), saturated_ra.x(), .{
                            .N = .doubleword,
                            .immr = @intCast(bits - 1),
                            .imms = @intCast(bits - 1 + 1 - 1),
                        }));
                        try isel.emit(.eor(saturated_ra.x(), lhs_mat.ra.x(), .{ .register = rhs_mat.ra.x() }));
                        try isel.emit(.madd(unwrapped_lo64_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x(), .xzr));
                        try isel.emit(.smulh(unwrapped_hi64_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x()));
                    },
                    .unsigned => {
                        switch (bits) {
                            else => unreachable,
                            32...63 => try isel.movImmediate(saturated_ra.x(), @as(u64, std.math.maxInt(u64)) >> @intCast(64 - bits)),
                            64 => {},
                        }
                        try isel.emit(.madd(unwrapped_lo64_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x(), .xzr));
                        try isel.emit(.umulh(unwrapped_hi64_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x()));
                    },
                }
                try rhs_mat.finish(isel);
                try lhs_mat.finish(isel);
            },
            else => return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) }),
        }
    }
}

/// The divisions of integers of at most 128 bits and of floats.
fn selectDiv(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const bin_op = isel.air.instructions.items(.data)[@backingInt(inst)].bin_op;
        const ty = isel.air.typeOf(bin_op.lhs, ip);
        if (!ty.isRuntimeFloat()) {
            if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
            const int_info = ty.intInfo(zcu);
            switch (int_info.bits) {
                0 => unreachable,
                1...64 => |bits| {
                    const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                    const res_lock = isel.lockReg(res_ra);
                    defer res_lock.unlock(isel);
                    const lhs_vi = try isel.use(bin_op.lhs);
                    const rhs_vi = try isel.use(bin_op.rhs);
                    const lhs_mat = try lhs_vi.matReg(isel);
                    const rhs_mat = try rhs_vi.matReg(isel);
                    const div_ra = div_ra: switch (air_tag) {
                        else => unreachable,
                        .div_trunc, .div_trunc_optimized, .div_exact, .div_exact_optimized => res_ra,
                        .div_floor, .div_floor_optimized => switch (int_info.signedness) {
                            .signed => {
                                const div_ra = try isel.allocIntReg();
                                errdefer isel.freeReg(div_ra);
                                const rem_ra = try isel.allocIntReg();
                                defer isel.freeReg(rem_ra);
                                switch (bits) {
                                    else => unreachable,
                                    1...32 => {
                                        try isel.emit(.csel(res_ra.w(), div_ra.w(), rem_ra.w(), .pl));
                                        try isel.emit(.sub(rem_ra.w(), div_ra.w(), .{ .immediate = 1 }));
                                        try isel.emit(.ccmp(
                                            rem_ra.w(),
                                            .{ .immediate = 0 },
                                            .{ .n = false, .z = false, .c = false, .v = false },
                                            .ne,
                                        ));
                                        try isel.emit(.eor(rem_ra.w(), rem_ra.w(), .{ .register = rhs_mat.ra.w() }));
                                        try isel.emit(.subs(.wzr, rem_ra.w(), .{ .immediate = 0 }));
                                        try isel.emit(.msub(rem_ra.w(), div_ra.w(), rhs_mat.ra.w(), lhs_mat.ra.w()));
                                    },
                                    33...64 => {
                                        try isel.emit(.csel(res_ra.x(), div_ra.x(), rem_ra.x(), .pl));
                                        try isel.emit(.sub(rem_ra.x(), div_ra.x(), .{ .immediate = 1 }));
                                        try isel.emit(.ccmp(
                                            rem_ra.x(),
                                            .{ .immediate = 0 },
                                            .{ .n = false, .z = false, .c = false, .v = false },
                                            .ne,
                                        ));
                                        try isel.emit(.eor(rem_ra.x(), rem_ra.x(), .{ .register = rhs_mat.ra.x() }));
                                        try isel.emit(.subs(.xzr, rem_ra.x(), .{ .immediate = 0 }));
                                        try isel.emit(.msub(rem_ra.x(), div_ra.x(), rhs_mat.ra.x(), lhs_mat.ra.x()));
                                    },
                                }
                                break :div_ra div_ra;
                            },
                            .unsigned => res_ra,
                        },
                        .div_ceil, .div_ceil_optimized => switch (int_info.signedness) {
                            .signed, .unsigned => {
                                const div_ra = try isel.allocIntReg();
                                errdefer isel.freeReg(div_ra);
                                const rem_ra = try isel.allocIntReg();
                                defer isel.freeReg(rem_ra);
                                switch (bits) {
                                    else => unreachable,
                                    1...32 => {
                                        try isel.emit(.csel(
                                            res_ra.w(),
                                            div_ra.w(),
                                            rem_ra.w(),
                                            if (int_info.signedness == .signed) .mi else .eq,
                                        ));
                                        try isel.emit(.add(rem_ra.w(), div_ra.w(), .{ .immediate = 1 }));
                                        if (int_info.signedness == .signed) try isel.emit(.ccmp(
                                            rem_ra.w(),
                                            .{ .immediate = 0 },
                                            .{ .n = true, .z = false, .c = false, .v = false },
                                            .ne,
                                        ));
                                        if (int_info.signedness == .signed) try isel.emit(.eor(
                                            rem_ra.w(),
                                            rem_ra.w(),
                                            .{ .register = rhs_mat.ra.w() },
                                        ));
                                        try isel.emit(.subs(.wzr, rem_ra.w(), .{ .immediate = 0 }));
                                        try isel.emit(.msub(rem_ra.w(), div_ra.w(), rhs_mat.ra.w(), lhs_mat.ra.w()));
                                    },
                                    33...64 => {
                                        try isel.emit(.csel(
                                            res_ra.x(),
                                            div_ra.x(),
                                            rem_ra.x(),
                                            if (int_info.signedness == .signed) .mi else .eq,
                                        ));
                                        try isel.emit(.add(rem_ra.x(), div_ra.x(), .{ .immediate = 1 }));
                                        if (int_info.signedness == .signed) try isel.emit(.ccmp(
                                            rem_ra.x(),
                                            .{ .immediate = 0 },
                                            .{ .n = true, .z = false, .c = false, .v = false },
                                            .ne,
                                        ));
                                        if (int_info.signedness == .signed) try isel.emit(.eor(
                                            rem_ra.x(),
                                            rem_ra.x(),
                                            .{ .register = rhs_mat.ra.x() },
                                        ));
                                        try isel.emit(.subs(.xzr, rem_ra.x(), .{ .immediate = 0 }));
                                        try isel.emit(.msub(rem_ra.x(), div_ra.x(), rhs_mat.ra.x(), lhs_mat.ra.x()));
                                    },
                                }
                                break :div_ra div_ra;
                            },
                        },
                    };
                    defer if (div_ra != res_ra) isel.freeReg(div_ra);
                    try isel.emit(switch (bits) {
                        else => unreachable,
                        1...32 => switch (int_info.signedness) {
                            .signed => .sdiv(div_ra.w(), lhs_mat.ra.w(), rhs_mat.ra.w()),
                            .unsigned => .udiv(div_ra.w(), lhs_mat.ra.w(), rhs_mat.ra.w()),
                        },
                        33...64 => switch (int_info.signedness) {
                            .signed => .sdiv(div_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x()),
                            .unsigned => .udiv(div_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x()),
                        },
                    });
                    try rhs_mat.finish(isel);
                    try lhs_mat.finish(isel);
                },
                65...128 => {
                    switch (air_tag) {
                        else => unreachable,
                        .div_trunc, .div_trunc_optimized, .div_exact, .div_exact_optimized => {},
                        .div_ceil, .div_ceil_optimized => {
                            try isel.divideRoundedWide(res_vi.value, ty, bin_op.lhs, bin_op.rhs, true);
                            break :unused;
                        },
                        .div_floor, .div_floor_optimized => switch (int_info.signedness) {
                            .signed => {
                                try isel.divideRoundedWide(res_vi.value, ty, bin_op.lhs, bin_op.rhs, false);
                                break :unused;
                            },
                            .unsigned => {},
                        },
                    }

                    try call.compilerRt(isel, switch (int_info.signedness) {
                        .signed => "__divti3",
                        .unsigned => "__udivti3",
                    }, res_vi.value, ty, &.{ bin_op.lhs, bin_op.rhs });
                },
                else => return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) }),
            }
        } else switch (ty.floatBits(isel.target)) {
            else => unreachable,
            16, 32, 64 => |bits| {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const need_fcvt = switch (bits) {
                    else => unreachable,
                    16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                    32, 64 => false,
                };
                if (need_fcvt) try isel.emit(.fcvt(res_ra.h(), res_ra.s()));
                const lhs_vi = try isel.use(bin_op.lhs);
                const rhs_vi = try isel.use(bin_op.rhs);
                const lhs_mat = try lhs_vi.matReg(isel);
                const rhs_mat = try rhs_vi.matReg(isel);
                const lhs_ra = if (need_fcvt) try isel.allocVecReg() else lhs_mat.ra;
                defer if (need_fcvt) isel.freeReg(lhs_ra);
                const rhs_ra = if (need_fcvt) try isel.allocVecReg() else rhs_mat.ra;
                defer if (need_fcvt) isel.freeReg(rhs_ra);
                bits: switch (bits) {
                    else => unreachable,
                    16 => if (need_fcvt) continue :bits 32 else {
                        switch (air_tag) {
                            else => unreachable,
                            .div_trunc, .div_trunc_optimized => try isel.emit(.frintz(res_ra.h(), res_ra.h())),
                            .div_floor, .div_floor_optimized => try isel.emit(.frintm(res_ra.h(), res_ra.h())),
                            .div_ceil, .div_ceil_optimized => try isel.emit(.frintp(res_ra.h(), res_ra.h())),
                            .div_exact, .div_exact_optimized => {},
                        }
                        try isel.emit(.fdiv(res_ra.h(), lhs_ra.h(), rhs_ra.h()));
                    },
                    32 => {
                        switch (air_tag) {
                            else => unreachable,
                            .div_trunc, .div_trunc_optimized => try isel.emit(.frintz(res_ra.s(), res_ra.s())),
                            .div_floor, .div_floor_optimized => try isel.emit(.frintm(res_ra.s(), res_ra.s())),
                            .div_ceil, .div_ceil_optimized => try isel.emit(.frintp(res_ra.s(), res_ra.s())),
                            .div_exact, .div_exact_optimized => {},
                        }
                        try isel.emit(.fdiv(res_ra.s(), lhs_ra.s(), rhs_ra.s()));
                    },
                    64 => {
                        switch (air_tag) {
                            else => unreachable,
                            .div_trunc, .div_trunc_optimized => try isel.emit(.frintz(res_ra.d(), res_ra.d())),
                            .div_floor, .div_floor_optimized => try isel.emit(.frintm(res_ra.d(), res_ra.d())),
                            .div_ceil, .div_ceil_optimized => try isel.emit(.frintp(res_ra.d(), res_ra.d())),
                            .div_exact, .div_exact_optimized => {},
                        }
                        try isel.emit(.fdiv(res_ra.d(), lhs_ra.d(), rhs_ra.d()));
                    },
                }
                if (need_fcvt) {
                    try isel.emit(.fcvt(rhs_ra.s(), rhs_mat.ra.h()));
                    try isel.emit(.fcvt(lhs_ra.s(), lhs_mat.ra.h()));
                }
                try rhs_mat.finish(isel);
                try lhs_mat.finish(isel);
            },
            80, 128 => |bits| {
                try call.compilerRtReturn(isel, res_vi.value, ty);

                try call.prepareCallee(isel);
                switch (air_tag) {
                    else => unreachable,
                    .div_trunc, .div_trunc_optimized => {
                        try call.global(isel, switch (bits) {
                            else => unreachable,
                            16 => "__trunch",
                            32 => "truncf",
                            64 => "trunc",
                            80 => "__truncx",
                            128 => "truncf128",
                        });
                    },
                    .div_floor, .div_floor_optimized => {
                        try call.global(isel, switch (bits) {
                            else => unreachable,
                            16 => "__floorh",
                            32 => "floorf",
                            64 => "floor",
                            80 => "__floorx",
                            128 => "floorf128",
                        });
                    },
                    .div_ceil, .div_ceil_optimized => {
                        try call.global(isel, switch (bits) {
                            else => unreachable,
                            16 => "__ceilh",
                            32 => "ceilf",
                            64 => "ceil",
                            80 => "__ceilx",
                            128 => "ceilf128",
                        });
                    },
                    .div_exact, .div_exact_optimized => {},
                }
                try call.global(isel, switch (bits) {
                    else => unreachable,
                    16 => "__divhf3",
                    32 => "__divsf3",
                    64 => "__divdf3",
                    80 => "__divxf3",
                    128 => "__divtf3",
                });
                try call.finishCallee(isel);

                try call.compilerRtParams(isel, &.{ bin_op.lhs, bin_op.rhs });
            },
        }
    }
}

/// `rem` and `mod` of integers of at most 128 bits and of floats.
fn selectRemMod(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const bin_op = isel.air.instructions.items(.data)[@backingInt(inst)].bin_op;
        const ty = isel.air.typeOf(bin_op.lhs, ip);
        if (!ty.isRuntimeFloat()) {
            if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
            const int_info = ty.intInfo(zcu);
            if (int_info.bits > 64) {
                if (int_info.bits > 128) return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) });
                try isel.remainderWide(res_vi.value, ty, bin_op.lhs, bin_op.rhs, air_tag == .mod or air_tag == .mod_optimized);
                break :unused;
            }

            const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
            const res_lock = isel.lockReg(res_ra);
            defer res_lock.unlock(isel);
            const lhs_vi = try isel.use(bin_op.lhs);
            const rhs_vi = try isel.use(bin_op.rhs);
            const lhs_mat = try lhs_vi.matReg(isel);
            const rhs_mat = try rhs_vi.matReg(isel);
            const div_ra = try isel.allocIntReg();
            defer isel.freeReg(div_ra);
            const rem_ra = rem_ra: switch (air_tag) {
                else => unreachable,
                .rem, .rem_optimized => res_ra,
                .mod, .mod_optimized => switch (int_info.signedness) {
                    .signed => {
                        const rem_ra = try isel.allocIntReg();
                        errdefer isel.freeReg(rem_ra);
                        switch (int_info.bits) {
                            else => unreachable,
                            1...32 => {
                                try isel.emit(.csel(res_ra.w(), rem_ra.w(), div_ra.w(), .pl));
                                try isel.emit(.add(div_ra.w(), rem_ra.w(), .{ .register = rhs_mat.ra.w() }));
                                try isel.emit(.ccmp(
                                    div_ra.w(),
                                    .{ .immediate = 0 },
                                    .{ .n = false, .z = false, .c = false, .v = false },
                                    .ne,
                                ));
                                try isel.emit(.eor(div_ra.w(), rem_ra.w(), .{ .register = rhs_mat.ra.w() }));
                                try isel.emit(.subs(.wzr, rem_ra.w(), .{ .immediate = 0 }));
                            },
                            33...64 => {
                                try isel.emit(.csel(res_ra.x(), rem_ra.x(), div_ra.x(), .pl));
                                try isel.emit(.add(div_ra.x(), rem_ra.x(), .{ .register = rhs_mat.ra.x() }));
                                try isel.emit(.ccmp(
                                    div_ra.x(),
                                    .{ .immediate = 0 },
                                    .{ .n = false, .z = false, .c = false, .v = false },
                                    .ne,
                                ));
                                try isel.emit(.eor(div_ra.x(), rem_ra.x(), .{ .register = rhs_mat.ra.x() }));
                                try isel.emit(.subs(.xzr, rem_ra.x(), .{ .immediate = 0 }));
                            },
                        }
                        break :rem_ra rem_ra;
                    },
                    .unsigned => res_ra,
                },
            };
            defer if (rem_ra != res_ra) isel.freeReg(rem_ra);
            switch (int_info.bits) {
                else => unreachable,
                1...32 => {
                    try isel.emit(.msub(rem_ra.w(), div_ra.w(), rhs_mat.ra.w(), lhs_mat.ra.w()));
                    try isel.emit(switch (int_info.signedness) {
                        .signed => .sdiv(div_ra.w(), lhs_mat.ra.w(), rhs_mat.ra.w()),
                        .unsigned => .udiv(div_ra.w(), lhs_mat.ra.w(), rhs_mat.ra.w()),
                    });
                },
                33...64 => {
                    try isel.emit(.msub(rem_ra.x(), div_ra.x(), rhs_mat.ra.x(), lhs_mat.ra.x()));
                    try isel.emit(switch (int_info.signedness) {
                        .signed => .sdiv(div_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x()),
                        .unsigned => .udiv(div_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x()),
                    });
                },
            }
            try rhs_mat.finish(isel);
            try lhs_mat.finish(isel);
        } else {
            const bits = ty.floatBits(isel.target);
            switch (air_tag) {
                else => unreachable,
                .rem, .rem_optimized => {
                    if (!res_vi.value.isUsed(isel)) break :unused;
                    try call.compilerRtReturn(isel, res_vi.value, ty);
                },
                .mod, .mod_optimized => switch (bits) {
                    else => unreachable,
                    16, 32, 64 => {
                        const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                        try call.prepareReturn(isel);
                        const result_lock = isel.tryLockReg(res_ra);
                        defer result_lock.unlock(isel);
                        const rem_ra: Register.Alias = .v0;
                        const temp1_ra: Register.Alias = .v1;
                        const temp2_ra: Register.Alias = switch (res_ra) {
                            rem_ra, temp1_ra => .v2,
                            else => res_ra,
                        };
                        // These fixed scratch registers can hold live
                        // continuation values. Restore them after the
                        // correction has finished using the registers.
                        try call.returnFill(isel, rem_ra);
                        try call.returnFill(isel, temp1_ra);
                        if (temp2_ra != res_ra) try call.returnFill(isel, temp2_ra);
                        const need_fcvt = switch (bits) {
                            else => unreachable,
                            16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                            32, 64 => false,
                        };
                        const rhs_vi = try isel.use(bin_op.rhs);
                        const rhs_mat = try rhs_vi.matReg(isel);
                        const rhs_work_ra = if (need_fcvt) try isel.allocVecReg() else rhs_mat.ra;
                        defer if (rhs_work_ra != rhs_mat.ra) isel.freeReg(rhs_work_ra);
                        if (need_fcvt) try isel.emit(.fcvt(res_ra.h(), res_ra.s()));
                        try isel.emit(switch (res_ra) {
                            rem_ra => .bif(res_ra.@"8b"(), temp2_ra.@"8b"(), temp1_ra.@"8b"()),
                            temp1_ra => .bsl(res_ra.@"8b"(), rem_ra.@"8b"(), temp2_ra.@"8b"()),
                            else => .bit(res_ra.@"8b"(), rem_ra.@"8b"(), temp1_ra.@"8b"()),
                        });
                        try isel.emit(bits: switch (bits) {
                            else => unreachable,
                            16 => if (need_fcvt)
                                continue :bits 32
                            else
                                .fadd(temp2_ra.h(), rem_ra.h(), rhs_work_ra.h()),
                            32 => .fadd(temp2_ra.s(), rem_ra.s(), rhs_work_ra.s()),
                            64 => .fadd(temp2_ra.d(), rem_ra.d(), rhs_work_ra.d()),
                        });
                        try isel.emit(.orr(temp1_ra.@"8b"(), temp1_ra.@"8b"(), .{
                            .register = temp2_ra.@"8b"(),
                        }));
                        try isel.emit(switch (bits) {
                            else => unreachable,
                            16 => if (need_fcvt)
                                .cmge(temp1_ra.@"2s"(), temp1_ra.@"2s"(), .zero)
                            else
                                .cmge(temp1_ra.@"4h"(), temp1_ra.@"4h"(), .zero),
                            32 => .cmge(temp1_ra.@"2s"(), temp1_ra.@"2s"(), .zero),
                            64 => .cmge(temp1_ra.d(), temp1_ra.d(), .zero),
                        });
                        try isel.emit(switch (bits) {
                            else => unreachable,
                            16 => if (need_fcvt)
                                .fcmeq(temp2_ra.s(), rem_ra.s(), .zero)
                            else
                                .fcmeq(temp2_ra.h(), rem_ra.h(), .zero),
                            32 => .fcmeq(temp2_ra.s(), rem_ra.s(), .zero),
                            64 => .fcmeq(temp2_ra.d(), rem_ra.d(), .zero),
                        });
                        try isel.emit(.eor(temp1_ra.@"8b"(), rem_ra.@"8b"(), .{
                            .register = rhs_work_ra.@"8b"(),
                        }));
                        if (need_fcvt) {
                            try isel.emit(.fcvt(rhs_work_ra.s(), rhs_mat.ra.h()));
                            try isel.emit(.fcvt(rem_ra.s(), rem_ra.h()));
                        }
                        try rhs_mat.finish(isel);
                        try call.finishReturn(isel);
                    },
                    80, 128 => {
                        if (!res_vi.value.isUsed(isel)) break :unused;
                        // The optional add clobbers all caller registers.
                        // Both paths must reach its continuation restores.
                        try call.compilerRtReturn(isel, res_vi.value, ty);
                        const skip_label = isel.instructions.items.len;
                        try call.global(isel, switch (bits) {
                            else => unreachable,
                            16 => "__addhf3",
                            32 => "__addsf3",
                            64 => "__adddf3",
                            80 => "__addxf3",
                            128 => "__addtf3",
                        });
                        const rhs_vi = try isel.use(bin_op.rhs);
                        switch (bits) {
                            else => unreachable,
                            80 => {
                                const lhs_lo64_ra: Register.Alias = .r0;
                                const lhs_hi16_ra: Register.Alias = .r1;
                                const rhs_lo64_ra: Register.Alias = .r2;
                                const rhs_hi16_ra: Register.Alias = .r3;
                                const temp_ra: Register.Alias = .r4;
                                var rhs_hi16_it = rhs_vi.field(ty, 8, 8);
                                const rhs_hi16_vi = try rhs_hi16_it.only(isel);
                                var rhs_lo64_it = rhs_vi.field(ty, 0, 8);
                                const rhs_lo64_vi = try rhs_lo64_it.only(isel);
                                try isel.emit(.cbz(
                                    temp_ra.x(),
                                    @intCast((isel.instructions.items.len + 1 - skip_label) << 2),
                                ));
                                try isel.emit(.orr(temp_ra.x(), lhs_lo64_ra.x(), .{ .shifted_register = .{
                                    .register = lhs_hi16_ra.x(),
                                    .shift = .{ .lsl = 64 - 15 },
                                } }));
                                try isel.emit(.tbz(
                                    temp_ra.w(),
                                    15,
                                    @intCast((isel.instructions.items.len + 1 - skip_label) << 2),
                                ));
                                try isel.emit(.eor(temp_ra.w(), lhs_hi16_ra.w(), .{
                                    .register = rhs_hi16_ra.w(),
                                }));
                                try call.paramLiveOut(isel, rhs_hi16_vi.?, rhs_hi16_ra);
                                try call.paramLiveOut(isel, rhs_lo64_vi.?, rhs_lo64_ra);
                            },
                            128 => if (call.softF128(isel, bits)) {
                                // fmodf128 returned the remainder in x0/x1 and
                                // __addtf3 takes the divisor in x2/x3.
                                const lhs_lo64_ra: Register.Alias = .r0;
                                const lhs_hi64_ra: Register.Alias = .r1;
                                const rhs_ra: Register.Alias = .v1;
                                const rhs_lo64_ra: Register.Alias = .r2;
                                const rhs_hi64_ra: Register.Alias = .r3;
                                const temp_ra: Register.Alias = .r4;
                                try isel.emit(.tbz(
                                    temp_ra.x(),
                                    63,
                                    @intCast((isel.instructions.items.len + 1 - skip_label) << 2),
                                ));
                                try isel.emit(.eor(temp_ra.x(), lhs_hi64_ra.x(), .{
                                    .register = rhs_hi64_ra.x(),
                                }));
                                try isel.emit(.cbz(
                                    temp_ra.x(),
                                    @intCast((isel.instructions.items.len + 1 - skip_label) << 2),
                                ));
                                try isel.emit(.orr(temp_ra.x(), lhs_lo64_ra.x(), .{ .shifted_register = .{
                                    .register = lhs_hi64_ra.x(),
                                    .shift = .{ .lsl = 1 },
                                } }));
                                try call.paramSoftF128(isel, rhs_ra, rhs_lo64_ra);
                                try call.paramLiveOut(isel, rhs_vi, rhs_ra);
                            } else {
                                const lhs_ra: Register.Alias = .v0;
                                const rhs_ra: Register.Alias = .v1;
                                const temp1_ra: Register.Alias = .r0;
                                const temp2_ra: Register.Alias = .r1;
                                try isel.emit(.tbz(
                                    temp1_ra.x(),
                                    63,
                                    @intCast((isel.instructions.items.len + 1 - skip_label) << 2),
                                ));
                                try isel.emit(.eor(temp1_ra.x(), temp1_ra.x(), .{
                                    .register = temp2_ra.x(),
                                }));
                                try isel.emit(.fmov(temp1_ra.x(), .{
                                    .register = rhs_ra.@"d[]"(1),
                                }));
                                try isel.emit(.cbz(
                                    temp1_ra.x(),
                                    @intCast((isel.instructions.items.len + 1 - skip_label) << 2),
                                ));
                                try isel.emit(.orr(temp1_ra.x(), temp1_ra.x(), .{ .shifted_register = .{
                                    .register = temp2_ra.x(),
                                    .shift = .{ .lsl = 1 },
                                } }));
                                try isel.emit(.fmov(temp2_ra.x(), .{
                                    .register = lhs_ra.@"d[]"(1),
                                }));
                                try isel.emit(.fmov(temp1_ra.x(), .{
                                    .register = lhs_ra.d(),
                                }));
                                try call.paramLiveOut(isel, rhs_vi, rhs_ra);
                            },
                        }
                        try call.finishReturn(isel);
                    },
                },
            }

            try call.prepareCallee(isel);
            try call.global(isel, switch (bits) {
                else => unreachable,
                16 => "__fmodh",
                32 => "fmodf",
                64 => "fmod",
                80 => "__fmodx",
                128 => "fmodf128",
            });
            try call.finishCallee(isel);

            try call.compilerRtParams(isel, &.{ bin_op.lhs, bin_op.rhs });
        }
    }
}

/// `max` and `min` of integers of at most 128 bits and of floats.
fn selectMinMax(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const bin_op = isel.air.instructions.items(.data)[@backingInt(inst)].bin_op;
        const ty = isel.air.typeOf(bin_op.lhs, ip);
        if (!ty.isRuntimeFloat()) {
            if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
            const int_info = ty.intInfo(zcu);
            if (int_info.bits > 128) return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) });
            if (int_info.bits > 64) {
                const res_pair: DefPair = try .init(isel, res_vi.value, ty);
                defer res_pair.deinit(isel);
                if (res_pair.unused()) break :unused;
                const lhs_vi = try isel.use(bin_op.lhs);
                const rhs_vi = try isel.use(bin_op.rhs);
                var lhs_hi_it = lhs_vi.field(ty, 8, 8);
                const lhs_hi_mat = try (try lhs_hi_it.only(isel)).?.matReg(isel);
                var lhs_lo_it = lhs_vi.field(ty, 0, 8);
                const lhs_lo_mat = try (try lhs_lo_it.only(isel)).?.matReg(isel);
                var rhs_hi_it = rhs_vi.field(ty, 8, 8);
                const rhs_hi_mat = try (try rhs_hi_it.only(isel)).?.matReg(isel);
                var rhs_lo_it = rhs_vi.field(ty, 0, 8);
                const rhs_lo_mat = try (try rhs_lo_it.only(isel)).?.matReg(isel);
                // The flags of the full 128-bit subtraction decide
                // ordering, but not equality.
                const cond: codegen.aarch64.encoding.ConditionCode = switch (air_tag) {
                    else => unreachable,
                    .max => if (int_info.signedness == .signed) .ge else .hs,
                    .min => if (int_info.signedness == .signed) .lt else .lo,
                };
                if (res_pair.hi) |ra| try isel.emit(.csel(ra.x(), lhs_hi_mat.ra.x(), rhs_hi_mat.ra.x(), cond));
                if (res_pair.lo) |ra| try isel.emit(.csel(ra.x(), lhs_lo_mat.ra.x(), rhs_lo_mat.ra.x(), cond));
                try isel.emit(.sbcs(.xzr, lhs_hi_mat.ra.x(), rhs_hi_mat.ra.x()));
                try isel.emit(.subs(.xzr, lhs_lo_mat.ra.x(), .{ .register = rhs_lo_mat.ra.x() }));
                try rhs_lo_mat.finish(isel);
                try rhs_hi_mat.finish(isel);
                try lhs_lo_mat.finish(isel);
                try lhs_hi_mat.finish(isel);
                break :unused;
            }

            const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
            const lhs_vi = try isel.use(bin_op.lhs);
            const rhs_vi = try isel.use(bin_op.rhs);
            const lhs_mat = try lhs_vi.matReg(isel);
            const rhs_mat = try rhs_vi.matReg(isel);
            const cond: codegen.aarch64.encoding.ConditionCode = switch (air_tag) {
                else => unreachable,
                .max => switch (int_info.signedness) {
                    .signed => .ge,
                    .unsigned => .hs,
                },
                .min => switch (int_info.signedness) {
                    .signed => .lt,
                    .unsigned => .lo,
                },
            };
            switch (int_info.bits) {
                else => unreachable,
                1...32 => {
                    try isel.emit(.csel(res_ra.w(), lhs_mat.ra.w(), rhs_mat.ra.w(), cond));
                    try isel.emit(.subs(.wzr, lhs_mat.ra.w(), .{ .register = rhs_mat.ra.w() }));
                },
                33...64 => {
                    try isel.emit(.csel(res_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x(), cond));
                    try isel.emit(.subs(.xzr, lhs_mat.ra.x(), .{ .register = rhs_mat.ra.x() }));
                },
            }
            try rhs_mat.finish(isel);
            try lhs_mat.finish(isel);
        } else switch (ty.floatBits(isel.target)) {
            else => unreachable,
            16, 32, 64 => |bits| {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const need_fcvt = switch (bits) {
                    else => unreachable,
                    16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                    32, 64 => false,
                };
                if (need_fcvt) try isel.emit(.fcvt(res_ra.h(), res_ra.s()));
                const lhs_vi = try isel.use(bin_op.lhs);
                const rhs_vi = try isel.use(bin_op.rhs);
                const lhs_mat = try lhs_vi.matReg(isel);
                const rhs_mat = try rhs_vi.matReg(isel);
                const lhs_ra = if (need_fcvt) try isel.allocVecReg() else lhs_mat.ra;
                defer if (need_fcvt) isel.freeReg(lhs_ra);
                const rhs_ra = if (need_fcvt) try isel.allocVecReg() else rhs_mat.ra;
                defer if (need_fcvt) isel.freeReg(rhs_ra);
                try isel.emit(bits: switch (bits) {
                    else => unreachable,
                    16 => if (need_fcvt) continue :bits 32 else switch (air_tag) {
                        else => unreachable,
                        .max => .fmaxnm(res_ra.h(), lhs_ra.h(), rhs_ra.h()),
                        .min => .fminnm(res_ra.h(), lhs_ra.h(), rhs_ra.h()),
                    },
                    32 => switch (air_tag) {
                        else => unreachable,
                        .max => .fmaxnm(res_ra.s(), lhs_ra.s(), rhs_ra.s()),
                        .min => .fminnm(res_ra.s(), lhs_ra.s(), rhs_ra.s()),
                    },
                    64 => switch (air_tag) {
                        else => unreachable,
                        .max => .fmaxnm(res_ra.d(), lhs_ra.d(), rhs_ra.d()),
                        .min => .fminnm(res_ra.d(), lhs_ra.d(), rhs_ra.d()),
                    },
                });
                if (need_fcvt) {
                    try isel.emit(.fcvt(rhs_ra.s(), rhs_mat.ra.h()));
                    try isel.emit(.fcvt(lhs_ra.s(), lhs_mat.ra.h()));
                }
                try rhs_mat.finish(isel);
                try lhs_mat.finish(isel);
            },
            80, 128 => |bits| {
                try call.compilerRt(isel, switch (air_tag) {
                    else => unreachable,
                    .max => switch (bits) {
                        else => unreachable,
                        16 => "__fmaxh",
                        32 => "fmaxf",
                        64 => "fmax",
                        80 => "__fmaxx",
                        128 => "fmaxf128",
                    },
                    .min => switch (bits) {
                        else => unreachable,
                        16 => "__fminh",
                        32 => "fminf",
                        64 => "fmin",
                        80 => "__fminx",
                        128 => "fminf128",
                    },
                }, res_vi.value, ty, &.{ bin_op.lhs, bin_op.rhs });
            },
        }
    }
}

/// `bit_and`, `bit_or` and `xor`, preceded by `before` in their body, of
/// integers of at most 128 bits, bools and vectors; a rotate idiom becomes a
/// rotate (`rotateOperands`).
fn selectBitwise(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag, before: []const Air.Inst.Index) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const bin_op = isel.air.instructions.items(.data)[@backingInt(inst)].bin_op;
        const ty = isel.air.typeOf(bin_op.lhs, ip);
        if (ty.zigTypeTag(zcu) == .vector) {
            try isel.vectorBitwise(res_vi.value, ty, bin_op.lhs, bin_op.rhs, air_tag);
        } else {
            const int_info: std.lang.Type.Int = if (ty.toIntern() == .bool_type)
                .{ .signedness = .unsigned, .bits = 1 }
            else if (ty.isAbiInt(zcu))
                ty.intInfo(zcu)
            else
                return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
            if (int_info.bits > 128) return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) });

            if (air_tag == .bit_or and (int_info.bits == 32 or int_info.bits == 64)) rotate: {
                const rotate = isel.rotateOperands(bin_op, int_info.bits, before) orelse break :rotate;
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const src_mat = try (try isel.use(rotate.src)).matReg(isel);
                const res_reg, const src_reg = switch (int_info.bits) {
                    else => unreachable,
                    32 => .{ res_ra.w(), src_mat.ra.w() },
                    64 => .{ res_ra.x(), src_mat.ra.x() },
                };
                switch (rotate.right) {
                    .immediate => |amount| try isel.emit(.extr(res_reg, src_reg, src_reg, amount)),
                    .by => |amount_ref| {
                        const amount_mat = try (try isel.use(amount_ref)).matReg(isel);
                        try isel.emit(.rorv(res_reg, src_reg, switch (int_info.bits) {
                            else => unreachable,
                            32 => amount_mat.ra.w(),
                            64 => amount_mat.ra.x(),
                        }));
                        try amount_mat.finish(isel);
                    },
                    .by_negated => |amount_ref| {
                        const amount_mat = try (try isel.use(amount_ref)).matReg(isel);
                        const neg_ra = try isel.allocIntReg();
                        defer isel.freeReg(neg_ra);
                        try isel.emit(.rorv(res_reg, src_reg, switch (int_info.bits) {
                            else => unreachable,
                            32 => neg_ra.w(),
                            64 => neg_ra.x(),
                        }));
                        try isel.emit(.sub(neg_ra.w(), .wzr, .{ .register = amount_mat.ra.w() }));
                        try amount_mat.finish(isel);
                    },
                }
                try src_mat.finish(isel);
                break :unused;
            }

            var lhs_vi = try isel.use(bin_op.lhs);
            var rhs_vi = try isel.use(bin_op.rhs);
            if (isel.constantImmediate(rhs_vi) == null) std.mem.swap(Value.Index, &lhs_vi, &rhs_vi);
            if (res_vi.value.size(isel) <= 8) if (isel.constantImmediate(rhs_vi)) |imm| {
                const size = res_vi.value.size(isel);
                const sf: codegen.aarch64.encoding.Register.GeneralSize = if (size <= 4) .word else .doubleword;
                if (codegen.aarch64.encoding.Instruction.DataProcessingImmediate.Bitmask.encodeImmediate(imm, sf)) |bitmask| {
                    var res_part_it = res_vi.value.field(ty, 0, size);
                    const res_ra = try (try res_part_it.only(isel)).?.defReg(isel) orelse break :unused;
                    var lhs_part_it = lhs_vi.field(ty, 0, size);
                    const lhs_part_mat = try (try lhs_part_it.only(isel)).?.matReg(isel);
                    const res_reg, const lhs_reg = switch (sf) {
                        .word => .{ res_ra.w(), lhs_part_mat.ra.w() },
                        .doubleword => .{ res_ra.x(), lhs_part_mat.ra.x() },
                    };
                    try isel.emit(switch (air_tag) {
                        else => unreachable,
                        .bit_and => .@"and"(res_reg, lhs_reg, .{ .immediate = bitmask }),
                        .bit_or => .orr(res_reg, lhs_reg, .{ .immediate = bitmask }),
                        .xor => .eor(res_reg, lhs_reg, .{ .immediate = bitmask }),
                    });
                    try lhs_part_mat.finish(isel);
                    break :unused;
                }
            };
            var offset = res_vi.value.size(isel);
            while (offset > 0) {
                const size = @min(offset, 8);
                offset -= size;
                var res_part_it = res_vi.value.field(ty, offset, size);
                const res_part_vi = try res_part_it.only(isel);
                const res_part_ra = try res_part_vi.?.defReg(isel) orelse continue;
                var lhs_part_it = lhs_vi.field(ty, offset, size);
                const lhs_part_vi = try lhs_part_it.only(isel);
                const lhs_part_mat = try lhs_part_vi.?.matReg(isel);
                var rhs_part_it = rhs_vi.field(ty, offset, size);
                const rhs_part_vi = try rhs_part_it.only(isel);
                const rhs_part_mat = try rhs_part_vi.?.matReg(isel);
                try isel.emit(switch (air_tag) {
                    else => unreachable,
                    .bit_and => switch (size) {
                        else => unreachable,
                        1, 2, 4 => .@"and"(res_part_ra.w(), lhs_part_mat.ra.w(), .{ .register = rhs_part_mat.ra.w() }),
                        8 => .@"and"(res_part_ra.x(), lhs_part_mat.ra.x(), .{ .register = rhs_part_mat.ra.x() }),
                    },
                    .bit_or => switch (size) {
                        else => unreachable,
                        1, 2, 4 => .orr(res_part_ra.w(), lhs_part_mat.ra.w(), .{ .register = rhs_part_mat.ra.w() }),
                        8 => .orr(res_part_ra.x(), lhs_part_mat.ra.x(), .{ .register = rhs_part_mat.ra.x() }),
                    },
                    .xor => switch (size) {
                        else => unreachable,
                        1, 2, 4 => .eor(res_part_ra.w(), lhs_part_mat.ra.w(), .{ .register = rhs_part_mat.ra.w() }),
                        8 => .eor(res_part_ra.x(), lhs_part_mat.ra.x(), .{ .register = rhs_part_mat.ra.x() }),
                    },
                });
                try rhs_part_mat.finish(isel);
                try lhs_part_mat.finish(isel);
            }
        }
    }
}

/// Shifts of integers of at most 128 bits, and of SIMD integer vectors by a
/// scalar (`Legalize.Feature.keep_simd_int_vectors`).
fn selectShift(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const bin_op = isel.air.instructions.items(.data)[@backingInt(inst)].bin_op;
        const ty = isel.air.typeOf(bin_op.lhs, ip);
        if (ty.isVector(zcu)) {
            const arrangement = isel.simdIntArrangement(ty) orelse
                return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
            if (isel.air.typeOf(bin_op.rhs, ip).isVector(zcu))
                return isel.fail("bad {t} {f} by a vector", .{ air_tag, isel.fmtType(ty) });
            const signedness = ty.childType(zcu).intInfo(zcu).signedness;
            const res_def = try isel.defVector(res_vi.value) orelse break :unused;
            defer res_def.finish(isel);
            const res_reg = res_def.ra.vector(arrangement);
            const lhs_mat = try (try isel.use(bin_op.lhs)).matReg(isel);
            const lhs_reg = lhs_mat.ra.vector(arrangement);
            const rhs_vi = try isel.use(bin_op.rhs);
            if (isel.constantImmediate(rhs_vi)) |amount| {
                // The amount is less than the element size by its type.
                try isel.emit(switch (air_tag) {
                    else => unreachable,
                    .shl, .shl_exact => .shl(res_reg, lhs_reg, @intCast(amount)),
                    .shr, .shr_exact => if (amount == 0) .shl(res_reg, lhs_reg, 0) else switch (signedness) {
                        .signed => .sshr(res_reg, lhs_reg, @intCast(amount)),
                        .unsigned => .ushr(res_reg, lhs_reg, @intCast(amount)),
                    },
                });
            } else {
                // A register shift by a negative amount shifts right.
                const amount_mat = try rhs_vi.matReg(isel);
                const amount_ra = try isel.allocVecReg();
                defer isel.freeReg(amount_ra);
                const amount_reg = amount_ra.vector(arrangement);
                try isel.emit(switch (signedness) {
                    .signed => .sshl(res_reg, lhs_reg, amount_reg),
                    .unsigned => .ushl(res_reg, lhs_reg, amount_reg),
                });
                switch (air_tag) {
                    else => unreachable,
                    .shl, .shl_exact => {},
                    .shr, .shr_exact => try isel.emit(.neg(amount_reg, amount_reg)),
                }
                // Only the low byte of each lane counts: clear the bits
                // above the amount's type.
                const mask_ra = try isel.allocIntReg();
                defer isel.freeReg(mask_ra);
                const elem_bits = ty.childType(zcu).intInfo(zcu).bits;
                const amount_bits: u6 = std.math.log2_int(u16, elem_bits);
                switch (elem_bits) {
                    else => unreachable,
                    8, 16, 32 => {
                        try isel.emit(.dup(amount_reg, mask_ra.w()));
                        try isel.emit(.@"and"(mask_ra.w(), amount_mat.ra.w(), .{ .immediate = .{
                            .N = .word,
                            .immr = 0,
                            .imms = amount_bits - 1,
                        } }));
                    },
                    64 => {
                        try isel.emit(.dup(amount_reg, mask_ra.x()));
                        try isel.emit(.@"and"(mask_ra.x(), amount_mat.ra.x(), .{ .immediate = .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = amount_bits - 1,
                        } }));
                    },
                }
                try amount_mat.finish(isel);
            }
            try lhs_mat.finish(isel);
            break :unused;
        }
        if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
        const int_info = ty.intInfo(zcu);
        switch (int_info.bits) {
            0 => unreachable,
            1...64 => |bits| {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                switch (air_tag) {
                    else => unreachable,
                    .shr, .shr_exact, .shl_exact => {},
                    .shl => switch (bits) {
                        else => unreachable,
                        1...31 => try isel.emit(switch (int_info.signedness) {
                            .signed => .sbfm(res_ra.w(), res_ra.w(), .{
                                .N = .word,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            }),
                            .unsigned => .ubfm(res_ra.w(), res_ra.w(), .{
                                .N = .word,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            }),
                        }),
                        32 => {},
                        33...63 => try isel.emit(switch (int_info.signedness) {
                            .signed => .sbfm(res_ra.x(), res_ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            }),
                            .unsigned => .ubfm(res_ra.x(), res_ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(bits - 1),
                            }),
                        }),
                        64 => {},
                    },
                }

                const lhs_vi = try isel.use(bin_op.lhs);
                const rhs_vi = try isel.use(bin_op.rhs);
                if (isel.constantImmediate(rhs_vi)) |amount| if (amount < bits) {
                    const shift: u6 = @intCast(amount);
                    const lhs_mat = try lhs_vi.matReg(isel);
                    try isel.emit(switch (bits) {
                        else => unreachable,
                        1...32 => switch (air_tag) {
                            else => unreachable,
                            .shr, .shr_exact => switch (int_info.signedness) {
                                .signed => .sbfm(res_ra.w(), lhs_mat.ra.w(), .{ .N = .word, .immr = shift, .imms = 31 }),
                                .unsigned => .ubfm(res_ra.w(), lhs_mat.ra.w(), .{ .N = .word, .immr = shift, .imms = 31 }),
                            },
                            .shl, .shl_exact => .ubfm(res_ra.w(), lhs_mat.ra.w(), .{
                                .N = .word,
                                .immr = @as(u5, -%@as(u5, @intCast(shift))),
                                .imms = 31 - shift,
                            }),
                        },
                        33...64 => switch (air_tag) {
                            else => unreachable,
                            .shr, .shr_exact => switch (int_info.signedness) {
                                .signed => .sbfm(res_ra.x(), lhs_mat.ra.x(), .{ .N = .doubleword, .immr = shift, .imms = 63 }),
                                .unsigned => .ubfm(res_ra.x(), lhs_mat.ra.x(), .{ .N = .doubleword, .immr = shift, .imms = 63 }),
                            },
                            .shl, .shl_exact => .ubfm(res_ra.x(), lhs_mat.ra.x(), .{
                                .N = .doubleword,
                                .immr = -%shift,
                                .imms = 63 - shift,
                            }),
                        },
                    });
                    try lhs_mat.finish(isel);
                    break :unused;
                };
                const lhs_mat = try lhs_vi.matReg(isel);
                const rhs_mat = try rhs_vi.matReg(isel);
                try isel.emit(switch (air_tag) {
                    else => unreachable,
                    .shr, .shr_exact => switch (bits) {
                        else => unreachable,
                        1...32 => switch (int_info.signedness) {
                            .signed => .asrv(res_ra.w(), lhs_mat.ra.w(), rhs_mat.ra.w()),
                            .unsigned => .lsrv(res_ra.w(), lhs_mat.ra.w(), rhs_mat.ra.w()),
                        },
                        33...64 => switch (int_info.signedness) {
                            .signed => .asrv(res_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x()),
                            .unsigned => .lsrv(res_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x()),
                        },
                    },
                    .shl, .shl_exact => switch (bits) {
                        else => unreachable,
                        1...32 => .lslv(res_ra.w(), lhs_mat.ra.w(), rhs_mat.ra.w()),
                        33...64 => .lslv(res_ra.x(), lhs_mat.ra.x(), rhs_mat.ra.x()),
                    },
                });
                try rhs_mat.finish(isel);
                try lhs_mat.finish(isel);
            },
            65...128 => |bits| {
                const res_pair: DefPair = try .init(isel, res_vi.value, ty);
                defer res_pair.deinit(isel);
                if (res_pair.unused()) break :unused;
                if (res_pair.hi) |res_ra| switch (air_tag) {
                    else => unreachable,
                    .shr, .shr_exact, .shl_exact => {},
                    .shl => switch (bits) {
                        else => unreachable,
                        65...127 => try isel.emit(switch (int_info.signedness) {
                            .signed => .sbfm(res_ra.x(), res_ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(bits - 64 - 1),
                            }),
                            .unsigned => .ubfm(res_ra.x(), res_ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(bits - 64 - 1),
                            }),
                        }),
                        128 => {},
                    },
                };

                const lhs_vi = try isel.use(bin_op.lhs);
                var lhs_hi64_it = lhs_vi.field(ty, 8, 8);
                const lhs_hi64_vi = try lhs_hi64_it.only(isel);
                const lhs_hi64_mat = try lhs_hi64_vi.?.matReg(isel);
                var lhs_lo64_it = lhs_vi.field(ty, 0, 8);
                const lhs_lo64_vi = try lhs_lo64_it.only(isel);
                const lhs_lo64_mat = try lhs_lo64_vi.?.matReg(isel);
                const rhs_vi = try isel.use(bin_op.rhs);
                const rhs_mat = try rhs_vi.matReg(isel);
                const lo64_ra = try isel.allocIntReg();
                defer isel.freeReg(lo64_ra);
                const hi64_ra = try isel.allocIntReg();
                defer isel.freeReg(hi64_ra);
                switch (air_tag) {
                    else => unreachable,
                    .shr, .shr_exact => {
                        if (res_pair.hi) |res_ra| switch (int_info.signedness) {
                            .signed => {
                                try isel.emit(.csel(res_ra.x(), hi64_ra.x(), lo64_ra.x(), .eq));
                                try isel.emit(.sbfm(lo64_ra.x(), lhs_hi64_mat.ra.x(), .{
                                    .N = .doubleword,
                                    .immr = @intCast(bits - 64 - 1),
                                    .imms = @intCast(bits - 64 - 1),
                                }));
                            },
                            .unsigned => try isel.emit(.csel(res_ra.x(), hi64_ra.x(), .xzr, .eq)),
                        };
                        if (res_pair.lo) |res_ra| try isel.emit(.csel(res_ra.x(), lo64_ra.x(), hi64_ra.x(), .eq));
                        switch (int_info.signedness) {
                            .signed => try isel.emit(.asrv(hi64_ra.x(), lhs_hi64_mat.ra.x(), rhs_mat.ra.x())),
                            .unsigned => try isel.emit(.lsrv(hi64_ra.x(), lhs_hi64_mat.ra.x(), rhs_mat.ra.x())),
                        }
                    },
                    .shl, .shl_exact => {
                        if (res_pair.lo) |res_ra| try isel.emit(.csel(res_ra.x(), lo64_ra.x(), .xzr, .eq));
                        if (res_pair.hi) |res_ra| try isel.emit(.csel(res_ra.x(), hi64_ra.x(), lo64_ra.x(), .eq));
                        try isel.emit(.lslv(lo64_ra.x(), lhs_lo64_mat.ra.x(), rhs_mat.ra.x()));
                    },
                }
                try isel.emit(.ands(.wzr, rhs_mat.ra.w(), .{ .immediate = .{ .N = .word, .immr = 32 - 6, .imms = 0 } }));
                switch (air_tag) {
                    else => unreachable,
                    .shr, .shr_exact => if (res_pair.lo) |_| {
                        try isel.emit(.orr(
                            lo64_ra.x(),
                            lo64_ra.x(),
                            .{ .shifted_register = .{ .register = hi64_ra.x(), .shift = .{ .lsl = 1 } } },
                        ));
                        try isel.emit(.lslv(hi64_ra.x(), lhs_hi64_mat.ra.x(), hi64_ra.x()));
                        try isel.emit(.lsrv(lo64_ra.x(), lhs_lo64_mat.ra.x(), rhs_mat.ra.x()));
                        try isel.emit(.orn(hi64_ra.w(), .wzr, .{ .register = rhs_mat.ra.w() }));
                    },
                    .shl, .shl_exact => if (res_pair.hi) |_| {
                        try isel.emit(.orr(
                            hi64_ra.x(),
                            hi64_ra.x(),
                            .{ .shifted_register = .{ .register = lo64_ra.x(), .shift = .{ .lsr = 1 } } },
                        ));
                        try isel.emit(.lsrv(lo64_ra.x(), lhs_lo64_mat.ra.x(), lo64_ra.x()));
                        try isel.emit(.lslv(hi64_ra.x(), lhs_hi64_mat.ra.x(), rhs_mat.ra.x()));
                        try isel.emit(.orn(lo64_ra.w(), .wzr, .{ .register = rhs_mat.ra.w() }));
                    },
                }
                try rhs_mat.finish(isel);
                try lhs_lo64_mat.finish(isel);
                try lhs_hi64_mat.finish(isel);
                break :unused;
            },
            else => return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) }),
        }
    }
}

/// `bit_cast` and the casts that do not change the bits of a value.
fn selectBitCast(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |dst_vi| unused: {
        defer dst_vi.value.deref(isel);
        const ty_op = isel.air.instructions.items(.data)[@backingInt(inst)].ty_op;
        const dst_ty = ty_op.ty;
        const dst_tag = dst_ty.zigTypeTag(zcu);
        const src_ty = isel.air.typeOf(ty_op.operand, ip);
        const src_tag = src_ty.zigTypeTag(zcu);
        if (air_tag == .union_from_enum) {
            // The union has no payload bits, so its representation is exactly its tag.
            if (dst_ty.abiSize(zcu) != src_ty.abiSize(zcu))
                return isel.fail("bad {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) });
            try dst_vi.value.move(isel, ty_op.operand);
        } else if (dst_ty.isAbiInt(zcu) and (src_tag == .bool or src_ty.isAbiInt(zcu))) {
            const dst_int_info = dst_ty.intInfo(zcu);
            const src_int_info: std.lang.Type.Int = if (src_tag == .bool) .{ .signedness = undefined, .bits = 1 } else src_ty.intInfo(zcu);
            assert(dst_int_info.bits == src_int_info.bits);
            if (dst_tag != .@"struct" and src_tag != .@"struct" and src_tag != .bool and dst_int_info.signedness == src_int_info.signedness) {
                try dst_vi.value.move(isel, ty_op.operand);
            } else switch (dst_int_info.bits) {
                0 => unreachable,
                1...31 => |dst_bits| {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    try isel.emit(switch (dst_int_info.signedness) {
                        .signed => .sbfm(dst_ra.w(), src_mat.ra.w(), .{
                            .N = .word,
                            .immr = 0,
                            .imms = @intCast(dst_bits - 1),
                        }),
                        .unsigned => .ubfm(dst_ra.w(), src_mat.ra.w(), .{
                            .N = .word,
                            .immr = 0,
                            .imms = @intCast(dst_bits - 1),
                        }),
                    });
                    try src_mat.finish(isel);
                },
                32 => try dst_vi.value.move(isel, ty_op.operand),
                33...63 => |dst_bits| {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    try isel.emit(switch (dst_int_info.signedness) {
                        .signed => .sbfm(dst_ra.x(), src_mat.ra.x(), .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = @intCast(dst_bits - 1),
                        }),
                        .unsigned => .ubfm(dst_ra.x(), src_mat.ra.x(), .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = @intCast(dst_bits - 1),
                        }),
                    });
                    try src_mat.finish(isel);
                },
                64 => try dst_vi.value.move(isel, ty_op.operand),
                65...127 => |dst_bits| {
                    const src_vi = try isel.use(ty_op.operand);
                    var dst_hi64_it = dst_vi.value.field(dst_ty, 8, 8);
                    const dst_hi64_vi = try dst_hi64_it.only(isel);
                    if (try dst_hi64_vi.?.defReg(isel)) |dst_hi64_ra| {
                        var src_hi64_it = src_vi.field(src_ty, 8, 8);
                        const src_hi64_vi = try src_hi64_it.only(isel);
                        const src_hi64_mat = try src_hi64_vi.?.matReg(isel);
                        try isel.emit(switch (dst_int_info.signedness) {
                            .signed => .sbfm(dst_hi64_ra.x(), src_hi64_mat.ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(dst_bits - 64 - 1),
                            }),
                            .unsigned => .ubfm(dst_hi64_ra.x(), src_hi64_mat.ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = @intCast(dst_bits - 64 - 1),
                            }),
                        });
                        try src_hi64_mat.finish(isel);
                    }
                    var dst_lo64_it = dst_vi.value.field(dst_ty, 0, 8);
                    const dst_lo64_vi = try dst_lo64_it.only(isel);
                    if (try dst_lo64_vi.?.defReg(isel)) |dst_lo64_ra| {
                        var src_lo64_it = src_vi.field(src_ty, 0, 8);
                        const src_lo64_vi = try src_lo64_it.only(isel);
                        try src_lo64_vi.?.liveOut(isel, dst_lo64_ra);
                    }
                },
                128 => try dst_vi.value.move(isel, ty_op.operand),
                129...(Value.max_parts * 64) => try isel.bitCastInteger(
                    dst_vi.value,
                    dst_ty,
                    try isel.use(ty_op.operand),
                    src_ty,
                ),
                else => return isel.fail("bad {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) }),
            }
        } else if (dst_tag == .bool and src_ty.isAbiInt(zcu) and src_ty.intInfo(zcu).bits == 1) {
            const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
            const dst_lock = isel.tryLockReg(dst_ra);
            defer dst_lock.unlock(isel);
            const src_mat = try (try isel.use(ty_op.operand)).matReg(isel);
            const work_ra = if (dst_ra.isVector()) try isel.allocIntReg() else dst_ra;
            defer if (dst_ra.isVector()) isel.freeReg(work_ra);
            if (dst_ra.isVector()) try isel.emit(.fmov(dst_ra.s(), .{ .register = work_ra.w() }));
            try isel.normalizeIntReg(work_ra, if (src_mat.ra.isVector()) work_ra else src_mat.ra, .{
                .bits = 1,
                .signedness = .unsigned,
            });
            if (src_mat.ra.isVector()) try isel.emit(.fmov(work_ra.w(), .{ .register = src_mat.ra.s() }));
            try src_mat.finish(isel);
        } else if ((dst_ty.isPtrAtRuntime(zcu) or dst_ty.isAbiInt(zcu)) and (src_ty.isPtrAtRuntime(zcu) or src_ty.isAbiInt(zcu))) {
            try dst_vi.value.move(isel, ty_op.operand);
        } else if (dst_ty.isSliceAtRuntime(zcu) and src_ty.isSliceAtRuntime(zcu)) {
            try dst_vi.value.move(isel, ty_op.operand);
        } else if (dst_tag == .error_union and src_tag == .error_union) {
            assert(dst_ty.errorUnionSet(zcu).hasRuntimeBits(zcu) ==
                src_ty.errorUnionSet(zcu).hasRuntimeBits(zcu));
            if (dst_ty.errorUnionPayload(zcu).toIntern() == src_ty.errorUnionPayload(zcu).toIntern()) {
                try dst_vi.value.move(isel, ty_op.operand);
            } else return isel.fail("bad {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) });
        } else if (dst_tag == .float and src_tag == .float) {
            assert(dst_ty.floatBits(isel.target) == src_ty.floatBits(isel.target));
            try dst_vi.value.move(isel, ty_op.operand);
        } else if (dst_ty.isAbiInt(zcu) and src_tag == .float) {
            const dst_int_info = dst_ty.intInfo(zcu);
            assert(dst_int_info.bits == src_ty.floatBits(isel.target));
            switch (dst_int_info.bits) {
                else => unreachable,
                16 => {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    switch (dst_int_info.signedness) {
                        .signed => try isel.emit(.smov(dst_ra.w(), src_mat.ra.@"h[]"(0))),
                        .unsigned => try isel.emit(if (isel.target.cpu.has(.aarch64, .fullfp16))
                            .fmov(dst_ra.w(), .{ .register = src_mat.ra.h() })
                        else
                            .umov(dst_ra.w(), src_mat.ra.@"h[]"(0))),
                    }
                    try src_mat.finish(isel);
                },
                32 => {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    try isel.emit(.fmov(dst_ra.w(), .{ .register = src_mat.ra.s() }));
                    try src_mat.finish(isel);
                },
                64 => {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    try isel.emit(.fmov(dst_ra.x(), .{ .register = src_mat.ra.d() }));
                    try src_mat.finish(isel);
                },
                80 => {
                    const src_vi = try isel.use(ty_op.operand);
                    var dst_hi16_it = dst_vi.value.field(dst_ty, 8, 8);
                    const dst_hi16_vi = try dst_hi16_it.only(isel);
                    if (try dst_hi16_vi.?.defReg(isel)) |dst_hi16_ra| {
                        var src_hi16_it = src_vi.field(src_ty, 8, 8);
                        const src_hi16_vi = try src_hi16_it.only(isel);
                        const src_hi16_mat = try src_hi16_vi.?.matReg(isel);
                        try isel.emit(switch (dst_int_info.signedness) {
                            .signed => .sbfm(
                                dst_hi16_ra.x(),
                                src_hi16_mat.ra.x(),
                                .{ .N = .doubleword, .immr = 0, .imms = 16 - 1 },
                            ),
                            .unsigned => .ubfm(
                                dst_hi16_ra.x(),
                                src_hi16_mat.ra.x(),
                                .{ .N = .doubleword, .immr = 0, .imms = 16 - 1 },
                            ),
                        });
                        try src_hi16_mat.finish(isel);
                    }
                    var dst_lo64_it = dst_vi.value.field(dst_ty, 0, 8);
                    const dst_lo64_vi = try dst_lo64_it.only(isel);
                    if (try dst_lo64_vi.?.defReg(isel)) |dst_lo64_ra| {
                        var src_lo64_it = src_vi.field(src_ty, 0, 8);
                        const src_lo64_vi = try src_lo64_it.only(isel);
                        try src_lo64_vi.?.liveOut(isel, dst_lo64_ra);
                    }
                },
                128 => {
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    var dst_hi64_it = dst_vi.value.field(dst_ty, 8, 8);
                    const dst_hi64_vi = try dst_hi64_it.only(isel);
                    if (try dst_hi64_vi.?.defReg(isel)) |dst_hi64_ra| try isel.emit(.fmov(dst_hi64_ra.x(), .{ .register = src_mat.ra.@"d[]"(1) }));
                    var dst_lo64_it = dst_vi.value.field(dst_ty, 0, 8);
                    const dst_lo64_vi = try dst_lo64_it.only(isel);
                    if (try dst_lo64_vi.?.defReg(isel)) |dst_lo64_ra| try isel.emit(.fmov(dst_lo64_ra.x(), .{ .register = src_mat.ra.d() }));
                    try src_mat.finish(isel);
                },
            }
        } else if (dst_tag == .float and src_ty.isAbiInt(zcu)) {
            const src_int_info = src_ty.intInfo(zcu);
            assert(dst_ty.floatBits(isel.target) == src_int_info.bits);
            switch (src_int_info.bits) {
                else => unreachable,
                16 => {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    try isel.emit(.fmov(
                        if (isel.target.cpu.has(.aarch64, .fullfp16)) dst_ra.h() else dst_ra.s(),
                        .{ .register = src_mat.ra.w() },
                    ));
                    try src_mat.finish(isel);
                },
                32 => {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    try isel.emit(.fmov(dst_ra.s(), .{ .register = src_mat.ra.w() }));
                    try src_mat.finish(isel);
                },
                64 => {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    try isel.emit(.fmov(dst_ra.d(), .{ .register = src_mat.ra.x() }));
                    try src_mat.finish(isel);
                },
                80 => switch (src_int_info.signedness) {
                    .signed => {
                        const src_vi = try isel.use(ty_op.operand);
                        var dst_hi16_it = dst_vi.value.field(dst_ty, 8, 8);
                        const dst_hi16_vi = try dst_hi16_it.only(isel);
                        if (try dst_hi16_vi.?.defReg(isel)) |dst_hi16_ra| {
                            var src_hi16_it = src_vi.field(src_ty, 8, 8);
                            const src_hi16_vi = try src_hi16_it.only(isel);
                            const src_hi16_mat = try src_hi16_vi.?.matReg(isel);
                            try isel.emit(.ubfm(dst_hi16_ra.x(), src_hi16_mat.ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = 16 - 1,
                            }));
                            try src_hi16_mat.finish(isel);
                        }
                        var dst_lo64_it = dst_vi.value.field(dst_ty, 0, 8);
                        const dst_lo64_vi = try dst_lo64_it.only(isel);
                        if (try dst_lo64_vi.?.defReg(isel)) |dst_lo64_ra| {
                            var src_lo64_it = src_vi.field(src_ty, 0, 8);
                            const src_lo64_vi = try src_lo64_it.only(isel);
                            try src_lo64_vi.?.liveOut(isel, dst_lo64_ra);
                        }
                    },
                    else => try dst_vi.value.move(isel, ty_op.operand),
                },
                128 => {
                    const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    var src_hi64_it = src_vi.field(src_ty, 8, 8);
                    const src_hi64_vi = try src_hi64_it.only(isel);
                    const src_hi64_mat = try src_hi64_vi.?.matReg(isel);
                    try isel.emit(.fmov(dst_ra.@"d[]"(1), .{ .register = src_hi64_mat.ra.x() }));
                    try src_hi64_mat.finish(isel);
                    var src_lo64_it = src_vi.field(src_ty, 0, 8);
                    const src_lo64_vi = try src_lo64_it.only(isel);
                    const src_lo64_mat = try src_lo64_vi.?.matReg(isel);
                    try isel.emit(.fmov(dst_ra.d(), .{ .register = src_lo64_mat.ra.x() }));
                    try src_lo64_mat.finish(isel);
                },
            }
        } else if (dst_tag == .vector and src_tag == .vector and
            isel.vectorLaneBits(dst_ty.childType(zcu)) == dst_ty.childType(zcu).bitSize(zcu) and
            isel.vectorLaneBits(src_ty.childType(zcu)) == src_ty.childType(zcu).bitSize(zcu) and
            dst_ty.abiSize(zcu) == src_ty.abiSize(zcu))
        {
            assert(dst_ty.bitSize(zcu) == src_ty.bitSize(zcu));
            const src_vi = try isel.use(ty_op.operand);
            try dst_vi.value.copyField(isel, dst_ty, 0, src_vi, src_ty, 0, dst_ty.abiSize(zcu));
        } else if (dst_tag == .array and src_tag == .array and
            dst_ty.childType(zcu).bitSize(zcu) == 8 * dst_ty.childType(zcu).abiSize(zcu) and
            src_ty.childType(zcu).bitSize(zcu) == 8 * src_ty.childType(zcu).abiSize(zcu) and
            dst_ty.abiSize(zcu) == src_ty.abiSize(zcu))
        {
            const src_vi = try isel.use(ty_op.operand);
            try dst_vi.value.copyField(isel, dst_ty, 0, src_vi, src_ty, 0, dst_ty.abiSize(zcu));
        } else if (((dst_ty.isAbiInt(zcu) or dst_tag == .float) and (src_tag == .array or src_tag == .vector) and
            isel.bitCastIsContiguous(src_ty)) or
            ((dst_tag == .array or dst_tag == .vector) and
                isel.bitCastIsContiguous(dst_ty) and (src_ty.isAbiInt(zcu) or src_tag == .float)))
        {
            try isel.bitCastContiguous(dst_vi.value, dst_ty, try isel.use(ty_op.operand), src_ty);
        } else if ((dst_tag == .array or dst_tag == .vector) and (src_tag == .array or src_tag == .vector) and
            isel.bitCastIsContiguous(dst_ty) and isel.bitCastIsContiguous(src_ty) and
            dst_ty.abiSize(zcu) == src_ty.abiSize(zcu))
        {
            // Neither side has padding, so both have the same bytes in memory.
            const src_vi = try isel.use(ty_op.operand);
            try dst_vi.value.copyField(isel, dst_ty, 0, src_vi, src_ty, 0, dst_ty.abiSize(zcu));
        } else return isel.fail("bad {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) });
    }
}

/// `sqrt` and the float roundings: an instruction for the hardware float
/// types, a compiler-rt call for the others.
fn selectFloatRounding(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const un_op = isel.air.instructions.items(.data)[@backingInt(inst)].un_op;
        const ty = isel.air.typeOf(un_op, ip);
        switch (ty.floatBits(isel.target)) {
            else => unreachable,
            16, 32, 64 => |bits| {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const need_fcvt = switch (bits) {
                    else => unreachable,
                    16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                    32, 64 => false,
                };
                if (need_fcvt) try isel.emit(.fcvt(res_ra.h(), res_ra.s()));
                const src_vi = try isel.use(un_op);
                const src_mat = try src_vi.matReg(isel);
                const src_ra = if (need_fcvt) try isel.allocVecReg() else src_mat.ra;
                defer if (need_fcvt) isel.freeReg(src_ra);
                try isel.emit(bits: switch (bits) {
                    else => unreachable,
                    16 => if (need_fcvt) continue :bits 32 else switch (air_tag) {
                        else => unreachable,
                        .sqrt => .fsqrt(res_ra.h(), src_ra.h()),
                        .floor => .frintm(res_ra.h(), src_ra.h()),
                        .ceil => .frintp(res_ra.h(), src_ra.h()),
                        .round => .frinta(res_ra.h(), src_ra.h()),
                        .trunc_float => .frintz(res_ra.h(), src_ra.h()),
                    },
                    32 => switch (air_tag) {
                        else => unreachable,
                        .sqrt => .fsqrt(res_ra.s(), src_ra.s()),
                        .floor => .frintm(res_ra.s(), src_ra.s()),
                        .ceil => .frintp(res_ra.s(), src_ra.s()),
                        .round => .frinta(res_ra.s(), src_ra.s()),
                        .trunc_float => .frintz(res_ra.s(), src_ra.s()),
                    },
                    64 => switch (air_tag) {
                        else => unreachable,
                        .sqrt => .fsqrt(res_ra.d(), src_ra.d()),
                        .floor => .frintm(res_ra.d(), src_ra.d()),
                        .ceil => .frintp(res_ra.d(), src_ra.d()),
                        .round => .frinta(res_ra.d(), src_ra.d()),
                        .trunc_float => .frintz(res_ra.d(), src_ra.d()),
                    },
                });
                if (need_fcvt) try isel.emit(.fcvt(src_ra.s(), src_mat.ra.h()));
                try src_mat.finish(isel);
            },
            80, 128 => |bits| {
                try call.compilerRt(isel, switch (air_tag) {
                    else => unreachable,
                    .sqrt => switch (bits) {
                        else => unreachable,
                        16 => "__sqrth",
                        32 => "sqrtf",
                        64 => "sqrt",
                        80 => "__sqrtx",
                        128 => "sqrtf128",
                    },
                    .floor => switch (bits) {
                        else => unreachable,
                        16 => "__floorh",
                        32 => "floorf",
                        64 => "floor",
                        80 => "__floorx",
                        128 => "floorf128",
                    },
                    .ceil => switch (bits) {
                        else => unreachable,
                        16 => "__ceilh",
                        32 => "ceilf",
                        64 => "ceil",
                        80 => "__ceilx",
                        128 => "ceilf128",
                    },
                    .round => switch (bits) {
                        else => unreachable,
                        16 => "__roundh",
                        32 => "roundf",
                        64 => "round",
                        80 => "__roundx",
                        128 => "roundf128",
                    },
                    .trunc_float => switch (bits) {
                        else => unreachable,
                        16 => "__trunch",
                        32 => "truncf",
                        64 => "trunc",
                        80 => "__truncx",
                        128 => "truncf128",
                    },
                }, res_vi.value, ty, &.{un_op});
            },
        }
    }
}

/// The float functions that are compiler-rt calls.
fn selectFloatLibCall(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| {
        defer res_vi.value.deref(isel);

        const un_op = isel.air.instructions.items(.data)[@backingInt(inst)].un_op;
        const ty = isel.air.typeOf(un_op, ip);
        const bits = ty.floatBits(isel.target);
        try call.compilerRt(isel, switch (air_tag) {
            else => unreachable,
            .sin => switch (bits) {
                else => unreachable,
                16 => "__sinh",
                32 => "sinf",
                64 => "sin",
                80 => "__sinx",
                128 => "sinf128",
            },
            .cos => switch (bits) {
                else => unreachable,
                16 => "__cosh",
                32 => "cosf",
                64 => "cos",
                80 => "__cosx",
                128 => "cosf128",
            },
            .tan => switch (bits) {
                else => unreachable,
                16 => "__tanh",
                32 => "tanf",
                64 => "tan",
                80 => "__tanx",
                128 => "tanf128",
            },
            .exp => switch (bits) {
                else => unreachable,
                16 => "__exph",
                32 => "expf",
                64 => "exp",
                80 => "__expx",
                128 => "expf128",
            },
            .exp2 => switch (bits) {
                else => unreachable,
                16 => "__exp2h",
                32 => "exp2f",
                64 => "exp2",
                80 => "__exp2x",
                128 => "exp2f128",
            },
            .log => switch (bits) {
                else => unreachable,
                16 => "__logh",
                32 => "logf",
                64 => "log",
                80 => "__logx",
                128 => "logf128",
            },
            .log2 => switch (bits) {
                else => unreachable,
                16 => "__log2h",
                32 => "log2f",
                64 => "log2",
                80 => "__log2x",
                128 => "log2f128",
            },
            .log10 => switch (bits) {
                else => unreachable,
                16 => "__log10h",
                32 => "log10f",
                64 => "log10",
                80 => "__log10x",
                128 => "log10f128",
            },
        }, res_vi.value, ty, &.{un_op});
    }
}

/// `abs` of integers of at most 128 bits and of floats.
fn selectAbs(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = zcu.gpa;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const ty_op = isel.air.instructions.items(.data)[@backingInt(inst)].ty_op;
        const ty = ty_op.ty;
        if (!ty.isRuntimeFloat()) {
            if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ air_tag, isel.fmtType(ty) });
            switch (ty.intInfo(zcu).bits) {
                0 => unreachable,
                1...32 => {
                    const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    try isel.emit(.csneg(res_ra.w(), src_mat.ra.w(), src_mat.ra.w(), .pl));
                    try isel.emit(.subs(.wzr, src_mat.ra.w(), .{ .immediate = 0 }));
                    try src_mat.finish(isel);
                },
                33...64 => {
                    const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                    const src_vi = try isel.use(ty_op.operand);
                    const src_mat = try src_vi.matReg(isel);
                    try isel.emit(.csneg(res_ra.x(), src_mat.ra.x(), src_mat.ra.x(), .pl));
                    try isel.emit(.subs(.xzr, src_mat.ra.x(), .{ .immediate = 0 }));
                    try src_mat.finish(isel);
                },
                65...128 => {
                    const res_pair: DefPair = try .init(isel, res_vi.value, ty);
                    defer res_pair.deinit(isel);
                    if (res_pair.unused()) break :unused;
                    const src_ty = isel.air.typeOf(ty_op.operand, ip);
                    const src_vi = try isel.use(ty_op.operand);
                    var src_hi64_it = src_vi.field(src_ty, 8, 8);
                    const src_hi64_vi = try src_hi64_it.only(isel);
                    const src_hi64_mat = try src_hi64_vi.?.matReg(isel);
                    var src_lo64_it = src_vi.field(src_ty, 0, 8);
                    const src_lo64_vi = try src_lo64_it.only(isel);
                    const src_lo64_mat = try src_lo64_vi.?.matReg(isel);
                    const lo64_ra = try isel.allocIntReg();
                    defer isel.freeReg(lo64_ra);
                    const hi64_ra = try isel.allocIntReg();
                    const mask_ra = try isel.allocIntReg();
                    defer {
                        isel.freeReg(hi64_ra);
                        isel.freeReg(mask_ra);
                    }
                    if (res_pair.hi) |res_ra| try isel.emit(.sbc(res_ra.x(), hi64_ra.x(), mask_ra.x()));
                    try isel.emit(.subs(
                        if (res_pair.lo) |res_ra| res_ra.x() else .xzr,
                        lo64_ra.x(),
                        .{ .register = mask_ra.x() },
                    ));
                    if (res_pair.hi) |_| try isel.emit(.eor(hi64_ra.x(), src_hi64_mat.ra.x(), .{ .register = mask_ra.x() }));
                    try isel.emit(.eor(lo64_ra.x(), src_lo64_mat.ra.x(), .{ .register = mask_ra.x() }));
                    try isel.emit(.sbfm(mask_ra.x(), src_hi64_mat.ra.x(), .{
                        .N = .doubleword,
                        .immr = 64 - 1,
                        .imms = 64 - 1,
                    }));
                    try src_lo64_mat.finish(isel);
                    try src_hi64_mat.finish(isel);
                },
                else => if (isel.air.typeOf(ty_op.operand, ip).isSignedInt(zcu))
                    return isel.fail("too big {t} {f}", .{ air_tag, isel.fmtType(ty) })
                else
                    try res_vi.value.move(isel, ty_op.operand),
            }
        } else switch (ty.floatBits(isel.target)) {
            else => unreachable,
            16 => {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = try src_vi.matReg(isel);
                if (isel.target.cpu.has(.aarch64, .fullfp16))
                    try isel.emit(.fabs(res_ra.h(), src_mat.ra.h()))
                else {
                    // Clears the sign bit in place: copy the operand first.
                    try isel.emit(.bic(res_ra.@"4h"(), res_ra.@"4h"(), .{ .shifted_immediate = .{
                        .immediate = 0b10000000,
                        .lsl = 8,
                    } }));
                    if (res_ra != src_mat.ra)
                        try isel.emit(.orr(res_ra.@"8b"(), src_mat.ra.@"8b"(), .{ .register = src_mat.ra.@"8b"() }));
                }
                try src_mat.finish(isel);
            },
            32 => {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = try src_vi.matReg(isel);
                try isel.emit(.fabs(res_ra.s(), src_mat.ra.s()));
                try src_mat.finish(isel);
            },
            64 => {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = try src_vi.matReg(isel);
                try isel.emit(.fabs(res_ra.d(), src_mat.ra.d()));
                try src_mat.finish(isel);
            },
            80 => {
                const src_vi = try isel.use(ty_op.operand);
                var res_hi16_it = res_vi.value.field(ty, 8, 8);
                const res_hi16_vi = try res_hi16_it.only(isel);
                if (try res_hi16_vi.?.defReg(isel)) |res_hi16_ra| {
                    var src_hi16_it = src_vi.field(ty, 8, 8);
                    const src_hi16_vi = try src_hi16_it.only(isel);
                    const src_hi16_mat = try src_hi16_vi.?.matReg(isel);
                    try isel.emit(.@"and"(res_hi16_ra.w(), src_hi16_mat.ra.w(), .{ .immediate = .{
                        .N = .word,
                        .immr = 0,
                        .imms = 15 - 1,
                    } }));
                    try src_hi16_mat.finish(isel);
                }
                var res_lo64_it = res_vi.value.field(ty, 0, 8);
                const res_lo64_vi = try res_lo64_it.only(isel);
                if (try res_lo64_vi.?.defReg(isel)) |res_lo64_ra| {
                    var src_lo64_it = src_vi.field(ty, 0, 8);
                    const src_lo64_vi = try src_lo64_it.only(isel);
                    try src_lo64_vi.?.liveOut(isel, res_lo64_ra);
                }
            },
            128 => {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = try src_vi.matReg(isel);
                const neg_zero_ra = try isel.allocVecReg();
                defer isel.freeReg(neg_zero_ra);
                try isel.emit(.bic(res_ra.@"16b"(), src_mat.ra.@"16b"(), .{ .register = neg_zero_ra.@"16b"() }));
                try isel.literals.appendNTimes(gpa, 0, -%isel.literals.items.len % 4);
                try isel.literal_relocs.append(gpa, .{
                    .label = @intCast(isel.instructions.items.len),
                });
                try isel.emit(.ldr(neg_zero_ra.q(), .{
                    .literal = @intCast((isel.instructions.items.len + 1 + isel.literals.items.len) << 2),
                }));
                try isel.emitLiteral(&(@as([15]u8, @splat(0)) ++ .{0x80}));
                try src_mat.finish(isel);
            },
        }
    }
}

/// `int_cast_safe`: an `int_cast` that panics when the value does not fit.
fn selectIntCastSafe(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (try isel.checkedDef(inst)) |dst_vi| unused: {
        defer dst_vi.deref(isel);

        const ty_op = isel.air.instructions.items(.data)[@backingInt(inst)].ty_op;
        const dst_ty = ty_op.ty;
        if (dst_ty.isVector(zcu)) return isel.fail(
            "unsupported checked vector integer cast {f} to {f}",
            .{ isel.fmtType(isel.air.typeOf(ty_op.operand, ip)), isel.fmtType(dst_ty) },
        );
        const dst_int_info = dst_ty.intInfo(zcu);
        const src_ty = isel.air.typeOf(ty_op.operand, ip);
        const src_int_info = src_ty.intInfo(zcu);
        const can_be_negative = dst_int_info.signedness == .signed and
            src_int_info.signedness == .signed;
        const panic_id: Zcu.SimplePanicId = panic_id: switch (dst_ty.zigTypeTag(zcu)) {
            else => unreachable,
            .int => .integer_out_of_bounds,
            .@"enum" => {
                if (dst_ty.isNonexhaustiveEnum(zcu)) break :panic_id .invalid_enum_value;
                if (dst_int_info.bits > 64 or src_int_info.bits > 64)
                    return isel.fail("bad {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) });
                // The integer must equal a named value; the named values
                // all fit the tag type, so this is also the range check.
                const dst_ra = try dst_vi.defReg(isel) orelse break :unused;
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = src_mat: {
                    const dst_lock = isel.lockReg(dst_ra);
                    defer dst_lock.unlock(isel);
                    break :src_mat try src_vi.matReg(isel);
                };
                try isel.emit(if (dst_int_info.bits > 32 and src_int_info.bits <= 32 and
                    src_int_info.signedness == .signed)
                    .sbfm(dst_ra.x(), src_mat.ra.x(), .{
                        .N = .doubleword,
                        .immr = 0,
                        .imms = @intCast(src_int_info.bits - 1),
                    })
                else switch (@min(dst_int_info.bits, src_int_info.bits)) {
                    else => unreachable,
                    0...32 => .orr(dst_ra.w(), .wzr, .{ .register = src_mat.ra.w() }),
                    33...64 => .orr(dst_ra.x(), .xzr, .{ .register = src_mat.ra.x() }),
                });
                const named_ra = try isel.allocIntReg();
                defer isel.freeReg(named_ra);
                const skip_label = isel.instructions.items.len;
                try isel.emitPanic(.invalid_enum_value);
                try isel.emit(.cbnz(
                    named_ra.w(),
                    @intCast((isel.instructions.items.len + 1 - skip_label) << 2),
                ));
                try isel.isNamedEnumValue(named_ra, dst_ty, switch (src_int_info.bits) {
                    else => unreachable,
                    0...32 => src_mat.ra.w(),
                    33...64 => src_mat.ra.x(),
                }, src_int_info);
                try src_mat.finish(isel);
                break :unused;
            },
        };
        if (dst_int_info.bits == src_int_info.bits and dst_int_info.signedness == src_int_info.signedness) {
            try dst_vi.move(isel, ty_op.operand);
        } else if (dst_int_info.bits <= 64 and src_int_info.bits <= 64) {
            const dst_ra = try dst_vi.defReg(isel) orelse break :unused;
            const src_vi = try isel.use(ty_op.operand);
            const dst_active_bits = dst_int_info.bits - @intFromBool(dst_int_info.signedness == .signed);
            const src_active_bits = src_int_info.bits - @intFromBool(src_int_info.signedness == .signed);
            if ((dst_int_info.signedness != .unsigned or src_int_info.signedness != .signed) and dst_active_bits >= src_active_bits) {
                const src_mat = try src_vi.matReg(isel);
                if (dst_int_info.bits <= 32 and src_int_info.bits <= 32)
                    try isel.moveInt32(dst_ra, src_mat.ra)
                else
                    try isel.emit(if (can_be_negative and dst_active_bits > 32 and src_active_bits <= 32)
                        .sbfm(dst_ra.x(), src_mat.ra.x(), .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = @intCast(src_int_info.bits - 1),
                        })
                    else switch (src_int_info.bits) {
                        else => unreachable,
                        1...32 => .orr(dst_ra.w(), .wzr, .{ .register = src_mat.ra.w() }),
                        33...64 => .orr(dst_ra.x(), .xzr, .{ .register = src_mat.ra.x() }),
                    });
                try src_mat.finish(isel);
            } else {
                const skip_label = isel.instructions.items.len;
                try isel.emitPanic(panic_id);
                try isel.emit(.@"b."(
                    .eq,
                    @intCast((isel.instructions.items.len + 1 - skip_label) << 2),
                ));
                if (can_be_negative) {
                    const src_mat = src_mat: {
                        const dst_lock = isel.lockReg(dst_ra);
                        defer dst_lock.unlock(isel);
                        break :src_mat try src_vi.matReg(isel);
                    };
                    try isel.emit(switch (src_int_info.bits) {
                        else => unreachable,
                        1...32 => .subs(.wzr, dst_ra.w(), .{ .register = src_mat.ra.w() }),
                        33...64 => .subs(.xzr, dst_ra.x(), .{ .register = src_mat.ra.x() }),
                    });
                    try isel.emit(switch (@max(dst_int_info.bits, src_int_info.bits)) {
                        else => unreachable,
                        1...32 => .sbfm(dst_ra.w(), src_mat.ra.w(), .{
                            .N = .word,
                            .immr = 0,
                            .imms = @intCast(dst_int_info.bits - 1),
                        }),
                        33...64 => .sbfm(dst_ra.x(), src_mat.ra.x(), .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = @intCast(dst_int_info.bits - 1),
                        }),
                    });
                    try src_mat.finish(isel);
                } else {
                    const src_mat = try src_vi.matReg(isel);
                    if (dst_int_info.bits <= 32)
                        try isel.moveInt32(dst_ra, src_mat.ra)
                    else
                        try isel.emit(switch (@min(dst_int_info.bits, src_int_info.bits)) {
                            else => unreachable,
                            1...32 => .orr(dst_ra.w(), .wzr, .{ .register = src_mat.ra.w() }),
                            33...64 => .orr(dst_ra.x(), .xzr, .{ .register = src_mat.ra.x() }),
                        });
                    const active_bits = @min(dst_active_bits, src_active_bits);
                    // With no value bits in common (`i1` on either side),
                    // only zero converts, and the mask below would be all ones.
                    try isel.emit(if (active_bits == 0) switch (src_int_info.bits) {
                        else => unreachable,
                        1...32 => .subs(.wzr, src_mat.ra.w(), .{ .immediate = 0 }),
                        33...64 => .subs(.xzr, src_mat.ra.x(), .{ .immediate = 0 }),
                    } else switch (src_int_info.bits) {
                        else => unreachable,
                        1...32 => .ands(.wzr, src_mat.ra.w(), .{ .immediate = .{
                            .N = .word,
                            .immr = @intCast(32 - active_bits),
                            .imms = @intCast(32 - active_bits - 1),
                        } }),
                        33...64 => .ands(.xzr, src_mat.ra.x(), .{ .immediate = .{
                            .N = .doubleword,
                            .immr = @intCast(64 - active_bits),
                            .imms = @intCast(64 - active_bits - 1),
                        } }),
                    });
                    try src_mat.finish(isel);
                }
            }
        } else if (dst_int_info.bits > 0 and dst_int_info.bits <= 128 and src_int_info.bits > 0 and src_int_info.bits <= 128) {
            try isel.castIntSafeWide(dst_vi, dst_ty, src_ty, ty_op.operand, panic_id);
        } else try isel.castIntWide(dst_vi, dst_ty, src_ty, ty_op.operand, panic_id);
    }
}

/// `int_from_float`.
fn selectIntFromFloat(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |dst_vi| unused: {
        defer dst_vi.value.deref(isel);

        const ty_op = isel.air.instructions.items(.data)[@backingInt(inst)].ty_op;
        const dst_ty = ty_op.ty;
        const src_ty = isel.air.typeOf(ty_op.operand, ip);
        if (!dst_ty.isAbiInt(zcu)) return isel.fail("bad {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) });
        const dst_int_info = dst_ty.intInfo(zcu);
        const src_bits = src_ty.floatBits(isel.target);
        if (dst_int_info.bits > 128) {
            try isel.intFromFloatWide(dst_vi.value, dst_ty, src_ty, ty_op.operand);
            break :unused;
        }
        switch (@max(dst_int_info.bits, src_bits)) {
            0 => unreachable,
            1...64 => {
                const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                const need_fcvt = switch (src_bits) {
                    else => unreachable,
                    16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                    32, 64 => false,
                };
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = try src_vi.matReg(isel);
                const src_ra = if (need_fcvt) try isel.allocVecReg() else src_mat.ra;
                defer if (need_fcvt) isel.freeReg(src_ra);
                const dst_reg = switch (dst_int_info.bits) {
                    else => unreachable,
                    1...32 => dst_ra.w(),
                    33...64 => dst_ra.x(),
                };
                const src_reg = switch (src_bits) {
                    else => unreachable,
                    16 => if (need_fcvt) src_ra.s() else src_ra.h(),
                    32 => src_ra.s(),
                    64 => src_ra.d(),
                };
                try isel.emit(switch (dst_int_info.signedness) {
                    .signed => .fcvtzs(dst_reg, src_reg),
                    .unsigned => .fcvtzu(dst_reg, src_reg),
                });
                if (need_fcvt) try isel.emit(.fcvt(src_reg, src_mat.ra.h()));
                try src_mat.finish(isel);
            },
            65...128 => {
                try call.compilerRt(isel, switch (dst_int_info.bits) {
                    else => unreachable,
                    1...32 => switch (dst_int_info.signedness) {
                        .signed => switch (src_bits) {
                            else => unreachable,
                            16 => "__fixhfsi",
                            32 => "__fixsfsi",
                            64 => "__fixdfsi",
                            80 => "__fixxfsi",
                            128 => "__fixtfsi",
                        },
                        .unsigned => switch (src_bits) {
                            else => unreachable,
                            16 => "__fixunshfsi",
                            32 => "__fixunssfsi",
                            64 => "__fixunsdfsi",
                            80 => "__fixunsxfsi",
                            128 => "__fixunstfsi",
                        },
                    },
                    33...64 => switch (dst_int_info.signedness) {
                        .signed => switch (src_bits) {
                            else => unreachable,
                            16 => "__fixhfdi",
                            32 => "__fixsfdi",
                            64 => "__fixdfdi",
                            80 => "__fixxfdi",
                            128 => "__fixtfdi",
                        },
                        .unsigned => switch (src_bits) {
                            else => unreachable,
                            16 => "__fixunshfdi",
                            32 => "__fixunssfdi",
                            64 => "__fixunsdfdi",
                            80 => "__fixunsxfdi",
                            128 => "__fixunstfdi",
                        },
                    },
                    65...128 => switch (dst_int_info.signedness) {
                        .signed => switch (src_bits) {
                            else => unreachable,
                            16 => "__fixhfti",
                            32 => "__fixsfti",
                            64 => "__fixdfti",
                            80 => "__fixxfti",
                            128 => "__fixtfti",
                        },
                        .unsigned => switch (src_bits) {
                            else => unreachable,
                            16 => "__fixunshfti",
                            32 => "__fixunssfti",
                            64 => "__fixunsdfti",
                            80 => "__fixunsxfti",
                            128 => "__fixunstfti",
                        },
                    },
                }, dst_vi.value, dst_ty, &.{ty_op.operand});
            },
            else => return isel.fail("too big {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) }),
        }
    }
}

/// `float_from_int`.
fn selectFloatFromInt(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |dst_vi| unused: {
        defer dst_vi.value.deref(isel);

        const ty_op = isel.air.instructions.items(.data)[@backingInt(inst)].ty_op;
        const dst_ty = ty_op.ty;
        const src_ty = isel.air.typeOf(ty_op.operand, ip);
        const dst_bits = dst_ty.floatBits(isel.target);
        if (!src_ty.isAbiInt(zcu)) return isel.fail("bad {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) });
        const src_int_info = src_ty.intInfo(zcu);
        if (src_int_info.bits > 128) {
            try isel.floatFromIntWide(dst_vi.value, dst_ty, src_ty, ty_op.operand);
            break :unused;
        }
        switch (@max(dst_bits, src_int_info.bits)) {
            0 => unreachable,
            1...64 => {
                const dst_ra = try dst_vi.value.defReg(isel) orelse break :unused;
                const dst_lock = isel.tryLockReg(dst_ra);
                defer dst_lock.unlock(isel);
                const float_ra = if (dst_ra.isVector()) dst_ra else try isel.allocVecReg();
                defer if (float_ra != dst_ra) isel.freeReg(float_ra);
                if (float_ra != dst_ra) try isel.emit(switch (dst_bits) {
                    else => unreachable,
                    16 => .umov(dst_ra.w(), float_ra.@"h[]"(0)),
                    32 => .fmov(dst_ra.w(), .{ .register = float_ra.s() }),
                    64 => .fmov(dst_ra.x(), .{ .register = float_ra.d() }),
                });
                const need_fcvt = switch (dst_bits) {
                    else => unreachable,
                    16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                    32, 64 => false,
                };
                if (need_fcvt) try isel.emit(.fcvt(float_ra.h(), float_ra.s()));
                const src_vi = try isel.use(ty_op.operand);
                const src_mat = try src_vi.matReg(isel);
                const dst_reg = switch (dst_bits) {
                    else => unreachable,
                    16 => if (need_fcvt) float_ra.s() else float_ra.h(),
                    32 => float_ra.s(),
                    64 => float_ra.d(),
                };
                const src_reg = switch (src_int_info.bits) {
                    else => unreachable,
                    1...32 => src_mat.ra.w(),
                    33...64 => src_mat.ra.x(),
                };
                try isel.emit(switch (src_int_info.signedness) {
                    .signed => .scvtf(dst_reg, src_reg),
                    .unsigned => .ucvtf(dst_reg, src_reg),
                });
                try src_mat.finish(isel);
            },
            65...128 => {
                try call.compilerRt(isel, switch (src_int_info.bits) {
                    else => unreachable,
                    1...32 => switch (src_int_info.signedness) {
                        .signed => switch (dst_bits) {
                            else => unreachable,
                            16 => "__floatsihf",
                            32 => "__floatsisf",
                            64 => "__floatsidf",
                            80 => "__floatsixf",
                            128 => "__floatsitf",
                        },
                        .unsigned => switch (dst_bits) {
                            else => unreachable,
                            16 => "__floatunsihf",
                            32 => "__floatunsisf",
                            64 => "__floatunsidf",
                            80 => "__floatunsixf",
                            128 => "__floatunsitf",
                        },
                    },
                    33...64 => switch (src_int_info.signedness) {
                        .signed => switch (dst_bits) {
                            else => unreachable,
                            16 => "__floatdihf",
                            32 => "__floatdisf",
                            64 => "__floatdidf",
                            80 => "__floatdixf",
                            128 => "__floatditf",
                        },
                        .unsigned => switch (dst_bits) {
                            else => unreachable,
                            16 => "__floatundihf",
                            32 => "__floatundisf",
                            64 => "__floatundidf",
                            80 => "__floatundixf",
                            128 => "__floatunditf",
                        },
                    },
                    65...128 => switch (src_int_info.signedness) {
                        .signed => switch (dst_bits) {
                            else => unreachable,
                            16 => "__floattihf",
                            32 => "__floattisf",
                            64 => "__floattidf",
                            80 => "__floattixf",
                            128 => "__floattitf",
                        },
                        .unsigned => switch (dst_bits) {
                            else => unreachable,
                            16 => "__floatuntihf",
                            32 => "__floatuntisf",
                            64 => "__floatuntidf",
                            80 => "__floatuntixf",
                            128 => "__floatuntitf",
                        },
                    },
                }, dst_vi.value, dst_ty, &.{ty_op.operand});
            },
            else => return isel.fail("too big {t} {f} {f}", .{ air_tag, isel.fmtType(dst_ty), isel.fmtType(src_ty) }),
        }
    }
}

/// `memset` and `memset_safe`.
fn selectMemset(isel: *Select, inst: Air.Inst.Index, air_tag: Air.Inst.Tag) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = zcu.gpa;
    const bin_op = isel.air.instructions.items(.data)[@backingInt(inst)].bin_op;
    const dst_ty = isel.air.typeOf(bin_op.lhs, ip);
    const dst_info = dst_ty.ptrInfo(zcu);
    const fill_byte: union(enum) { constant: u8, value: Air.Inst.Ref } = fill_byte: {
        if (bin_op.rhs.toInterned()) |fill_val| {
            if (ip.isUndef(fill_val)) switch (air_tag) {
                else => unreachable,
                .memset => return,
                .memset_safe => break :fill_byte .{ .constant = 0xaa },
            };
            if (try isel.hasRepeatedByteRepr(.fromInterned(fill_val))) |fill_byte|
                break :fill_byte .{ .constant = fill_byte };
        }
        switch (dst_ty.indexableElem(zcu).abiSize(zcu)) {
            0 => unreachable,
            1 => break :fill_byte .{ .value = bin_op.rhs },
            else => |size| {
                const dst_vi = try isel.use(bin_op.lhs);
                const ptr_ra = try isel.allocIntReg();
                const fill_vi = try isel.use(bin_op.rhs);
                const fill_mat: ?Value.Materialize = switch (size) {
                    2, 4, 8 => try fill_vi.matReg(isel),
                    else => null,
                };
                const stride_ra = if (fill_mat == null) try isel.allocIntReg() else .zr;
                const len_mat: Value.Materialize = len_mat: switch (dst_info.flags.size) {
                    .one => .{ .vi = undefined, .ra = try isel.allocIntReg() },
                    .many => unreachable,
                    .slice => {
                        var dst_len_it = dst_vi.field(dst_ty, 8, 8);
                        const dst_len_vi = try dst_len_it.only(isel);
                        break :len_mat try dst_len_vi.?.matReg(isel);
                    },
                    .c => unreachable,
                };

                const count_ra = if (dst_info.flags.size == .slice)
                    try isel.allocIntReg()
                else
                    len_mat.ra;

                const skip_label = isel.instructions.items.len;
                _ = try isel.instructions.addOne(gpa);
                try isel.emit(.sub(count_ra.x(), count_ra.x(), .{ .immediate = 1 }));
                if (fill_mat) |mat| {
                    try isel.emit(switch (size) {
                        else => unreachable,
                        2 => if (mat.ra.isVector())
                            .str(mat.ra.h(), .{ .post_index = .{ .base = ptr_ra.x(), .index = 2 } })
                        else
                            .strh(mat.ra.w(), .{ .post_index = .{ .base = ptr_ra.x(), .index = 2 } }),
                        4 => .str(
                            if (mat.ra.isVector()) mat.ra.s() else mat.ra.w(),
                            .{ .post_index = .{ .base = ptr_ra.x(), .index = 4 } },
                        ),
                        8 => .str(
                            if (mat.ra.isVector()) mat.ra.d() else mat.ra.x(),
                            .{ .post_index = .{ .base = ptr_ra.x(), .index = 8 } },
                        ),
                    });
                } else {
                    try isel.emit(.add(ptr_ra.x(), ptr_ra.x(), .{ .register = stride_ra.x() }));
                    try fill_vi.store(isel, dst_ty.indexableElem(zcu), ptr_ra, .{});
                }
                isel.instructions.items[skip_label] = .cbnz(
                    count_ra.x(),
                    std.math.cast(i21, -@as(i64, @intCast(isel.instructions.items.len - 1 - skip_label)) * 4) orelse
                        return isel.fail("memset fill loop too large", .{}),
                );
                if (fill_mat == null) {
                    try isel.movImmediate(stride_ra.x(), size);
                    isel.freeReg(stride_ra);
                }
                switch (dst_info.flags.size) {
                    .one => {
                        const len_imm = ZigType.fromInterned(dst_info.child).arrayLen(zcu);
                        assert(len_imm > 0);
                        try isel.movImmediate(len_mat.ra.x(), len_imm);
                        isel.freeReg(len_mat.ra);
                        if (fill_mat) |mat| try mat.finish(isel);
                        isel.freeReg(ptr_ra);
                        try dst_vi.liveOut(isel, ptr_ra);
                    },
                    .many => unreachable,
                    .slice => {
                        try isel.emit(.cbz(
                            count_ra.x(),
                            std.math.cast(i21, (isel.instructions.items.len + 1 - skip_label) * 4) orelse
                                return isel.fail("memset fill loop too large", .{}),
                        ));
                        // The slice length can remain live after this loop.
                        try isel.emit(.orr(count_ra.x(), .xzr, .{ .register = len_mat.ra.x() }));
                        isel.freeReg(count_ra);
                        try len_mat.finish(isel);
                        if (fill_mat) |mat| try mat.finish(isel);
                        isel.freeReg(ptr_ra);
                        var dst_ptr_it = dst_vi.field(dst_ty, 0, 8);
                        const dst_ptr_vi = try dst_ptr_it.only(isel);
                        try dst_ptr_vi.?.liveOut(isel, ptr_ra);
                    },
                    .c => unreachable,
                }

                return;
            },
        }
    };

    try call.prepareVoidGlobal(isel, "memset");
    const dst_vi = try isel.use(bin_op.lhs);
    switch (dst_info.flags.size) {
        .one => {
            try isel.movImmediate(.x2, ZigType.fromInterned(dst_info.child).abiSize(zcu));
            switch (fill_byte) {
                .constant => |byte| try isel.movImmediate(.w1, byte),
                .value => |byte| try call.paramLiveOut(isel, try isel.use(byte), .r1),
            }
            try call.paramLiveOut(isel, dst_vi, .r0);
        },
        .many => unreachable,
        .slice => {
            var dst_ptr_it = dst_vi.field(dst_ty, 0, 8);
            const dst_ptr_vi = try dst_ptr_it.only(isel);
            var dst_len_it = dst_vi.field(dst_ty, 8, 8);
            const dst_len_vi = try dst_len_it.only(isel);
            try isel.elemPtr(.r2, .zr, .add, ZigType.fromInterned(dst_info.child).abiSize(zcu), dst_len_vi.?);
            switch (fill_byte) {
                .constant => |byte| try isel.movImmediate(.w1, byte),
                .value => |byte| try call.paramLiveOut(isel, try isel.use(byte), .r1),
            }
            try call.paramLiveOut(isel, dst_ptr_vi.?, .r0);
        },
        .c => unreachable,
    }
    try call.finishParams(isel);
}

/// `aggregate_init` of structs, tuples, arrays and vectors.
fn selectAggregateInit(isel: *Select, inst: Air.Inst.Index) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |agg_vi| {
        defer agg_vi.value.deref(isel);

        const ty_pl = isel.air.instructions.items(.data)[@backingInt(inst)].ty_pl;
        const agg_ty = ty_pl.ty;
        switch (ip.indexToKey(agg_ty.toIntern())) {
            .vector_type => |vector_type| vector_init: {
                const elem_ty: ZigType = .fromInterned(vector_type.child);
                if (elem_ty.bitSize(zcu) == 0) break :vector_init;
                try agg_vi.value.defAddr(isel, agg_ty, .{}) orelse break :vector_init;
                const ptr_ra = try isel.allocIntReg();
                defer if (isel.live_registers.get(ptr_ra) == .allocating) isel.freeReg(ptr_ra);
                const elems: []const Air.Inst.Ref =
                    @ptrCast(isel.air.extra.items[ty_pl.payload..][0..vector_type.len]);
                for (elems, 0..) |elem, index| {
                    try isel.vectorMemoryOffset(try isel.use(elem), elem_ty, ptr_ra, index, false, true);
                }
                isel.freeReg(ptr_ra);
                try agg_vi.value.address(isel, 0, ptr_ra);
            },
            .array_type => |array_type| {
                const elems: []const Air.Inst.Ref =
                    @ptrCast(isel.air.extra.items[ty_pl.payload..][0..@intCast(array_type.len)]);
                var elem_offset: u64 = 0;
                const elem_size = ZigType.fromInterned(array_type.child).abiSize(zcu);
                for (elems) |elem| {
                    var agg_part_it = agg_vi.value.field(agg_ty, elem_offset, elem_size);
                    const agg_part_vi = try agg_part_it.only(isel);
                    try agg_part_vi.?.move(isel, elem);
                    elem_offset += elem_size;
                }
                switch (array_type.sentinel) {
                    .none => {},
                    else => |sentinel| {
                        var agg_part_it = agg_vi.value.field(agg_ty, elem_offset, elem_size);
                        const agg_part_vi = try agg_part_it.only(isel);
                        try agg_part_vi.?.move(isel, .fromIntern(sentinel));
                    },
                }
            },
            .struct_type => {
                const loaded_struct = ip.loadStructType(agg_ty.toIntern());
                const elems: []const Air.Inst.Ref =
                    @ptrCast(isel.air.extra.items[ty_pl.payload..][0..loaded_struct.field_types.len]);
                if (loaded_struct.layout == .@"packed") packed_init: {
                    const agg_bits = agg_ty.bitSize(zcu);
                    if (agg_bits > 128) return isel.fail("too big packed aggregate init {f}", .{isel.fmtType(agg_ty)});
                    if (agg_vi.value.size(isel) > 8) {
                        var low_it = agg_vi.value.field(agg_ty, 0, 8);
                        _ = try low_it.only(isel);
                    }
                    try agg_vi.value.defAddr(isel, agg_ty, .{ .wrap = agg_ty.intInfo(zcu) }) orelse break :packed_init;
                    const ptr_ra = try isel.allocIntReg();
                    defer isel.freeReg(ptr_ra);
                    var bit_offset: u16 = 0;
                    for (loaded_struct.field_types.get(ip), elems, 0..) |field_ty_index, elem, field_index| {
                        if (loaded_struct.field_is_comptime_bits.get(ip, field_index)) continue;
                        const field_ty: ZigType = .fromInterned(field_ty_index);
                        const field_bits = field_ty.bitSize(zcu);
                        if (field_bits == 0) continue;
                        try isel.packedMemory(try isel.use(elem), field_ty, ptr_ra, bit_offset, true);
                        bit_offset += @intCast(field_bits);
                    }
                    assert(bit_offset == agg_bits);
                    try agg_vi.value.address(isel, 0, ptr_ra);
                } else {
                    var field_offset: u64 = 0;
                    var field_it = loaded_struct.iterateRuntimeOrder(ip);
                    while (field_it.next()) |field_index| {
                        const field_ty: ZigType = .fromInterned(loaded_struct.field_types.get(ip)[field_index]);
                        field_offset = loaded_struct.field_offsets.get(ip)[field_index];
                        const field_size = field_ty.abiSize(zcu);
                        if (field_size == 0) continue;
                        const field_vi = try isel.use(elems[field_index]);
                        var agg_part_it = agg_vi.value.field(agg_ty, field_offset, field_size);
                        while (try agg_part_it.next(isel)) |agg_part| {
                            var field_part_it = field_vi.field(field_ty, agg_part.offset, agg_part.vi.size(isel));
                            const field_part_vi = try field_part_it.only(isel);
                            // The field's own parts may straddle this part.
                            if (field_part_vi) |part_vi| try agg_part.vi.copy(isel, field_ty, part_vi) else try agg_vi.value.copyField(
                                isel,
                                agg_ty,
                                field_offset + agg_part.offset,
                                field_vi,
                                field_ty,
                                agg_part.offset,
                                agg_part.vi.size(isel),
                            );
                        }
                        field_offset += field_size;
                    }
                    assert(loaded_struct.alignment.forward(field_offset) == agg_vi.value.size(isel));
                }
            },
            .tuple_type => |tuple_type| {
                const elems: []const Air.Inst.Ref =
                    @ptrCast(isel.air.extra.items[ty_pl.payload..][0..tuple_type.types.len]);
                var tuple_align: InternPool.Alignment = .@"1";
                var field_offset: u64 = 0;
                for (
                    tuple_type.types.get(ip),
                    tuple_type.values.get(ip),
                    elems,
                ) |field_ty_index, field_val, elem| {
                    if (field_val != .none) continue;
                    const field_ty: ZigType = .fromInterned(field_ty_index);
                    const field_align = field_ty.abiAlignment(zcu);
                    tuple_align = tuple_align.maxStrict(field_align);
                    field_offset = field_align.forward(field_offset);
                    const field_size = field_ty.abiSize(zcu);
                    if (field_size == 0) continue;
                    const field_vi = try isel.use(elem);
                    var agg_part_it = agg_vi.value.field(agg_ty, field_offset, field_size);
                    while (try agg_part_it.next(isel)) |agg_part| {
                        var field_part_it = field_vi.field(field_ty, agg_part.offset, agg_part.vi.size(isel));
                        const field_part_vi = try field_part_it.only(isel);
                        // The field's own parts may straddle this part.
                        if (field_part_vi) |part_vi| try agg_part.vi.copy(isel, field_ty, part_vi) else try agg_vi.value.copyField(
                            isel,
                            agg_ty,
                            field_offset + agg_part.offset,
                            field_vi,
                            field_ty,
                            agg_part.offset,
                            agg_part.vi.size(isel),
                        );
                    }
                    field_offset += field_size;
                }
                assert(tuple_align.forward(field_offset) == agg_vi.value.size(isel));
            },
            else => return isel.fail("aggregate init {f}", .{isel.fmtType(agg_ty)}),
        }
    }
}

/// `mul_add`: a fused multiply-add for the hardware float types, `fma` from
/// compiler-rt for the others.
fn selectMulAdd(isel: *Select, inst: Air.Inst.Index) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.fetchRemove(inst)) |res_vi| unused: {
        defer res_vi.value.deref(isel);

        const pl_op = isel.air.instructions.items(.data)[@backingInt(inst)].pl_op;
        const bin_op = isel.air.extraData(Air.Bin, pl_op.payload).data;
        const ty = isel.air.typeOf(pl_op.operand, ip);
        switch (ty.floatBits(isel.target)) {
            else => unreachable,
            16, 32, 64 => |bits| {
                const res_ra = try res_vi.value.defReg(isel) orelse break :unused;
                const need_fcvt = switch (bits) {
                    else => unreachable,
                    16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                    32, 64 => false,
                };
                if (need_fcvt) try isel.emit(.fcvt(res_ra.h(), res_ra.s()));
                const lhs_vi = try isel.use(bin_op.lhs);
                const rhs_vi = try isel.use(bin_op.rhs);
                const addend_vi = try isel.use(pl_op.operand);
                const lhs_mat = try lhs_vi.matReg(isel);
                const rhs_mat = try rhs_vi.matReg(isel);
                const addend_mat = try addend_vi.matReg(isel);
                const lhs_ra = if (need_fcvt) try isel.allocVecReg() else lhs_mat.ra;
                defer if (need_fcvt) isel.freeReg(lhs_ra);
                const rhs_ra = if (need_fcvt) try isel.allocVecReg() else rhs_mat.ra;
                defer if (need_fcvt) isel.freeReg(rhs_ra);
                const addend_ra = if (need_fcvt) try isel.allocVecReg() else addend_mat.ra;
                defer if (need_fcvt) isel.freeReg(addend_ra);
                try isel.emit(bits: switch (bits) {
                    else => unreachable,
                    16 => if (need_fcvt)
                        continue :bits 32
                    else
                        .fmadd(res_ra.h(), lhs_ra.h(), rhs_ra.h(), addend_ra.h()),
                    32 => .fmadd(res_ra.s(), lhs_ra.s(), rhs_ra.s(), addend_ra.s()),
                    64 => .fmadd(res_ra.d(), lhs_ra.d(), rhs_ra.d(), addend_ra.d()),
                });
                if (need_fcvt) {
                    try isel.emit(.fcvt(addend_ra.s(), addend_mat.ra.h()));
                    try isel.emit(.fcvt(rhs_ra.s(), rhs_mat.ra.h()));
                    try isel.emit(.fcvt(lhs_ra.s(), lhs_mat.ra.h()));
                }
                try addend_mat.finish(isel);
                try rhs_mat.finish(isel);
                try lhs_mat.finish(isel);
            },
            80, 128 => |bits| {
                try call.compilerRt(isel, switch (bits) {
                    else => unreachable,
                    16 => "__fmah",
                    32 => "fmaf",
                    64 => "fma",
                    80 => "__fmax",
                    128 => "fmaf128",
                }, res_vi.value, ty, &.{ bin_op.lhs, bin_op.rhs, pl_op.operand });
            },
        }
    }
}

/// `c_va_arg`, from the platform's `va_list`.
fn selectVaArg(isel: *Select, inst: Air.Inst.Index) !void {
    const zcu = isel.pt.zcu;
    const maybe_arg_vi = isel.live_values.fetchRemove(inst);
    defer if (maybe_arg_vi) |arg_vi| arg_vi.value.deref(isel);
    const ty_op = isel.air.instructions.items(.data)[@backingInt(inst)].ty_op;
    const ty = ty_op.ty;
    const promote_float = ty.toIntern() == .f32_type;
    const passed_ty: ZigType = if (promote_float) .f64 else ty;
    var param_it: CallAbiIterator = .init;
    const param_vi = try param_it.param(isel, passed_ty);
    defer param_vi.?.deref(isel);
    const passed_vi = switch (param_vi.?.parent(isel)) {
        .unallocated => param_vi.?,
        .stack_slot, .value, .constant, .stack_address => unreachable,
        .address => |address_vi| address_vi,
    };
    const passed_size: u5 = @intCast(passed_vi.alignment(isel).forward(passed_vi.size(isel)));
    const passed_is_vector = passed_vi.isVector(isel);
    const register_size: u5 = if (passed_is_vector) 16 else passed_size;

    const va_list_ptr_vi = try isel.use(ty_op.operand);
    const va_list_ptr_mat = try va_list_ptr_vi.matReg(isel);
    const offs_ra = try isel.allocIntReg();
    defer isel.freeReg(offs_ra);
    const stack_ra = try isel.allocIntReg();
    defer isel.freeReg(stack_ra);

    var promoted_ra: ?Register.Alias = null;
    defer if (promoted_ra) |ra| isel.freeReg(ra);
    var result_lock: RegLock = .empty;
    defer result_lock.unlock(isel);
    var part_vis: [2]Value.Index = undefined;
    var arg_part_ras: [2]?Register.Alias = @splat(null);
    const parts_len = parts_len: {
        var parts_len: u2 = 0;
        var part_it = passed_vi.parts(isel);
        while (part_it.next()) |part_vi| : (parts_len += 1) {
            part_vis[parts_len] = part_vi;
            const arg_vi = maybe_arg_vi orelse continue;
            const part_offset, const part_size = part_vi.position(isel);
            var arg_part_it = arg_vi.value.field(ty, part_offset, if (promote_float) ty.abiSize(zcu) else part_size);
            const arg_part_vi = try arg_part_it.only(isel);
            arg_part_ras[parts_len] = try arg_part_vi.?.defReg(isel);
            if (promote_float) if (arg_part_ras[parts_len]) |result_ra| {
                assert(parts_len == 0);
                result_lock = isel.tryLockReg(result_ra);
                const work_ra = if (result_ra.isVector()) result_ra else work: {
                    const ra = try isel.allocVecReg();
                    promoted_ra = ra;
                    try isel.emit(.fmov(result_ra.w(), .{ .register = ra.s() }));
                    break :work ra;
                };
                try isel.emit(.fcvt(work_ra.s(), work_ra.d()));
                arg_part_ras[parts_len] = work_ra;
            };
        }
        break :parts_len parts_len;
    };

    const done_label = isel.instructions.items.len;
    try isel.emit(.str(stack_ra.x(), .{ .unsigned_offset = .{
        .base = va_list_ptr_mat.ra.x(),
        .offset = 0,
    } }));
    try isel.emit(switch (parts_len) {
        else => unreachable,
        1 => if (arg_part_ras[0]) |arg_part_ra| switch (part_vis[0].size(isel)) {
            else => unreachable,
            1 => if (arg_part_ra.isVector()) .ldr(arg_part_ra.b(), .{ .post_index = .{
                .base = stack_ra.x(),
                .index = passed_size,
            } }) else switch (part_vis[0].signedness(isel)) {
                .signed => .ldrsb(arg_part_ra.w(), .{ .post_index = .{
                    .base = stack_ra.x(),
                    .index = passed_size,
                } }),
                .unsigned => .ldrb(arg_part_ra.w(), .{ .post_index = .{
                    .base = stack_ra.x(),
                    .index = passed_size,
                } }),
            },
            2 => if (arg_part_ra.isVector()) .ldr(arg_part_ra.h(), .{ .post_index = .{
                .base = stack_ra.x(),
                .index = passed_size,
            } }) else switch (part_vis[0].signedness(isel)) {
                .signed => .ldrsh(arg_part_ra.w(), .{ .post_index = .{
                    .base = stack_ra.x(),
                    .index = passed_size,
                } }),
                .unsigned => .ldrh(arg_part_ra.w(), .{ .post_index = .{
                    .base = stack_ra.x(),
                    .index = passed_size,
                } }),
            },
            4 => .ldr(if (arg_part_ra.isVector()) arg_part_ra.s() else arg_part_ra.w(), .{ .post_index = .{
                .base = stack_ra.x(),
                .index = passed_size,
            } }),
            8 => .ldr(if (arg_part_ra.isVector()) arg_part_ra.d() else arg_part_ra.x(), .{ .post_index = .{
                .base = stack_ra.x(),
                .index = passed_size,
            } }),
            16 => .ldr(arg_part_ra.q(), .{ .post_index = .{
                .base = stack_ra.x(),
                .index = passed_size,
            } }),
        } else .add(stack_ra.x(), stack_ra.x(), .{ .immediate = passed_size }),
        2 => if (arg_part_ras[0] != null or arg_part_ras[1] != null) .ldp(
            @as(Register.Alias, arg_part_ras[0] orelse .zr).x(),
            @as(Register.Alias, arg_part_ras[1] orelse .zr).x(),
            .{ .post_index = .{
                .base = stack_ra.x(),
                .index = passed_size,
            } },
        ) else .add(stack_ra.x(), stack_ra.x(), .{ .immediate = passed_size }),
    });
    try isel.emit(.ldr(stack_ra.x(), .{ .unsigned_offset = .{
        .base = va_list_ptr_mat.ra.x(),
        .offset = 0,
    } }));
    switch (isel.va_list) {
        .other => {},
        .sysv => {
            const stack_label = isel.instructions.items.len;
            try isel.emit(.b(
                @intCast((isel.instructions.items.len + 1 - done_label) << 2),
            ));
            switch (parts_len) {
                else => unreachable,
                1 => if (arg_part_ras[0]) |arg_part_ra| try isel.emit(switch (part_vis[0].size(isel)) {
                    else => unreachable,
                    1 => if (arg_part_ra.isVector()) .ldr(arg_part_ra.b(), .{ .extended_register = .{
                        .base = stack_ra.x(),
                        .index = offs_ra.w(),
                        .extend = .{ .sxtw = 0 },
                    } }) else switch (part_vis[0].signedness(isel)) {
                        .signed => .ldrsb(arg_part_ra.w(), .{ .extended_register = .{
                            .base = stack_ra.x(),
                            .index = offs_ra.w(),
                            .extend = .{ .sxtw = 0 },
                        } }),
                        .unsigned => .ldrb(arg_part_ra.w(), .{ .extended_register = .{
                            .base = stack_ra.x(),
                            .index = offs_ra.w(),
                            .extend = .{ .sxtw = 0 },
                        } }),
                    },
                    2 => if (arg_part_ra.isVector()) .ldr(arg_part_ra.h(), .{ .extended_register = .{
                        .base = stack_ra.x(),
                        .index = offs_ra.w(),
                        .extend = .{ .sxtw = 0 },
                    } }) else switch (part_vis[0].signedness(isel)) {
                        .signed => .ldrsh(arg_part_ra.w(), .{ .extended_register = .{
                            .base = stack_ra.x(),
                            .index = offs_ra.w(),
                            .extend = .{ .sxtw = 0 },
                        } }),
                        .unsigned => .ldrh(arg_part_ra.w(), .{ .extended_register = .{
                            .base = stack_ra.x(),
                            .index = offs_ra.w(),
                            .extend = .{ .sxtw = 0 },
                        } }),
                    },
                    4 => .ldr(if (arg_part_ra.isVector()) arg_part_ra.s() else arg_part_ra.w(), .{ .extended_register = .{
                        .base = stack_ra.x(),
                        .index = offs_ra.w(),
                        .extend = .{ .sxtw = 0 },
                    } }),
                    8 => .ldr(if (arg_part_ra.isVector()) arg_part_ra.d() else arg_part_ra.x(), .{ .extended_register = .{
                        .base = stack_ra.x(),
                        .index = offs_ra.w(),
                        .extend = .{ .sxtw = 0 },
                    } }),
                    16 => .ldr(arg_part_ra.q(), .{ .extended_register = .{
                        .base = stack_ra.x(),
                        .index = offs_ra.w(),
                        .extend = .{ .sxtw = 0 },
                    } }),
                }),
                2 => if (arg_part_ras[0] != null or arg_part_ras[1] != null) {
                    try isel.emit(.ldp(
                        @as(Register.Alias, arg_part_ras[0] orelse .zr).x(),
                        @as(Register.Alias, arg_part_ras[1] orelse .zr).x(),
                        .{ .base = stack_ra.x() },
                    ));
                    try isel.emit(.add(stack_ra.x(), stack_ra.x(), .{ .extended_register = .{
                        .register = offs_ra.w(),
                        .extend = .{ .sxtw = 0 },
                    } }));
                },
            }
            try isel.emit(.ldr(stack_ra.x(), .{ .unsigned_offset = .{
                .base = va_list_ptr_mat.ra.x(),
                .offset = if (passed_is_vector) 16 else 8,
            } }));
            try isel.emit(.@"b."(
                .gt,
                @intCast((isel.instructions.items.len + 1 - stack_label) << 2),
            ));
            try isel.emit(.str(stack_ra.w(), .{ .unsigned_offset = .{
                .base = va_list_ptr_mat.ra.x(),
                .offset = if (passed_is_vector) 28 else 24,
            } }));
            try isel.emit(.adds(stack_ra.w(), offs_ra.w(), .{ .immediate = register_size }));
            try isel.emit(.tbz(
                offs_ra.w(),
                31,
                @intCast((isel.instructions.items.len + 1 - stack_label) << 2),
            ));
            try isel.emit(.ldr(offs_ra.w(), .{ .unsigned_offset = .{
                .base = va_list_ptr_mat.ra.x(),
                .offset = if (passed_is_vector) 28 else 24,
            } }));
        },
    }
    try va_list_ptr_mat.finish(isel);
}

/// `cond_br`, preceded by `before` in its body; `block_pred` is as for `body`.
fn selectCondBr(
    isel: *Select,
    inst: Air.Inst.Index,
    before: []const Air.Inst.Index,
    block_pred: ?Air.Inst.Index,
) !void {
    const cond_br = isel.air.unwrapCondBr(inst);
    try isel.body(cond_br.then_body, null);
    if (cond_br.condition.toIndex()) |cond_inst| if (isel.canFuseCondition(cond_inst, before, block_pred))
        return isel.condBrFused(cond_inst, cond_br.else_body);
    // Take the condition's register at the start of the then body:
    // a live value it displaces is reloaded on the taken path here,
    // and on the fallthrough path by the merge below. Displacing it
    // after the merge would reload it on the fallthrough path only.
    const cond_vi = try isel.use(cond_br.condition);
    const cond_mat = try cond_vi.matReg(isel);
    const else_label = isel.instructions.items.len;
    const else_live_registers = isel.live_registers;
    try isel.body(cond_br.else_body, null);
    try isel.merge(&else_live_registers, .{});
    try isel.emitBranch(.{ .bit0_set = cond_mat.ra.x() }, else_label);
    try cond_mat.finish(isel);
}

/// Whether the condition `cond_inst` of a `cond_br` preceded by `before` (in
/// the body of a block that `block_pred` precedes, if any) can set the flags
/// at the branch instead of materializing a bool to test: a comparison that
/// only feeds this branch, in the same body or just before the block, so that
/// no loop boundary is crossed.
fn canFuseCondition(
    isel: *Select,
    cond_inst: Air.Inst.Index,
    before: []const Air.Inst.Index,
    block_pred: ?Air.Inst.Index,
) bool {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (isel.live_values.contains(cond_inst)) return false;
    const tags = isel.air.instructions.items(.tag);
    switch (tags[@backingInt(cond_inst)]) {
        else => return false,
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            const cmp_ty = isel.air.typeOf(isel.air.instructions.items(.data)[@backingInt(cond_inst)].bin_op.lhs, ip);
            if (!isel.cmpCanBranch(cmp_ty)) return false;
            if (ip.indexToKey(cmp_ty.toIntern()) == .opt_type and !cmp_ty.optionalReprIsPayload(zcu)) return false;
        },
        .is_null, .is_non_null, .is_err, .is_non_err => {},
    }
    var index = before.len;
    while (index > 0) {
        index -= 1;
        if (before[index] == cond_inst) return true;
        switch (tags[@backingInt(before[index])]) {
            else => return false,
            .dbg_stmt, .dbg_empty_stmt => {},
        }
    }
    return block_pred == cond_inst;
}

/// The rest of a `cond_br` whose condition `cond_inst` sets the flags at the
/// branch (`canFuseCondition`); the then body is selected. The comparison's
/// operands are taken after the merge with the else body's registers, so a
/// live value they displace is reloaded between the comparison and the
/// branch, with loads and moves that keep the flags. A later use of the
/// condition in the else body selects the comparison again.
fn condBrFused(isel: *Select, cond_inst: Air.Inst.Index, else_body: []const Air.Inst.Index) !void {
    const ip = &isel.pt.zcu.intern_pool;
    const cond_tag = isel.air.instructions.items(.tag)[@backingInt(cond_inst)];
    const cond_data = isel.air.instructions.items(.data)[@backingInt(cond_inst)];
    // A test against zero branches with cbz/cbnz on the register, which
    // must then be taken before the else body, as for a bool condition.
    if (try isel.zeroTestOperand(cond_inst)) |zero_test| {
        const operand_vi, const operand_ty, const offset, const size, const branch_if_zero = zero_test;
        var operand_part_it = operand_vi.field(operand_ty, offset, size);
        const operand_mat = try (try operand_part_it.only(isel)).?.matReg(isel);
        const operand_reg = if (size <= 4) operand_mat.ra.w() else operand_mat.ra.x();
        const then_label = isel.instructions.items.len;
        const else_live_registers = isel.live_registers;
        try isel.body(else_body, null);
        try isel.merge(&else_live_registers, .{});
        try isel.emitBranch(if (branch_if_zero) .{ .zero = operand_reg } else .{ .nonzero = operand_reg }, then_label);
        return operand_mat.finish(isel);
    }
    const then_label = isel.instructions.items.len;
    const else_live_registers = isel.live_registers;
    try isel.body(else_body, null);
    try isel.merge(&else_live_registers, .{});
    switch (cond_tag) {
        else => unreachable,
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => try isel.cmpUse(
            .{ .branch = then_label },
            isel.air.typeOf(cond_data.bin_op.lhs, ip),
            try isel.use(cond_data.bin_op.lhs),
            cond_tag.toCmpOp().?,
            try isel.use(cond_data.bin_op.rhs),
        ),
        .is_null, .is_non_null => try isel.isNullUse(.{ .branch = then_label }, cond_tag, cond_data.un_op),
        .is_err, .is_non_err => try isel.isErrUse(.{ .branch = then_label }, cond_tag, cond_data.un_op),
    }
}

/// `store` and `store_safe`, preceded by `before` in their body.
fn selectStore(
    isel: *Select,
    bin_op: @FieldType(Air.Inst.Data, "bin_op"),
    safety: bool,
    before: []const Air.Inst.Index,
) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    // Every load of a stored-once local shares the stored value. Nothing
    // else reads its memory: `analyze` does not count `dbg_var_ptr` as a use,
    // since no variable locations are emitted (see `body`).
    if (bin_op.lhs.toIndex()) |ptr_inst| if (isel.promotion.stored_once.get(ptr_inst)) |local| if (local.valid) return;
    if (isel.promotedLocalRegister(bin_op.lhs)) |pin_ra| return isel.storeToPromotedLocal(pin_ra, bin_op, before);
    const ptr_ty = isel.air.typeOf(bin_op.lhs, ip);
    const ptr_info = ptr_ty.ptrInfo(zcu);
    const src_ty = isel.air.typeOf(bin_op.rhs, ip);
    if (bin_op.rhs.toInterned()) |rhs_val| if (ip.isUndef(rhs_val)) {
        // Safety fills undefined memory with 0xaa. Like the LLVM backend, leave
        // packed fields alone rather than stomping over neighbouring bits.
        if (!safety or ptr_info.flags.vector_index != .none or ptr_info.packed_offset.host_size > 0) return;
        // Small values store the undefined constant, whose parts materialize as 0xaa.
        const undef_size = src_ty.abiSize(zcu);
        if (undef_size > Value.max_parts) {
            try call.prepareVoidGlobal(isel, "memset");
            const ptr_vi = try isel.use(bin_op.lhs);
            try isel.movImmediate(.x2, undef_size);
            try isel.movImmediate(.w1, 0xaa);
            try call.paramLiveOut(isel, ptr_vi, .r0);
            try call.finishParams(isel);
            return;
        }
    };
    if (ptr_info.flags.vector_index == .none and ptr_info.packed_offset.host_size == 0 and
        !ptr_info.flags.is_volatile)
    {
        if (try isel.storeAsMemmove(ptr_info, bin_op, before)) return;
        if (try isel.storeByDefiningInPlace(ptr_ty, bin_op, before)) return;
    }

    const src_vi = try isel.use(bin_op.rhs);
    const size = src_vi.size(isel);
    if (ptr_info.flags.vector_index != .none) {
        const ptr_mat = try (try isel.use(bin_op.lhs)).matReg(isel);
        try isel.vectorMemory(src_vi, src_ty, ptr_mat.ra, ptr_info, true);
        return ptr_mat.finish(isel);
    }
    if (ptr_info.packed_offset.host_size > 0) {
        const ptr_mat = try (try isel.use(bin_op.lhs)).matReg(isel);
        try isel.packedMemory(src_vi, src_ty, ptr_mat.ra, ptr_info.packed_offset.bit_offset, true);
        return ptr_mat.finish(isel);
    }
    if (ZigType.fromInterned(ptr_info.child).zigTypeTag(zcu) != .@"union") switch (size) {
        0 => unreachable,
        1...Value.max_parts => {
            const ptr_base: MemoryBase = try .init(isel, try isel.use(bin_op.lhs));
            try src_vi.store(isel, src_ty, ptr_base.ra, .{
                .offset = ptr_base.offset,
                .@"volatile" = ptr_info.flags.is_volatile,
            });
            return ptr_base.finish(isel);
        },
        else => {},
    };
    if (!ptr_info.flags.is_volatile and try isel.copyInline(
        .{ .ptr = try isel.use(bin_op.lhs) },
        .{ .value = .{ .vi = src_vi } },
        size,
        false,
    )) return;
    try call.prepareVoidGlobal(isel, "memcpy");
    const ptr_vi = try isel.use(bin_op.lhs);
    try isel.movImmediate(.x2, size);
    try call.paramAddress(isel, src_vi, .r1);
    try call.paramLiveOut(isel, ptr_vi, .r0);
    try call.finishParams(isel);
}

/// A store to the local promoted to `pin_ra`, preceded by `before`.
fn storeToPromotedLocal(
    isel: *Select,
    pin_ra: Register.Alias,
    bin_op: @FieldType(Air.Inst.Data, "bin_op"),
    before: []const Air.Inst.Index,
) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    // Only a value defined in the register for this store may
    // occupy it here; see `pinnedStoreSourceAdjacent`.
    if (isel.live_registers.get(pin_ra) != .free)
        return isel.promotionBug("promoted local register {t} is live at a store", .{pin_ra});
    if (bin_op.rhs.toInterned()) |rhs_val| if (ip.isUndef(rhs_val)) {
        // Keep the register a valid value of the type.
        return isel.emit(if (pin_ra.isVector())
            .movi(pin_ra.@"8b"(), 0, .{ .lsl = 0 })
        else
            .orr(pin_ra.x(), .xzr, .{ .register = .xzr }));
    };
    const src_vi = try isel.use(bin_op.rhs);
    // A value that is not live yet would be defined straight into
    // the local's register, which then no longer holds the local
    // in between: only allowed when nothing is in between.
    if (src_vi.isMaterializedAt(isel) or (src_vi.parent(isel) == .unallocated and
        isel.pinnedStoreSourceAdjacent(before, bin_op.rhs)))
    {
        return src_vi.liveOutToPromotedLocal(isel, pin_ra);
    }
    const src_mat = try src_vi.matReg(isel);
    try isel.pinnedMove(pin_ra, src_mat.ra, isel.air.typeOf(bin_op.rhs, ip).abiSize(zcu));
    try src_mat.finish(isel);
}

/// Whether `inst` is in `before`, followed only by instructions with one of
/// the `allowed` tags.
fn followedOnlyBy(
    isel: *Select,
    before: []const Air.Inst.Index,
    inst: Air.Inst.Index,
    comptime allowed: []const Air.Inst.Tag,
) bool {
    const tags = isel.air.instructions.items(.tag);
    var index = before.len;
    while (index > 0) {
        index -= 1;
        if (before[index] == inst) return true;
        if (std.mem.indexOfScalar(Air.Inst.Tag, allowed, tags[@backingInt(before[index])]) == null) return false;
    }
    return false;
}

/// `dst.* = src.*` where the stored value is only this load, of a value too
/// big for registers (or a union): copies memory to memory instead of through
/// the loaded value's stack slot. The operands may overlap, so this is a
/// memmove. Returns false, having emitted nothing, for any other store.
fn storeAsMemmove(
    isel: *Select,
    ptr_info: InternPool.Key.PtrType,
    bin_op: @FieldType(Air.Inst.Data, "bin_op"),
    before: []const Air.Inst.Index,
) !bool {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const load_inst = bin_op.rhs.toIndex() orelse return false;
    if (isel.air.instructions.items(.tag)[@backingInt(load_inst)] != .load) return false;
    // Later uses were already selected; earlier ones are excluded below.
    if (isel.live_values.contains(load_inst)) return false;
    const load_ptr = isel.air.instructions.items(.data)[@backingInt(load_inst)].ty_op.operand;
    const load_ptr_info = isel.air.typeOf(load_ptr, ip).ptrInfo(zcu);
    if (load_ptr_info.flags.vector_index != .none or load_ptr_info.packed_offset.host_size > 0 or
        load_ptr_info.flags.is_volatile) return false;
    const ty: ZigType = .fromInterned(ptr_info.child);
    const size = ty.abiSize(zcu);
    if (size <= Value.max_parts and ty.zigTypeTag(zcu) != .@"union") return false;
    // Only instructions that neither access memory nor use the loaded
    // value may separate the load from this store.
    if (!isel.followedOnlyBy(before, load_inst, &.{
        .dbg_stmt,
        .dbg_empty_stmt,
        .struct_field_ptr,
        .struct_field_ptr_index_0,
        .struct_field_ptr_index_1,
        .struct_field_ptr_index_2,
        .struct_field_ptr_index_3,
    })) return false;
    return isel.copyInline(.{ .ptr = try isel.use(bin_op.lhs) }, .{ .ptr = try isel.use(load_ptr) }, size, true);
}

/// A store into a local of a large value whose last use is this store and
/// which is defined just before it, part by part from other values: defines
/// it in the local instead of in a temporary that is then copied (and read
/// back with wider loads than the part stores that just wrote it). Returns
/// false, having emitted nothing, for any other store.
fn storeByDefiningInPlace(
    isel: *Select,
    ptr_ty: ZigType,
    bin_op: @FieldType(Air.Inst.Data, "bin_op"),
    before: []const Air.Inst.Index,
) !bool {
    const zcu = isel.pt.zcu;
    const src_inst = bin_op.rhs.toIndex() orelse return false;
    // Later uses were already selected.
    if (isel.live_values.contains(src_inst)) return false;
    const ty = ptr_ty.childType(zcu);
    if (ty.abiSize(zcu) <= Value.max_parts) return false;
    if (ptr_ty.ptrAlignment(zcu).compare(.lt, ty.abiAlignment(zcu))) return false;
    switch (isel.air.instructions.items(.tag)[@backingInt(src_inst)]) {
        // These read only operand values, never memory through a pointer.
        .optional_payload,
        .unwrap_errunion_payload,
        .agg_field_val,
        .wrap_optional,
        .wrap_errunion_payload,
        .aggregate_init,
        => {},
        // Defined by the `br`s that end its body, after the rest of the
        // body has run; only the instructions after the block are scanned.
        .block => {},
        else => return false,
    }
    // Nothing between the definition and the store may access memory, so
    // the local is not read or written before the store.
    if (!isel.followedOnlyBy(before, src_inst, &.{
        .dbg_stmt,
        .dbg_empty_stmt,
        .dbg_var_ptr,
        .dbg_var_val,
        .alloc,
        .struct_field_ptr,
        .struct_field_ptr_index_0,
        .struct_field_ptr_index_1,
        .struct_field_ptr_index_2,
        .struct_field_ptr_index_3,
    })) return false;
    const stack_address = switch ((try isel.use(bin_op.lhs)).parent(isel)) {
        .stack_address => |stack_address| stack_address,
        else => return false,
    };
    const src_vi = try isel.use(bin_op.rhs);
    if (src_vi.parent(isel) != .unallocated) return false;
    src_vi.setParent(isel, .{ .stack_slot = stack_address });
    return true;
}

pub fn emitDebug(isel: *Select, info: @FieldType(codegen.aarch64.Mir.Debug, "info")) !void {
    try isel.debug_events.append(isel.pt.zcu.gpa, .{
        .section = isel.debug_section,
        .offset = @intCast(isel.instructions.items.len),
        .seq = @intCast(isel.debug_events.items.len),
        .info = info,
    });
}

pub fn emit(isel: *Select, instruction: codegen.aarch64.encoding.Instruction) !void {
    wip_mir_log.debug("  | {f}", .{instruction});
    try isel.instructions.append(isel.pt.zcu.gpa, instruction);
}

/// Moves an integer of at most 32 bits. Its register's bits above 32 are not
/// part of it, and every use that needs them extends it, so a move onto its
/// own register is dropped.
fn moveInt32(isel: *Select, dst_ra: Register.Alias, src_ra: Register.Alias) !void {
    if (dst_ra != src_ra) try isel.emit(.orr(dst_ra.w(), .wzr, .{ .register = src_ra.w() }));
}

pub fn emitPanic(isel: *Select, panic_id: Zcu.SimplePanicId) !void {
    const zcu = isel.pt.zcu;
    try isel.nav_relocs.append(zcu.gpa, .{
        .nav = switch (zcu.intern_pool.indexToKey(zcu.std_lang_decl_values.get(panic_id.toStdLangDecl()))) {
            else => unreachable,
            inline .@"extern", .func => |func| func.owner_nav,
        },
        .reloc = .{ .label = @intCast(isel.instructions.items.len) },
    });
    try isel.emit(.bl(0));
}

fn emitLiteral(isel: *Select, bytes: []const u8) !void {
    const words: []align(1) const u32 = @ptrCast(bytes);
    const literals = try isel.literals.addManyAsSlice(isel.pt.zcu.gpa, words.len);
    switch (isel.target.cpu.arch.endian()) {
        .little => @memcpy(literals, words),
        .big => for (words, 0..) |word, word_index| {
            literals[literals.len - 1 - word_index] = @byteSwap(word);
        },
    }
}

fn atomicIntInfo(isel: *Select, ty: ZigType) !?std.lang.Type.Int {
    if (!ty.isAbiInt(isel.pt.zcu)) return null;
    const int_info = ty.intInfo(isel.pt.zcu);
    assert(int_info.bits > 0);
    if (int_info.bits > 64)
        return isel.fail("unsupported atomic integer width {f}", .{isel.fmtType(ty)});
    return int_info;
}

fn isAtomicInt128(isel: *Select, ty: ZigType) bool {
    const zcu = isel.pt.zcu;
    return ty.isAbiInt(zcu) and ty.intInfo(zcu).bits > 64 and ty.abiSize(zcu) == 16;
}

/// A run of instructions emitted in execution order, unlike the rest of
/// selection, so that a fixed sequence (inline assembly, an exclusive access
/// loop, a byte loop) can encode its internal branches as they run. Operands
/// are materialized outside of it. `end` reverses the run into place, along
/// with the labels of the relocations and debug events recorded in it.
const ForwardSegment = struct {
    start: usize,
    debug_events_start: usize,
    nav_relocs_start: usize,
    uav_relocs_start: usize,
    lazy_relocs_start: usize,
    global_relocs_start: usize,
    literal_relocs_start: usize,

    fn begin(isel: *const Select) ForwardSegment {
        return .{
            .start = isel.instructions.items.len,
            .debug_events_start = isel.debug_events.items.len,
            .nav_relocs_start = isel.nav_relocs.items.len,
            .uav_relocs_start = isel.uav_relocs.items.len,
            .lazy_relocs_start = isel.lazy_relocs.items.len,
            .global_relocs_start = isel.global_relocs.items.len,
            .literal_relocs_start = isel.literal_relocs.items.len,
        };
    }

    /// The byte offset from the next instruction to the one at `label`,
    /// emitted earlier in the segment.
    fn offsetTo(segment: ForwardSegment, isel: *const Select, label: usize) i64 {
        assert(label >= segment.start and label <= isel.instructions.items.len);
        return (@as(i64, @intCast(label)) - @as(i64, @intCast(isel.instructions.items.len))) * 4;
    }

    fn end(segment: ForwardSegment, isel: *Select) void {
        const len = isel.instructions.items.len;
        std.mem.reverse(codegen.aarch64.encoding.Instruction, isel.instructions.items[segment.start..]);
        for (isel.debug_events.items[segment.debug_events_start..]) |*event|
            event.offset = @intCast(segment.start + len - event.offset);
        for (isel.nav_relocs.items[segment.nav_relocs_start..]) |*reloc|
            reloc.reloc.label = @intCast(segment.start + len - 1 - reloc.reloc.label);
        for (isel.uav_relocs.items[segment.uav_relocs_start..]) |*reloc|
            reloc.reloc.label = @intCast(segment.start + len - 1 - reloc.reloc.label);
        assert(isel.lazy_relocs.items.len == segment.lazy_relocs_start);
        assert(isel.global_relocs.items.len == segment.global_relocs_start);
        assert(isel.literal_relocs.items.len == segment.literal_relocs_start);
    }
};

/// The registers that define the 8-byte halves of a 16-byte value, each
/// locked until `deinit`. A half that nothing uses has none.
const DefPair = struct {
    lo: ?Register.Alias,
    hi: ?Register.Alias,
    locks: [2]RegLock,

    const none: DefPair = .{ .lo = null, .hi = null, .locks = .{ .empty, .empty } };

    fn init(isel: *Select, vi: Value.Index, ty: ZigType) !DefPair {
        var hi_it = vi.field(ty, 8, 8);
        const hi = try (try hi_it.only(isel)).?.defReg(isel);
        const hi_lock: RegLock = if (hi) |ra| isel.tryLockReg(ra) else .empty;
        errdefer hi_lock.unlock(isel);
        var lo_it = vi.field(ty, 0, 8);
        const lo = try (try lo_it.only(isel)).?.defReg(isel);
        const lo_lock: RegLock = if (lo) |ra| isel.tryLockReg(ra) else .empty;
        return .{ .lo = lo, .hi = hi, .locks = .{ lo_lock, hi_lock } };
    }

    fn unused(pair: DefPair) bool {
        return pair.lo == null and pair.hi == null;
    }

    fn deinit(pair: DefPair, isel: *Select) void {
        for (pair.locks) |lock| lock.unlock(isel);
    }
};

/// The registers of a 128-bit atomic result, or scratch registers for the
/// halves that are not used.
const AtomicPair = struct {
    lo: Register.Alias,
    hi: Register.Alias,
    def: DefPair,

    fn init(isel: *Select, vi: ?Value.Index, ty: ZigType) !AtomicPair {
        const def: DefPair = if (vi) |res_vi| try .init(isel, res_vi, ty) else .none;
        errdefer def.deinit(isel);
        const lo = def.lo orelse try isel.allocIntReg();
        errdefer if (def.lo == null) isel.freeReg(lo);
        return .{ .lo = lo, .hi = def.hi orelse try isel.allocIntReg(), .def = def };
    }

    fn deinit(pair: AtomicPair, isel: *Select) void {
        if (pair.def.lo == null) isel.freeReg(pair.lo);
        if (pair.def.hi == null) isel.freeReg(pair.hi);
        pair.def.deinit(isel);
    }
};

/// 128-bit compare and exchange with an exclusive pair loop. A failed
/// comparison stores the loaded value back, so that the load was atomic.
fn atomicCmpxchg128(isel: *Select, result_ty: ZigType, extra: Air.Cmpxchg, dst: ?Value.Index) !void {
    const zcu = isel.pt.zcu;
    const acquire = switch (extra.successOrder()) {
        .acquire, .acq_rel, .seq_cst => true,
        .monotonic, .release => extra.failureOrder() == .acquire or extra.failureOrder() == .seq_cst,
        else => unreachable,
    };
    const release = switch (extra.successOrder()) {
        .release, .acq_rel, .seq_cst => true,
        .monotonic, .acquire => false,
        else => unreachable,
    };
    const old = try AtomicPair.init(isel, dst, result_ty);
    defer old.deinit(isel);
    const flag_ra = if (dst) |vi| ra: {
        var flag_it = vi.field(result_ty, 16, 1);
        break :ra try (try flag_it.only(isel)).?.defReg(isel);
    } else null;
    const flag = flag_ra orelse try isel.allocIntReg();
    defer if (flag_ra == null) isel.freeReg(flag);
    const flag_lock = if (flag_ra != null) isel.lockReg(flag) else RegLock.empty;
    defer flag_lock.unlock(isel);
    const status = try isel.allocIntReg();
    defer isel.freeReg(status);
    const ty = isel.air.typeOf(extra.expected_value, &zcu.intern_pool);
    const ptr_mat = try (try isel.use(extra.ptr)).matReg(isel);
    const expected_vi = try isel.use(extra.expected_value);
    const new_vi = try isel.use(extra.new_value);
    var expected_lo_it = expected_vi.field(ty, 0, 8);
    const expected_lo = try (try expected_lo_it.only(isel)).?.matReg(isel);
    var expected_hi_it = expected_vi.field(ty, 8, 8);
    const expected_hi = try (try expected_hi_it.only(isel)).?.matReg(isel);
    var new_lo_it = new_vi.field(ty, 0, 8);
    const new_lo = try (try new_lo_it.only(isel)).?.matReg(isel);
    var new_hi_it = new_vi.field(ty, 8, 8);
    const new_hi = try (try new_hi_it.only(isel)).?.matReg(isel);
    const ptr = ptr_mat.ra.x();
    const segment: ForwardSegment = .begin(isel);
    try isel.emit(.ldxp(old.lo.x(), old.hi.x(), ptr, acquire));
    try isel.emit(.subs(.xzr, old.lo.x(), .{ .register = expected_lo.ra.x() }));
    try isel.emit(.ccmp(old.hi.x(), .{ .register = expected_hi.ra.x() }, .{ .n = false, .z = false, .c = false, .v = false }, .eq));
    try isel.emit(.@"b."(.ne, 5 << 2));
    try isel.emit(.stxp(status.w(), new_lo.ra.x(), new_hi.ra.x(), ptr, release));
    try isel.emit(.cbnz(status.w(), -5 << 2));
    try isel.emit(.orr(flag.w(), .wzr, .{ .register = .wzr }));
    try isel.emit(.b(4 << 2));
    try isel.emit(.stxp(status.w(), old.lo.x(), old.hi.x(), ptr, release));
    try isel.emit(.cbnz(status.w(), -9 << 2));
    try isel.emit(.movz(flag.w(), 1, .{ .lsl = .@"0" }));
    segment.end(isel);
    try new_hi.finish(isel);
    try new_lo.finish(isel);
    try expected_hi.finish(isel);
    try expected_lo.finish(isel);
    try ptr_mat.finish(isel);
}

/// 128-bit read-modify-write with an exclusive pair loop.
fn atomicRmw128(isel: *Select, ptr_ref: Air.Inst.Ref, extra: Air.AtomicRmw, dst: ?Value.Index) !void {
    const zcu = isel.pt.zcu;
    const ty = isel.air.typeOf(extra.operand, &zcu.intern_pool);
    const info = ty.intInfo(zcu);
    const acquire = switch (extra.ordering()) {
        .acquire, .acq_rel, .seq_cst => true,
        .monotonic, .release => false,
        else => unreachable,
    };
    const release = switch (extra.ordering()) {
        .release, .acq_rel, .seq_cst => true,
        .monotonic, .acquire => false,
        else => unreachable,
    };
    const old = try AtomicPair.init(isel, dst, ty);
    defer old.deinit(isel);
    const new = try AtomicPair.init(isel, null, ty);
    defer new.deinit(isel);
    const status = try isel.allocIntReg();
    defer isel.freeReg(status);
    const ptr_mat = try (try isel.use(ptr_ref)).matReg(isel);
    const operand_vi = try isel.use(extra.operand);
    var operand_lo_it = operand_vi.field(ty, 0, 8);
    const operand_lo = try (try operand_lo_it.only(isel)).?.matReg(isel);
    var operand_hi_it = operand_vi.field(ty, 8, 8);
    const operand_hi = try (try operand_hi_it.only(isel)).?.matReg(isel);
    const op_lo = operand_lo.ra.x();
    const op_hi = operand_hi.ra.x();
    const new_lo = new.lo.x();
    const new_hi = new.hi.x();
    const old_lo = old.lo.x();
    const old_hi = old.hi.x();
    const segment: ForwardSegment = .begin(isel);
    try isel.emit(.ldxp(old_lo, old_hi, ptr_mat.ra.x(), acquire));
    switch (extra.op()) {
        .Xchg => {
            try isel.emit(.orr(new_lo, .xzr, .{ .register = op_lo }));
            try isel.emit(.orr(new_hi, .xzr, .{ .register = op_hi }));
        },
        .Add => {
            try isel.emit(.adds(new_lo, old_lo, .{ .register = op_lo }));
            try isel.emit(.adc(new_hi, old_hi, op_hi));
        },
        .Sub => {
            try isel.emit(.subs(new_lo, old_lo, .{ .register = op_lo }));
            try isel.emit(.sbc(new_hi, old_hi, op_hi));
        },
        .And => {
            try isel.emit(.@"and"(new_lo, old_lo, .{ .register = op_lo }));
            try isel.emit(.@"and"(new_hi, old_hi, .{ .register = op_hi }));
        },
        .Or => {
            try isel.emit(.orr(new_lo, old_lo, .{ .register = op_lo }));
            try isel.emit(.orr(new_hi, old_hi, .{ .register = op_hi }));
        },
        .Xor => {
            try isel.emit(.eor(new_lo, old_lo, .{ .register = op_lo }));
            try isel.emit(.eor(new_hi, old_hi, .{ .register = op_hi }));
        },
        .Nand => {
            try isel.emit(.@"and"(new_lo, old_lo, .{ .register = op_lo }));
            try isel.emit(.orn(new_lo, .xzr, .{ .register = new_lo }));
            try isel.emit(.@"and"(new_hi, old_hi, .{ .register = op_hi }));
            try isel.emit(.orn(new_hi, .xzr, .{ .register = new_hi }));
        },
        .Min, .Max => |op| {
            const signed = info.signedness == .signed;
            const cond: codegen.aarch64.encoding.ConditionCode = if (op == .Min)
                (if (signed) .lt else .lo)
            else
                (if (signed) .ge else .hs);
            try isel.emit(.subs(.xzr, old_lo, .{ .register = op_lo }));
            try isel.emit(.sbcs(.xzr, old_hi, op_hi));
            try isel.emit(.csel(new_lo, old_lo, op_lo, cond));
            try isel.emit(.csel(new_hi, old_hi, op_hi, cond));
        },
    }
    if (info.bits < 128) try isel.normalizeIntReg(new.hi, new.hi, .{ .signedness = info.signedness, .bits = info.bits - 64 });
    try isel.emit(.stxp(status.w(), new_lo, new_hi, ptr_mat.ra.x(), release));
    try isel.emit(.cbnz(status.w(), @intCast(segment.offsetTo(isel, segment.start))));
    segment.end(isel);
    try operand_hi.finish(isel);
    try operand_lo.finish(isel);
    try ptr_mat.finish(isel);
}

fn normalizeAtomic(isel: *Select, dst: Register, src: Register, int_info: std.lang.Type.Int) !void {
    const reg_bits: u16 = if (dst.size() == 8) 64 else 32;
    if (int_info.bits == reg_bits) return;
    try isel.emit(switch (int_info.signedness) {
        .signed => .sbfm(dst, src, .{
            .N = if (reg_bits == 64) .doubleword else .word,
            .immr = 0,
            .imms = @intCast(int_info.bits - 1),
        }),
        .unsigned => .ubfm(dst, src, .{
            .N = if (reg_bits == 64) .doubleword else .word,
            .immr = 0,
            .imms = @intCast(int_info.bits - 1),
        }),
    });
}

/// Baseline AArch64 scalar atomics use an exclusive retry loop. All operands
/// are materialized outside the loop so spills cannot invalidate the monitor.
fn atomicCmpxchg(isel: *Select, result_ty: ZigType, extra: Air.Cmpxchg, dst: ?Value.Index, strong: bool) !void {
    const zcu = isel.pt.zcu;
    const ty = isel.air.typeOf(extra.expected_value, &zcu.intern_pool);
    const ptr_ty = isel.air.typeOf(extra.ptr, &zcu.intern_pool);
    if (isel.isAtomicInt128(ty)) return isel.atomicCmpxchg128(result_ty, extra, dst);
    const size = ty.abiSize(zcu);
    const int_info = try isel.atomicIntInfo(ty);
    const pointer_repr = ty.zigTypeTag(zcu) == .pointer or
        (ty.zigTypeTag(zcu) == .optional and ty.optionalReprIsPayload(zcu));
    assert(ptr_ty.ptrInfo(zcu).packed_offset.host_size == 0);
    const is_supported_type = ty.isAbiInt(zcu) or pointer_repr or ty.zigTypeTag(zcu) == .bool;
    const is_supported_size = size == 1 or size == 2 or size == 4 or size == 8;
    assert(is_supported_type);
    assert(is_supported_size);
    const repr_payload = result_ty.optionalReprIsPayload(zcu);
    var payload_ra: ?Register.Alias = null;
    var flag_ra: ?Register.Alias = null;
    if (dst) |vi| {
        if (repr_payload) {
            payload_ra = try vi.defReg(isel);
        } else {
            var payload_it = vi.field(result_ty, 0, size);
            const payload_vi = try payload_it.only(isel);
            payload_ra = try payload_vi.?.defReg(isel);
        }
    }
    const payload_lock = if (payload_ra) |ra| isel.tryLockReg(ra) else RegLock.empty;
    defer payload_lock.unlock(isel);
    if (dst) |vi| if (!repr_payload) {
        var flag_it = vi.field(result_ty, size, 1);
        const flag_vi = try flag_it.only(isel);
        flag_ra = try flag_vi.?.defReg(isel);
    };
    const flag_lock = if (flag_ra) |ra| isel.tryLockReg(ra) else RegLock.empty;
    defer flag_lock.unlock(isel);
    const old_ra = payload_ra orelse try isel.allocIntReg();
    defer if (payload_ra == null) isel.freeReg(old_ra);
    const status_ra = try isel.allocIntReg();
    defer isel.freeReg(status_ra);
    const ptr_mat = try (try isel.use(extra.ptr)).matReg(isel);
    const expected_mat = try (try isel.use(extra.expected_value)).matReg(isel);
    const new_mat = try (try isel.use(extra.new_value)).matReg(isel);
    const old = if (size == 8) old_ra.x() else old_ra.w();
    const expected = if (size == 8) expected_mat.ra.x() else expected_mat.ra.w();
    const wrap_new = if (int_info) |info| info.bits < 8 * size else false;
    const new_ra = if (wrap_new) try isel.allocIntReg() else new_mat.ra;
    defer if (wrap_new) isel.freeReg(new_ra);
    const new = if (size == 8) new_ra.x() else new_ra.w();
    const zero: Register = if (size == 8) .xzr else .wzr;
    const acquire = switch (extra.successOrder()) {
        .acquire, .acq_rel, .seq_cst => true,
        .monotonic, .release => extra.failureOrder() == .acquire or extra.failureOrder() == .seq_cst,
        else => unreachable,
    };
    const release = switch (extra.successOrder()) {
        .release, .acq_rel, .seq_cst => true,
        .monotonic, .acquire => false,
        else => unreachable,
    };
    if (repr_payload and payload_ra != null) {
        try isel.emit(.csel(old, old, zero, .ne));
        try isel.emit(.subs(.wzr, status_ra.w(), .{ .immediate = 0 }));
    }
    if (flag_ra) |ra| try isel.emit(.orr(ra.w(), .wzr, .{ .register = status_ra.w() }));
    try isel.emit(.clrex(15));
    const done_label = isel.instructions.items.len;
    const retry_label = isel.instructions.items.len;
    if (strong) try isel.emit(.cbnz(status_ra.w(), 0));
    try isel.emit(.stxr(status_ra.w(), new, ptr_mat.ra.x(), @intCast(std.math.log2_int(u64, size)), release));
    try isel.emit(.@"b."(.ne, @intCast((isel.instructions.items.len + 1 - done_label) << 2)));
    try isel.emit(.subs(zero, old, .{ .register = expected }));
    try isel.movImmediate(status_ra.w(), 1);
    if (int_info) |info| try isel.normalizeAtomic(old, old, info);
    const load_label = isel.instructions.items.len;
    try isel.emit(.ldxr(old, ptr_mat.ra.x(), @intCast(std.math.log2_int(u64, size)), acquire));
    if (strong) isel.instructions.items[retry_label] = .cbnz(status_ra.w(), -@as(i21, @intCast((load_label - retry_label) << 2)));
    if (wrap_new) try isel.normalizeAtomic(new, if (size == 8) new_mat.ra.x() else new_mat.ra.w(), .{
        .signedness = .unsigned,
        .bits = int_info.?.bits,
    });
    try new_mat.finish(isel);
    try expected_mat.finish(isel);
    try ptr_mat.finish(isel);
}

fn atomicRmw(isel: *Select, ptr: Air.Inst.Ref, extra: Air.AtomicRmw, dst: ?Value.Index) !void {
    const zcu = isel.pt.zcu;
    const ty = isel.air.typeOf(extra.operand, &zcu.intern_pool);
    const ptr_ty = isel.air.typeOf(ptr, &zcu.intern_pool);
    if (isel.isAtomicInt128(ty)) return isel.atomicRmw128(ptr, extra, dst);
    const size = ty.abiSize(zcu);
    const int_info = try isel.atomicIntInfo(ty);
    const pointer_repr = ty.zigTypeTag(zcu) == .pointer or
        (ty.zigTypeTag(zcu) == .optional and ty.optionalReprIsPayload(zcu));
    assert(ptr_ty.ptrInfo(zcu).packed_offset.host_size == 0);
    if (ty.isRuntimeFloat()) return isel.atomicRmwFloat(ptr, extra, dst);
    const is_supported_type = ty.isAbiInt(zcu) or
        ((ty.zigTypeTag(zcu) == .bool or pointer_repr) and extra.op() == .Xchg);
    const is_supported_size = size == 1 or size == 2 or size == 4 or size == 8;
    if (!is_supported_type or !is_supported_size)
        return isel.fail("unsupported atomic RMW {f}", .{isel.fmtType(ty)});
    const result_ra = if (dst) |vi| try vi.defReg(isel) else null;
    const old_ra = result_ra orelse try isel.allocIntReg();
    defer if (result_ra == null) isel.freeReg(old_ra);
    const old_lock = isel.tryLockReg(old_ra);
    defer old_lock.unlock(isel);
    const new_ra = try isel.allocIntReg();
    defer isel.freeReg(new_ra);
    const status_ra = try isel.allocIntReg();
    defer isel.freeReg(status_ra);
    const ptr_mat = try (try isel.use(ptr)).matReg(isel);
    const operand_mat = try (try isel.use(extra.operand)).matReg(isel);
    const old = if (size == 8) old_ra.x() else old_ra.w();
    const new = if (size == 8) new_ra.x() else new_ra.w();
    const operand = if (size == 8) operand_mat.ra.x() else operand_mat.ra.w();
    const zero: Register = if (size == 8) .xzr else .wzr;
    const acquire = switch (extra.ordering()) {
        .acquire, .acq_rel, .seq_cst => true,
        .monotonic, .release => false,
        else => unreachable,
    };
    const release = switch (extra.ordering()) {
        .release, .acq_rel, .seq_cst => true,
        .monotonic, .acquire => false,
        else => unreachable,
    };
    const loop_branch = isel.instructions.items.len;
    try isel.emit(.cbnz(status_ra.w(), 0));
    try isel.emit(.stxr(status_ra.w(), new, ptr_mat.ra.x(), @intCast(std.math.log2_int(u64, size)), release));
    if (int_info) |info| if (info.bits < 8 * size) {
        try isel.normalizeAtomic(new, new, .{ .signedness = .unsigned, .bits = info.bits });
    };
    switch (extra.op()) {
        .Xchg => try isel.emit(.orr(new, zero, .{ .register = operand })),
        .Add => try isel.emit(.add(new, old, .{ .register = operand })),
        .Sub => try isel.emit(.sub(new, old, .{ .register = operand })),
        .And => try isel.emit(.@"and"(new, old, .{ .register = operand })),
        .Or => try isel.emit(.orr(new, old, .{ .register = operand })),
        .Xor => try isel.emit(.eor(new, old, .{ .register = operand })),
        .Nand => {
            try isel.emit(.orn(new, zero, .{ .register = new }));
            try isel.emit(.@"and"(new, old, .{ .register = operand }));
        },
        .Min, .Max => |op| {
            const signed = ty.intInfo(zcu).signedness == .signed;
            const cond: codegen.aarch64.encoding.ConditionCode = if (op == .Min) (if (signed) .lt else .lo) else (if (signed) .gt else .hi);
            try isel.emit(.csel(new, old, operand, cond));
            try isel.emit(.subs(zero, old, .{ .register = operand }));
        },
    }
    if (int_info) |info| try isel.normalizeAtomic(old, old, info);
    const loop_load = isel.instructions.items.len;
    try isel.emit(.ldxr(old, ptr_mat.ra.x(), @intCast(std.math.log2_int(u64, size)), acquire));
    isel.instructions.items[loop_branch] = .cbnz(status_ra.w(), -@as(i21, @intCast((loop_load - loop_branch) << 2)));
    try operand_mat.finish(isel);
    try ptr_mat.finish(isel);
}

/// Float atomic RMW: the exclusive loop moves the loaded bits into a vector
/// register, applies the operation there and moves the result back.
fn atomicRmwFloat(isel: *Select, ptr: Air.Inst.Ref, extra: Air.AtomicRmw, dst: ?Value.Index) !void {
    const zcu = isel.pt.zcu;
    const ty = isel.air.typeOf(extra.operand, &zcu.intern_pool);
    const bits = ty.floatBits(isel.target);
    switch (bits) {
        16, 32, 64 => {},
        else => return isel.fail("unsupported atomic RMW {f}", .{isel.fmtType(ty)}),
    }
    const fullfp16 = isel.target.cpu.has(.aarch64, .fullfp16);
    const need_fcvt = bits == 16 and !fullfp16 and extra.op() != .Xchg;
    const result_ra = if (dst) |vi| try vi.defReg(isel) else null;
    const result_lock = if (result_ra) |ra| isel.tryLockReg(ra) else RegLock.empty;
    defer result_lock.unlock(isel);
    const old_ra = try isel.allocIntReg();
    defer isel.freeReg(old_ra);
    const new_ra = try isel.allocIntReg();
    defer isel.freeReg(new_ra);
    const status_ra = try isel.allocIntReg();
    defer isel.freeReg(status_ra);
    const old_float_ra = try isel.allocVecReg();
    defer isel.freeReg(old_float_ra);
    const new_float_ra = try isel.allocVecReg();
    defer isel.freeReg(new_float_ra);
    const operand_float_ra = if (need_fcvt) try isel.allocVecReg() else Register.Alias.zr;
    defer if (need_fcvt) isel.freeReg(operand_float_ra);
    const ptr_mat = try (try isel.use(ptr)).matReg(isel);
    const operand_mat = try (try isel.use(extra.operand)).matReg(isel);
    const operand_ra = if (need_fcvt) operand_float_ra else operand_mat.ra;
    const old = if (bits == 64) old_ra.x() else old_ra.w();
    const new = if (bits == 64) new_ra.x() else new_ra.w();
    const log2_size: u2 = @intCast(std.math.log2_int(u16, bits / 8));
    const acquire = switch (extra.ordering()) {
        .acquire, .acq_rel, .seq_cst => true,
        .monotonic, .release => false,
        else => unreachable,
    };
    const release = switch (extra.ordering()) {
        .release, .acq_rel, .seq_cst => true,
        .monotonic, .acquire => false,
        else => unreachable,
    };
    if (result_ra) |ra| try isel.emit(if (bits == 64)
        .fmov(ra.d(), .{ .register = old })
    else
        .fmov(ra.s(), .{ .register = old }));
    const loop_branch = isel.instructions.items.len;
    try isel.emit(.cbnz(status_ra.w(), 0));
    try isel.emit(.stxr(status_ra.w(), new, ptr_mat.ra.x(), log2_size, release));
    if (extra.op() == .Xchg) {
        try isel.emit(switch (bits) {
            else => unreachable,
            16 => if (fullfp16) .fmov(new, .{ .register = operand_ra.h() }) else .umov(new, operand_ra.@"h[]"(0)),
            32 => .fmov(new, .{ .register = operand_ra.s() }),
            64 => .fmov(new, .{ .register = operand_ra.d() }),
        });
    } else {
        try isel.emit(switch (bits) {
            else => unreachable,
            16 => if (fullfp16) .fmov(new, .{ .register = new_float_ra.h() }) else .umov(new, new_float_ra.@"h[]"(0)),
            32 => .fmov(new, .{ .register = new_float_ra.s() }),
            64 => .fmov(new, .{ .register = new_float_ra.d() }),
        });
        if (need_fcvt) try isel.emit(.fcvt(new_float_ra.h(), new_float_ra.s()));
        const new_float: Register, const old_float: Register, const operand_float: Register = switch (bits) {
            else => unreachable,
            16 => if (need_fcvt)
                .{ new_float_ra.s(), old_float_ra.s(), operand_ra.s() }
            else
                .{ new_float_ra.h(), old_float_ra.h(), operand_ra.h() },
            32 => .{ new_float_ra.s(), old_float_ra.s(), operand_ra.s() },
            64 => .{ new_float_ra.d(), old_float_ra.d(), operand_ra.d() },
        };
        try isel.emit(switch (extra.op()) {
            .Add => .fadd(new_float, old_float, operand_float),
            .Sub => .fsub(new_float, old_float, operand_float),
            .Max => .fmaxnm(new_float, old_float, operand_float),
            .Min => .fminnm(new_float, old_float, operand_float),
            else => return isel.fail("unsupported atomic RMW {t} {f}", .{ extra.op(), isel.fmtType(ty) }),
        });
        if (need_fcvt) try isel.emit(.fcvt(old_float_ra.s(), old_float_ra.h()));
        try isel.emit(if (bits == 64)
            .fmov(old_float_ra.d(), .{ .register = old })
        else
            .fmov(old_float_ra.s(), .{ .register = old }));
    }
    const loop_load = isel.instructions.items.len;
    try isel.emit(.ldxr(old, ptr_mat.ra.x(), log2_size, acquire));
    isel.instructions.items[loop_branch] = .cbnz(status_ra.w(), -@as(i21, @intCast((loop_load - loop_branch) << 2)));
    if (need_fcvt) try isel.emit(.fcvt(operand_float_ra.s(), operand_mat.ra.h()));
    try operand_mat.finish(isel);
    try ptr_mat.finish(isel);
}

pub fn fail(isel: *Select, comptime format: []const u8, args: anytype) codegen.Error {
    @branchHint(.cold);
    return isel.pt.zcu.codegenFail(isel.nav_index, format, args);
}

/// An invariant that the promotion analysis (`promoteLocals`,
/// `Promotion.pinned_values`) should guarantee does not hold. With promotion,
/// `generate` selects the function again without it, so the program still
/// compiles; compilers with runtime safety stop here instead, since this is a
/// bug in that analysis. Without promotion, this is an ordinary codegen
/// failure.
pub fn promotionBug(isel: *Select, comptime format: []const u8, args: anytype) Error {
    @branchHint(.cold);
    if (!isel.promotion.enabled) return isel.fail(format, args);
    if (std.debug.runtime_safety) std.debug.panic("aarch64 promotion invariant violated in {f}: " ++ format, .{
        isel.pt.zcu.intern_pool.getNav(isel.nav_index).fqn.fmt(&isel.pt.zcu.intern_pool),
    } ++ args);
    return error.RetryWithoutPromotion;
}

/// dst = src
pub fn movImmediate(isel: *Select, dst_reg: Register, src_imm: u64) !void {
    const sf = dst_reg.format.general;
    if (src_imm == 0) {
        const zr: Register = switch (sf) {
            .word => .wzr,
            .doubleword => .xzr,
        };
        return isel.emit(.orr(dst_reg, zr, .{ .register = zr }));
    }

    const Part = u16;
    const min_part: Part = std.math.minInt(Part);
    const max_part: Part = std.math.maxInt(Part);

    const parts: [4]Part = @bitCast(switch (sf) {
        .word => @as(u32, @intCast(src_imm)),
        .doubleword => @as(u64, @intCast(src_imm)),
    });
    const width: u7 = switch (sf) {
        .word => 32,
        .doubleword => 64,
    };
    const parts_len: u3 = @intCast(@divExact(width, @bitSizeOf(Part)));
    var equal_min_count: u3 = 0;
    var equal_max_count: u3 = 0;
    for (parts[0..parts_len]) |part| {
        equal_min_count += @intFromBool(part == min_part);
        equal_max_count += @intFromBool(part == max_part);
    }

    const equal_fill_count, const fill_part: Part = if (equal_min_count >= equal_max_count)
        .{ equal_min_count, min_part }
    else
        .{ equal_max_count, max_part };
    var remaining_parts = @max(parts_len - equal_fill_count, 1);

    if (remaining_parts > 1) {
        if (codegen.aarch64.encoding.Instruction.DataProcessingImmediate.Bitmask.encodeImmediate(src_imm, sf)) |bitmask| {
            return isel.emit(.orr(dst_reg, switch (sf) {
                .word => .wzr,
                .doubleword => .xzr,
            }, .{ .immediate = bitmask }));
        }
    }

    var part_index = parts_len;
    while (part_index > 0) {
        part_index -= 1;
        if (part_index >= remaining_parts and parts[part_index] == fill_part) continue;
        remaining_parts -= 1;
        try isel.emit(if (remaining_parts > 0) .movk(
            dst_reg,
            parts[part_index],
            .{ .lsl = @fromBackingInt(@intCast(part_index)) },
        ) else switch (fill_part) {
            else => unreachable,
            min_part => .movz(
                dst_reg,
                parts[part_index],
                .{ .lsl = @fromBackingInt(@intCast(part_index)) },
            ),
            max_part => .movn(
                dst_reg,
                ~parts[part_index],
                .{ .lsl = @fromBackingInt(@intCast(part_index)) },
            ),
        });
    }
    assert(remaining_parts == 0);
}

/// elem_ptr = base +- elem_size * index
/// elem_ptr, base, and index may alias
fn elemPtr(
    isel: *Select,
    elem_ptr_ra: Register.Alias,
    base_ra: Register.Alias,
    op: codegen.aarch64.encoding.Instruction.AddSubtractOp,
    elem_size: u64,
    index_vi: Value.Index,
) !void {
    const result_lock = isel.tryLockReg(elem_ptr_ra);
    defer result_lock.unlock(isel);
    const index_mat = try index_vi.matReg(isel);
    switch (@popCount(elem_size)) {
        0 => unreachable,
        1 => try isel.emit(switch (op) {
            .add => switch (base_ra) {
                else => .add(elem_ptr_ra.x(), base_ra.x(), .{ .shifted_register = .{
                    .register = index_mat.ra.x(),
                    .shift = .{ .lsl = @intCast(@ctz(elem_size)) },
                } }),
                .zr => switch (@ctz(elem_size)) {
                    0 => .orr(elem_ptr_ra.x(), .xzr, .{ .register = index_mat.ra.x() }),
                    else => |shift| .ubfm(elem_ptr_ra.x(), index_mat.ra.x(), .{
                        .N = .doubleword,
                        .immr = @intCast(64 - shift),
                        .imms = @intCast(63 - shift),
                    }),
                },
            },
            .sub => .sub(elem_ptr_ra.x(), base_ra.x(), .{ .shifted_register = .{
                .register = index_mat.ra.x(),
                .shift = .{ .lsl = @intCast(@ctz(elem_size)) },
            } }),
        }),
        2 => {
            const shift: u6 = @intCast(@ctz(elem_size));
            const temp_ra, const free_temp_ra = temp_ra: switch (op) {
                .add => switch (base_ra) {
                    else => {
                        const temp_ra = try isel.allocIntReg();
                        errdefer isel.freeReg(temp_ra);
                        try isel.emit(.add(elem_ptr_ra.x(), base_ra.x(), .{ .shifted_register = .{
                            .register = temp_ra.x(),
                            .shift = .{ .lsl = shift },
                        } }));
                        break :temp_ra .{ temp_ra, true };
                    },
                    .zr => {
                        if (shift > 0) try isel.emit(.ubfm(elem_ptr_ra.x(), elem_ptr_ra.x(), .{
                            .N = .doubleword,
                            .immr = -%shift,
                            .imms = ~shift,
                        }));
                        break :temp_ra .{ elem_ptr_ra, false };
                    },
                },
                .sub => {
                    const temp_ra = try isel.allocIntReg();
                    errdefer isel.freeReg(temp_ra);
                    try isel.emit(.sub(elem_ptr_ra.x(), base_ra.x(), .{ .shifted_register = .{
                        .register = temp_ra.x(),
                        .shift = .{ .lsl = shift },
                    } }));
                    break :temp_ra .{ temp_ra, true };
                },
            };
            defer if (free_temp_ra) isel.freeReg(temp_ra);
            try isel.emit(.add(temp_ra.x(), index_mat.ra.x(), .{ .shifted_register = .{
                .register = index_mat.ra.x(),
                .shift = .{ .lsl = @intCast(63 - @clz(elem_size) - shift) },
            } }));
        },
        else => {
            const elem_size_lsb1 = (elem_size - 1) | elem_size;
            if ((elem_size_lsb1 +% 1) & elem_size_lsb1 == 0) {
                const shift: u6 = @intCast(@ctz(elem_size));
                const temp_ra = temp_ra: switch (op) {
                    .add => {
                        const temp_ra = try isel.allocIntReg();
                        errdefer isel.freeReg(temp_ra);
                        try isel.emit(.sub(elem_ptr_ra.x(), base_ra.x(), .{ .shifted_register = .{
                            .register = temp_ra.x(),
                            .shift = .{ .lsl = shift },
                        } }));
                        break :temp_ra temp_ra;
                    },
                    .sub => switch (base_ra) {
                        else => {
                            const temp_ra = try isel.allocIntReg();
                            errdefer isel.freeReg(temp_ra);
                            try isel.emit(.add(elem_ptr_ra.x(), base_ra.x(), .{ .shifted_register = .{
                                .register = temp_ra.x(),
                                .shift = .{ .lsl = shift },
                            } }));
                            break :temp_ra temp_ra;
                        },
                        .zr => {
                            if (shift > 0) try isel.emit(.ubfm(elem_ptr_ra.x(), elem_ptr_ra.x(), .{
                                .N = .doubleword,
                                .immr = -%shift,
                                .imms = ~shift,
                            }));
                            break :temp_ra elem_ptr_ra;
                        },
                    },
                };
                defer if (temp_ra != elem_ptr_ra) isel.freeReg(temp_ra);
                try isel.emit(.sub(temp_ra.x(), index_mat.ra.x(), .{ .shifted_register = .{
                    .register = index_mat.ra.x(),
                    .shift = .{ .lsl = @intCast(64 - @clz(elem_size) - shift) },
                } }));
            } else {
                const factor_ra = if (base_ra == elem_ptr_ra) try isel.allocIntReg() else elem_ptr_ra;
                defer if (factor_ra != elem_ptr_ra) isel.freeReg(factor_ra);
                try isel.emit(switch (op) {
                    .add => .madd(elem_ptr_ra.x(), index_mat.ra.x(), factor_ra.x(), base_ra.x()),
                    .sub => .msub(elem_ptr_ra.x(), index_mat.ra.x(), factor_ra.x(), base_ra.x()),
                });
                try isel.movImmediate(factor_ra.x(), elem_size);
            }
        },
    }
    try index_mat.finish(isel);
}

fn normalizeIntReg(isel: *Select, dst: Register.Alias, src: Register.Alias, info: InternPool.Key.IntType) !void {
    assert(info.bits > 0 and info.bits <= 64);
    try isel.emit(switch (info.signedness) {
        .signed => .sbfm(dst.x(), src.x(), .{ .N = .doubleword, .immr = 0, .imms = @intCast(info.bits - 1) }),
        .unsigned => .ubfm(dst.x(), src.x(), .{ .N = .doubleword, .immr = 0, .imms = @intCast(info.bits - 1) }),
    });
}

fn multiplyWithOverflow(
    isel: *Select,
    res_vi: Value.Index,
    overflow_ra: Register.Alias,
    ty: ZigType,
    lhs_ref: Air.Inst.Ref,
    rhs_ref: Air.Inst.Ref,
) !void {
    if (!ty.isAbiInt(isel.pt.zcu)) return isel.fail("unsupported overflowing multiply {f}", .{isel.fmtType(ty)});
    const info = ty.intInfo(isel.pt.zcu);
    if (info.bits > 64 and info.bits <= 128) return isel.multiplyWithOverflowWide(res_vi, overflow_ra, ty, lhs_ref, rhs_ref);
    assert(info.bits > 0);
    if (info.bits > 128) return isel.fail("unsupported overflowing multiply {f}", .{isel.fmtType(ty)});
    const maybe_res_ra = try res_vi.defReg(isel);
    const res_ra = maybe_res_ra orelse try isel.allocIntReg();
    defer if (maybe_res_ra == null) isel.freeReg(res_ra);
    const result_lock = isel.tryLockReg(res_ra);
    defer result_lock.unlock(isel);
    const lo_ra = try isel.allocIntReg();
    defer isel.freeReg(lo_ra);
    const hi_ra = try isel.allocIntReg();
    defer isel.freeReg(hi_ra);
    const lhs_ra = try isel.allocIntReg();
    defer isel.freeReg(lhs_ra);
    const rhs_ra = try isel.allocIntReg();
    defer isel.freeReg(rhs_ra);
    const lhs_mat = try (try isel.use(lhs_ref)).matReg(isel);
    const rhs_mat = try (try isel.use(rhs_ref)).matReg(isel);
    try isel.emit(.csinc(overflow_ra.w(), .wzr, .wzr, .eq));
    try isel.emit(.subs(.xzr, hi_ra.x(), .{ .immediate = 0 }));
    try isel.emit(.orr(hi_ra.x(), hi_ra.x(), .{ .register = lo_ra.x() }));
    try isel.emit(.eor(lo_ra.x(), lo_ra.x(), .{ .register = res_ra.x() }));
    if (info.signedness == .signed) {
        try isel.emit(.eor(hi_ra.x(), hi_ra.x(), .{ .register = lhs_ra.x() }));
        try isel.emit(.sbfm(lhs_ra.x(), res_ra.x(), .{ .N = .doubleword, .immr = 63, .imms = 63 }));
    }
    try isel.normalizeIntReg(res_ra, lo_ra, info);
    try isel.emit(switch (info.signedness) {
        .signed => .smulh(hi_ra.x(), lhs_ra.x(), rhs_ra.x()),
        .unsigned => .umulh(hi_ra.x(), lhs_ra.x(), rhs_ra.x()),
    });
    try isel.emit(.madd(lo_ra.x(), lhs_ra.x(), rhs_ra.x(), .xzr));
    try isel.normalizeIntReg(rhs_ra, rhs_mat.ra, info);
    try isel.normalizeIntReg(lhs_ra, lhs_mat.ra, info);
    try rhs_mat.finish(isel);
    try lhs_mat.finish(isel);
}

fn castIntSafeWide(
    isel: *Select,
    dst_vi: Value.Index,
    dst_ty: ZigType,
    src_ty: ZigType,
    src_ref: Air.Inst.Ref,
    panic_id: Zcu.SimplePanicId,
) !void {
    const dst_info = dst_ty.intInfo(isel.pt.zcu);
    const src_info = src_ty.intInfo(isel.pt.zcu);
    assert(dst_info.bits > 0 and dst_info.bits <= 128 and src_info.bits > 0 and src_info.bits <= 128);
    var dst_lo_it = dst_vi.field(dst_ty, 0, @min(dst_ty.abiSize(isel.pt.zcu), 8));
    const dst_lo_vi = (try dst_lo_it.only(isel)).?;
    const maybe_lo = try dst_lo_vi.defReg(isel);
    const dst_lo = maybe_lo orelse try isel.allocIntReg();
    defer if (maybe_lo == null) isel.freeReg(dst_lo);
    const lo_lock = isel.tryLockReg(dst_lo);
    defer lo_lock.unlock(isel);
    var maybe_hi: ?Register.Alias = null;
    if (dst_info.bits > 64) {
        var dst_hi_it = dst_vi.field(dst_ty, 8, 8);
        maybe_hi = try (try dst_hi_it.only(isel)).?.defReg(isel);
    }
    const dst_hi = maybe_hi orelse try isel.allocIntReg();
    defer if (maybe_hi == null) isel.freeReg(dst_hi);
    const hi_lock = isel.tryLockReg(dst_hi);
    defer hi_lock.unlock(isel);
    const src_lo = try isel.allocIntReg();
    defer isel.freeReg(src_lo);
    const src_hi = try isel.allocIntReg();
    defer isel.freeReg(src_hi);
    const diff = try isel.allocIntReg();
    defer isel.freeReg(diff);
    const temp = try isel.allocIntReg();
    defer isel.freeReg(temp);
    const src_vi = try isel.use(src_ref);
    var src_lo_it = src_vi.field(src_ty, 0, @min(src_ty.abiSize(isel.pt.zcu), 8));
    const src_lo_mat = try (try src_lo_it.only(isel)).?.matReg(isel);
    const src_hi_mat: ?Value.Materialize = if (src_info.bits > 64) mat: {
        var src_hi_it = src_vi.field(src_ty, 8, 8);
        break :mat try (try src_hi_it.only(isel)).?.matReg(isel);
    } else null;
    const skip_label = isel.instructions.items.len;
    try isel.emitPanic(panic_id);
    try isel.emit(.cbz(diff.x(), @intCast((isel.instructions.items.len + 1 - skip_label) << 2)));
    const segment: ForwardSegment = .begin(isel);
    if (src_info.bits <= 64) {
        try isel.normalizeIntReg(src_lo, src_lo_mat.ra, src_info);
        if (src_info.signedness == .signed) {
            try isel.emit(.sbfm(src_hi.x(), src_lo.x(), .{ .N = .doubleword, .immr = 63, .imms = 63 }));
        } else try isel.movImmediate(src_hi.x(), 0);
    } else {
        try isel.emit(.orr(src_lo.x(), .xzr, .{ .register = src_lo_mat.ra.x() }));
        try isel.normalizeIntReg(src_hi, src_hi_mat.?.ra, .{ .bits = src_info.bits - 64, .signedness = src_info.signedness });
    }
    if (dst_info.bits <= 64) {
        try isel.normalizeIntReg(dst_lo, src_lo, dst_info);
        if (dst_info.signedness == .signed) {
            try isel.emit(.sbfm(dst_hi.x(), dst_lo.x(), .{ .N = .doubleword, .immr = 63, .imms = 63 }));
        } else try isel.movImmediate(dst_hi.x(), 0);
    } else {
        try isel.emit(.orr(dst_lo.x(), .xzr, .{ .register = src_lo.x() }));
        try isel.normalizeIntReg(dst_hi, src_hi, .{ .bits = dst_info.bits - 64, .signedness = dst_info.signedness });
    }
    try isel.emit(.eor(diff.x(), src_lo.x(), .{ .register = dst_lo.x() }));
    try isel.emit(.eor(temp.x(), src_hi.x(), .{ .register = dst_hi.x() }));
    try isel.emit(.orr(diff.x(), diff.x(), .{ .register = temp.x() }));
    if (src_info.signedness != dst_info.signedness) {
        const sign_ra = if (src_info.signedness == .signed) src_hi else if (dst_info.bits > 64) dst_hi else dst_lo;
        try isel.emit(.ubfm(temp.x(), sign_ra.x(), .{ .N = .doubleword, .immr = 63, .imms = 63 }));
        try isel.emit(.orr(diff.x(), diff.x(), .{ .register = temp.x() }));
    }
    segment.end(isel);
    if (src_hi_mat) |mat| try mat.finish(isel);
    try src_lo_mat.finish(isel);
}

fn multiplyWithOverflowWide(
    isel: *Select,
    res_vi: Value.Index,
    overflow_ra: Register.Alias,
    ty: ZigType,
    lhs_ref: Air.Inst.Ref,
    rhs_ref: Air.Inst.Ref,
) !void {
    const info = ty.intInfo(isel.pt.zcu);
    var lo_it = res_vi.field(ty, 0, 8);
    var hi_it = res_vi.field(ty, 8, 8);
    const lo_vi = (try lo_it.only(isel)).?;
    const hi_vi = (try hi_it.only(isel)).?;
    const maybe_lo = try lo_vi.defReg(isel);
    const lo = maybe_lo orelse try isel.allocIntReg();
    defer if (maybe_lo == null) isel.freeReg(lo);
    const lo_lock = isel.tryLockReg(lo);
    defer lo_lock.unlock(isel);
    const maybe_hi = try hi_vi.defReg(isel);
    const hi = maybe_hi orelse try isel.allocIntReg();
    defer if (maybe_hi == null) isel.freeReg(hi);
    const hi_lock = isel.tryLockReg(hi);
    defer hi_lock.unlock(isel);
    var scratch: [7]Register.Alias = undefined;
    var allocated: usize = 0;
    defer for (scratch[0..allocated]) |ra| isel.freeReg(ra);
    for (scratch[0..if (info.bits == 128) 5 else 7]) |*ra| {
        ra.* = try isel.allocIntReg();
        allocated += 1;
    }
    const p1 = scratch[0].x();
    const p2 = scratch[1].x();
    const p3 = scratch[2].x();
    const t0 = scratch[3].x();
    const t1 = scratch[4].x();
    const lhs_vi = try isel.use(lhs_ref);
    const rhs_vi = try isel.use(rhs_ref);
    var lhs_lo_it = lhs_vi.field(ty, 0, 8);
    var lhs_hi_it = lhs_vi.field(ty, 8, 8);
    var rhs_lo_it = rhs_vi.field(ty, 0, 8);
    var rhs_hi_it = rhs_vi.field(ty, 8, 8);
    const lhs_lo = try (try lhs_lo_it.only(isel)).?.matReg(isel);
    const lhs_hi = try (try lhs_hi_it.only(isel)).?.matReg(isel);
    const rhs_lo = try (try rhs_lo_it.only(isel)).?.matReg(isel);
    const rhs_hi = try (try rhs_hi_it.only(isel)).?.matReg(isel);
    const a0 = lhs_lo.ra.x();
    const a1_ra = if (info.bits == 128) lhs_hi.ra else scratch[5];
    const a1 = a1_ra.x();
    const b0 = rhs_lo.ra.x();
    const b1_ra = if (info.bits == 128) rhs_hi.ra else scratch[6];
    const b1 = b1_ra.x();
    const segment: ForwardSegment = .begin(isel);
    if (info.bits < 128) {
        try isel.normalizeIntReg(a1_ra, lhs_hi.ra, .{ .bits = info.bits - 64, .signedness = info.signedness });
        try isel.normalizeIntReg(b1_ra, rhs_hi.ra, .{ .bits = info.bits - 64, .signedness = info.signedness });
    }
    try isel.emit(.madd(lo.x(), a0, b0, .xzr));
    try isel.emit(.umulh(p1, a0, b0));
    try isel.emit(.madd(t0, a0, b1, .xzr));
    try isel.emit(.umulh(t1, a0, b1));
    try isel.emit(.adds(p1, p1, .{ .register = t0 }));
    try isel.emit(.adc(p2, t1, .xzr));
    try isel.emit(.madd(t0, a1, b0, .xzr));
    try isel.emit(.umulh(t1, a1, b0));
    try isel.emit(.adds(p1, p1, .{ .register = t0 }));
    try isel.emit(.adcs(p2, p2, t1));
    try isel.emit(.adc(p3, .xzr, .xzr));
    try isel.emit(.madd(t0, a1, b1, .xzr));
    try isel.emit(.umulh(t1, a1, b1));
    try isel.emit(.adds(p2, p2, .{ .register = t0 }));
    try isel.emit(.adc(p3, p3, t1));
    if (info.signedness == .signed) {
        // Convert the unsigned 256-bit product of two's-complement limbs.
        try isel.emit(.sbfm(t0, a1, .{ .N = .doubleword, .immr = 63, .imms = 63 }));
        try isel.emit(.@"and"(t1, b0, .{ .register = t0 }));
        try isel.emit(.@"and"(t0, b1, .{ .register = t0 }));
        try isel.emit(.subs(p2, p2, .{ .register = t1 }));
        try isel.emit(.sbc(p3, p3, t0));
        try isel.emit(.sbfm(t0, b1, .{ .N = .doubleword, .immr = 63, .imms = 63 }));
        try isel.emit(.@"and"(t1, a0, .{ .register = t0 }));
        try isel.emit(.@"and"(t0, a1, .{ .register = t0 }));
        try isel.emit(.subs(p2, p2, .{ .register = t1 }));
        try isel.emit(.sbc(p3, p3, t0));
    }
    try isel.normalizeIntReg(hi, scratch[0], .{ .bits = info.bits - 64, .signedness = info.signedness });
    try isel.emit(.eor(p1, p1, .{ .register = hi.x() }));
    if (info.signedness == .signed) {
        try isel.emit(.sbfm(t0, hi.x(), .{ .N = .doubleword, .immr = 63, .imms = 63 }));
        try isel.emit(.eor(p2, p2, .{ .register = t0 }));
        try isel.emit(.eor(p3, p3, .{ .register = t0 }));
    }
    try isel.emit(.orr(p1, p1, .{ .register = p2 }));
    try isel.emit(.orr(p1, p1, .{ .register = p3 }));
    try isel.emit(.subs(.xzr, p1, .{ .immediate = 0 }));
    try isel.emit(.csinc(overflow_ra.w(), .wzr, .wzr, .eq));
    segment.end(isel);
    try rhs_hi.finish(isel);
    try rhs_lo.finish(isel);
    try lhs_hi.finish(isel);
    try lhs_lo.finish(isel);
}

fn shiftSaturating(isel: *Select, res_vi: Value.Index, ty: ZigType, lhs_ref: Air.Inst.Ref, rhs_ref: Air.Inst.Ref) !void {
    const zcu = isel.pt.zcu;
    const rhs_ty = isel.air.typeOf(rhs_ref, &zcu.intern_pool);
    if (!ty.isAbiInt(zcu) or !rhs_ty.isAbiInt(zcu)) return isel.fail(
        "unsupported saturating shift {f} by {f}",
        .{ isel.fmtType(ty), isel.fmtType(rhs_ty) },
    );
    const info = ty.intInfo(zcu);
    const rhs_info = rhs_ty.intInfo(zcu);
    assert(info.bits > 0 and rhs_info.bits > 0 and rhs_info.signedness == .unsigned);
    // Legalize expands this into `shl_with_overflow` (`soft_big_int`).
    if (info.bits > 64) return isel.fail("too big shl_sat {f}", .{isel.fmtType(ty)});
    if (rhs_info.bits > Value.max_parts * 64) return isel.fail(
        "unsupported saturating shift {f} by {f}",
        .{ isel.fmtType(ty), isel.fmtType(rhs_ty) },
    );
    const res_ra = try res_vi.defReg(isel) orelse return;
    const result_lock = isel.tryLockReg(res_ra);
    defer result_lock.unlock(isel);
    const lhs_ra = try isel.allocIntReg();
    defer isel.freeReg(lhs_ra);
    const count_ra = try isel.allocIntReg();
    defer isel.freeReg(count_ra);
    const roundtrip_ra = try isel.allocIntReg();
    defer isel.freeReg(roundtrip_ra);
    const limit_ra = try isel.allocIntReg();
    defer isel.freeReg(limit_ra);
    const lhs_mat = try (try isel.use(lhs_ref)).matReg(isel);
    const rhs_vi = try isel.use(rhs_ref);
    var rhs_lo_it = rhs_vi.field(rhs_ty, 0, 8);
    const rhs_mat = if (rhs_info.bits > 64) try (try rhs_lo_it.only(isel)).?.matReg(isel) else try rhs_vi.matReg(isel);
    // Variable shifts mask their amount. Test the original amount separately,
    // and preserve zero even when an oversized shift would otherwise saturate.
    try isel.emit(.csel(res_ra.x(), .xzr, res_ra.x(), .eq));
    try isel.emit(.subs(.xzr, lhs_ra.x(), .{ .immediate = 0 }));
    try isel.emit(.csel(res_ra.x(), res_ra.x(), limit_ra.x(), .lo));
    try isel.emit(.subs(.xzr, count_ra.x(), .{ .immediate = @intCast(info.bits) }));
    try isel.emit(.csel(res_ra.x(), res_ra.x(), limit_ra.x(), .eq));
    try isel.emit(.subs(.xzr, roundtrip_ra.x(), .{ .register = lhs_ra.x() }));
    try isel.emit(switch (info.signedness) {
        .signed => .asrv(roundtrip_ra.x(), res_ra.x(), count_ra.x()),
        .unsigned => .lsrv(roundtrip_ra.x(), res_ra.x(), count_ra.x()),
    });
    try isel.normalizeIntReg(res_ra, res_ra, info);
    try isel.emit(.lslv(res_ra.x(), lhs_ra.x(), count_ra.x()));
    switch (info.signedness) {
        .unsigned => try isel.movImmediate(limit_ra.x(), @as(u64, std.math.maxInt(u64)) >> @intCast(64 - info.bits)),
        .signed => {
            try isel.emit(.eor(limit_ra.x(), limit_ra.x(), .{ .register = roundtrip_ra.x() }));
            try isel.movImmediate(roundtrip_ra.x(), (@as(u64, 1) << @intCast(info.bits - 1)) - 1);
            try isel.emit(.asrv(limit_ra.x(), lhs_ra.x(), roundtrip_ra.x()));
            try isel.movImmediate(roundtrip_ra.x(), 63);
        },
    }
    if (rhs_info.bits > 64) {
        // Any nonzero high limb makes the amount at least `info.bits`.
        try isel.emit(.csinv(count_ra.x(), count_ra.x(), .xzr, .eq));
        try isel.emit(.subs(.xzr, roundtrip_ra.x(), .{ .immediate = 0 }));
        const limbs = std.math.divCeil(u16, rhs_info.bits, 64) catch unreachable;
        var index = limbs;
        while (index > 1) {
            index -= 1;
            var part_it = rhs_vi.field(rhs_ty, 8 * @as(u64, index), 8);
            const part_mat = try (try part_it.only(isel)).?.matReg(isel);
            try isel.emit(.orr(
                roundtrip_ra.x(),
                if (index == 1) .xzr else roundtrip_ra.x(),
                .{ .register = part_mat.ra.x() },
            ));
            try part_mat.finish(isel);
        }
        try isel.emit(.orr(count_ra.x(), .xzr, .{ .register = rhs_mat.ra.x() }));
    } else try isel.normalizeIntReg(count_ra, rhs_mat.ra, rhs_info);
    try isel.normalizeIntReg(lhs_ra, lhs_mat.ra, info);
    try rhs_mat.finish(isel);
    try lhs_mat.finish(isel);
}

fn shiftWithOverflow(
    isel: *Select,
    res_vi: Value.Index,
    overflow_ra: Register.Alias,
    ty: ZigType,
    lhs_ref: Air.Inst.Ref,
    rhs_ref: Air.Inst.Ref,
) !void {
    if (!ty.isAbiInt(isel.pt.zcu)) return isel.fail("unsupported overflowing shift {f}", .{isel.fmtType(ty)});
    const info = ty.intInfo(isel.pt.zcu);
    assert(info.bits > 0);
    if (info.bits > 64) return isel.fail("unsupported overflowing shift {f}", .{isel.fmtType(ty)});
    const maybe_res_ra = try res_vi.defReg(isel);
    const res_ra = maybe_res_ra orelse try isel.allocIntReg();
    defer if (maybe_res_ra == null) isel.freeReg(res_ra);
    const result_lock = isel.tryLockReg(res_ra);
    defer result_lock.unlock(isel);
    if (info.bits == 1) {
        try isel.movImmediate(overflow_ra.w(), 0);
        const lhs_mat = try (try isel.use(lhs_ref)).matReg(isel);
        try isel.normalizeIntReg(res_ra, lhs_mat.ra, info);
        try lhs_mat.finish(isel);
        return;
    }
    const lhs_ra = try isel.allocIntReg();
    defer isel.freeReg(lhs_ra);
    const roundtrip_ra = try isel.allocIntReg();
    defer isel.freeReg(roundtrip_ra);
    const lhs_mat = try (try isel.use(lhs_ref)).matReg(isel);
    const rhs_mat = try (try isel.use(rhs_ref)).matReg(isel);
    try isel.emit(.csinc(overflow_ra.w(), .wzr, .wzr, .eq));
    try isel.emit(.subs(.xzr, roundtrip_ra.x(), .{ .register = lhs_ra.x() }));
    try isel.emit(switch (info.signedness) {
        .signed => .asrv(roundtrip_ra.x(), res_ra.x(), rhs_mat.ra.x()),
        .unsigned => .lsrv(roundtrip_ra.x(), res_ra.x(), rhs_mat.ra.x()),
    });
    try isel.normalizeIntReg(res_ra, res_ra, info);
    try isel.emit(.lslv(res_ra.x(), lhs_ra.x(), rhs_mat.ra.x()));
    try isel.normalizeIntReg(lhs_ra, lhs_mat.ra, info);
    try rhs_mat.finish(isel);
    try lhs_mat.finish(isel);
}

fn remainderWide(isel: *Select, res_vi: Value.Index, ty: ZigType, lhs_ref: Air.Inst.Ref, rhs_ref: Air.Inst.Ref, modulo: bool) !void {
    const zcu = isel.pt.zcu;
    const info = ty.intInfo(zcu);
    const adjust = modulo and info.signedness == .signed;
    try call.prepareReturn(isel);
    var res_hi_it = res_vi.field(ty, 8, 8);
    try call.returnLiveIn(isel, (try res_hi_it.only(isel)).?, .r1);
    var res_lo_it = res_vi.field(ty, 0, 8);
    try call.returnLiveIn(isel, (try res_lo_it.only(isel)).?, .r0);
    const rhs_vi = try isel.use(rhs_ref);
    if (adjust) {
        try call.returnFill(isel, .r2);
        try call.returnFill(isel, .r3);
        var rhs_lo_it = rhs_vi.field(ty, 0, 8);
        var rhs_hi_it = rhs_vi.field(ty, 8, 8);
        const rhs_lo = try (try rhs_lo_it.only(isel)).?.matReg(isel);
        const rhs_hi = try (try rhs_hi_it.only(isel)).?.matReg(isel);
        // Add the denominator only for a nonzero remainder of opposite sign.
        try isel.emit(.adc(.x1, .x1, .x3));
        try isel.emit(.adds(.x0, .x0, .{ .register = .x2 }));
        try isel.emit(.csel(.x3, .x3, .xzr, .mi));
        try isel.emit(.csel(.x2, rhs_lo.ra.x(), .xzr, .mi));
        try isel.emit(.ccmp(.x2, .{ .immediate = 0 }, .{ .n = false, .z = false, .c = false, .v = false }, .ne));
        try isel.emit(.eor(.x2, .x1, .{ .register = .x3 }));
        try isel.emit(.subs(.xzr, .x2, .{ .immediate = 0 }));
        try isel.emit(.orr(.x2, .x0, .{ .register = .x1 }));
        try isel.normalizeIntReg(.r3, rhs_hi.ra, .{ .bits = info.bits - 64, .signedness = .signed });
        try rhs_hi.finish(isel);
        try rhs_lo.finish(isel);
    }
    try call.finishReturn(isel);
    try call.prepareCallee(isel);
    try call.global(isel, if (info.signedness == .signed) "__modti3" else "__umodti3");
    try call.finishCallee(isel);
    try call.prepareParams(isel);
    if (info.bits < 128) try isel.normalizeIntReg(.r3, .r3, .{ .bits = info.bits - 64, .signedness = info.signedness });
    var rhs_hi_it = rhs_vi.field(ty, 8, 8);
    try call.paramLiveOut(isel, (try rhs_hi_it.only(isel)).?, .r3);
    var rhs_lo_it = rhs_vi.field(ty, 0, 8);
    try call.paramLiveOut(isel, (try rhs_lo_it.only(isel)).?, .r2);
    const lhs_vi = try isel.use(lhs_ref);
    if (info.bits < 128) try isel.normalizeIntReg(.r1, .r1, .{ .bits = info.bits - 64, .signedness = info.signedness });
    var lhs_hi_it = lhs_vi.field(ty, 8, 8);
    try call.paramLiveOut(isel, (try lhs_hi_it.only(isel)).?, .r1);
    var lhs_lo_it = lhs_vi.field(ty, 0, 8);
    try call.paramLiveOut(isel, (try lhs_lo_it.only(isel)).?, .r0);
    try call.finishParams(isel);
}

fn divideRoundedWide(isel: *Select, res_vi: Value.Index, ty: ZigType, lhs_ref: Air.Inst.Ref, rhs_ref: Air.Inst.Ref, ceiling: bool) !void {
    const zcu = isel.pt.zcu;
    const int_info = ty.intInfo(zcu);
    const signedness = int_info.signedness;
    try isel.values.ensureUnusedCapacity(zcu.gpa, 1);
    const rem_vi = isel.initValue(.u128).ref(isel);
    defer rem_vi.deref(isel);
    const rem_slot = rem_vi.allocStackSlot(isel);
    rem_vi.setParent(isel, .{ .stack_slot = rem_slot });

    try call.prepareReturn(isel);
    var res_hi_it = res_vi.field(ty, 8, 8);
    try call.returnLiveIn(isel, (try res_hi_it.only(isel)).?, .r1);
    var res_lo_it = res_vi.field(ty, 0, 8);
    try call.returnLiveIn(isel, (try res_lo_it.only(isel)).?, .r0);
    try call.returnFill(isel, .r2);
    try call.returnFill(isel, .r3);
    try call.returnFill(isel, .r4);
    const rhs_vi = try isel.use(rhs_ref);
    const rhs_hi_mat: ?Value.Materialize = if (signedness == .signed) mat: {
        var rhs_hi_it = rhs_vi.field(ty, 8, 8);
        break :mat try (try rhs_hi_it.only(isel)).?.matReg(isel);
    } else null;
    try isel.emit(if (ceiling) .adc(.x1, .x1, .xzr) else .sbc(.x1, .x1, .xzr));
    try isel.emit(if (ceiling) .adds(.x0, .x0, .{ .register = .x4 }) else .subs(.x0, .x0, .{ .register = .x4 }));
    try isel.emit(.csinc(.x4, .xzr, .xzr, if (signedness == .signed) (if (ceiling) .mi else .pl) else .eq));
    if (rhs_hi_mat) |mat| {
        try isel.emit(.ccmp(.x3, .{ .immediate = 0 }, .{ .n = ceiling, .z = false, .c = false, .v = false }, .ne));
        try isel.emit(.eor(.x3, .x3, .{ .register = .x4 }));
        try isel.emit(.sbfm(.x4, mat.ra.x(), .{ .N = .doubleword, .immr = 0, .imms = @intCast(int_info.bits - 65) }));
    }
    try isel.emit(.subs(.xzr, .x2, .{ .immediate = 0 }));
    try isel.emit(.orr(.x2, .x2, .{ .register = .x3 }));
    try isel.loadReg(.r3, 8, .unsigned, rem_slot.base, rem_slot.offset + 8);
    try isel.loadReg(.r2, 8, .unsigned, rem_slot.base, rem_slot.offset);
    if (rhs_hi_mat) |mat| try mat.finish(isel);
    try call.finishReturn(isel);

    try call.prepareCallee(isel);
    try call.global(isel, if (signedness == .signed) "__divmodti4" else "__udivmodti4");
    try call.finishCallee(isel);

    try call.prepareParams(isel);
    try call.paramAddress(isel, rem_vi, .r4);
    if (int_info.bits < 128) try isel.emit(switch (signedness) {
        .signed => .sbfm(.x3, .x3, .{ .N = .doubleword, .immr = 0, .imms = @intCast(int_info.bits - 65) }),
        .unsigned => .ubfm(.x3, .x3, .{ .N = .doubleword, .immr = 0, .imms = @intCast(int_info.bits - 65) }),
    });
    var rhs_hi_it = rhs_vi.field(ty, 8, 8);
    try call.paramLiveOut(isel, (try rhs_hi_it.only(isel)).?, .r3);
    var rhs_lo_it = rhs_vi.field(ty, 0, 8);
    try call.paramLiveOut(isel, (try rhs_lo_it.only(isel)).?, .r2);
    const lhs_vi = try isel.use(lhs_ref);
    if (int_info.bits < 128) try isel.emit(switch (signedness) {
        .signed => .sbfm(.x1, .x1, .{ .N = .doubleword, .immr = 0, .imms = @intCast(int_info.bits - 65) }),
        .unsigned => .ubfm(.x1, .x1, .{ .N = .doubleword, .immr = 0, .imms = @intCast(int_info.bits - 65) }),
    });
    var lhs_hi_it = lhs_vi.field(ty, 8, 8);
    try call.paramLiveOut(isel, (try lhs_hi_it.only(isel)).?, .r1);
    var lhs_lo_it = lhs_vi.field(ty, 0, 8);
    try call.paramLiveOut(isel, (try lhs_lo_it.only(isel)).?, .r0);
    try call.finishParams(isel);
}

fn bitCastIsContiguous(isel: *Select, ty: ZigType) bool {
    const zcu = isel.pt.zcu;
    if (ty.bitSize(zcu) != 8 * ty.abiSize(zcu)) return false;
    return switch (ty.zigTypeTag(zcu)) {
        // Arrays use the ABI stride of each element; inspect nested arrays too.
        .array => isel.bitCastIsContiguous(ty.childType(zcu)),
        // Hard vector lanes share bytes, independently of scalar ABI padding.
        .vector => isel.vectorLaneBits(ty.childType(zcu)) == ty.childType(zcu).bitSize(zcu),
        else => ty.isAbiInt(zcu) or ty.isRuntimeFloat(),
    };
}

fn bitCastContiguous(isel: *Select, dst_vi: Value.Index, dst_ty: ZigType, src_vi: Value.Index, src_ty: ZigType) !void {
    const zcu = isel.pt.zcu;
    assert(dst_ty.bitSize(zcu) == src_ty.bitSize(zcu));
    if (isel.target.cpu.arch.endian() != .little)
        return isel.fail("logical aggregate bitcast on big endian target", .{});
    const wrap: ?std.lang.Type.Int = if (dst_ty.isAbiInt(zcu)) dst_ty.intInfo(zcu) else null;
    try dst_vi.defAddr(isel, dst_ty, .{ .wrap = wrap }) orelse return;
    // The unsigned intermediate created by Legalize can have ABI padding.
    // Copy only logical bytes, then canonicalize integer output registers.
    const size = @divExact(dst_ty.bitSize(zcu), 8);
    if (try isel.copyInline(.{ .value = .{ .vi = dst_vi } }, .{ .value = .{ .vi = src_vi } }, size, false)) return;
    try call.prepareVoidGlobal(isel, "memcpy");
    try isel.movImmediate(.x2, size);
    try call.paramAddress(isel, src_vi, .r1);
    try call.paramAddress(isel, dst_vi, .r0);
    try call.finishParams(isel);
}

fn bitCastInteger(isel: *Select, dst_vi: Value.Index, dst_ty: ZigType, src_vi: Value.Index, src_ty: ZigType) !void {
    if (isel.target.cpu.arch.endian() != .little)
        return isel.fail("wide backing-integer conversion on big endian target", .{});
    const zcu = isel.pt.zcu;
    const info = dst_ty.intInfo(zcu);
    assert(info.bits == src_ty.intInfo(zcu).bits);
    const top_offset = @as(u64, (info.bits - 1) / 64) * 8;
    const top_bits: u16 = info.bits - @as(u16, @intCast(top_offset * 8));
    var dst_top_it = dst_vi.field(dst_ty, top_offset, 8);
    const dst_top_vi = (try dst_top_it.only(isel)).?;
    const dst_top_ra = try dst_top_vi.defReg(isel);
    const top_lock = if (dst_top_ra) |ra| isel.tryLockReg(ra) else RegLock.empty;
    defer top_lock.unlock(isel);
    if (dst_top_ra) |ra| {
        var src_top_it = src_vi.field(src_ty, top_offset, 8);
        const src_top_mat = try (try src_top_it.only(isel)).?.matReg(isel);
        const use_work = ra.isVector();
        const work_ra = if (use_work) try isel.allocIntReg() else ra;
        defer if (use_work) isel.freeReg(work_ra);
        if (ra.isVector()) try isel.emit(.fmov(ra.d(), .{ .register = work_ra.x() }));
        // Only the logical top bits survive a backing-integer conversion.
        // Its sign follows the destination type, independently of source padding.
        try isel.normalizeIntReg(work_ra, if (src_top_mat.ra.isVector()) work_ra else src_top_mat.ra, .{
            .bits = top_bits,
            .signedness = info.signedness,
        });
        if (src_top_mat.ra.isVector()) try isel.emit(.fmov(work_ra.x(), .{ .register = src_top_mat.ra.d() }));
        try src_top_mat.finish(isel);
    }
    try dst_vi.copyField(isel, dst_ty, 0, src_vi, src_ty, 0, top_offset);
}

fn intFromFloatWide(isel: *Select, dst_vi: Value.Index, dst_ty: ZigType, src_ty: ZigType, operand: Air.Inst.Ref) !void {
    if (isel.target.cpu.arch.endian() != .little) return isel.fail("wide float conversion on big endian target", .{});
    const info = dst_ty.intInfo(isel.pt.zcu);
    if (info.bits > Value.max_parts * 64) return isel.fail(
        "unsupported wide float-to-integer conversion {f} to {f}",
        .{ isel.fmtType(src_ty), isel.fmtType(dst_ty) },
    );
    try dst_vi.defAddr(isel, dst_ty, .{ .wrap = info }) orelse return;
    try call.prepareReturn(isel);
    try call.finishReturn(isel);
    try call.prepareCallee(isel);
    const bits = src_ty.floatBits(isel.target);
    try call.global(isel, switch (info.signedness) {
        .signed => switch (bits) {
            16 => "__fixhfei",
            32 => "__fixsfei",
            64 => "__fixdfei",
            80 => "__fixxfei",
            128 => "__fixtfei",
            else => unreachable,
        },
        .unsigned => switch (bits) {
            16 => "__fixunshfei",
            32 => "__fixunssfei",
            64 => "__fixunsdfei",
            80 => "__fixunsxfei",
            128 => "__fixunstfei",
            else => unreachable,
        },
    });
    try call.finishCallee(isel);
    try call.prepareParams(isel);
    const src_vi = try isel.use(operand);
    // The soft compiler-rt ABI is a 16-byte integer pair. The pointer and
    // bit count occupy x0/x1, so the aligned pair starts at x2/x3.
    if (call.softF128(isel, bits)) {
        try call.paramSoftF128(isel, .v0, .r2);
        try call.paramLiveOut(isel, src_vi, .v0);
    } else if (std.zig.target.compilerRtFloatAbi(isel.target, bits) == .soft) {
        assert(bits == 80);
        var high_it = src_vi.field(src_ty, 8, 8);
        try call.paramLiveOut(isel, (try high_it.only(isel)).?, .r3);
        var low_it = src_vi.field(src_ty, 0, 8);
        try call.paramLiveOut(isel, (try low_it.only(isel)).?, .r2);
    } else try call.paramLiveOut(isel, src_vi, .v0);
    try isel.movImmediate(.x1, info.bits);
    try call.paramAddress(isel, dst_vi, .r0);
    try call.finishParams(isel);
}

fn floatFromIntWide(isel: *Select, dst_vi: Value.Index, dst_ty: ZigType, src_ty: ZigType, operand: Air.Inst.Ref) !void {
    if (isel.target.cpu.arch.endian() != .little) return isel.fail("wide float conversion on big endian target", .{});
    const zcu = isel.pt.zcu;
    const info = src_ty.intInfo(zcu);
    // FieldPartIterator represents at most max_parts 64-bit integer limbs.
    if (info.bits > Value.max_parts * 64) return isel.fail(
        "unsupported wide integer-to-float conversion {f} to {f}",
        .{ isel.fmtType(src_ty), isel.fmtType(dst_ty) },
    );
    const buffer_ty = try isel.pt.intType(info.signedness, @intCast(8 * src_ty.abiSize(zcu)));
    try isel.values.ensureUnusedCapacity(zcu.gpa, 1);
    const buffer_vi = isel.initValue(buffer_ty).ref(isel);
    defer buffer_vi.deref(isel);
    const buffer_slot = buffer_vi.allocStackSlot(isel);
    buffer_vi.setParent(isel, .{ .stack_slot = buffer_slot });
    const bits = dst_ty.floatBits(isel.target);
    try call.prepareReturn(isel);
    if (std.zig.target.compilerRtFloatAbi(isel.target, bits) == .soft and !call.softF128(isel, bits)) {
        assert(bits == 80);
        var high_it = dst_vi.field(dst_ty, 8, 8);
        try call.returnLiveIn(isel, (try high_it.only(isel)).?, .r1);
        var low_it = dst_vi.field(dst_ty, 0, 8);
        try call.returnLiveIn(isel, (try low_it.only(isel)).?, .r0);
    } else try call.returnLiveIn(isel, dst_vi, .v0);
    try call.finishReturn(isel);
    try call.returnSoftF128(isel, bits);
    try call.prepareCallee(isel);
    try call.global(isel, switch (info.signedness) {
        .signed => switch (bits) {
            16 => "__floateihf",
            32 => "__floateisf",
            64 => "__floateidf",
            80 => "__floateixf",
            128 => "__floateitf",
            else => unreachable,
        },
        .unsigned => switch (bits) {
            16 => "__floatuneihf",
            32 => "__floatuneisf",
            64 => "__floatuneidf",
            80 => "__floatuneixf",
            128 => "__floatuneitf",
            else => unreachable,
        },
    });
    try call.finishCallee(isel);
    try call.prepareParams(isel);
    try isel.movImmediate(.x1, info.bits);
    try call.paramAddress(isel, buffer_vi, .r0);
    try isel.storeExtendedInteger(try isel.use(operand), src_ty, buffer_slot);
    try call.finishParams(isel);
}

fn storeExtendedInteger(isel: *Select, src_vi: Value.Index, ty: ZigType, slot: Value.Indirect) !void {
    const zcu = isel.pt.zcu;
    const info = ty.intInfo(zcu);
    const limbs = std.math.divCeil(u64, info.bits, 64) catch unreachable;
    const high_bits: u16 = @intCast(info.bits - 64 * (limbs - 1));
    // Generic compiler-rt conversions consume the entire rounded ABI span.
    // Initialize its padding with canonical zero/sign extension, not stale bytes.
    for (0..@intCast(ty.abiSize(zcu) / 8)) |index| {
        const work_ra = try isel.allocIntReg();
        defer isel.freeReg(work_ra);
        const source_index = @min(index, limbs - 1);
        var field_it = src_vi.field(ty, 8 * source_index, 8);
        const src_mat = try (try field_it.only(isel)).?.matReg(isel);
        try isel.storeReg(work_ra, 8, slot.base, slot.offset + @as(i65, @intCast(8 * index)));
        if (index >= limbs) {
            switch (info.signedness) {
                .unsigned => try isel.movImmediate(work_ra.x(), 0),
                .signed => try isel.emit(.sbfm(work_ra.x(), src_mat.ra.x(), .{
                    .N = .doubleword,
                    .immr = @intCast(high_bits - 1),
                    .imms = @intCast(high_bits - 1),
                })),
            }
        } else try isel.normalizeIntReg(work_ra, src_mat.ra, .{
            .bits = if (index + 1 == limbs) high_bits else 64,
            .signedness = info.signedness,
        });
        try src_mat.finish(isel);
    }
}

/// The info of an integer above 128 bits, which is handled limb by limb in
/// memory, as long as its value has no more than `Value.max_parts` limbs.
fn wideIntInfo(isel: *Select, what: []const u8, ty: ZigType) !std.lang.Type.Int {
    if (isel.target.cpu.arch.endian() != .little) return isel.fail("wide integer {s} on big endian target", .{what});
    const info = ty.intInfo(isel.pt.zcu);
    if (info.bits > Value.max_parts * 64) return isel.fail("unsupported wide integer {s} {f}", .{ what, isel.fmtType(ty) });
    return info;
}

/// Integer casts (`int_cast`, `int_cast_safe`, `trunc`) where an operand is
/// above 128 bits, limb by limb through memory (operands of at most 64 bits
/// stay in registers). The result's padding limbs are written canonically.
/// With `panic_id`, a value that does not survive the round trip panics.
fn castIntWide(
    isel: *Select,
    dst_vi: Value.Index,
    dst_ty: ZigType,
    src_ty: ZigType,
    src_ref: Air.Inst.Ref,
    panic_id: ?Zcu.SimplePanicId,
) !void {
    const zcu = isel.pt.zcu;
    const dst_info = try isel.wideIntInfo("cast", dst_ty);
    const src_info = try isel.wideIntInfo("cast", src_ty);
    const dst_small = dst_info.bits <= 64;
    const src_small = src_info.bits <= 64;
    const dst_ra: ?Register.Alias = if (dst_small) try dst_vi.defReg(isel) else null;
    const dst_lock = if (dst_ra) |ra| isel.lockReg(ra) else RegLock.empty;
    defer dst_lock.unlock(isel);
    const dst_used = if (dst_small) dst_ra != null else dst_vi.isUsed(isel);
    if (!dst_used and panic_id == null) return;
    if (dst_used and !dst_small) try dst_vi.defAddr(isel, dst_ty, .{ .wrap = dst_info }) orelse unreachable;
    const src_limbs: u16 = std.math.divCeil(u16, src_info.bits, 64) catch unreachable;
    const dst_limbs: u16 = std.math.divCeil(u16, dst_info.bits, 64) catch unreachable;
    const dst_abi_limbs: u16 = if (dst_small) 1 else @intCast(@divExact(dst_ty.abiSize(zcu), 8));
    const dst_top = dst_limbs - 1;
    const dst_top_bits: u16 = dst_info.bits - 64 * dst_top;

    var regs: [7]Register.Alias = undefined;
    for (&regs, 0..) |*ra, index| {
        errdefer for (regs[0..index]) |allocated_ra| isel.freeReg(allocated_ra);
        ra.* = try isel.allocIntReg();
    }
    // An indirect operand's pointer can end up live in `src_ptr` or `dst_ptr`
    // (for example an incoming argument); only free a plain scratch.
    defer for (regs) |ra| if (isel.live_registers.get(ra) == .allocating) isel.freeReg(ra);
    const src_ptr, const dst_ptr, const limb, const top, const fill_ra, const diff, const copy = regs;
    const src_vi = try isel.use(src_ref);
    const src_mat: ?Value.Materialize = if (src_small) try src_vi.matReg(isel) else null;

    if (panic_id) |id| {
        const skip_label = isel.instructions.items.len;
        try isel.emitPanic(id);
        try isel.emit(.cbz(diff.x(), @intCast((isel.instructions.items.len + 1 - skip_label) << 2)));
    }
    const segment: ForwardSegment = .begin(isel);
    const Limbs = struct {
        isel: *Select,
        src_ptr: Register.Alias,
        src_mat: ?Value.Materialize,
        src_info: std.lang.Type.Int,
        /// Loads source limb `index`, which is canonically extended.
        fn load(limbs: @This(), ra: Register.Alias, index: u16) !void {
            if (limbs.src_mat) |mat| {
                assert(index == 0);
                try limbs.isel.normalizeIntReg(ra, mat.ra, limbs.src_info);
            } else try limbs.isel.loadReg(ra, 8, .unsigned, limbs.src_ptr, 8 * @as(i65, index));
        }
    };
    const src: Limbs = .{ .isel = isel, .src_ptr = src_ptr, .src_mat = src_mat, .src_info = src_info };
    const src_fill_ra: Register.Alias = if (src_info.signedness == .signed) fill_ra else .zr;
    const src_fill = src_fill_ra.x();
    if (src_info.signedness == .signed and dst_abi_limbs > src_limbs) {
        try src.load(fill_ra, src_limbs - 1);
        try isel.emit(.sbfm(fill_ra.x(), fill_ra.x(), .{ .N = .doubleword, .immr = 63, .imms = 63 }));
    }
    // The most significant limb of the result, normalized.
    if (dst_top < src_limbs)
        try src.load(top, dst_top)
    else
        try isel.emit(.orr(top.x(), .xzr, .{ .register = src_fill }));
    if (dst_top_bits < 64) try isel.normalizeIntReg(top, top, .{ .signedness = dst_info.signedness, .bits = dst_top_bits });
    const dst_fill_ra: Register.Alias = switch (dst_info.signedness) {
        .signed => dst_fill: {
            try isel.emit(.sbfm(limb.x(), top.x(), .{ .N = .doubleword, .immr = 63, .imms = 63 }));
            break :dst_fill limb;
        },
        .unsigned => .zr,
    };
    const dst_fill = dst_fill_ra.x();
    if (panic_id != null) {
        try isel.movImmediate(diff.x(), 0);
        // Limbs at and above the result's top limb must survive the round trip.
        if (dst_top < src_limbs) for (dst_top..src_limbs) |index| {
            try src.load(copy, @intCast(index));
            try isel.emit(.eor(copy.x(), copy.x(), .{ .register = if (index == dst_top) top.x() else dst_fill }));
            try isel.emit(.orr(diff.x(), diff.x(), .{ .register = copy.x() }));
        };
        if (src_info.signedness != dst_info.signedness) {
            // A negative source, or a result that became negative.
            if (src_info.signedness == .signed)
                try src.load(copy, src_limbs - 1)
            else
                try isel.emit(.orr(copy.x(), .xzr, .{ .register = top.x() }));
            try isel.emit(.ubfm(copy.x(), copy.x(), .{ .N = .doubleword, .immr = 63, .imms = 63 }));
            try isel.emit(.orr(diff.x(), diff.x(), .{ .register = copy.x() }));
        }
    }
    if (dst_ra) |ra| try isel.emit(.orr(ra.x(), .xzr, .{ .register = top.x() })) else if (dst_used) for (0..dst_abi_limbs) |index| {
        const offset = 8 * @as(i65, @intCast(index));
        if (index == dst_top) {
            try isel.storeReg(top, 8, dst_ptr, offset);
        } else if (index > dst_top) {
            try isel.storeReg(dst_fill_ra, 8, dst_ptr, offset);
        } else if (index < src_limbs) {
            try src.load(copy, @intCast(index));
            try isel.storeReg(copy, 8, dst_ptr, offset);
        } else try isel.storeReg(src_fill_ra, 8, dst_ptr, offset);
    };
    segment.end(isel);
    if (dst_used and !dst_small) try call.paramAddress(isel, dst_vi, dst_ptr);
    if (src_mat) |mat| try mat.finish(isel) else try call.paramAddress(isel, src_vi, src_ptr);
}

fn vectorIntCast(isel: *Select, dst_vi: Value.Index, dst_ty: ZigType, operand: Air.Inst.Ref) !void {
    const zcu = isel.pt.zcu;
    const src_ty = isel.air.typeOf(operand, &zcu.intern_pool);
    assert(src_ty.isVector(zcu) and src_ty.vectorLen(zcu) == dst_ty.vectorLen(zcu));
    const dst_elem_ty = dst_ty.childType(zcu);
    const src_elem_ty = src_ty.childType(zcu);
    const dst_info = dst_elem_ty.intInfo(zcu);
    const src_info = src_elem_ty.intInfo(zcu);
    if (dst_info.bits == 0) return;
    if (dst_info.bits > 64 or src_info.bits > 64 or dst_ty.vectorLen(zcu) > 64) return isel.fail(
        "unsupported vector integer cast {f} to {f}",
        .{ isel.fmtType(src_ty), isel.fmtType(dst_ty) },
    );
    _ = try dst_vi.defAddr(isel, dst_ty, .{});
    const dst_ptr = try isel.allocIntReg();
    defer if (isel.live_registers.get(dst_ptr) == .allocating) isel.freeReg(dst_ptr);
    const src_ptr = try isel.allocIntReg();
    defer if (isel.live_registers.get(src_ptr) == .allocating) isel.freeReg(src_ptr);
    const src_vi = try isel.use(operand);
    for (0..dst_ty.vectorLen(zcu)) |index| {
        try isel.values.ensureUnusedCapacity(zcu.gpa, 2);
        const src_elem_vi = isel.initValue(src_elem_ty).ref(isel);
        defer src_elem_vi.deref(isel);
        const dst_elem_vi = isel.initValue(dst_elem_ty).ref(isel);
        defer dst_elem_vi.deref(isel);
        // Each lane can change its storage width. Keep source and destination
        // layouts independent, including tightly packed sub-byte integers.
        try isel.vectorMemoryOffset(dst_elem_vi, dst_elem_ty, dst_ptr, index, false, true);
        const dst_ra = (try dst_elem_vi.defReg(isel)).?;
        const dst_lock = isel.tryLockReg(dst_ra);
        defer dst_lock.unlock(isel);
        if (src_info.bits == 0) {
            try isel.movImmediate(dst_ra.x(), 0);
        } else {
            const src_mat = try src_elem_vi.matReg(isel);
            try isel.normalizeIntReg(dst_ra, src_mat.ra, .{
                .bits = @min(dst_info.bits, src_info.bits),
                .signedness = if (dst_info.signedness == .signed and src_info.signedness == .signed) .signed else .unsigned,
            });
            try src_mat.finish(isel);
            try isel.vectorMemoryOffset(src_elem_vi, src_elem_ty, src_ptr, index, false, false);
        }
    }
    isel.freeReg(dst_ptr);
    try dst_vi.address(isel, 0, dst_ptr);
    isel.freeReg(src_ptr);
    if (src_info.bits > 0) try src_vi.address(isel, 0, src_ptr);
}

/// Bitwise vector operations act on the contiguous lane bits, including packed lanes.
fn vectorBitwise(
    isel: *Select,
    dst_vi: Value.Index,
    ty: ZigType,
    lhs_ref: Air.Inst.Ref,
    rhs_ref: Air.Inst.Ref,
    air_tag: Air.Inst.Tag,
) !void {
    const elem_ty = ty.childType(isel.pt.zcu);
    switch (elem_ty.zigTypeTag(isel.pt.zcu)) {
        .int, .bool => {},
        else => unreachable, // Sema only permits bitwise operations on integers and bools.
    }
    if (ty.bitSize(isel.pt.zcu) == 0) return;
    // A vector of 8 or 16 bytes lives in one vector register.
    switch (ty.abiSize(isel.pt.zcu)) {
        else => {},
        8, 16 => |size| {
            const arrangement: Register.Arrangement = if (size == 8) .@"8b" else .@"16b";
            const dst_def = try isel.defVector(dst_vi) orelse return;
            defer dst_def.finish(isel);
            const dst_ra = dst_def.ra;
            const lhs_mat = try (try isel.use(lhs_ref)).matReg(isel);
            const rhs_mat = try (try isel.use(rhs_ref)).matReg(isel);
            const dst_reg = dst_ra.vector(arrangement);
            const lhs_reg = lhs_mat.ra.vector(arrangement);
            const rhs_reg = rhs_mat.ra.vector(arrangement);
            try isel.emit(switch (air_tag) {
                .bit_and => .@"and"(dst_reg, lhs_reg, .{ .register = rhs_reg }),
                .bit_or => .orr(dst_reg, lhs_reg, .{ .register = rhs_reg }),
                .xor => .eor(dst_reg, lhs_reg, .{ .register = rhs_reg }),
                else => unreachable,
            });
            try rhs_mat.finish(isel);
            try lhs_mat.finish(isel);
            return;
        },
    }
    _ = try dst_vi.defAddr(isel, ty, .{});
    var scratch: [6]Register.Alias = undefined;
    var allocated: usize = 0;
    defer for (scratch[0..allocated]) |ra| {
        if (isel.live_registers.get(ra) == .allocating) isel.freeReg(ra);
    };
    for (&scratch) |*ra| {
        ra.* = try isel.allocIntReg();
        allocated += 1;
    }
    const dst = scratch[0];
    const lhs = scratch[1];
    const rhs = scratch[2];
    const count = scratch[3];
    const left = scratch[4];
    const right = scratch[5];
    const lhs_vi = try isel.use(lhs_ref);
    const rhs_vi = try isel.use(rhs_ref);

    const segment: ForwardSegment = .begin(isel);
    try isel.emit(.ldrb(left.w(), .{ .base = lhs.x() }));
    try isel.emit(.ldrb(right.w(), .{ .base = rhs.x() }));
    try isel.emit(switch (air_tag) {
        .bit_and => .@"and"(left.w(), left.w(), .{ .register = right.w() }),
        .bit_or => .orr(left.w(), left.w(), .{ .register = right.w() }),
        .xor => .eor(left.w(), left.w(), .{ .register = right.w() }),
        else => unreachable,
    });
    try isel.emit(.strb(left.w(), .{ .base = dst.x() }));
    try isel.emit(.add(dst.x(), dst.x(), .{ .immediate = 1 }));
    try isel.emit(.add(lhs.x(), lhs.x(), .{ .immediate = 1 }));
    try isel.emit(.add(rhs.x(), rhs.x(), .{ .immediate = 1 }));
    try isel.emit(.subs(count.x(), count.x(), .{ .immediate = 1 }));
    try isel.emit(.@"b."(.ne, @intCast(segment.offsetTo(isel, segment.start))));
    segment.end(isel);
    try isel.movImmediate(count.x(), ty.abiSize(isel.pt.zcu));
    isel.freeReg(dst);
    try dst_vi.address(isel, 0, dst);
    isel.freeReg(rhs);
    try rhs_vi.address(isel, 0, rhs);
    isel.freeReg(lhs);
    try lhs_vi.address(isel, 0, lhs);
}

/// The register that defines a vector of 8 or 16 bytes, which lives in one
/// vector register.
const VectorDef = struct {
    ra: Register.Alias,
    /// `ra` is a temporary that the parts of the vector are defined from.
    temporary: bool,

    /// Call after emitting the instructions that compute `ra`.
    fn finish(def: VectorDef, isel: *Select) void {
        if (def.temporary) isel.freeReg(def.ra);
    }
};

/// Defines `vi`, a vector of 8 or 16 bytes, from the register returned, which
/// the caller computes the vector into, or returns null when it is unused.
/// When uses have split the vector into parts, such as the lanes of an array
/// it is cast to, the parts are extracted from a temporary register.
fn defVector(isel: *Select, vi: Value.Index) !?VectorDef {
    if (vi.parts(isel).only() != null) return .{ .ra = try vi.defReg(isel) orelse return null, .temporary = false };
    const ra = try isel.allocVecReg();
    try vi.defLiveIn(isel, ra, comptime &.initFill(.free));
    return .{ .ra = ra, .temporary = true };
}

/// The arrangement of a SIMD integer vector (`Legalize.Feature.keep_simd_int_vectors`),
/// which lives in one vector register, or null for any other vector type.
fn simdIntArrangement(isel: *Select, ty: ZigType) ?Register.Arrangement {
    const zcu = isel.pt.zcu;
    const elem_ty = ty.childType(zcu);
    if (!elem_ty.isInt(zcu)) return null;
    const len = ty.vectorLen(zcu);
    const elem_size: codegen.aarch64.encoding.Instruction.DataProcessingVector.Size = switch (elem_ty.intInfo(zcu).bits) {
        else => return null,
        8 => .byte,
        16 => .half,
        32 => .single,
        64 => .double,
    };
    if (len < 2) return null;
    return switch (len * elem_ty.intInfo(zcu).bits) {
        else => null,
        64 => .wrap(.{ .size = .double, .elem_size = elem_size }),
        128 => .wrap(.{ .size = .quad, .elem_size = elem_size }),
    };
}

/// Picks the first alternative of a comma-separated inline asm constraint that
/// is supported, falling back to the whole constraint for error reporting.
fn asmConstraintAlternative(constraint: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, constraint, ',');
    while (it.next()) |alternative| {
        if (std.mem.eql(u8, alternative, "r") or std.mem.eql(u8, alternative, "i") or
            std.mem.eql(u8, alternative, "n") or std.mem.eql(u8, alternative, "X") or
            (std.mem.startsWith(u8, alternative, "{") and std.mem.endsWith(u8, alternative, "}")))
            return alternative;
    }
    return constraint;
}

pub fn tlsNavAddress(isel: *Select, dst_ra: Register.Alias, nav_index: InternPool.Nav.Index, addend: u64) !void {
    const zcu = isel.pt.zcu;
    if (isel.target.os.tag.isDarwin() and isel.target.ofmt == .macho) return isel.tlvNavAddress(dst_ra, nav_index, addend);
    if (isel.target.os.tag != .linux or isel.target.ofmt != .elf)
        return isel.fail("thread-local addresses on {t} {t}", .{ isel.target.os.tag, isel.target.ofmt });
    if (zcu.comp.config.output_mode == .Lib and zcu.comp.config.link_mode == .dynamic)
        return isel.fail("thread-local addresses in AArch64 dynamic libraries", .{});
    if (ZigType.fromInterned(zcu.intern_pool.getNav(nav_index).resolved.?.type).zigTypeTag(zcu) == .@"fn")
        return isel.fail("thread-local function address", .{});

    const dst_lock = isel.tryLockReg(dst_ra);
    defer dst_lock.unlock(isel);
    if (zcu.intern_pool.getNav(nav_index).getExtern(&zcu.intern_pool) != null) {
        // Initial-exec loads a TP-relative offset, not the variable's address.
        const tp_ra = try isel.allocIntReg();
        defer isel.freeReg(tp_ra);
        if (addend > 0) {
            if (addend <= 0xfff) {
                try isel.emit(.add(dst_ra.x(), dst_ra.x(), .{ .immediate = @intCast(addend) }));
            } else {
                try isel.emit(.add(dst_ra.x(), dst_ra.x(), .{ .register = tp_ra.x() }));
                try isel.movImmediate(tp_ra.x(), addend);
            }
        }
        try isel.emit(.add(dst_ra.x(), tp_ra.x(), .{ .register = dst_ra.x() }));
        try isel.emit(.mrs(tp_ra.x(), Register.System.tpidr_el0));
        try isel.nav_relocs.append(zcu.gpa, .{
            .nav = nav_index,
            .tls = true,
            .reloc = .{ .label = @intCast(isel.instructions.items.len) },
        });
        try isel.emit(.ldr(dst_ra.x(), .{ .unsigned_offset = .{ .base = dst_ra.x(), .offset = 0 } }));
        try isel.nav_relocs.append(zcu.gpa, .{
            .nav = nav_index,
            .tls = true,
            .reloc = .{ .label = @intCast(isel.instructions.items.len) },
        });
        try isel.emit(.adrp(dst_ra.x(), 0));
    } else {
        // Local-exec is also valid in PIE executables: the TLS offset is fixed.
        try isel.nav_relocs.append(zcu.gpa, .{
            .nav = nav_index,
            .tls = true,
            .reloc = .{ .label = @intCast(isel.instructions.items.len), .addend = addend },
        });
        try isel.emit(.add(dst_ra.x(), dst_ra.x(), .{ .immediate = 0 }));
        try isel.nav_relocs.append(zcu.gpa, .{
            .nav = nav_index,
            .tls = true,
            .reloc = .{ .label = @intCast(isel.instructions.items.len), .addend = addend },
        });
        try isel.emit(.add(dst_ra.x(), dst_ra.x(), .{ .shifted_immediate = .{ .immediate = 0, .lsl = .@"12" } }));
        try isel.emit(.mrs(dst_ra.x(), Register.System.tpidr_el0));
    }
}

fn vectorMemoryDynamic(
    isel: *Select,
    vi: Value.Index,
    vector_ref: Air.Inst.Ref,
    index_ref: Air.Inst.Ref,
    comptime store: bool,
) Error!void {
    const zcu = isel.pt.zcu;
    const operand_ty = isel.air.typeOf(vector_ref, &zcu.intern_pool);
    const vector_ty = if (store) operand_ty.childType(zcu) else operand_ty;
    assert(vector_ty.zigTypeTag(zcu) == .vector);
    const elem_ty = vector_ty.childType(zcu);
    const elem_size = elem_ty.abiSize(zcu);
    if (elem_size == 0) return;
    const stride_bits = isel.vectorLaneBits(elem_ty);
    const vector_vi = try isel.use(vector_ref);
    if (stride_bits == 8 * elem_size) {
        const base_ra = try isel.allocIntReg();
        defer if (isel.live_registers.get(base_ra) == .allocating) isel.freeReg(base_ra);
        const element_ra = try isel.allocIntReg();
        defer isel.freeReg(element_ra);
        if (store) {
            try vi.store(isel, elem_ty, element_ra, .{});
        } else _ = try vi.load(isel, elem_ty, element_ra, .{});
        try isel.elemPtr(element_ra, base_ra, .add, elem_size, try isel.use(index_ref));
        isel.freeReg(base_ra);
        if (store) {
            try vector_vi.liveOut(isel, base_ra);
        } else try vector_vi.address(isel, 0, base_ra);
        return;
    }
    if (isel.target.cpu.arch.endian() != .little)
        return isel.fail("packed vector element on big endian target", .{});
    const info: InternPool.Key.IntType = switch (elem_ty.zigTypeTag(zcu)) {
        .bool => .{ .bits = 1, .signedness = .unsigned },
        .int => elem_ty.intInfo(zcu),
        else => return isel.fail("unsupported dynamic vector element {f}", .{isel.fmtType(elem_ty)}),
    };
    if (info.bits > 128)
        return isel.fail("unsupported dynamic vector element {f}", .{isel.fmtType(elem_ty)});
    assert(info.bits > 0);
    // Lanes above 64 bits are accessed as a low and a high limb.
    const wide = info.bits > 64;
    var dst_ras: [2]?Register.Alias = .{ null, null };
    if (!store) {
        if (wide) {
            var hi_it = vi.field(elem_ty, 8, 8);
            dst_ras[1] = try (try hi_it.only(isel)).?.defReg(isel);
            var lo_it = vi.field(elem_ty, 0, 8);
            dst_ras[0] = try (try lo_it.only(isel)).?.defReg(isel);
        } else dst_ras[0] = try vi.defReg(isel);
        if (dst_ras[0] == null and dst_ras[1] == null) return;
    }
    const dst_lo_lock = if (dst_ras[0]) |ra| isel.tryLockReg(ra) else RegLock.empty;
    defer dst_lo_lock.unlock(isel);
    const dst_hi_lock = if (dst_ras[1]) |ra| isel.tryLockReg(ra) else RegLock.empty;
    defer dst_hi_lock.unlock(isel);
    var scratch: [9]Register.Alias = undefined;
    var allocated: usize = 0;
    defer for (scratch[0..allocated]) |ra| {
        if (isel.live_registers.get(ra) == .allocating) isel.freeReg(ra);
    };
    for (scratch[0..if (wide) 9 else 8]) |*ra| {
        ra.* = try isel.allocIntReg();
        allocated += 1;
    }
    const ptr = scratch[0];
    const position = scratch[1];
    const lane = scratch[2];
    const shift = scratch[3];
    const byte = scratch[4];
    const temp = scratch[5];
    const offset = scratch[6];
    const mask = scratch[7];
    const lane_hi = scratch[8];
    const index_mat = try (try isel.use(index_ref)).matReg(isel);
    var lane_mats: [2]?Value.Materialize = .{ null, null };
    if (store) {
        if (wide) {
            var lo_it = vi.field(elem_ty, 0, 8);
            lane_mats[0] = try (try lo_it.only(isel)).?.matReg(isel);
            var hi_it = vi.field(elem_ty, 8, 8);
            lane_mats[1] = try (try hi_it.only(isel)).?.matReg(isel);
        } else lane_mats[0] = try vi.matReg(isel);
    }
    if (wide) {
        if (dst_ras[1]) |ra| try isel.emit(.orr(ra.x(), .xzr, .{ .register = lane_hi.x() }));
        if (dst_ras[0]) |ra| try isel.emit(.orr(ra.x(), .xzr, .{ .register = lane.x() }));
        if (!store) try isel.normalizeIntReg(lane_hi, lane_hi, .{ .signedness = info.signedness, .bits = info.bits - 64 });
    } else if (dst_ras[0]) |ra| {
        if (ra.isVector()) {
            try isel.emit(.fmov(if (info.bits <= 32) ra.s() else ra.d(), .{
                .register = if (info.bits <= 32) lane.w() else lane.x(),
            }));
        } else try isel.emit(.orr(ra.x(), .xzr, .{ .register = lane.x() }));
        try isel.normalizeIntReg(lane, lane, info);
    }
    // The byte loop accesses only bits belonging to the selected lane.
    const segment: ForwardSegment = .begin(isel);
    for (0..if (wide) 2 else 1) |pass| {
        const pass_bits: u16 = if (pass == 0) @min(info.bits, 64) else info.bits - 64;
        const pass_lane = if (pass == 0) lane else lane_hi;
        if (pass == 1) {
            // Continue at the next bit with the high limb.
            try isel.emit(.movz(shift.x(), 0, .{ .lsl = .@"0" }));
            if (!store) try isel.emit(.movz(lane_hi.x(), 0, .{ .lsl = .@"0" }));
        }
        const loop_start = isel.instructions.items.len;
        try isel.emit(.ldrb(byte.w(), .{ .base = ptr.x() }));
        if (store) {
            try isel.emit(.lsrv(temp.x(), pass_lane.x(), shift.x()));
            try isel.emit(.ubfm(temp.x(), temp.x(), .{ .N = .doubleword, .immr = 0, .imms = 0 }));
            try isel.emit(.lslv(temp.x(), temp.x(), position.x()));
            try isel.emit(.movz(mask.x(), 1, .{ .lsl = .@"0" }));
            try isel.emit(.lslv(mask.x(), mask.x(), position.x()));
            try isel.emit(.bic(byte.x(), byte.x(), .{ .register = mask.x() }));
            try isel.emit(.orr(byte.x(), byte.x(), .{ .register = temp.x() }));
            try isel.emit(.strb(byte.w(), .{ .base = ptr.x() }));
        } else {
            try isel.emit(.lsrv(byte.x(), byte.x(), position.x()));
            try isel.emit(.ubfm(byte.x(), byte.x(), .{ .N = .doubleword, .immr = 0, .imms = 0 }));
            try isel.emit(.lslv(byte.x(), byte.x(), shift.x()));
            try isel.emit(.orr(pass_lane.x(), pass_lane.x(), .{ .register = byte.x() }));
        }
        try isel.emit(.add(position.x(), position.x(), .{ .immediate = 1 }));
        try isel.emit(.ubfm(temp.x(), position.x(), .{ .N = .doubleword, .immr = 3, .imms = 63 }));
        try isel.emit(.add(ptr.x(), ptr.x(), .{ .register = temp.x() }));
        try isel.emit(.ubfm(position.x(), position.x(), .{ .N = .doubleword, .immr = 0, .imms = 2 }));
        try isel.emit(.add(shift.x(), shift.x(), .{ .immediate = 1 }));
        try isel.emit(.subs(.xzr, shift.x(), .{ .immediate = @intCast(pass_bits) }));
        try isel.emit(.@"b."(.ne, @intCast(segment.offsetTo(isel, loop_start))));
    }
    segment.end(isel);

    try isel.movImmediate(shift.x(), 0);
    if (lane_mats[1]) |mat| {
        try isel.emit(.orr(lane_hi.x(), .xzr, .{ .register = mat.ra.x() }));
        try mat.finish(isel);
    }
    if (lane_mats[0]) |mat| {
        if (wide)
            try isel.emit(.orr(lane.x(), .xzr, .{ .register = mat.ra.x() }))
        else
            try isel.normalizeIntReg(lane, if (mat.ra.isVector()) lane else mat.ra, info);
        if (mat.ra.isVector()) try isel.emit(.fmov(
            if (info.bits <= 32) lane.w() else lane.x(),
            .{ .register = if (info.bits <= 32) mat.ra.s() else mat.ra.d() },
        ));
        try mat.finish(isel);
    } else try isel.movImmediate(lane.x(), 0);
    try isel.emit(.add(ptr.x(), ptr.x(), .{ .register = temp.x() }));
    try isel.emit(.ubfm(temp.x(), offset.x(), .{ .N = .doubleword, .immr = 3, .imms = 63 }));
    try isel.emit(.ubfm(position.x(), offset.x(), .{ .N = .doubleword, .immr = 0, .imms = 2 }));
    try isel.emit(.madd(offset.x(), index_mat.ra.x(), mask.x(), .xzr));
    try isel.movImmediate(mask.x(), info.bits);
    isel.freeReg(ptr);
    if (store) {
        try vector_vi.liveOut(isel, ptr);
    } else try vector_vi.address(isel, 0, ptr);
    try index_mat.finish(isel);
}

/// Mach-O thread-local variables are reached through their descriptor's
/// thunk, which returns the address in x0 and preserves every other register
/// except x16, x17 and lr. Those are saved around the call here, so the
/// sequence clobbers only `dst_ra` (and the condition flags).
fn tlvNavAddress(isel: *Select, dst_ra: Register.Alias, nav_index: InternPool.Nav.Index, addend: u64) !void {
    const zcu = isel.pt.zcu;
    if (zcu.comp.config.output_mode == .Lib and zcu.comp.config.link_mode == .dynamic)
        return isel.fail("thread-local addresses in AArch64 dynamic libraries", .{});
    if (ZigType.fromInterned(zcu.intern_pool.getNav(nav_index).resolved.?.type).zigTypeTag(zcu) == .@"fn")
        return isel.fail("thread-local function address", .{});

    const saved = [4]Register.Alias{ .r0, .r16, .r17, .r30 };
    try isel.emit(.add(.sp, .sp, .{ .immediate = 8 * saved.len }));
    var pair_index = saved.len / 2;
    while (pair_index > 0) {
        pair_index -= 1;
        const pair = saved[2 * pair_index ..][0..2];
        const offset: u12 = @intCast(8 * 2 * pair_index);
        if (pair[0] != dst_ra and pair[1] != dst_ra) {
            try isel.emit(.ldp(pair[0].x(), pair[1].x(), .{ .signed_offset = .{ .base = .sp, .offset = @intCast(offset) } }));
        } else for (pair, 0..) |ra, index| if (ra != dst_ra) try isel.emit(.ldr(ra.x(), .{ .unsigned_offset = .{
            .base = .sp,
            .offset = offset + 8 * @as(u12, @intCast(index)),
        } }));
    }
    if (dst_ra != .r0) try isel.emit(.orr(dst_ra.x(), .xzr, .{ .register = Register.Alias.r0.x() }));
    if (addend > 0) {
        if (addend <= 0xfff) {
            try isel.emit(.add(Register.Alias.r0.x(), Register.Alias.r0.x(), .{ .immediate = @intCast(addend) }));
        } else {
            try isel.emit(.add(Register.Alias.r0.x(), Register.Alias.r0.x(), .{ .register = Register.Alias.r16.x() }));
            try isel.movImmediate(Register.Alias.r16.x(), addend);
        }
    }
    try isel.emit(.blr(Register.Alias.r16.x()));
    try isel.emit(.ldr(Register.Alias.r16.x(), .{ .unsigned_offset = .{ .base = Register.Alias.r0.x(), .offset = 0 } }));
    try isel.nav_relocs.append(zcu.gpa, .{
        .nav = nav_index,
        .tls = true,
        .reloc = .{ .label = @intCast(isel.instructions.items.len) },
    });
    try isel.emit(.ldr(Register.Alias.r0.x(), .{ .unsigned_offset = .{ .base = Register.Alias.r0.x(), .offset = 0 } }));
    try isel.nav_relocs.append(zcu.gpa, .{
        .nav = nav_index,
        .tls = true,
        .reloc = .{ .label = @intCast(isel.instructions.items.len) },
    });
    try isel.emit(.adrp(Register.Alias.r0.x(), 0));
    pair_index = saved.len / 2;
    while (pair_index > 0) {
        pair_index -= 1;
        const pair = saved[2 * pair_index ..][0..2];
        try isel.emit(.stp(pair[0].x(), pair[1].x(), .{ .signed_offset = .{
            .base = .sp,
            .offset = @intCast(8 * 2 * pair_index),
        } }));
    }
    try isel.emit(.sub(.sp, .sp, .{ .immediate = 8 * saved.len }));
}

fn vectorMemory(
    isel: *Select,
    vi: Value.Index,
    ty: ZigType,
    base_ra: Register.Alias,
    ptr_info: InternPool.Key.PtrType,
    comptime store: bool,
) Error!void {
    assert(ptr_info.flags.vector_index != .none);
    // Sema.elemPtrVector uses packed_offset.host_size for the vector length.
    try isel.vectorMemoryOffset(
        vi,
        ty,
        base_ra,
        @backingInt(ptr_info.flags.vector_index),
        ptr_info.flags.is_volatile,
        store,
    );
}

pub fn vectorLaneBits(isel: *Select, ty: ZigType) u64 {
    return if (ty.isRuntimeFloat() and
        std.zig.target.compilerRtFloatAbi(isel.target, ty.floatBits(isel.target)) == .soft)
        8 * ty.abiSize(isel.pt.zcu)
    else
        ty.bitSize(isel.pt.zcu);
}

fn vectorMemoryOffset(
    isel: *Select,
    vi: Value.Index,
    ty: ZigType,
    base_ra: Register.Alias,
    index: u64,
    is_volatile: bool,
    comptime store: bool,
) Error!void {
    const abi_bits = 8 * ty.abiSize(isel.pt.zcu);
    const stride_bits = isel.vectorLaneBits(ty);
    const bit_offset = index * stride_bits;
    if (stride_bits == abi_bits) {
        if (store) {
            try vi.store(isel, ty, base_ra, .{
                .offset = bit_offset / 8,
                .@"volatile" = is_volatile,
            });
        } else {
            _ = try vi.load(isel, ty, base_ra, .{
                .offset = bit_offset / 8,
                .@"volatile" = is_volatile,
            });
        }
        return;
    }

    // Hard vector lanes have no padding between their bits. Advance the byte
    // base separately so long vectors do not overflow packedMemory's offset.
    const byte_offset = bit_offset / 8;
    const adjusted_ra = if (byte_offset > 0) try isel.allocIntReg() else base_ra;
    defer if (byte_offset > 0) isel.freeReg(adjusted_ra);
    try isel.packedMemory(vi, ty, adjusted_ra, @intCast(bit_offset % 8), store);
    if (byte_offset > 0) {
        if (byte_offset <= 0xfff) {
            try isel.emit(.add(adjusted_ra.x(), base_ra.x(), .{ .immediate = @intCast(byte_offset) }));
        } else {
            try isel.emit(.add(adjusted_ra.x(), base_ra.x(), .{ .register = adjusted_ra.x() }));
            try isel.movImmediate(adjusted_ra.x(), byte_offset);
        }
    }
}

fn packedFloatMemory(
    isel: *Select,
    vi: Value.Index,
    ty: ZigType,
    base_ra: Register.Alias,
    bit_offset: u16,
    comptime store: bool,
) Error!void {
    const bits = ty.floatBits(isel.target);
    const int_ty = try isel.pt.intType(.unsigned, bits);
    try isel.values.ensureUnusedCapacity(isel.pt.zcu.gpa, 1);
    const bits_vi = isel.initValue(int_ty).ref(isel);
    defer bits_vi.deref(isel);
    if (store) {
        try isel.packedMemory(bits_vi, int_ty, base_ra, bit_offset, true);
        const src_mat = try vi.matReg(isel);
        if (bits == 128) {
            var high_it = bits_vi.field(int_ty, 8, 8);
            if (try (try high_it.only(isel)).?.defReg(isel)) |ra| {
                try isel.emit(.fmov(ra.x(), .{ .register = src_mat.ra.@"d[]"(1) }));
            }
            var low_it = bits_vi.field(int_ty, 0, 8);
            if (try (try low_it.only(isel)).?.defReg(isel)) |ra| {
                try isel.emit(.fmov(ra.x(), .{ .register = src_mat.ra.d() }));
            }
        } else if (try bits_vi.defReg(isel)) |ra| try isel.emit(switch (bits) {
            else => unreachable,
            16 => .umov(ra.w(), src_mat.ra.@"h[]"(0)),
            32 => .fmov(ra.w(), .{ .register = src_mat.ra.s() }),
            64 => .fmov(ra.x(), .{ .register = src_mat.ra.d() }),
        });
        try src_mat.finish(isel);
    } else {
        const maybe_dst_ra = try vi.defReg(isel);
        const dst_ra = maybe_dst_ra orelse try isel.allocVecReg();
        const dst_lock: RegLock = if (maybe_dst_ra != null) isel.lockReg(dst_ra) else .{ .ra = dst_ra };
        defer dst_lock.unlock(isel);
        if (bits == 128) {
            var high_it = bits_vi.field(int_ty, 8, 8);
            const high_mat = try (try high_it.only(isel)).?.matReg(isel);
            try isel.emit(.fmov(dst_ra.@"d[]"(1), .{ .register = high_mat.ra.x() }));
            var low_it = bits_vi.field(int_ty, 0, 8);
            const low_mat = try (try low_it.only(isel)).?.matReg(isel);
            try isel.emit(.fmov(dst_ra.d(), .{ .register = low_mat.ra.x() }));
            try low_mat.finish(isel);
            try high_mat.finish(isel);
        } else {
            const bits_mat = try bits_vi.matReg(isel);
            try isel.emit(switch (bits) {
                else => unreachable,
                16, 32 => .fmov(dst_ra.s(), .{ .register = bits_mat.ra.w() }),
                64 => .fmov(dst_ra.d(), .{ .register = bits_mat.ra.x() }),
            });
            try bits_mat.finish(isel);
        }
        try isel.packedMemory(bits_vi, int_ty, base_ra, bit_offset, false);
    }
}

fn packedMemory(
    isel: *Select,
    vi: Value.Index,
    ty: ZigType,
    base_ra: Register.Alias,
    bit_offset: u16,
    comptime store: bool,
) Error!void {
    const zcu = isel.pt.zcu;
    if (isel.target.cpu.arch.endian() != .little) return isel.fail("packed access on big endian target", .{});
    if (ty.isRuntimeFloat() and ty.floatBits(isel.target) != 80) {
        return isel.packedFloatMemory(vi, ty, base_ra, bit_offset, store);
    }
    const bits: u16 = bits: {
        switch (ty.zigTypeTag(zcu)) {
            .bool => break :bits 1,
            .float => {
                assert(ty.floatBits(isel.target) == 80);
                break :bits 80;
            },
            else => {
                assert(ty.isAbiInt(zcu));
                break :bits ty.intInfo(zcu).bits;
            },
        }
    };
    if (bits > Value.max_parts * 64) {
        if (bit_offset != 0 or !ty.isAbiInt(zcu)) return isel.fail("too big packed access to {f}", .{isel.fmtType(ty)});
        return isel.packedMemoryWide(vi, ty, base_ra, store);
    }
    var offset: u16 = 0;
    while (offset < bits) : (offset += 64) {
        const part_bits: u7 = @intCast(@min(bits - offset, 64));
        const part_vi = if (bits <= 64) vi else part: {
            var part_it = vi.field(ty, offset / 8, 8);
            break :part (try part_it.only(isel)).?;
        };
        const part_mat: ?Value.Materialize = if (store) try part_vi.matReg(isel) else null;
        const maybe_part_ra: ?Register.Alias = if (store) part_mat.?.ra else try part_vi.defReg(isel);
        const part_ra = maybe_part_ra orelse try isel.allocIntReg();
        const part_lock: RegLock = if (store) .empty else if (maybe_part_ra != null) isel.lockReg(part_ra) else .{ .ra = part_ra };
        defer part_lock.unlock(isel);
        if (bit_offset % 8 == 0 and part_bits % 8 == 0) {
            if (store) {
                try isel.storeReg(part_ra, part_bits / 8, base_ra, (@as(u32, bit_offset) + offset) / 8);
                try part_mat.?.finish(isel);
            } else {
                if (ty.isAbiInt(zcu) and offset + part_bits == bits and ty.intInfo(zcu).signedness == .signed) {
                    try isel.emit(.sbfm(part_ra.x(), part_ra.x(), .{ .N = .doubleword, .immr = 0, .imms = @intCast(part_bits - 1) }));
                }
                try isel.loadReg(part_ra, part_bits / 8, .unsigned, base_ra, (@as(u32, bit_offset) + offset) / 8);
            }
            continue;
        }
        const byte_ra = try isel.allocIntReg();
        defer isel.freeReg(byte_ra);
        const temp_ra = try isel.allocIntReg();
        defer isel.freeReg(temp_ra);
        if (!store and ty.isAbiInt(zcu) and offset + part_bits == bits and ty.intInfo(zcu).signedness == .signed) {
            try isel.emit(.sbfm(part_ra.x(), part_ra.x(), .{ .N = .doubleword, .immr = 0, .imms = @intCast(part_bits - 1) }));
        }
        var remaining: u7 = part_bits;
        while (remaining > 0) {
            const field_pos: u16 = remaining - 1;
            const byte_pos = (@as(u32, bit_offset) + offset + field_pos) / 8;
            const end_bit: u4 = @intCast((@as(u32, bit_offset) + offset + field_pos) % 8 + 1);
            const chunk_bits: u4 = @intCast(@min(remaining, end_bit));
            const src_pos: u6 = @intCast(remaining - chunk_bits);
            const byte_bit: u3 = @intCast(end_bit - chunk_bits);
            if (store) {
                if (chunk_bits == 8) {
                    try isel.storeReg(temp_ra, 1, base_ra, byte_pos);
                } else {
                    try isel.storeReg(byte_ra, 1, base_ra, byte_pos);
                    try isel.emit(.bfm(
                        byte_ra.x(),
                        temp_ra.x(),
                        .{ .N = .doubleword, .immr = @truncate(@as(u7, 64) - byte_bit), .imms = chunk_bits - 1 },
                    ));
                }
                try isel.emit(.ubfm(
                    temp_ra.x(),
                    part_ra.x(),
                    .{ .N = .doubleword, .immr = src_pos, .imms = @intCast(@as(u7, src_pos) + chunk_bits - 1) },
                ));
                if (chunk_bits < 8) try isel.loadReg(byte_ra, 1, .unsigned, base_ra, byte_pos);
            } else {
                try isel.emit(.orr(
                    part_ra.x(),
                    part_ra.x(),
                    .{ .shifted_register = .{ .register = temp_ra.x(), .shift = .{ .lsl = src_pos } } },
                ));
                try isel.emit(.ubfm(
                    temp_ra.x(),
                    byte_ra.x(),
                    .{ .N = .doubleword, .immr = byte_bit, .imms = @intCast(byte_bit + chunk_bits - 1) },
                ));
                try isel.loadReg(byte_ra, 1, .unsigned, base_ra, byte_pos);
            }
            remaining -= chunk_bits;
        }
        if (store) try part_mat.?.finish(isel) else try isel.movImmediate(part_ra.x(), 0);
    }
}

/// A byte-aligned packed integer too wide for registers: copy its whole bytes
/// through memory and merge the final partial byte.
fn packedMemoryWide(isel: *Select, vi: Value.Index, ty: ZigType, base_ra: Register.Alias, comptime store: bool) !void {
    const info = ty.intInfo(isel.pt.zcu);
    const full_bytes = info.bits / 8;
    const rem_bits: u6 = @intCast(info.bits % 8);
    if (!store) try vi.defAddr(isel, ty, .{ .wrap = info }) orelse return;
    var regs: [6]Register.Alias = undefined;
    for (&regs, 0..) |*ra, index| {
        errdefer for (regs[0..index]) |allocated_ra| isel.freeReg(allocated_ra);
        ra.* = try isel.allocIntReg();
    }
    // An indirect value's pointer can end up live in `value_ptr` (for example
    // an incoming argument); only free a plain scratch.
    defer for (regs) |ra| if (isel.live_registers.get(ra) == .allocating) isel.freeReg(ra);
    const value_ptr, const src_ptr, const dst_ptr, const count, const byte, const merged = regs;
    const segment: ForwardSegment = .begin(isel);
    try isel.emit(.orr(src_ptr.x(), .xzr, .{ .register = if (store) value_ptr.x() else base_ra.x() }));
    try isel.emit(.orr(dst_ptr.x(), .xzr, .{ .register = if (store) base_ra.x() else value_ptr.x() }));
    if (full_bytes >= 8) {
        try isel.emit(.movz(count.x(), @intCast(full_bytes / 8), .{ .lsl = .@"0" }));
        try isel.emit(.ldr(byte.x(), .{ .post_index = .{ .base = src_ptr.x(), .index = 8 } }));
        try isel.emit(.str(byte.x(), .{ .post_index = .{ .base = dst_ptr.x(), .index = 8 } }));
        try isel.emit(.subs(count.x(), count.x(), .{ .immediate = 1 }));
        try isel.emit(.@"b."(.ne, -3 << 2));
    }
    for (0..full_bytes % 8) |_| {
        try isel.emit(.ldrb(byte.w(), .{ .post_index = .{ .base = src_ptr.x(), .index = 1 } }));
        try isel.emit(.strb(byte.w(), .{ .post_index = .{ .base = dst_ptr.x(), .index = 1 } }));
    }
    if (rem_bits > 0) {
        try isel.loadReg(byte, 1, .unsigned, src_ptr, 0);
        if (store) {
            // Keep the neighboring bits of the final byte.
            try isel.loadReg(merged, 1, .unsigned, dst_ptr, 0);
            try isel.emit(.bfm(merged.x(), byte.x(), .{ .N = .doubleword, .immr = 0, .imms = rem_bits - 1 }));
            try isel.storeReg(merged, 1, dst_ptr, 0);
        } else try isel.storeReg(byte, 1, dst_ptr, 0);
    }
    if (!store) {
        // Canonicalize the bits above the integer in its top limb.
        const top_offset = 8 * @as(i65, (info.bits - 1) / 64);
        try isel.loadReg(byte, 8, .unsigned, value_ptr, top_offset);
        try isel.normalizeIntReg(byte, byte, .{ .signedness = info.signedness, .bits = info.bits - @as(u16, @intCast(top_offset * 8)) });
        try isel.storeReg(byte, 8, value_ptr, top_offset);
    }
    segment.end(isel);
    try call.paramAddress(isel, vi, value_ptr);
}

fn clzLimb(
    isel: *Select,
    res_ra: Register.Alias,
    src_int_info: std.lang.Type.Int,
    src_ra: Register.Alias,
) !void {
    switch (src_int_info.bits) {
        else => unreachable,
        1...31 => |bits| {
            try isel.emit(.sub(res_ra.w(), res_ra.w(), .{
                .immediate = @intCast(32 - bits),
            }));
            switch (src_int_info.signedness) {
                .signed => {
                    try isel.emit(.clz(res_ra.w(), res_ra.w()));
                    try isel.emit(.ubfm(res_ra.w(), src_ra.w(), .{
                        .N = .word,
                        .immr = 0,
                        .imms = @intCast(bits - 1),
                    }));
                },
                .unsigned => try isel.emit(.clz(res_ra.w(), src_ra.w())),
            }
        },
        32 => try isel.emit(.clz(res_ra.w(), src_ra.w())),
        33...63 => |bits| {
            try isel.emit(.sub(res_ra.w(), res_ra.w(), .{
                .immediate = @intCast(64 - bits),
            }));
            switch (src_int_info.signedness) {
                .signed => {
                    try isel.emit(.clz(res_ra.x(), res_ra.x()));
                    try isel.emit(.ubfm(res_ra.x(), src_ra.x(), .{
                        .N = .doubleword,
                        .immr = 0,
                        .imms = @intCast(bits - 1),
                    }));
                },
                .unsigned => try isel.emit(.clz(res_ra.x(), src_ra.x())),
            }
        },
        64 => try isel.emit(.clz(res_ra.x(), src_ra.x())),
    }
}

fn ctzLimb(
    isel: *Select,
    res_ra: Register.Alias,
    src_int_info: std.lang.Type.Int,
    src_ra: Register.Alias,
) !void {
    switch (src_int_info.bits) {
        else => unreachable,
        1...31 => |bits| {
            try isel.emit(.clz(res_ra.w(), res_ra.w()));
            try isel.emit(.rbit(res_ra.w(), res_ra.w()));
            try isel.emit(.orr(res_ra.w(), src_ra.w(), .{ .immediate = .{
                .N = .word,
                .immr = @intCast(32 - bits),
                .imms = @intCast(32 - bits - 1),
            } }));
        },
        32 => {
            try isel.emit(.clz(res_ra.w(), res_ra.w()));
            try isel.emit(.rbit(res_ra.w(), src_ra.w()));
        },
        33...63 => |bits| {
            try isel.emit(.clz(res_ra.x(), res_ra.x()));
            try isel.emit(.rbit(res_ra.x(), res_ra.x()));
            try isel.emit(.orr(res_ra.x(), src_ra.x(), .{ .immediate = .{
                .N = .doubleword,
                .immr = @intCast(64 - bits),
                .imms = @intCast(64 - bits - 1),
            } }));
        },
        64 => {
            try isel.emit(.clz(res_ra.x(), res_ra.x()));
            try isel.emit(.rbit(res_ra.x(), src_ra.x()));
        },
    }
}

fn tailCall(isel: *Select, inst: Air.Inst.Index) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    // A merged return block can still reference this call's synthetic result.
    // The tail jump bypasses that continuation; consume the definition while
    // retaining it until the ordinary call register cleanup has finished.
    const result_vi = isel.live_values.fetchRemove(inst);
    defer if (result_vi) |result| result.value.deref(isel);
    const call_info = isel.callInfo(inst);
    const air_call = isel.air.unwrapCall(inst);
    const callee_ty = isel.air.typeOf(air_call.callee, ip);
    const func_info = switch (ip.indexToKey(callee_ty.toIntern())) {
        else => unreachable,
        .func_type => |func_type| func_type,
        .ptr_type => |ptr_type| ip.indexToKey(ptr_type.child).func_type,
    };
    if (func_info.is_var_args) return isel.fail("variadic tail call", .{});

    var param_it: CallAbiIterator = .init;
    for (air_call.args) |arg| {
        const restore_values_len = isel.values.items.len;
        defer isel.values.shrinkRetainingCapacity(restore_values_len);
        const param_ty = isel.air.typeOf(arg, ip);
        const param_vi = try param_it.param(isel, param_ty) orelse continue;
        defer param_vi.deref(isel);
        if (param_vi.parent(isel) == .address)
            return isel.fail("tail call with indirect by-value argument {f}", .{isel.fmtType(param_ty)});
    }
    // Sema requires the caller and callee to have the same function type.
    // Variadic calls are excluded above, so their stack argument spans match.
    assert(param_it.stackSize() == isel.incoming_stack_size);
    try isel.tail_branches.append(zcu.gpa, @intCast(isel.instructions.items.len));
    isel.branch_placeholder = @intCast(isel.instructions.items.len);
    try isel.emit(.b(0));
    try call.prepareReturn(isel);
    try call.finishReturn(isel);

    // Stage arguments in the ordinary outgoing area first. This copy runs
    // after their stores, so overlapping incoming argument sources are safe.
    // Caller registers remain reserved while the copy's scratch registers are
    // allocated; the epilogue restores the callee registers used here.
    if (param_it.stackSize() > 0) {
        const source_ra = try isel.allocIntReg();
        defer isel.freeReg(source_ra);
        const dest_ra = try isel.allocIntReg();
        defer isel.freeReg(dest_ra);
        const count_ra = try isel.allocIntReg();
        defer isel.freeReg(count_ra);
        const data_ra = try isel.allocIntReg();
        defer isel.freeReg(data_ra);
        try isel.emit(.@"b."(.ne, -12));
        try isel.emit(.subs(count_ra.x(), count_ra.x(), .{ .immediate = 1 }));
        try isel.emit(.str(data_ra.x(), .{ .post_index = .{ .base = dest_ra.x(), .index = 8 } }));
        try isel.emit(.ldr(data_ra.x(), .{ .post_index = .{ .base = source_ra.x(), .index = 8 } }));
        try isel.movImmediate(count_ra.x(), param_it.stackSize() / 8);
        const incoming_stack_args = isel.incoming_stack_args.?;
        try isel.emit(.add(dest_ra.x(), incoming_stack_args.base.x(), .{
            .immediate = @intCast(incoming_stack_args.offset),
        }));
        try isel.emit(.add(source_ra.x(), .sp, .{ .immediate = 0 }));
    }

    try call.prepareCallee(isel);
    const target_ra: Register.Alias = .r16;
    const target_lock = isel.lockReg(target_ra);
    try call.prepareParams(isel);
    _ = try isel.callArguments(call_info, true);
    if (isel.live_values.get(Block.main)) |ret_vi| switch (ret_vi.parent(isel)) {
        .address => |address_vi| try call.paramLiveOut(isel, address_vi, .r8),
        else => {},
    };

    // Capture the target before argument register moves at runtime. x16 is
    // reserved throughout selection of those moves and survives the epilogue.
    if (air_call.callee.toInterned()) |ct_callee| {
        const reloc: codegen.aarch64.Mir.Reloc.Nav = switch (ip.indexToKey(ct_callee)) {
            else => unreachable,
            inline .@"extern", .func => |func| .{ .nav = func.owner_nav, .reloc = .{ .label = 0 } },
            .ptr => |ptr| .{ .nav = ptr.base_addr.nav, .reloc = .{ .label = 0, .addend = ptr.byte_offset } },
        };
        if (zcu.comp.config.any_non_single_threaded and ip.getNav(reloc.nav).resolved.?.@"threadlocal")
            return isel.fail("thread-local function call", .{});
        var target_reloc = reloc;
        target_reloc.reloc.label = @intCast(isel.instructions.items.len);
        try isel.nav_relocs.append(zcu.gpa, target_reloc);
        if (ip.getNav(reloc.nav).getExtern(ip) != null)
            try isel.emit(.ldr(target_ra.x(), .{ .unsigned_offset = .{ .base = target_ra.x(), .offset = 0 } }))
        else
            try isel.emit(.add(target_ra.x(), target_ra.x(), .{ .immediate = 0 }));
        target_reloc.reloc.label = @intCast(isel.instructions.items.len);
        try isel.nav_relocs.append(zcu.gpa, target_reloc);
        try isel.emit(.adrp(target_ra.x(), 0));
    } else {
        const callee_mat = try (try isel.use(air_call.callee)).matReg(isel);
        try isel.emit(.orr(target_ra.x(), .xzr, .{ .register = callee_mat.ra.x() }));
        try callee_mat.finish(isel);
    }
    target_lock.unlock(isel);
    try call.finishParams(isel);
}

const VectorAbi = struct {
    lanes: u5,
    bits: u7,
    lane_bits: u7,
    register_size: u5,
};

pub fn vectorAbi(isel: *Select, ty: ZigType) ?VectorAbi {
    const zcu = isel.pt.zcu;
    if (ty.zigTypeTag(zcu) != .vector) return null;
    const lanes = ty.arrayLen(zcu);
    if (lanes < 1 or lanes > 16) return null;
    // LLVM widens a non-power-of-two lane count to the next power of two.
    const register_lanes = std.math.ceilPowerOfTwoAssert(u64, lanes);
    const child_ty = ty.childType(zcu);
    const bits: u16, const lane_bits: u16 = if (child_ty.isPtrAtRuntime(zcu))
        .{ 64, 64 }
    else switch (child_ty.zigTypeTag(zcu)) {
        // LLVM passes a single bool lane as a scalar in a general register.
        .bool => if (lanes == 1) return null else .{ 1, @max(8, @as(u16, @intCast(64 / register_lanes))) },
        .int => bits: {
            const bits = child_ty.intInfo(zcu).bits;
            if (bits == 0 or bits > 64) return null;
            // A single lane is widened to a full register, never promoted.
            if (lanes == 1) break :bits switch (bits) {
                else => return null,
                8, 16, 32, 64 => .{ bits, bits },
            };
            // Integer lanes are promoted until the register is at least 64 bits.
            break :bits .{ bits, @max(@as(u16, 8), @max(
                @as(u16, @intCast(64 / register_lanes)),
                std.math.ceilPowerOfTwo(u16, bits) catch unreachable,
            )) };
        },
        // Float lanes are never promoted; short vectors are widened instead.
        .float => switch (child_ty.floatBits(isel.target)) {
            else => return null,
            16, 32, 64 => |bits| .{ bits, bits },
        },
        else => return null,
    };
    const register_bits = @max(64, lane_bits * register_lanes);
    if (register_bits > 128) return null;
    return .{
        .lanes = @intCast(lanes),
        .bits = @intCast(bits),
        .lane_bits = @intCast(lane_bits),
        .register_size = @intCast(register_bits / 8),
    };
}

/// LLVM's legal SIMD argument lanes can be wider than the packed memory lanes.
/// Keep Values in their logical layout and adapt only at the ABI boundary.
fn vectorAbiAdapt(isel: *Select, info: VectorAbi, ra: Register.Alias, comptime pack: bool) Error!void {
    assert(ra.isVector());
    // Lanes that are already exactly as wide as their legal ABI lanes are laid
    // out identically in memory and in the argument register.
    if (info.lane_bits == info.bits) return;
    // `ra` holds the vector being adapted: allocating the scratch registers
    // must neither take it nor move another value into it.
    const ra_lock = isel.tryLockReg(ra);
    defer ra_lock.unlock(isel);
    const low_ra = try isel.allocIntReg();
    defer isel.freeReg(low_ra);
    const has_high = @as(u16, info.bits) * info.lanes > 64;
    const high_ra = if (has_high) try isel.allocIntReg() else Register.Alias.zr;
    defer if (has_high) isel.freeReg(high_ra);
    const lane_ra = try isel.allocIntReg();
    defer isel.freeReg(lane_ra);

    const segment: ForwardSegment = .begin(isel);
    if (pack) {
        try isel.emit(.orr(low_ra.x(), .xzr, .{ .register = .xzr }));
        if (has_high) try isel.emit(.orr(high_ra.x(), .xzr, .{ .register = .xzr }));
    } else {
        try isel.emit(.fmov(low_ra.x(), .{ .register = ra.d() }));
        if (has_high) try isel.emit(.umov(high_ra.x(), ra.@"d[]"(1)));
    }
    for (0..info.lanes) |index| {
        const offset = index * info.bits;
        if (pack) {
            try isel.emit(switch (info.lane_bits) {
                else => unreachable,
                8 => .umov(lane_ra.w(), ra.@"b[]"(@intCast(index))),
                16 => .umov(lane_ra.w(), ra.@"h[]"(@intCast(index))),
                32 => .umov(lane_ra.w(), ra.@"s[]"(@intCast(index))),
                64 => .umov(lane_ra.x(), ra.@"d[]"(@intCast(index))),
            });
            if (info.bits < 64) try isel.emit(.ubfm(lane_ra.x(), lane_ra.x(), .{
                .N = .doubleword,
                .immr = 0,
                .imms = @intCast(info.bits - 1),
            }));
            if (offset < 64) {
                try isel.emit(.orr(low_ra.x(), low_ra.x(), .{ .shifted_register = .{
                    .register = lane_ra.x(),
                    .shift = .{ .lsl = @intCast(offset) },
                } }));
                if (offset + info.bits > 64) try isel.emit(.orr(high_ra.x(), high_ra.x(), .{ .shifted_register = .{
                    .register = lane_ra.x(),
                    .shift = .{ .lsr = @intCast(64 - offset) },
                } }));
            } else try isel.emit(.orr(high_ra.x(), high_ra.x(), .{ .shifted_register = .{
                .register = lane_ra.x(),
                .shift = .{ .lsl = @intCast(offset - 64) },
            } }));
        } else {
            if (offset < 64 and offset + info.bits > 64) {
                try isel.emit(.ubfm(lane_ra.x(), low_ra.x(), .{
                    .N = .doubleword,
                    .immr = @intCast(offset),
                    .imms = 63,
                }));
                try isel.emit(.orr(lane_ra.x(), lane_ra.x(), .{ .shifted_register = .{
                    .register = high_ra.x(),
                    .shift = .{ .lsl = @intCast(64 - offset) },
                } }));
                try isel.emit(.ubfm(lane_ra.x(), lane_ra.x(), .{
                    .N = .doubleword,
                    .immr = 0,
                    .imms = @intCast(info.bits - 1),
                }));
            } else {
                const shift = offset % 64;
                try isel.emit(.ubfm(lane_ra.x(), if (offset < 64) low_ra.x() else high_ra.x(), .{
                    .N = .doubleword,
                    .immr = @intCast(shift),
                    .imms = @intCast(shift + info.bits - 1),
                }));
            }
            try isel.emit(switch (info.lane_bits) {
                else => unreachable,
                8 => .ins(ra.@"b[]"(@intCast(index)), lane_ra.w()),
                16 => .ins(ra.@"h[]"(@intCast(index)), lane_ra.w()),
                32 => .ins(ra.@"s[]"(@intCast(index)), lane_ra.w()),
                64 => .ins(ra.@"d[]"(@intCast(index)), lane_ra.x()),
            });
        }
    }
    if (pack) {
        try isel.emit(.fmov(ra.d(), .{ .register = low_ra.x() }));
        if (has_high) try isel.emit(.ins(ra.@"d[]"(1), high_ra.x()));
    }
    segment.end(isel);
}

fn vectorAbiArgument(isel: *Select, vi: Value.Index, info: VectorAbi) Error!void {
    const hinted_ra = vi.hint(isel);
    const ra = hinted_ra orelse try isel.allocVecReg();
    defer if (hinted_ra == null and isel.live_registers.get(ra) == .allocating) isel.freeReg(ra);
    try vi.defLiveIn(isel, ra, comptime &.initFill(.free));
    const ra_lock = isel.tryLockReg(ra);
    defer ra_lock.unlock(isel);
    const offset_from_parent, const parent_vi = vi.valueParent(isel);
    if (parent_vi.parent(isel) == .stack_slot) {
        const slot = parent_vi.parent(isel).stack_slot;
        if (slot.base == Register.Alias.fp) {
            // The register save area and incoming stack slot initially contain
            // expanded ABI lanes. Publish the packed by-value representation.
            try isel.storeReg(ra, vi.size(isel), slot.base, @as(i65, slot.offset) + offset_from_parent);
        }
    }
    try isel.vectorAbiAdapt(info, ra, true);
    if (hinted_ra == null) {
        const slot = parent_vi.parent(isel).stack_slot;
        assert(slot.base == Register.Alias.fp);
        try isel.loadReg(ra, info.register_size, .unsigned, slot.base, @as(i65, slot.offset) + offset_from_parent);
    }
}

/// A call as selection sees it: `call` and its variants, or a compiler-rt
/// routine that Legalize calls.
const CallInfo = struct {
    callee: union(enum) {
        value: Air.Inst.Ref,
        global: [*:0]const u8,
    },
    args: []const Air.Inst.Ref,
    /// The callee's type, for a `value` callee.
    func_type: ?InternPool.Key.FuncType,

    fn isVarArg(call_info: CallInfo, arg_index: usize) bool {
        const func_type = call_info.func_type orelse return false;
        if (arg_index < func_type.param_types.len) return false;
        assert(func_type.is_var_args);
        return true;
    }
};

fn callInfo(isel: *Select, inst: Air.Inst.Index) CallInfo {
    const ip = &isel.pt.zcu.intern_pool;
    if (isel.air.instructions.items(.tag)[@backingInt(inst)] == .legalize_compiler_rt_call) {
        const rt_call = isel.air.unwrapCompilerRtCall(inst);
        // These routines take and return integers and pointers only, as
        // the target's C calling convention does.
        assert(rt_call.func.@"callconv"(isel.target).eql(isel.target.cCallingConvention().?));
        return .{ .callee = .{ .global = rt_call.func.name(isel.target) }, .args = rt_call.args, .func_type = null };
    }
    const air_call = isel.air.unwrapCall(inst);
    const callee_ty = isel.air.typeOf(air_call.callee, ip);
    return .{
        .callee = .{ .value = air_call.callee },
        .args = air_call.args,
        .func_type = switch (ip.indexToKey(callee_ty.toIntern())) {
            else => unreachable,
            .func_type => |func_type| func_type,
            .ptr_type => |ptr_type| ip.indexToKey(ptr_type.child).func_type,
        },
    };
}

fn callArguments(isel: *Select, call_info: CallInfo, tail: bool) !u24 {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = zcu.gpa;
    const args = call_info.args;
    var param_it: CallAbiIterator = .init;
    for (args, 0..) |arg, arg_index| {
        const param_ty = isel.air.typeOf(arg, ip);
        const param_vi = param_vi: {
            if (call_info.isVarArg(arg_index)) {
                switch (isel.va_list) {
                    .other => break :param_vi try param_it.nonSysvVarArg(isel, param_ty),
                    .sysv => {},
                }
            }
            break :param_vi try param_it.param(isel, param_ty);
        } orelse continue;
        defer param_vi.deref(isel);
        if (tail and param_vi.parent(isel) == .address)
            return isel.fail("tail call with indirect by-value argument {f}", .{isel.fmtType(param_ty)});
        const arg_vi = try isel.use(arg);
        switch (param_vi.parent(isel)) {
            .unallocated => if (param_vi.hint(isel)) |param_ra| {
                if (isel.vectorAbi(param_ty)) |info|
                    try isel.vectorAbiAdapt(info, param_ra, false);
                try call.paramLiveOut(isel, arg_vi, param_ra);
            } else {
                var param_part_it = param_vi.parts(isel);
                var arg_part_it = arg_vi.parts(isel);
                if (arg_part_it.only()) |_| {
                    try isel.values.ensureUnusedCapacity(gpa, param_part_it.remaining);
                    arg_vi.setParts(isel, param_part_it.remaining);
                    while (param_part_it.next()) |param_part_vi| {
                        const arg_part_vi = arg_vi.addPart(
                            isel,
                            param_part_vi.get(isel).offset_from_parent,
                            param_part_vi.size(isel),
                        );
                        if (param_part_vi.isVector(isel)) arg_part_vi.setIsVector(isel);
                        if (param_part_vi.signedness(isel) == .signed) arg_part_vi.setSignedness(isel, .signed);
                    }
                    param_part_it = param_vi.parts(isel);
                    arg_part_it = arg_vi.parts(isel);
                }
                const matching_parts = matching_parts: {
                    while (param_part_it.next()) |param_part_vi| {
                        const arg_part_vi = arg_part_it.next() orelse break :matching_parts false;
                        if (arg_part_vi.get(isel).offset_from_parent !=
                            param_part_vi.get(isel).offset_from_parent or
                            arg_part_vi.size(isel) != param_part_vi.size(isel))
                            break :matching_parts false;
                    }
                    break :matching_parts arg_part_it.next() == null;
                };
                param_part_it = param_vi.parts(isel);
                arg_part_it = (if (matching_parts) arg_vi else param_vi).parts(isel);
                while (param_part_it.next()) |param_part_vi| {
                    const arg_part_vi = arg_part_it.next().?;
                    assert(arg_part_vi.get(isel).offset_from_parent ==
                        param_part_vi.get(isel).offset_from_parent);
                    assert(arg_part_vi.size(isel) == param_part_vi.size(isel));
                    try call.paramLiveOut(isel, arg_part_vi, param_part_vi.hint(isel).?);
                }
                // An argument can have semantic fields instead of ABI register-sized parts.
                // Define the ABI-shaped temporary before the outgoing moves at runtime.
                if (!matching_parts) {
                    try param_vi.copy(isel, param_ty, arg_vi);
                    param_part_it = param_vi.parts(isel);
                    while (param_part_it.next()) |param_part_vi| call.reserveParamReg(isel, param_part_vi.hint(isel).?);
                }
            },
            .stack_slot => |stack_slot| if (isel.vectorAbi(param_ty)) |info| {
                const ra = try isel.allocVecReg();
                defer if (isel.live_registers.get(ra) == .allocating) isel.freeReg(ra);
                const temporary_vi = isel.initValue(param_ty).ref(isel);
                defer temporary_vi.deref(isel);
                try isel.storeReg(ra, info.register_size, stack_slot.base, stack_slot.offset);
                try isel.vectorAbiAdapt(info, ra, false);
                try call.paramLiveOut(isel, temporary_vi, ra);
                try temporary_vi.copy(isel, param_ty, arg_vi);
            } else try arg_vi.store(isel, param_ty, stack_slot.base, .{
                .offset = @intCast(stack_slot.offset),
            }),
            .value, .constant, .stack_address => unreachable,
            .address => |address_vi| if (address_vi.hint(isel)) |address_ra| {
                try call.paramAddress(isel, arg_vi, address_ra);
            } else switch (address_vi.parent(isel)) {
                .stack_slot => |stack_slot| {
                    const address_ra = try isel.allocIntReg();
                    defer if (isel.live_registers.get(address_ra) == .allocating) isel.freeReg(address_ra);
                    try isel.storeReg(address_ra, 8, stack_slot.base, @intCast(stack_slot.offset));
                    try call.paramAddress(isel, arg_vi, address_ra);
                },
                else => unreachable,
            },
        }
    }
    return param_it.stackSize();
}

/// `switch_br` and `loop_switch_br`: a branch table when the cases are
/// dense enough, else a compare chain.
fn switchBr(isel: *Select, inst: Air.Inst.Index, is_loop: bool) !void {
    const zcu = isel.pt.zcu;
    const switch_br = isel.air.unwrapSwitch(inst);
    const cond_ty = isel.air.typeOf(switch_br.operand, &zcu.intern_pool);
    const cond_int_info: std.lang.Type.Int = if (cond_ty.toIntern() == .bool_type)
        .{ .signedness = .unsigned, .bits = 1 }
    else if (cond_ty.isAbiInt(zcu))
        cond_ty.intInfo(zcu)
    else if (cond_ty.isPtrAtRuntime(zcu)) cond_int_info: {
        // Pointer items are compared by address, so every item must be a fixed address.
        var cases_it = switch_br.iterateCases();
        while (cases_it.next()) |case| {
            for (case.items) |item| if (Constant.fromInterned(item.toInterned().?).getUnsignedInt(zcu) == null)
                return isel.fail("unsupported switch case item {f}", .{isel.fmtConstant(.fromInterned(item.toInterned().?))});
            for (case.ranges) |range| for (range) |bound| if (Constant.fromInterned(bound.toInterned().?).getUnsignedInt(zcu) == null)
                return isel.fail("unsupported switch case item {f}", .{isel.fmtConstant(.fromInterned(bound.toInterned().?))});
        }
        break :cond_int_info .{ .signedness = .unsigned, .bits = 64 };
    } else return isel.fail("bad switch cond {f}", .{isel.fmtType(cond_ty)});
    if (cond_int_info.bits > Value.max_parts * 64)
        return isel.fail("unsupported switch condition {f}", .{isel.fmtType(cond_ty)});

    const loop = if (is_loop) try isel.beginLoopSwitch(inst) else null;
    if (cond_int_info.bits > 64)
        try isel.switchWide(inst, loop, cond_int_info)
    else if (cond_int_info.bits == 1 or cond_ty.isPtrAtRuntime(zcu) or
        !try isel.switchTable(inst, loop, cond_int_info))
        try isel.switchChain(inst, loop, cond_int_info);
    if (loop) |target_loop| try isel.finishLoopSwitch(inst, target_loop);
}

/// A `loop_switch_br` keeps its condition in a stack slot, which every
/// `switch_dispatch` updates before restoring the loop's live registers. It
/// is the live value of the `loop_switch_br` instruction, which has no result
/// of its own. The dispatch loads it into temporary registers
/// (`loadLoopSwitchCondition`), so that a spilled condition cannot restore an
/// older iteration's value.
fn beginLoopSwitch(isel: *Select, inst: Air.Inst.Index) !*Loop {
    const zcu = isel.pt.zcu;
    const loop = isel.loops.getPtr(inst).?;
    try isel.values.ensureUnusedCapacity(zcu.gpa, 1);
    const cond_vi = isel.initValue(isel.air.typeOf(isel.air.unwrapSwitch(inst).operand, &zcu.intern_pool));
    cond_vi.setParent(isel, .{ .stack_slot = cond_vi.allocStackSlot(isel) });
    try isel.live_values.putNoClobber(zcu.gpa, inst, cond_vi.ref(isel));
    loop.live_registers = isel.live_registers;
    loop.repeat_list = Loop.empty_list;
    return loop;
}

/// Loads the condition of the `loop_switch_br` `inst` into `reg`, a
/// temporary register that is free before the load.
fn loadLoopSwitchCondition(isel: *Select, inst: Air.Inst.Index, reg: Register) !void {
    const cond_vi = isel.live_values.get(inst).?;
    const slot = cond_vi.parent(isel).stack_slot;
    try isel.loadReg(reg.alias, cond_vi.size(isel), cond_vi.signedness(isel), slot.base, slot.offset);
    isel.freeReg(reg.alias);
}

/// The start of a `loop_switch_br`: the dispatch is where `switch_dispatch`
/// repeats the loop, and the operand is stored as the first condition.
fn finishLoopSwitch(isel: *Select, inst: Air.Inst.Index, loop: *Loop) !void {
    try isel.merge(&loop.live_registers, .{ .fill_extra = true });
    loop.patchRepeats(isel);
    const cond_vi = isel.live_values.fetchRemove(inst).?.value;
    defer cond_vi.deref(isel);
    const slot = cond_vi.parent(isel).stack_slot;
    const switch_br = isel.air.unwrapSwitch(inst);
    const initial_vi = try isel.use(switch_br.operand);
    try initial_vi.store(
        isel,
        isel.air.typeOf(switch_br.operand, &isel.pt.zcu.intern_pool),
        slot.base,
        .{ .offset = @intCast(slot.offset) },
    );
}

/// The compare chain of a `switch_br` on an integer of at most 64 bits: a
/// compare of each prong's items and ranges, and a branch to the next prong
/// when none matches.
fn switchChain(isel: *Select, inst: Air.Inst.Index, loop: ?*Loop, cond_int_info: std.lang.Type.Int) !void {
    const zcu = isel.pt.zcu;
    const switch_br = isel.air.unwrapSwitch(inst);
    const cond_ref = if (loop != null) inst.toRef() else switch_br.operand;
    var final_case = true;
    if (switch_br.else_body_len > 0) {
        var cases_it = switch_br.iterateCases();
        while (cases_it.next()) |_| {}
        try isel.body(cases_it.elseBody(), null);
        final_case = false;
    }
    const zero_reg: Register = switch (cond_int_info.bits) {
        else => unreachable,
        1...32 => .wzr,
        33...64 => .xzr,
    };
    var cond_mat: ?Value.Materialize = null;
    var cond_reg: Register = undefined;
    var cases_it = switch_br.iterateCases();
    while (cases_it.next()) |case| {
        const next_label = isel.instructions.items.len;
        const next_live_registers = isel.live_registers;
        try isel.body(case.body, null);
        if (final_case) {
            final_case = false;
            continue;
        }
        try isel.merge(&next_live_registers, .{});
        if (cond_mat == null) {
            const cond_ra = if (loop != null) try isel.allocIntReg() else cond_ra: {
                const cond_vi = try isel.use(cond_ref);
                cond_mat = try cond_vi.matReg(isel);
                break :cond_ra cond_mat.?.ra;
            };
            cond_reg = switch (cond_int_info.bits) {
                else => unreachable,
                1...32 => cond_ra.w(),
                33...64 => cond_ra.x(),
            };
        }
        if (case.ranges.len == 0 and case.items.len == 1 and Constant.fromInterned(
            case.items[0].toInterned().?,
        ).getUnsignedInt(zcu) == 0) {
            try isel.emit(.cbnz(
                cond_reg,
                @intCast((isel.instructions.items.len + 1 - next_label) << 2),
            ));
        } else {
            try isel.emit(.@"b."(
                .invert(switch (case.ranges.len) {
                    0 => .eq,
                    else => .ls,
                }),
                @intCast((isel.instructions.items.len + 1 - next_label) << 2),
            ));
            var case_range_index = case.ranges.len;
            while (case_range_index > 0) {
                case_range_index -= 1;
                const range = case.ranges[case_range_index];
                const low = try isel.caseInt(.fromInterned(range[0].toInterned().?));
                const high = try isel.caseInt(.fromInterned(range[1].toInterned().?));
                const tmp_ra = if (regImmediate(cond_reg, low) == 0) cond_reg.alias else try isel.allocIntReg();
                defer if (tmp_ra != cond_reg.alias) isel.freeReg(tmp_ra);
                try isel.rangeCheck(cond_reg, switch (cond_reg.format.general) {
                    .word => tmp_ra.w(),
                    .doubleword => tmp_ra.x(),
                }, low, high, if (case_range_index > 0) .hi else if (case.items.len > 0) .ne else null);
            }
            var case_item_index = case.items.len;
            while (case_item_index > 0) {
                case_item_index -= 1;
                const item = regImmediate(cond_reg, try isel.caseInt(.fromInterned(case.items[case_item_index].toInterned().?)));
                if (case_item_index > 0)
                    try isel.ccmpImmediate(cond_reg, item, .{ .n = false, .z = true, .c = false, .v = false }, .ne)
                else
                    try isel.addSubImmediate(.sub, zero_reg, cond_reg, item, .{ .set_flags = true });
            }
        }
        if (loop != null) try isel.loadLoopSwitchCondition(inst, cond_reg);
    }
    if (cond_mat) |mat| try mat.finish(isel);
}

/// The compare chain of a `switch_br` on an integer of 65 to
/// `Value.max_parts * 64` bits: each item or range is compared into a bool.
fn switchWide(isel: *Select, inst: Air.Inst.Index, loop: ?*Loop, int_info: std.lang.Type.Int) !void {
    const switch_br = isel.air.unwrapSwitch(inst);
    const compare_ty = try isel.pt.intType(int_info.signedness, int_info.bits);
    const cond_ref = if (loop != null) inst.toRef() else switch_br.operand;

    var final_case = true;
    if (switch_br.else_body_len > 0) {
        var cases_it = switch_br.iterateCases();
        while (cases_it.next()) |_| {}
        try isel.body(cases_it.elseBody(), null);
        final_case = false;
    }
    var cases_it = switch_br.iterateCases();
    while (cases_it.next()) |case| {
        const next_label = isel.instructions.items.len;
        const next_live_registers = isel.live_registers;
        try isel.body(case.body, null);
        if (final_case) {
            final_case = false;
            continue;
        }
        try isel.merge(&next_live_registers, .{ .fill_extra = true });
        const body_label = isel.instructions.items.len;
        // Each successful comparison jumps to this arm. Otherwise execution
        // reaches the next arm, without carrying flags across materializations.
        const next_offset = std.math.cast(i28, (body_label + 1 - next_label) << 2) orelse
            return isel.fail("switch arm branch too large", .{});
        try isel.emit(.b(next_offset));
        const match_ra = try isel.allocIntReg();
        defer isel.freeReg(match_ra);
        const bound_ra = try isel.allocIntReg();
        defer isel.freeReg(bound_ra);
        const cond_vi = try isel.use(cond_ref);
        for (case.items) |item| {
            const body_offset = std.math.cast(i28, (isel.instructions.items.len + 1 - body_label) << 2) orelse
                return isel.fail("switch arm branch too large", .{});
            try isel.emit(.b(body_offset));
            try isel.emit(.tbz(match_ra.x(), 0, 8));
            try isel.cmp(match_ra, compare_ty, cond_vi, .eq, try isel.use(item));
        }
        for (case.ranges) |range| {
            const body_offset = std.math.cast(i28, (isel.instructions.items.len + 1 - body_label) << 2) orelse
                return isel.fail("switch arm branch too large", .{});
            try isel.emit(.b(body_offset));
            try isel.emit(.tbz(match_ra.x(), 0, 8));
            try isel.emit(.@"and"(match_ra.w(), match_ra.w(), .{ .register = bound_ra.w() }));
            try isel.cmp(bound_ra, compare_ty, cond_vi, .lte, try isel.use(range[1]));
            try isel.cmp(match_ra, compare_ty, cond_vi, .gte, try isel.use(range[0]));
        }
    }
}

/// Lowers a dense `switch_br` or `loop_switch_br` on an integer of at most 64
/// bits through a table of branches indexed by `cond - min`:
///
///     sub  idx, cond, #min
///     cmp  idx, #(max - min)
///     b.hi default
///     adr  addr, table
///     add  addr, addr, idx, lsl #2
///     br   addr
///   table:
///     b    case_for_min
///     ...
///
/// The table holds code, not data, and is addressed relative to the `adr`, so
/// it needs no relocations. Returns false, having emitted nothing, unless
/// there are at least `min_clusters` runs of consecutive values with the same
/// prong, the table has at most `max_len` entries, and either a quarter of
/// them are distinct items or ranges (the x86_64 backend's density rule) or
/// 40% of them belong to a prong (LLVM's density rule when optimizing for
/// size; a byte switch with a few wide ranges qualifies only by this one).
fn switchTable(
    isel: *Select,
    inst: Air.Inst.Index,
    loop: ?*Loop,
    int_info: std.lang.Type.Int,
) !bool {
    const min_clusters = 4;
    const max_len = 1024;
    const zcu = isel.pt.zcu;
    const gpa = zcu.gpa;
    const switch_br = isel.air.unwrapSwitch(inst);

    var prong_items: usize = 0;
    var min: i128 = std.math.maxInt(i128);
    var max: i128 = std.math.minInt(i128);
    {
        var cases_it = switch_br.iterateCases();
        while (cases_it.next()) |case| {
            prong_items += case.items.len + case.ranges.len;
            for (case.items) |item| {
                const value = try isel.caseInt(.fromInterned(item.toInterned().?));
                min = @min(min, value);
                max = @max(max, value);
            }
            for (case.ranges) |range| {
                min = @min(min, try isel.caseInt(.fromInterned(range[0].toInterned().?)));
                max = @max(max, try isel.caseInt(.fromInterned(range[1].toInterned().?)));
            }
        }
    }
    if (prong_items < min_clusters or max - min >= max_len) return false;
    const table_len: usize = @intCast(max - min + 1);

    const no_case = std.math.maxInt(u32);
    const targets = try gpa.alloc(u32, table_len);
    defer gpa.free(targets);
    @memset(targets, no_case);
    {
        var cases_it = switch_br.iterateCases();
        while (cases_it.next()) |case| {
            for (case.items) |item|
                targets[@intCast(try isel.caseInt(.fromInterned(item.toInterned().?)) - min)] = case.idx;
            for (case.ranges) |range| @memset(targets[@intCast(
                try isel.caseInt(.fromInterned(range[0].toInterned().?)) - min,
            )..@intCast(
                try isel.caseInt(.fromInterned(range[1].toInterned().?)) - min + 1,
            )], case.idx);
        }
    }
    var clusters: usize = 0;
    var covered: usize = 0;
    for (targets, 0..) |target, index| {
        if (target == no_case) continue;
        covered += 1;
        if (index == 0 or targets[index - 1] != target) clusters += 1;
    }
    if (clusters < min_clusters) return false;
    if (table_len > prong_items * 4 and table_len * 2 > covered * 5) return false;

    const case_labels = try gpa.alloc(u32, switch_br.cases_len);
    defer gpa.free(case_labels);
    var default_label: u32 = undefined;
    var cases_it = switch_br.iterateCases();
    if (switch_br.else_body_len > 0) {
        while (cases_it.next()) |_| {}
        try isel.body(cases_it.elseBody(), null);
        default_label = @intCast(isel.instructions.items.len);
        cases_it = switch_br.iterateCases();
    } else {
        // Without an else prong, the first prong also takes the values that
        // cannot occur, as in the compare chain.
        const case = cases_it.next().?;
        try isel.body(case.body, null);
        default_label = @intCast(isel.instructions.items.len);
        case_labels[case.idx] = default_label;
    }
    // As in the compare chain, each prong keeps the register assignments of
    // the prongs selected before it, so the registers at the dispatch agree
    // with every prong's entry.
    while (cases_it.next()) |case| {
        const prev_live_registers = isel.live_registers;
        try isel.body(case.body, null);
        try isel.merge(&prev_live_registers, .{});
        case_labels[case.idx] = @intCast(isel.instructions.items.len);
    }

    try isel.instructions.ensureUnusedCapacity(gpa, table_len);
    var table_index = table_len;
    while (table_index > 0) {
        table_index -= 1;
        const target = targets[table_index];
        const target_label = if (target == no_case) default_label else case_labels[target];
        try isel.emit(.b(std.math.cast(i28, (isel.instructions.items.len + 1 - target_label) << 2) orelse
            return isel.fail("switch table branch too large", .{})));
    }
    const table_label = isel.instructions.items.len;

    const cond_reg: Register, const cond_mat: ?Value.Materialize = if (loop != null) cond: {
        const cond_ra = try isel.allocIntReg();
        break :cond .{ switch (int_info.bits) {
            else => unreachable,
            1...32 => cond_ra.w(),
            33...64 => cond_ra.x(),
        }, null };
    } else cond: {
        const cond_mat = try (try isel.use(switch_br.operand)).matReg(isel);
        break :cond .{ switch (int_info.bits) {
            else => unreachable,
            1...32 => cond_mat.ra.w(),
            33...64 => cond_mat.ra.x(),
        }, cond_mat };
    };
    const addr_ra = try isel.allocIntReg();
    defer isel.freeReg(addr_ra);
    const idx_ra = try isel.allocIntReg();
    defer isel.freeReg(idx_ra);
    const idx_reg = rangeCheckReg(cond_reg, switch (cond_reg.format.general) {
        .word => idx_ra.w(),
        .doubleword => idx_ra.x(),
    }, min);
    try isel.emit(.br(addr_ra.x()));
    try isel.emit(.add(addr_ra.x(), addr_ra.x(), switch (idx_reg.format.general) {
        .word => .{ .extended_register = .{ .register = idx_reg, .extend = .{ .uxtw = 2 } } },
        .doubleword => .{ .shifted_register = .{ .register = idx_reg, .shift = .{ .lsl = 2 } } },
    }));
    try isel.emit(.adr(addr_ra.x(), @intCast((isel.instructions.items.len + 1 - table_label) << 2)));
    try isel.emitBranch(.{ .flags = .hi }, default_label);
    try isel.rangeCheck(cond_reg, idx_reg, min, max, null);
    if (cond_mat) |mat| try mat.finish(isel) else try isel.loadLoopSwitchCondition(inst, cond_reg);
    return true;
}

/// An inclusive range of case values, in the condition's signedness.
const CaseRange = struct {
    low: i128,
    high: i128,

    fn lessThan(_: void, lhs: CaseRange, rhs: CaseRange) bool {
        return lhs.low < rhs.low;
    }

    /// Sorts `ranges` and merges overlapping and adjacent ones; returns the merged length.
    fn merge(ranges: []CaseRange) usize {
        if (ranges.len == 0) return 0;
        std.mem.sort(CaseRange, ranges, {}, lessThan);
        var len: usize = 1;
        for (ranges[1..]) |range| {
            const last = &ranges[len - 1];
            if (range.low <= last.high +| 1) {
                last.high = @max(last.high, range.high);
            } else {
                ranges[len] = range;
                len += 1;
            }
        }
        return len;
    }
};

fn caseInt(isel: *Select, constant: Constant) !i128 {
    var bigint_space: Constant.BigIntSpace = undefined;
    return constant.toBigInt(&bigint_space, isel.pt.zcu).toInt(i128) catch
        return isel.fail("too big case item: {f}", .{isel.fmtConstant(constant)});
}

/// The bit pattern of `value` in a register of `reg`'s width.
fn regImmediate(reg: Register, value: i128) u64 {
    const bits: u64 = @truncate(@as(u128, @bitCast(value)));
    return switch (reg.format.general) {
        .word => bits & std.math.maxInt(u32),
        .doubleword => bits,
    };
}

/// Emits `dst = src op imm`, modulo the register width.
///
/// An immediate that `AddSubtractImmediate.encode` accepts takes one
/// instruction. Without `set_flags`, one of magnitude below 2^24 takes two,
/// and adding zero to `src` itself takes none. Any other immediate is
/// materialized in `scratch` (which may be `dst` when it differs from `src`),
/// or else in a temporary register.
pub fn addSubImmediate(
    isel: *Select,
    op: codegen.aarch64.encoding.Instruction.AddSubtractOp,
    dst: Register,
    src: Register,
    imm: u64,
    options: struct { set_flags: bool = false, scratch: ?Register = null },
) !void {
    const sf = src.format.general;
    const mask: u64 = switch (sf) {
        .word => std.math.maxInt(u32),
        .doubleword => std.math.maxInt(u64),
    };
    if (!options.set_flags and imm & mask == 0 and dst.alias == src.alias) return;
    if (AddSubtractImmediate.encode(op, imm, sf)) |enc| return enc.emit(isel, options.set_flags, dst, src);
    if (!options.set_flags) for ([_]struct { codegen.aarch64.encoding.Instruction.AddSubtractOp, u64 }{
        .{ op, imm & mask },
        .{ op.invert(), -%imm & mask },
    }) |candidate| {
        const candidate_op, const value = candidate;
        if (value >> 24 != 0) continue;
        // Instructions are emitted backwards: the low 12 bits are added first.
        const hi: AddSubtractImmediate = .{ .op = candidate_op, .imm = @intCast(value >> 12), .lsl_12 = true };
        const lo: AddSubtractImmediate = .{ .op = candidate_op, .imm = @truncate(value), .lsl_12 = false };
        try hi.emit(isel, false, dst, dst);
        try lo.emit(isel, false, dst, src);
        return;
    };
    const scratch_ra = if (options.scratch) |scratch| scratch.alias else try isel.allocIntReg();
    defer if (options.scratch == null) isel.freeReg(scratch_ra);
    const scratch_reg = switch (sf) {
        .word => scratch_ra.w(),
        .doubleword => scratch_ra.x(),
    };
    try isel.emit(switch (op) {
        .add => if (options.set_flags)
            .adds(dst, src, .{ .register = scratch_reg })
        else
            .add(dst, src, .{ .register = scratch_reg }),
        .sub => if (options.set_flags)
            .subs(dst, src, .{ .register = scratch_reg })
        else
            .sub(dst, src, .{ .register = scratch_reg }),
    });
    try isel.movImmediate(scratch_reg, imm & mask);
}

/// Emits `ccmp reg, #imm, nzcv, cond` (unsigned and equality conditions only).
fn ccmpImmediate(
    isel: *Select,
    reg: Register,
    imm: u64,
    nzcv: codegen.aarch64.encoding.Instruction.Nzcv,
    cond: codegen.aarch64.encoding.ConditionCode,
) !void {
    if (std.math.cast(u5, imm)) |pos_imm| return isel.emit(.ccmp(reg, .{ .immediate = pos_imm }, nzcv, cond));
    if (std.math.cast(u5, regImmediate(reg, -@as(i128, imm)))) |neg_imm|
        return isel.emit(.ccmn(reg, .{ .immediate = neg_imm }, nzcv, cond));
    const imm_ra = try isel.allocIntReg();
    defer isel.freeReg(imm_ra);
    const imm_reg = switch (reg.format.general) {
        .word => imm_ra.w(),
        .doubleword => imm_ra.x(),
    };
    try isel.emit(.ccmp(reg, .{ .register = imm_reg }, nzcv, cond));
    try isel.movImmediate(imm_reg, imm);
}

/// The register holding `reg - low` for a range check: `reg` itself when `low` is zero.
fn rangeCheckReg(reg: Register, tmp: Register, low: i128) Register {
    return if (regImmediate(reg, low) == 0) reg else tmp;
}

/// Emits flags for `low <= reg <= high`, as an unsigned `ls` on `reg - low`.
/// With a `chain` condition, the comparison only happens if the flags before
/// it satisfy that condition (no earlier match); otherwise they are forced to `ls`.
fn rangeCheck(
    isel: *Select,
    reg: Register,
    tmp: Register,
    low: i128,
    high: i128,
    chain: ?codegen.aarch64.encoding.ConditionCode,
) !void {
    const adjusted = rangeCheckReg(reg, tmp, low);
    const delta = regImmediate(reg, high - low);
    if (chain) |cond|
        try isel.ccmpImmediate(adjusted, delta, .{ .n = false, .z = true, .c = false, .v = false }, cond)
    else
        try isel.addSubImmediate(.sub, switch (reg.format.general) {
            .word => .wzr,
            .doubleword => .xzr,
        }, adjusted, delta, .{ .set_flags = true });
    if (adjusted.alias != reg.alias) try isel.addSubImmediate(.sub, adjusted, reg, regImmediate(reg, low), .{});
}

/// Sets `named_ra` to whether the integer in `src_reg` (of at most 64 bits,
/// described by `src_info`) is a named value of the exhaustive `enum_ty`. Values
/// outside the source type's range are ignored, so `src_reg` may hold an integer
/// of a different width than the tag. Contiguous tag values need one range
/// check, values within 64 of each other a bit test, and otherwise there is a
/// chain of conditional range compares.
fn isNamedEnumValue(
    isel: *Select,
    named_ra: Register.Alias,
    enum_ty: ZigType,
    src_reg: Register,
    src_info: std.lang.Type.Int,
) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const gpa = zcu.gpa;
    const loaded_enum = ip.loadEnumType(enum_ty.toIntern());
    const fields_len = loaded_enum.field_names.len;

    var ranges: std.ArrayList(CaseRange) = .empty;
    defer ranges.deinit(gpa);
    if (loaded_enum.field_values.len == 0) {
        if (fields_len > 0) try ranges.append(gpa, .{ .low = 0, .high = fields_len - 1 });
    } else {
        try ranges.ensureTotalCapacityPrecise(gpa, loaded_enum.field_values.len);
        for (loaded_enum.field_values.get(ip)) |field_value| {
            const value = try isel.caseInt(.fromInterned(field_value));
            ranges.appendAssumeCapacity(.{ .low = value, .high = value });
        }
    }
    {
        const src_min: i128 = switch (src_info.signedness) {
            .signed => -(@as(i128, 1) << @intCast(src_info.bits - 1)),
            .unsigned => 0,
        };
        const src_max: i128 = (@as(i128, 1) << @intCast(src_info.bits - @intFromBool(src_info.signedness == .signed))) - 1;
        var len: usize = 0;
        for (ranges.items) |range| {
            if (range.high < src_min or range.low > src_max) continue;
            ranges.items[len] = .{ .low = @max(range.low, src_min), .high = @min(range.high, src_max) };
            len += 1;
        }
        ranges.items.len = CaseRange.merge(ranges.items[0..len]);
    }
    if (ranges.items.len == 0) return isel.movImmediate(named_ra.w(), 0);

    const tmp_ra = try isel.allocIntReg();
    defer isel.freeReg(tmp_ra);
    const reg = src_reg;
    const tmp = switch (reg.format.general) {
        .word => tmp_ra.w(),
        .doubleword => tmp_ra.x(),
    };
    const min = ranges.items[0].low;
    const max = ranges.items[ranges.items.len - 1].high;
    if (ranges.items.len == 1) {
        try isel.emit(.csinc(named_ra.w(), .wzr, .wzr, .hi));
        try isel.rangeCheck(reg, tmp, min, max, null);
    } else if (max - min < 64) {
        var mask: u64 = 0;
        for (ranges.items) |range| {
            var value = range.low;
            while (value <= range.high) : (value += 1) mask |= @as(u64, 1) << @intCast(value - min);
        }
        const mask_ra = try isel.allocIntReg();
        defer isel.freeReg(mask_ra);
        try isel.emit(.csel(named_ra.w(), named_ra.w(), .wzr, .ls));
        try isel.emit(.ubfm(named_ra.w(), mask_ra.w(), .{ .N = .word, .immr = 0, .imms = 0 }));
        try isel.emit(.lsrv(mask_ra.x(), mask_ra.x(), rangeCheckReg(reg, tmp, min).alias.x()));
        try isel.rangeCheck(reg, tmp, min, max, null);
        try isel.movImmediate(mask_ra.x(), mask);
    } else {
        try isel.emit(.csinc(named_ra.w(), .wzr, .wzr, .hi));
        var range_index = ranges.items.len;
        while (range_index > 0) {
            range_index -= 1;
            const range = ranges.items[range_index];
            try isel.rangeCheck(reg, tmp, range.low, range.high, if (range_index > 0) .hi else null);
        }
    }
}

/// How a condition computed into the flags is consumed.
const CondUse = union(enum) {
    /// Materialize the condition as a bool in this register.
    reg: Register.Alias,
    /// Like `reg`, also storing the label of the instruction that sets the
    /// register, which a branch can skip to.
    reg_labeled: struct { ra: Register.Alias, label: *usize },
    /// Branch to this label when the condition holds. Instructions are
    /// emitted backwards, so everything emitted after the branch is placed
    /// before it and executes on both paths.
    branch: usize,

    fn emit(cond_use: CondUse, isel: *Select, cond: codegen.aarch64.encoding.ConditionCode) !void {
        switch (cond_use) {
            .reg => |ra| try isel.emit(.csinc(ra.w(), .wzr, .wzr, cond.invert())),
            .reg_labeled => |reg| {
                try isel.emit(.csinc(reg.ra.w(), .wzr, .wzr, cond.invert()));
                reg.label.* = isel.instructions.items.len;
            },
            .branch => |label| try isel.emitBranch(.{ .flags = cond }, label),
        }
    }
};

/// What a conditional branch tests.
const BranchCondition = union(enum) {
    /// The flags satisfy the condition (`b.cond`).
    flags: codegen.aarch64.encoding.ConditionCode,
    /// The register is zero (`cbz`).
    zero: Register,
    /// The register is not zero (`cbnz`).
    nonzero: Register,
    /// Bit 0 of the register is clear (`tbz`).
    bit0_clear: Register,
    /// Bit 0 of the register is set (`tbnz`).
    bit0_set: Register,

    fn invert(condition: BranchCondition) BranchCondition {
        return switch (condition) {
            .flags => |cond| .{ .flags = cond.invert() },
            .zero => |reg| .{ .nonzero = reg },
            .nonzero => |reg| .{ .zero = reg },
            .bit0_clear => |reg| .{ .bit0_set = reg },
            .bit0_set => |reg| .{ .bit0_clear = reg },
        };
    }

    /// The branch by `offset` bytes, or null when it is out of range.
    fn encode(condition: BranchCondition, offset: i28) ?codegen.aarch64.encoding.Instruction {
        return switch (condition) {
            .flags => |cond| .@"b."(cond, std.math.cast(i21, offset) orelse return null),
            .zero => |reg| .cbz(reg, std.math.cast(i21, offset) orelse return null),
            .nonzero => |reg| .cbnz(reg, std.math.cast(i21, offset) orelse return null),
            .bit0_clear => |reg| .tbz(reg, 0, std.math.cast(i16, offset) orelse return null),
            .bit0_set => |reg| .tbnz(reg, 0, std.math.cast(i16, offset) orelse return null),
        };
    }
};

/// Emits a branch to `label` taken when `condition` holds. When the only
/// instruction since `label` is a `b`, it becomes the inverse branch to that
/// `b`'s target instead. When `label` is out of range, the inverse branch
/// skips a `b label`.
fn emitBranch(isel: *Select, condition: BranchCondition, label: usize) !void {
    if (isel.soleBranchOffset(label)) |offset| if (condition.invert().encode(offset)) |branch| {
        isel.instructions.items[label] = branch;
        return;
    };
    const offset = std.math.cast(i28, (isel.instructions.items.len + 1 - label) << 2) orelse
        return isel.fail("conditional branch exceeds unconditional branch range", .{});
    if (condition.encode(offset)) |branch| return isel.emit(branch);
    // Instructions are emitted backwards: the inverse branch skips the `b`.
    try isel.emit(.b(offset));
    try isel.emit(condition.invert().encode(8).?);
}

/// For a condition that tests one register-sized part against zero (an
/// integer or pointer `==`/`!=` against a comptime zero, or a null check),
/// returns the tested value and its type, the part's offset and size, and whether the
/// condition holds when the part is zero.
fn zeroTestOperand(isel: *Select, cond_inst: Air.Inst.Index) !?struct { Value.Index, ZigType, u64, u64, bool } {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const air_tag = isel.air.instructions.items(.tag)[@backingInt(cond_inst)];
    const air_data = isel.air.instructions.items(.data)[@backingInt(cond_inst)];
    switch (air_tag) {
        else => return null,
        .cmp_eq, .cmp_neq => {
            const bin_op = air_data.bin_op;
            const ty = isel.air.typeOf(bin_op.lhs, ip);
            if (ty.isRuntimeFloat()) return null;
            const size = ty.abiSize(zcu);
            if (size == 0 or size > 8) return null;
            if (!(ty.toIntern() == .bool_type or ty.isAbiInt(zcu) or ty.isPtrAtRuntime(zcu))) return null;
            const operand, const constant = if (bin_op.rhs.toInterned()) |rhs|
                .{ bin_op.lhs, rhs }
            else if (bin_op.lhs.toInterned()) |lhs|
                .{ bin_op.rhs, lhs }
            else
                return null;
            if (operand.toInterned() != null) return null;
            const constant_val: Constant = .fromInterned(constant);
            if (constant_val.isUndef(zcu)) return null;
            if ((constant_val.getUnsignedInt(zcu) orelse return null) != 0) return null;
            return .{ try isel.use(operand), ty, 0, size, air_tag == .cmp_eq };
        },
        .is_null, .is_non_null => {
            const opt_ty = isel.air.typeOf(air_data.un_op, ip);
            const payload_ty = opt_ty.optionalChild(zcu);
            const payload_size = payload_ty.abiSize(zcu);
            const offset: u64, const size: u64 = if (!opt_ty.optionalReprIsPayload(zcu))
                .{ payload_size, 1 }
            else if (payload_ty.isSlice(zcu))
                .{ 0, 8 }
            else
                .{ 0, payload_size };
            if (size == 0 or size > 8) return null;
            return .{ try isel.use(air_data.un_op), opt_ty, offset, size, air_tag == .is_null };
        },
    }
}

/// `is_null` or `is_non_null` of an optional value, consumed by `res`.
fn isNullUse(isel: *Select, res: CondUse, air_tag: Air.Inst.Tag, un_op: Air.Inst.Ref) !void {
    const zcu = isel.pt.zcu;
    const opt_ty = isel.air.typeOf(un_op, &zcu.intern_pool);
    const payload_ty = opt_ty.optionalChild(zcu);
    const payload_size = payload_ty.abiSize(zcu);
    const has_value_offset, const has_value_size = if (!opt_ty.optionalReprIsPayload(zcu))
        .{ payload_size, 1 }
    else if (payload_ty.isSlice(zcu))
        .{ 0, 8 }
    else
        .{ 0, payload_size };

    try res.emit(isel, switch (air_tag) {
        else => unreachable,
        .is_null => .eq,
        .is_non_null => .ne,
    });
    const opt_vi = try isel.use(un_op);
    var has_value_part_it = opt_vi.field(opt_ty, has_value_offset, has_value_size);
    const has_value_part_vi = try has_value_part_it.only(isel);
    const has_value_part_mat = try has_value_part_vi.?.matReg(isel);
    try isel.emit(switch (has_value_size) {
        else => unreachable,
        1...4 => .subs(.wzr, has_value_part_mat.ra.w(), .{ .immediate = 0 }),
        5...8 => .subs(.xzr, has_value_part_mat.ra.x(), .{ .immediate = 0 }),
    });
    try has_value_part_mat.finish(isel);
}

/// `is_err` or `is_non_err` of an error union value, consumed by `res`.
fn isErrUse(isel: *Select, res: CondUse, air_tag: Air.Inst.Tag, un_op: Air.Inst.Ref) !void {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const error_union_ty = isel.air.typeOf(un_op, ip);
    const error_union_info = ip.indexToKey(error_union_ty.toIntern()).error_union_type;
    const error_set_ty: ZigType = .fromInterned(error_union_info.error_set_type);
    const payload_ty: ZigType = .fromInterned(error_union_info.payload_type);
    const error_set_offset = codegen.errUnionErrorOffset(payload_ty, zcu);
    const error_set_size = error_set_ty.abiSize(zcu);

    try res.emit(isel, switch (air_tag) {
        else => unreachable,
        .is_err => .ne,
        .is_non_err => .eq,
    });
    const error_union_vi = try isel.use(un_op);
    var error_set_part_it = error_union_vi.field(error_union_ty, error_set_offset, error_set_size);
    const error_set_part_vi = try error_set_part_it.only(isel);
    const error_set_part_mat = try error_set_part_vi.?.matReg(isel);
    try isel.emit(.ands(.wzr, error_set_part_mat.ra.w(), .{ .immediate = .{
        .N = .word,
        .immr = 0,
        .imms = @intCast(8 * error_set_size - 1),
    } }));
    try error_set_part_mat.finish(isel);
}

const RotateOperands = struct {
    src: Air.Inst.Ref,
    right: union(enum) {
        immediate: u6,
        /// The `shr` amount.
        by: Air.Inst.Ref,
        /// The `shl` amount, negated.
        by_negated: Air.Inst.Ref,
    },
};

/// `x << a | x >> b` (either order) with `a + b` equal to the width, as
/// `std.math.rotl`/`rotr` write a rotate, where nothing else uses the shifts:
/// a rotate right of `x` by `b`. `x` may also be two loads of the same pointer
/// among the instructions just before the `or` (`before`), as `v = v << 13 |
/// v >> 51` reads a local twice.
///
/// AIR has no rotate instruction, so this shape is all that is left of one by
/// the time it reaches a backend; the match only accepts exact rotates and
/// anything it does not recognize is selected as written.
fn rotateOperands(
    isel: *Select,
    bin_op: @FieldType(Air.Inst.Data, "bin_op"),
    bits: u16,
    before: []const Air.Inst.Index,
) ?RotateOperands {
    const tags = isel.air.instructions.items(.tag);
    const data = isel.air.instructions.items(.data);
    const shl_inst, const shr_inst = for ([2][2]Air.Inst.Ref{
        .{ bin_op.lhs, bin_op.rhs },
        .{ bin_op.rhs, bin_op.lhs },
    }) |operands| {
        const shl_inst = operands[0].toIndex() orelse continue;
        const shr_inst = operands[1].toIndex() orelse continue;
        if (tags[@backingInt(shl_inst)] == .shl and tags[@backingInt(shr_inst)] == .shr) break .{ shl_inst, shr_inst };
    } else return null;
    // Later uses were already selected; an earlier one just keeps that shift.
    if (isel.live_values.contains(shl_inst) or isel.live_values.contains(shr_inst)) return null;
    const shl = data[@backingInt(shl_inst)].bin_op;
    const shr = data[@backingInt(shr_inst)].bin_op;
    if (shl.lhs != shr.lhs and !isel.isSameLoad(shl.lhs, shr.lhs, before)) return null;
    if (isel.constantShiftAmount(shl.rhs)) |shl_amount| {
        const shr_amount = isel.constantShiftAmount(shr.rhs) orelse return null;
        if (shl_amount == 0 or shl_amount >= bits or shl_amount + shr_amount != bits) return null;
        return .{ .src = shl.lhs, .right = .{ .immediate = @intCast(shr_amount) } };
    }
    if (isel.isNegatedShiftAmount(shl.rhs, shr.rhs)) return .{ .src = shl.lhs, .right = .{ .by = shr.rhs } };
    if (isel.isNegatedShiftAmount(shr.rhs, shl.rhs)) return .{ .src = shl.lhs, .right = .{ .by_negated = shl.rhs } };
    return null;
}

/// Whether `a` and `b` are loads through the same pointer that both appear in the
/// last 8 instructions of `before`, with only shifts, `not`, wrapping add and
/// subtract (the other halves of a rotate) and debug statements between them,
/// none of which writes memory, so they load the same value.
fn isSameLoad(isel: *Select, a: Air.Inst.Ref, b: Air.Inst.Ref, before: []const Air.Inst.Index) bool {
    const tags = isel.air.instructions.items(.tag);
    const data = isel.air.instructions.items(.data);
    const a_inst = a.toIndex() orelse return false;
    const b_inst = b.toIndex() orelse return false;
    if (tags[@backingInt(a_inst)] != .load or tags[@backingInt(b_inst)] != .load) return false;
    const ptr = data[@backingInt(a_inst)].ty_op.operand;
    if (data[@backingInt(b_inst)].ty_op.operand != ptr) return false;
    if (isel.air.typeOf(ptr, &isel.pt.zcu.intern_pool).isVolatilePtr(isel.pt.zcu)) return false;
    var found: u2 = 0;
    var index = before.len;
    while (index > 0 and before.len - index < 8) {
        index -= 1;
        const inst = before[index];
        if (inst == a_inst or inst == b_inst) {
            found += 1;
            if (found == 2) return true;
            continue;
        }
        switch (tags[@backingInt(inst)]) {
            .shl, .shr, .not, .add_wrap, .sub_wrap, .dbg_stmt => {},
            else => return false,
        }
    }
    return false;
}

fn constantShiftAmount(isel: *Select, ref: Air.Inst.Ref) ?u64 {
    const ip = &isel.pt.zcu.intern_pool;
    return switch (ip.indexToKey(ref.toInterned() orelse return null)) {
        else => null,
        .int => |int| switch (int.storage) {
            .u64 => |amount| amount,
            .i64 => |amount| std.math.cast(u64, amount),
            .big_int => |big_int| big_int.toInt(u64) catch null,
        },
    };
}

/// Whether the shift amount `neg` is `1 +% ~amount` or `0 -% amount`, the amount
/// in the opposite direction that completes a rotate by `amount`.
fn isNegatedShiftAmount(isel: *Select, neg: Air.Inst.Ref, amount: Air.Inst.Ref) bool {
    const tags = isel.air.instructions.items(.tag);
    const data = isel.air.instructions.items(.data);
    const neg_inst = neg.toIndex() orelse return false;
    switch (tags[@backingInt(neg_inst)]) {
        else => return false,
        .add_wrap => {
            const neg_op = data[@backingInt(neg_inst)].bin_op;
            for ([2][2]Air.Inst.Ref{
                .{ neg_op.lhs, neg_op.rhs },
                .{ neg_op.rhs, neg_op.lhs },
            }) |operands| {
                if (isel.constantShiftAmount(operands[1]) != 1) continue;
                const not_inst = operands[0].toIndex() orelse continue;
                if (tags[@backingInt(not_inst)] == .not and data[@backingInt(not_inst)].ty_op.operand == amount) return true;
            }
            return false;
        },
        .sub_wrap => {
            const neg_op = data[@backingInt(neg_inst)].bin_op;
            return isel.constantShiftAmount(neg_op.lhs) == 0 and neg_op.rhs == amount;
        },
    }
}

/// The register contents of a comptime-known scalar operand of at most 8
/// bytes, as `Value.Materialize` would produce them: the integer sign- or
/// zero-extended to 32 bits for sizes up to 4 bytes, else to 64 bits.
/// Null when the value is not such a constant.
pub fn constantImmediate(isel: *Select, vi: Value.Index) ?u64 {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const constant = switch (vi.parent(isel)) {
        .constant => |constant| constant,
        else => return null,
    };
    if (vi.register(isel) != null or vi.isVector(isel) or vi.get(isel).flags.is_padding) return null;
    const size = vi.size(isel);
    if (size > 8) return null;
    const value: i65 = value: switch (ip.indexToKey(constant.toIntern())) {
        else => return null,
        .undef => return null,
        .simple_value => |simple_value| switch (simple_value) {
            .true => 1,
            .false => 0,
            else => return null,
        },
        .int => |int| switch (int.storage) {
            .u64 => |imm| imm,
            .i64 => |imm| imm,
            .big_int => |big_int| big_int.toInt(i65) catch return null,
        },
        .enum_tag => |enum_tag| continue :value ip.indexToKey(enum_tag.int),
    };
    return if (size <= 4) @as(u32, @truncate(@as(u65, @bitCast(value)))) else @as(u64, @truncate(@as(u65, @bitCast(value))));
}

pub const AddSubtractImmediate = struct {
    op: codegen.aarch64.encoding.Instruction.AddSubtractOp,
    imm: u12,
    lsl_12: bool,

    /// Encodes `n op imm`, modulo the register width, as an immediate add or
    /// subtract, negating the immediate and the operation if necessary. For
    /// a nonzero immediate, the negated form sets the same flags: the same
    /// result, the same signed overflow and, as `n + imm` carries exactly
    /// when `n - (2^W - imm)` does not borrow, the same carry.
    pub fn encode(
        op: codegen.aarch64.encoding.Instruction.AddSubtractOp,
        imm: u64,
        sf: codegen.aarch64.encoding.Register.GeneralSize,
    ) ?AddSubtractImmediate {
        const mask: u64 = switch (sf) {
            .word => std.math.maxInt(u32),
            .doubleword => std.math.maxInt(u64),
        };
        for ([_]struct { codegen.aarch64.encoding.Instruction.AddSubtractOp, u64 }{
            .{ op, imm & mask },
            .{ op.invert(), -%imm & mask },
        }) |candidate| {
            const candidate_op, const value = candidate;
            if (std.math.cast(u12, value)) |imm12| return .{ .op = candidate_op, .imm = imm12, .lsl_12 = false };
            if (value & 0xfff == 0) if (std.math.cast(u12, value >> 12)) |imm12|
                return .{ .op = candidate_op, .imm = imm12, .lsl_12 = true };
        }
        return null;
    }

    pub fn emit(enc: AddSubtractImmediate, isel: *Select, set_flags: bool, d: Register, n: Register) !void {
        const shift: codegen.aarch64.encoding.Instruction.DataProcessingImmediate.AddSubtractImmediate.Shift =
            if (enc.lsl_12) .@"12" else .@"0";
        try isel.emit(switch (enc.op) {
            .add => if (set_flags)
                .adds(d, n, .{ .shifted_immediate = .{ .immediate = enc.imm, .lsl = shift } })
            else
                .add(d, n, .{ .shifted_immediate = .{ .immediate = enc.imm, .lsl = shift } }),
            .sub => if (set_flags)
                .subs(d, n, .{ .shifted_immediate = .{ .immediate = enc.imm, .lsl = shift } })
            else
                .sub(d, n, .{ .shifted_immediate = .{ .immediate = enc.imm, .lsl = shift } }),
        });
    }
};

fn isFloatZeroConstant(isel: *Select, vi: Value.Index) bool {
    const constant = switch (vi.parent(isel)) {
        .constant => |constant| constant,
        else => return false,
    };
    if (vi.register(isel) != null) return false;
    return switch (isel.pt.zcu.intern_pool.indexToKey(constant.toIntern())) {
        else => false,
        .float => |float| switch (float.storage) {
            inline else => |value| value == 0,
        },
    };
}

/// If the only instruction emitted since `label` is an unconditional
/// branch with a final offset, returns that offset. A conditional branch to
/// `label` can then replace it in place with the inverted condition.
fn soleBranchOffset(isel: *Select, label: usize) ?i28 {
    if (isel.instructions.items.len != label + 1) return null;
    if (isel.branch_placeholder) |placeholder| if (placeholder == label) return null;
    switch (isel.instructions.items[label].decode()) {
        else => return null,
        .branch_exception_generating_system => |branch| switch (branch.decode()) {
            else => return null,
            .unconditional_branch_immediate => |unconditional| switch (unconditional.decode()) {
                .b => |b| return @as(i28, b.imm26) << 2,
                .bl => return null,
            },
        },
    }
}

fn cmp(
    isel: *Select,
    res_ra: Register.Alias,
    ty: ZigType,
    lhs_vi: Value.Index,
    op: std.math.CompareOperator,
    rhs_vi: Value.Index,
) !void {
    return isel.cmpUse(.{ .reg = res_ra }, ty, lhs_vi, op, rhs_vi);
}

/// Whether `cmpUse` can branch on a comparison of `ty` directly: the
/// soft-float comparisons prepare a call before consuming the flags.
fn cmpCanBranch(isel: *Select, ty: ZigType) bool {
    const zcu = isel.pt.zcu;
    if (ty.isRuntimeFloat()) return switch (ty.floatBits(isel.target)) {
        else => false,
        16, 32, 64 => true,
    };
    if (ty.toIntern() == .bool_type or ty.isPtrAtRuntime(zcu)) return true;
    return ty.isAbiInt(zcu) and ty.intInfo(zcu).bits <= Value.max_parts * 64;
}

fn cmpUse(
    isel: *Select,
    res: CondUse,
    ty: ZigType,
    orig_lhs_vi: Value.Index,
    orig_op: std.math.CompareOperator,
    orig_rhs_vi: Value.Index,
) !void {
    var lhs_vi = orig_lhs_vi;
    var op = orig_op;
    var rhs_vi = orig_rhs_vi;
    // Put a constant operand on the right, where it can be an immediate.
    if (lhs_vi.size(isel) <= 8 and
        (isel.constantImmediate(lhs_vi) != null or isel.isFloatZeroConstant(lhs_vi)) and
        isel.constantImmediate(rhs_vi) == null and !isel.isFloatZeroConstant(rhs_vi))
    {
        std.mem.swap(Value.Index, &lhs_vi, &rhs_vi);
        op = op.reverse();
    }
    if (!ty.isRuntimeFloat()) {
        const int_info: std.lang.Type.Int = if (ty.toIntern() == .bool_type)
            .{ .signedness = .unsigned, .bits = 1 }
        else if (ty.isAbiInt(isel.pt.zcu))
            ty.intInfo(isel.pt.zcu)
        else if (ty.isPtrAtRuntime(isel.pt.zcu))
            .{ .signedness = .unsigned, .bits = 64 }
        else if (ty.zigTypeTag(isel.pt.zcu) == .optional and ty.optionalReprIsPayload(isel.pt.zcu) and
            ty.optionalChild(isel.pt.zcu).zigTypeTag(isel.pt.zcu) == .error_set)
            // Null is the error value zero.
            ty.optionalChild(isel.pt.zcu).intInfo(isel.pt.zcu)
        else
            return isel.fail("bad cmp_{t} {f}", .{ op, isel.fmtType(ty) });
        if (int_info.bits > Value.max_parts * 64) {
            // Too many limbs for registers: compare in memory, then the
            // three-way result against zero.
            if (isel.target.cpu.arch.endian() != .little) return isel.fail("too big cmp_{t} {f}", .{ op, isel.fmtType(ty) });
            try res.emit(isel, switch (op) {
                .lt => .lt,
                .lte => .le,
                .eq => .eq,
                .gte => .ge,
                .gt => .gt,
                .neq => .ne,
            });
            try isel.values.ensureUnusedCapacity(isel.pt.zcu.gpa, 1);
            const order_vi = isel.initValue(.i8).ref(isel);
            defer order_vi.deref(isel);
            const order_mat = try order_vi.matReg(isel);
            try isel.emit(.subs(.wzr, order_mat.ra.w(), .{ .immediate = 0 }));
            try order_mat.finish(isel);
            try call.prepareReturn(isel);
            try call.returnLiveIn(isel, order_vi, .r0);
            try call.finishReturn(isel);
            // C does not define the high bits of a narrow integer result.
            try isel.normalizeIntReg(.r0, .r0, .{ .signedness = .signed, .bits = 8 });
            try call.prepareCallee(isel);
            try call.global(isel, "__cmp_limb64");
            try call.finishCallee(isel);
            try call.prepareParams(isel);
            try isel.movImmediate(.x3, int_info.bits);
            try isel.movImmediate(.x2, @intFromBool(int_info.signedness == .signed));
            try call.paramAddress(isel, rhs_vi, .r1);
            try call.paramAddress(isel, lhs_vi, .r0);
            try call.finishParams(isel);
            return;
        }
        try res.emit(isel, cond: switch (op) {
            .lt => switch (int_info.signedness) {
                .signed => .lt,
                .unsigned => .lo,
            },
            .lte => switch (int_info.bits) {
                else => unreachable,
                1...64 => switch (int_info.signedness) {
                    .signed => .le,
                    .unsigned => .ls,
                },
                65...(Value.max_parts * 64) => {
                    std.mem.swap(Value.Index, &lhs_vi, &rhs_vi);
                    continue :cond .gte;
                },
            },
            .eq => .eq,
            .gte => switch (int_info.signedness) {
                .signed => .ge,
                .unsigned => .hs,
            },
            .gt => switch (int_info.bits) {
                else => unreachable,
                1...64 => switch (int_info.signedness) {
                    .signed => .gt,
                    .unsigned => .hi,
                },
                65...(Value.max_parts * 64) => {
                    std.mem.swap(Value.Index, &lhs_vi, &rhs_vi);
                    continue :cond .lt;
                },
            },
            .neq => .ne,
        });

        if (int_info.bits <= 64) if (isel.constantImmediate(rhs_vi)) |imm| {
            const sf: codegen.aarch64.encoding.Register.GeneralSize = if (lhs_vi.size(isel) <= 4) .word else .doubleword;
            if (AddSubtractImmediate.encode(.sub, imm, sf)) |enc| {
                var lhs_part_it = lhs_vi.field(ty, 0, lhs_vi.size(isel));
                const lhs_part_mat = try (try lhs_part_it.only(isel)).?.matReg(isel);
                try enc.emit(isel, true, switch (sf) {
                    .word => .wzr,
                    .doubleword => .xzr,
                }, switch (sf) {
                    .word => lhs_part_mat.ra.w(),
                    .doubleword => lhs_part_mat.ra.x(),
                });
                try lhs_part_mat.finish(isel);
                return;
            }
        };

        var part_offset = if (int_info.bits > 64)
            @divCeil(@as(u64, int_info.bits), 64) * 8
        else
            lhs_vi.size(isel);
        while (part_offset > 0) {
            const part_size = @min(part_offset, 8);
            part_offset -= part_size;
            var lhs_part_it = lhs_vi.field(ty, part_offset, part_size);
            const lhs_part_vi = try lhs_part_it.only(isel);
            const lhs_part_mat = try lhs_part_vi.?.matReg(isel);
            var rhs_part_it = rhs_vi.field(ty, part_offset, part_size);
            const rhs_part_vi = try rhs_part_it.only(isel);
            const rhs_part_mat = try rhs_part_vi.?.matReg(isel);
            try isel.emit(switch (part_size) {
                else => unreachable,
                1...4 => switch (part_offset) {
                    0 => .subs(.wzr, lhs_part_mat.ra.w(), .{ .register = rhs_part_mat.ra.w() }),
                    else => switch (op) {
                        .lt, .lte, .gte, .gt => .sbcs(
                            .wzr,
                            lhs_part_mat.ra.w(),
                            rhs_part_mat.ra.w(),
                        ),
                        .eq, .neq => .ccmp(
                            lhs_part_mat.ra.w(),
                            .{ .register = rhs_part_mat.ra.w() },
                            .{ .n = false, .z = false, .c = false, .v = false },
                            .eq,
                        ),
                    },
                },
                5...8 => switch (part_offset) {
                    0 => .subs(.xzr, lhs_part_mat.ra.x(), .{ .register = rhs_part_mat.ra.x() }),
                    else => switch (op) {
                        .lt, .lte, .gte, .gt => .sbcs(
                            .xzr,
                            lhs_part_mat.ra.x(),
                            rhs_part_mat.ra.x(),
                        ),
                        .eq, .neq => .ccmp(
                            lhs_part_mat.ra.x(),
                            .{ .register = rhs_part_mat.ra.x() },
                            .{ .n = false, .z = false, .c = false, .v = false },
                            .eq,
                        ),
                    },
                },
            });
            if (int_info.bits > 64 and part_offset / 8 == (int_info.bits - 1) / 64) {
                const top_bits: u6 = @truncate(int_info.bits);
                if (top_bits > 0) {
                    // This extends the top limbs in the registers they are
                    // materialized in, which may be where the operands live.
                    // That only changes the bits above the integer, which are
                    // not part of its value and which every use extends.
                    for ([_]Register.Alias{ lhs_part_mat.ra, rhs_part_mat.ra }) |part_ra|
                        try isel.emit(switch (int_info.signedness) {
                            .signed => .sbfm(part_ra.x(), part_ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = top_bits - 1,
                            }),
                            .unsigned => .ubfm(part_ra.x(), part_ra.x(), .{
                                .N = .doubleword,
                                .immr = 0,
                                .imms = top_bits - 1,
                            }),
                        });
                }
            }
            try rhs_part_mat.finish(isel);
            try lhs_part_mat.finish(isel);
        }
        return;
    }
    switch (ty.floatBits(isel.target)) {
        else => unreachable,
        16, 32, 64 => |bits| {
            const need_fcvt = switch (bits) {
                else => unreachable,
                16 => !isel.target.cpu.has(.aarch64, .fullfp16),
                32, 64 => false,
            };
            try res.emit(isel, switch (op) {
                .lt => .lo,
                .lte => .ls,
                .eq => .eq,
                .gte => .ge,
                .gt => .gt,
                .neq => .ne,
            });

            if (!need_fcvt and isel.isFloatZeroConstant(rhs_vi)) {
                const lhs_mat = try lhs_vi.matReg(isel);
                try isel.emit(switch (bits) {
                    else => unreachable,
                    16 => .fcmp(lhs_mat.ra.h(), .zero),
                    32 => .fcmp(lhs_mat.ra.s(), .zero),
                    64 => .fcmp(lhs_mat.ra.d(), .zero),
                });
                try lhs_mat.finish(isel);
                return;
            }
            const lhs_mat = try lhs_vi.matReg(isel);
            const rhs_mat = try rhs_vi.matReg(isel);
            const lhs_ra = if (need_fcvt) try isel.allocVecReg() else lhs_mat.ra;
            defer if (need_fcvt) isel.freeReg(lhs_ra);
            const rhs_ra = if (need_fcvt) try isel.allocVecReg() else rhs_mat.ra;
            defer if (need_fcvt) isel.freeReg(rhs_ra);
            try isel.emit(bits: switch (bits) {
                else => unreachable,
                16 => if (need_fcvt)
                    continue :bits 32
                else
                    .fcmp(lhs_ra.h(), .{ .register = rhs_ra.h() }),
                32 => .fcmp(lhs_ra.s(), .{ .register = rhs_ra.s() }),
                64 => .fcmp(lhs_ra.d(), .{ .register = rhs_ra.d() }),
            });
            if (need_fcvt) {
                try isel.emit(.fcvt(rhs_ra.s(), rhs_mat.ra.h()));
                try isel.emit(.fcvt(lhs_ra.s(), lhs_mat.ra.h()));
            }
            try rhs_mat.finish(isel);
            try lhs_mat.finish(isel);
            return;
        },
        80, 128 => |bits| {
            try call.prepareReturn(isel);
            // The result is set right after the call, so no value that
            // lives across the call or is moved out of x0 may use its
            // register; a caller-saved one is already reserved.
            const res_lock: RegLock = switch (res) {
                .reg => |ra| isel.tryLockReg(ra),
                .reg_labeled => |reg| isel.tryLockReg(reg.ra),
                .branch => .empty,
            };
            try call.returnFill(isel, .r0);
            try res.emit(isel, cond: switch (op) {
                .lt => .lt,
                .lte => .le,
                .eq => .eq,
                .gte => {
                    std.mem.swap(Value.Index, &lhs_vi, &rhs_vi);
                    continue :cond .lte;
                },
                .gt => {
                    std.mem.swap(Value.Index, &lhs_vi, &rhs_vi);
                    continue :cond .lt;
                },
                .neq => .ne,
            });
            try isel.emit(.subs(.wzr, .w0, .{ .immediate = 0 }));
            try call.finishReturn(isel);
            res_lock.unlock(isel);

            try call.prepareCallee(isel);
            try call.global(isel, switch (bits) {
                else => unreachable,
                16 => "__cmphf2",
                32 => "__cmpsf2",
                64 => "__cmpdf2",
                80 => "__cmpxf2",
                128 => "__cmptf2",
            });
            try call.finishCallee(isel);

            try call.compilerRtParamValues(isel, &.{ .{ .vi = lhs_vi, .ty = ty }, .{ .vi = rhs_vi, .ty = ty } });
            return;
        },
    }
}

pub fn loadReg(
    isel: *Select,
    ra: Register.Alias,
    size: u64,
    signedness: std.lang.Signedness,
    base_ra: Register.Alias,
    offset: i65,
) !void {
    switch (size) {
        0 => unreachable,
        1 => {
            if (std.math.cast(u12, offset)) |unsigned_offset| return isel.emit(if (ra.isVector()) .ldr(
                ra.b(),
                .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } },
            ) else switch (signedness) {
                .signed => .ldrsb(ra.w(), .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } }),
                .unsigned => .ldrb(ra.w(), .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } }),
            });
            if (std.math.cast(i9, offset)) |signed_offset| return isel.emit(if (ra.isVector())
                .ldur(ra.b(), base_ra.x(), signed_offset)
            else switch (signedness) {
                .signed => .ldursb(ra.w(), base_ra.x(), signed_offset),
                .unsigned => .ldurb(ra.w(), base_ra.x(), signed_offset),
            });
        },
        2 => {
            if (std.math.cast(u13, offset)) |unsigned_offset| if (unsigned_offset % 2 == 0)
                return isel.emit(if (ra.isVector()) .ldr(
                    ra.h(),
                    .{ .unsigned_offset = .{
                        .base = base_ra.x(),
                        .offset = unsigned_offset,
                    } },
                ) else switch (signedness) {
                    .signed => .ldrsh(
                        ra.w(),
                        .{ .unsigned_offset = .{
                            .base = base_ra.x(),
                            .offset = unsigned_offset,
                        } },
                    ),
                    .unsigned => .ldrh(
                        ra.w(),
                        .{ .unsigned_offset = .{
                            .base = base_ra.x(),
                            .offset = unsigned_offset,
                        } },
                    ),
                });
            if (std.math.cast(i9, offset)) |signed_offset| return isel.emit(if (ra.isVector())
                .ldur(ra.h(), base_ra.x(), signed_offset)
            else switch (signedness) {
                .signed => .ldursh(ra.w(), base_ra.x(), signed_offset),
                .unsigned => .ldurh(ra.w(), base_ra.x(), signed_offset),
            });
        },
        3 => {
            const lo16_ra = try isel.allocIntReg();
            defer isel.freeReg(lo16_ra);
            try isel.emit(.orr(ra.w(), lo16_ra.w(), .{ .shifted_register = .{
                .register = ra.w(),
                .shift = .{ .lsl = 16 },
            } }));
            try isel.loadReg(ra, 1, signedness, base_ra, offset + 2);
            return isel.loadReg(lo16_ra, 2, .unsigned, base_ra, offset);
        },
        4 => {
            if (std.math.cast(u14, offset)) |unsigned_offset| if (unsigned_offset % 4 == 0) return isel.emit(.ldr(
                if (ra.isVector()) ra.s() else ra.w(),
                .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } },
            ));
            if (std.math.cast(i9, offset)) |signed_offset| return isel.emit(.ldur(
                if (ra.isVector()) ra.s() else ra.w(),
                base_ra.x(),
                signed_offset,
            ));
        },
        5, 6 => {
            const lo32_ra = try isel.allocIntReg();
            defer isel.freeReg(lo32_ra);
            try isel.emit(.orr(ra.x(), lo32_ra.x(), .{ .shifted_register = .{
                .register = ra.x(),
                .shift = .{ .lsl = 32 },
            } }));
            try isel.loadReg(ra, size - 4, signedness, base_ra, offset + 4);
            return isel.loadReg(lo32_ra, 4, .unsigned, base_ra, offset);
        },
        7 => {
            const lo32_ra = try isel.allocIntReg();
            defer isel.freeReg(lo32_ra);
            const lo48_ra = try isel.allocIntReg();
            defer isel.freeReg(lo48_ra);
            try isel.emit(.orr(ra.x(), lo48_ra.x(), .{ .shifted_register = .{
                .register = ra.x(),
                .shift = .{ .lsl = 32 + 16 },
            } }));
            try isel.loadReg(ra, 1, signedness, base_ra, offset + 4 + 2);
            try isel.emit(.orr(lo48_ra.x(), lo32_ra.x(), .{ .shifted_register = .{
                .register = lo48_ra.x(),
                .shift = .{ .lsl = 32 },
            } }));
            try isel.loadReg(lo48_ra, 2, .unsigned, base_ra, offset + 4);
            return isel.loadReg(lo32_ra, 4, .unsigned, base_ra, offset);
        },
        8 => {
            if (std.math.cast(u15, offset)) |unsigned_offset| if (unsigned_offset % 8 == 0) return isel.emit(.ldr(
                if (ra.isVector()) ra.d() else ra.x(),
                .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } },
            ));
            if (std.math.cast(i9, offset)) |signed_offset| return isel.emit(.ldur(
                if (ra.isVector()) ra.d() else ra.x(),
                base_ra.x(),
                signed_offset,
            ));
        },
        16 => {
            if (std.math.cast(u16, offset)) |unsigned_offset| if (unsigned_offset % 16 == 0) return isel.emit(.ldr(
                ra.q(),
                .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } },
            ));
            if (std.math.cast(i9, offset)) |signed_offset| return isel.emit(.ldur(ra.q(), base_ra.x(), signed_offset));
        },
        else => return isel.fail("bad load size: {d}", .{size}),
    }
    const ptr_ra = try isel.allocIntReg();
    defer isel.freeReg(ptr_ra);
    try isel.loadReg(ra, size, signedness, ptr_ra, 0);
    try isel.addSubImmediate(.add, ptr_ra.x(), base_ra.x(), @truncate(@as(u65, @bitCast(offset))), .{ .scratch = ptr_ra.x() });
}

pub fn storeReg(
    isel: *Select,
    ra: Register.Alias,
    size: u64,
    base_ra: Register.Alias,
    offset: i65,
) !void {
    switch (size) {
        0 => unreachable,
        1 => {
            if (std.math.cast(u12, offset)) |unsigned_offset| return isel.emit(if (ra.isVector()) .str(
                ra.b(),
                .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } },
            ) else .strb(
                ra.w(),
                .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } },
            ));
            if (std.math.cast(i9, offset)) |signed_offset| return isel.emit(if (ra.isVector())
                .stur(ra.b(), base_ra.x(), signed_offset)
            else
                .sturb(ra.w(), base_ra.x(), signed_offset));
        },
        2 => {
            if (std.math.cast(u13, offset)) |unsigned_offset| if (unsigned_offset % 2 == 0)
                return isel.emit(if (ra.isVector()) .str(
                    ra.h(),
                    .{ .unsigned_offset = .{
                        .base = base_ra.x(),
                        .offset = unsigned_offset,
                    } },
                ) else .strh(
                    ra.w(),
                    .{ .unsigned_offset = .{
                        .base = base_ra.x(),
                        .offset = unsigned_offset,
                    } },
                ));
            if (std.math.cast(i9, offset)) |signed_offset| return isel.emit(if (ra.isVector())
                .stur(ra.h(), base_ra.x(), signed_offset)
            else
                .sturh(ra.w(), base_ra.x(), signed_offset));
        },
        3 => {
            const hi8_ra = try isel.allocIntReg();
            defer isel.freeReg(hi8_ra);
            try isel.storeReg(hi8_ra, 1, base_ra, offset + 2);
            try isel.storeReg(ra, 2, base_ra, offset);
            return isel.emit(.ubfm(hi8_ra.w(), ra.w(), .{
                .N = .word,
                .immr = 16,
                .imms = 16 + 8 - 1,
            }));
        },
        4 => {
            if (std.math.cast(u14, offset)) |unsigned_offset| if (unsigned_offset % 4 == 0) return isel.emit(.str(
                if (ra.isVector()) ra.s() else ra.w(),
                .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } },
            ));
            if (std.math.cast(i9, offset)) |signed_offset| return isel.emit(.stur(
                if (ra.isVector()) ra.s() else ra.w(),
                base_ra.x(),
                signed_offset,
            ));
        },
        5 => {
            const hi8_ra = try isel.allocIntReg();
            defer isel.freeReg(hi8_ra);
            try isel.storeReg(hi8_ra, 1, base_ra, offset + 4);
            try isel.storeReg(ra, 4, base_ra, offset);
            return isel.emit(.ubfm(hi8_ra.x(), ra.x(), .{
                .N = .doubleword,
                .immr = 32,
                .imms = 32 + 8 - 1,
            }));
        },
        6 => {
            const hi16_ra = try isel.allocIntReg();
            defer isel.freeReg(hi16_ra);
            try isel.storeReg(hi16_ra, 2, base_ra, offset + 4);
            try isel.storeReg(ra, 4, base_ra, offset);
            return isel.emit(.ubfm(hi16_ra.x(), ra.x(), .{
                .N = .doubleword,
                .immr = 32,
                .imms = 32 + 16 - 1,
            }));
        },
        7 => {
            const hi16_ra = try isel.allocIntReg();
            defer isel.freeReg(hi16_ra);
            const hi8_ra = try isel.allocIntReg();
            defer isel.freeReg(hi8_ra);
            try isel.storeReg(hi8_ra, 1, base_ra, offset + 6);
            try isel.storeReg(hi16_ra, 2, base_ra, offset + 4);
            try isel.storeReg(ra, 4, base_ra, offset);
            try isel.emit(.ubfm(hi8_ra.x(), ra.x(), .{
                .N = .doubleword,
                .immr = 32 + 16,
                .imms = 32 + 16 + 8 - 1,
            }));
            return isel.emit(.ubfm(hi16_ra.x(), ra.x(), .{
                .N = .doubleword,
                .immr = 32,
                .imms = 32 + 16 - 1,
            }));
        },
        8 => {
            if (std.math.cast(u15, offset)) |unsigned_offset| if (unsigned_offset % 8 == 0) return isel.emit(.str(
                if (ra.isVector()) ra.d() else ra.x(),
                .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } },
            ));
            if (std.math.cast(i9, offset)) |signed_offset| return isel.emit(.stur(
                if (ra.isVector()) ra.d() else ra.x(),
                base_ra.x(),
                signed_offset,
            ));
        },
        16 => {
            assert(ra.isVector());
            if (std.math.cast(u16, offset)) |unsigned_offset| if (unsigned_offset % 16 == 0) return isel.emit(.str(
                ra.q(),
                .{ .unsigned_offset = .{
                    .base = base_ra.x(),
                    .offset = unsigned_offset,
                } },
            ));
            if (std.math.cast(i9, offset)) |signed_offset| return isel.emit(.stur(ra.q(), base_ra.x(), signed_offset));
        },
        else => return isel.fail("bad store size: {d}", .{size}),
    }
    const ptr_ra = try isel.allocIntReg();
    defer isel.freeReg(ptr_ra);
    try isel.storeReg(ra, size, ptr_ra, 0);
    try isel.addSubImmediate(.add, ptr_ra.x(), base_ra.x(), @truncate(@as(u65, @bitCast(offset))), .{ .scratch = ptr_ra.x() });
}

/// Fixed-size copies of at most this many bytes are inlined instead of calling memcpy.
const inline_copy_max_size = 256;
/// Overlapping copies hold every byte in a q register, at most this many bytes.
const inline_move_max_size = 128;

const CopyOperand = union(enum) {
    /// A pointer value.
    ptr: Value.Index,
    /// The memory of a value, from a byte offset.
    value: struct { vi: Value.Index, offset: u64 = 0 },
};

/// A part of an inline copy: 32 bytes in a pair of q registers, or 1 to 16
/// bytes in one register.
const CopyChunk = struct {
    offset: u8,
    size: u8,

    fn regs(chunk: CopyChunk) usize {
        return if (chunk.size == 32) 2 else 1;
    }
};

/// The chunks of an inline copy of `size` bytes, in execution order, as LLVM
/// copies small fixed sizes: 32-byte q-register pairs, then 16 bytes, then an
/// overlapping tail; below 16 bytes, the largest power of two from either end.
fn copyChunks(size: u64, buf: *[inline_copy_max_size / 32 + 2]CopyChunk) []const CopyChunk {
    var len: usize = 0;
    if (size >= 16) {
        var offset: u64 = 0;
        while (size - offset >= 32) : (offset += 32) {
            buf[len] = .{ .offset = @intCast(offset), .size = 32 };
            len += 1;
        }
        if (size - offset >= 16) {
            buf[len] = .{ .offset = @intCast(offset), .size = 16 };
            len += 1;
            offset += 16;
        }
        if (offset < size) {
            buf[len] = .{ .offset = @intCast(size - 16), .size = 16 };
            len += 1;
        }
    } else {
        const width = std.math.floorPowerOfTwo(u64, size);
        buf[0] = .{ .offset = 0, .size = @intCast(width) };
        len = 1;
        if (width < size) {
            buf[1] = .{ .offset = @intCast(size - width), .size = @intCast(width) };
            len = 2;
        }
    }
    return buf[0..len];
}

/// How an inline copy addresses one operand: memory of a value in a stack
/// slot directly from `sp` or `fp`; a pointer in its register; any other
/// memory of a value through its address in a scratch register.
const CopyBase = struct {
    ra: Register.Alias,
    offset: i65,
    kind: enum { direct, ptr, address },
    vi: Value.Index,
    vi_offset: u64,

    fn direct(isel: *Select, vi: Value.Index, vi_offset: u64, chunks: []const CopyChunk) ?CopyBase {
        var parent_vi = vi;
        var offset: i65 = parent_vi.get(isel).offset_from_parent + vi_offset;
        parent: switch (parent_vi.parent(isel)) {
            .unallocated => {
                const stack_slot = parent_vi.allocStackSlot(isel);
                parent_vi.setParent(isel, .{ .stack_slot = stack_slot });
                continue :parent .{ .stack_slot = stack_slot };
            },
            .stack_slot => |stack_slot| {
                switch (stack_slot.base) {
                    .sp, .fp => {},
                    else => return null,
                }
                offset += stack_slot.offset;
                if (!fits(offset, chunks)) return null;
                return .{ .ra = stack_slot.base, .offset = offset, .kind = .direct, .vi = vi, .vi_offset = vi_offset };
            },
            .value => |next_vi| {
                parent_vi = next_vi;
                offset += parent_vi.get(isel).offset_from_parent;
                continue :parent parent_vi.parent(isel);
            },
            .address, .constant, .stack_address => return null,
        }
    }

    /// A pointer that is a stack address is folded into the accesses.
    fn ptr(isel: *Select, vi: Value.Index, chunks: []const CopyChunk) CopyBase {
        switch (vi.parent(isel)) {
            else => {},
            .stack_address => |stack_address| if (fits(stack_address.offset, chunks)) return .{
                .ra = stack_address.base,
                .offset = stack_address.offset,
                .kind = .direct,
                .vi = vi,
                .vi_offset = 0,
            },
        }
        return .{ .ra = .zr, .offset = 0, .kind = .ptr, .vi = vi, .vi_offset = 0 };
    }

    /// Whether every access of `chunks` from `offset` has an immediate offset.
    fn fits(offset: i65, chunks: []const CopyChunk) bool {
        for (chunks) |chunk| {
            const width: u8 = @min(chunk.size, 16);
            var chunk_offset = offset + chunk.offset;
            while (chunk_offset < offset + chunk.offset + chunk.size) : (chunk_offset += width) {
                if (chunk_offset >= 0 and @rem(chunk_offset, width) == 0 and
                    @divExact(chunk_offset, width) < 1 << 12) continue;
                if (std.math.cast(i9, chunk_offset) != null) continue;
                return false;
            }
        }
        return true;
    }

    /// Loads or stores `chunk` of the operand with `regs`.
    fn emitChunk(base: CopyBase, isel: *Select, comptime is_load: bool, chunk: CopyChunk, regs: []const Register.Alias) !void {
        const offset = base.offset + chunk.offset;
        if (chunk.size == 32) {
            if (std.math.cast(i10, offset)) |pair_offset| if (@rem(pair_offset, 16) == 0) {
                return isel.emit(if (is_load)
                    .ldp(regs[0].q(), regs[1].q(), .{ .signed_offset = .{ .base = base.ra.x(), .offset = pair_offset } })
                else
                    .stp(regs[0].q(), regs[1].q(), .{ .signed_offset = .{ .base = base.ra.x(), .offset = pair_offset } }));
            };
            if (is_load) {
                try isel.loadReg(regs[1], 16, .unsigned, base.ra, offset + 16);
                try isel.loadReg(regs[0], 16, .unsigned, base.ra, offset);
            } else {
                try isel.storeReg(regs[1], 16, base.ra, offset + 16);
                try isel.storeReg(regs[0], 16, base.ra, offset);
            }
            return;
        }
        if (is_load)
            try isel.loadReg(regs[0], chunk.size, .unsigned, base.ra, offset)
        else
            try isel.storeReg(regs[0], chunk.size, base.ra, offset);
    }
};

/// Emits an inline copy of `size` bytes from `src` to `dst` (`copyChunks`).
/// With `overlap` (memmove), the operands may overlap, so every byte is loaded
/// before any is stored; otherwise (memcpy) they must not overlap.
/// Returns false, having emitted nothing, if the copy should call a function instead.
fn copyInline(isel: *Select, dst: CopyOperand, src: CopyOperand, size: u64, overlap: bool) !bool {
    if (size == 0 or size > @as(u64, if (overlap) inline_move_max_size else inline_copy_max_size)) return false;
    if (isel.target.cpu.has(.aarch64, .strict_align)) return false;
    var chunks_buf: [inline_copy_max_size / 32 + 2]CopyChunk = undefined;
    const chunks = copyChunks(size, &chunks_buf);

    // Without overlap, the chunks reuse the same registers.
    var regs_needed: usize = 0;
    for (chunks) |chunk| regs_needed = if (overlap) regs_needed + chunk.regs() else @max(regs_needed, chunk.regs());
    var regs_buf: [inline_move_max_size / 16 + 1]Register.Alias = undefined;
    var regs_len: usize = 0;
    defer for (regs_buf[0..regs_len]) |ra| isel.freeReg(ra);
    while (regs_len < regs_needed) : (regs_len += 1) switch (isel.tryAllocVecReg()) {
        .allocated => |ra| regs_buf[regs_len] = ra,
        // Under register pressure the call, which spills anyway, is no worse.
        .fill_candidate, .out_of_registers => return false,
    };

    var bases: [2]CopyBase = undefined;
    var bases_len: usize = 0;
    defer for (bases[0..bases_len]) |base| if (base.kind == .address) isel.freeReg(base.ra);
    for ([_]CopyOperand{ dst, src }) |operand| {
        switch (operand) {
            .ptr => |vi| bases[bases_len] = CopyBase.ptr(isel, vi, chunks),
            .value => |value| bases[bases_len] = CopyBase.direct(isel, value.vi, value.offset, chunks) orelse switch (isel.tryAllocIntReg()) {
                .allocated => |ra| .{ .ra = ra, .offset = 0, .kind = .address, .vi = value.vi, .vi_offset = value.offset },
                .fill_candidate, .out_of_registers => return false,
            },
        }
        bases_len += 1;
    }
    // Materializing a pointer cannot fail softly, so it comes last.
    var mats: [2]?Value.Materialize = .{ null, null };
    for ([_]CopyOperand{ dst, src }, &bases, &mats) |operand, *base, *mat| switch (operand) {
        .ptr => |vi| if (base.kind == .ptr) {
            mat.* = try vi.matReg(isel);
            base.* = .{ .ra = mat.*.?.ra, .offset = 0, .kind = .ptr, .vi = vi, .vi_offset = 0 };
        },
        .value => {},
    };
    const dst_base = bases[0];
    const src_base = bases[1];

    // Emitted backwards.
    const regs = regs_buf[0..regs_len];
    if (overlap) {
        var regs_end = regs.len;
        var chunk_index = chunks.len;
        while (chunk_index > 0) {
            chunk_index -= 1;
            const chunk = chunks[chunk_index];
            try dst_base.emitChunk(isel, false, chunk, regs[regs_end - chunk.regs() .. regs_end]);
            regs_end -= chunk.regs();
        }
        regs_end = regs.len;
        chunk_index = chunks.len;
        while (chunk_index > 0) {
            chunk_index -= 1;
            const chunk = chunks[chunk_index];
            try src_base.emitChunk(isel, true, chunk, regs[regs_end - chunk.regs() .. regs_end]);
            regs_end -= chunk.regs();
        }
    } else {
        var chunk_index = chunks.len;
        while (chunk_index > 0) {
            chunk_index -= 1;
            const chunk = chunks[chunk_index];
            try dst_base.emitChunk(isel, false, chunk, regs);
            try src_base.emitChunk(isel, true, chunk, regs);
        }
    }

    for (&bases, &mats) |*base, mat| switch (base.kind) {
        .direct => {},
        .ptr => try mat.?.finish(isel),
        .address => {
            // `paramAddressAt` frees the base register first.
            base.kind = .direct;
            try call.paramAddressAt(isel, base.vi, base.vi_offset, base.ra);
            // An indirect value's pointer can now live in the base register
            // (for example an incoming argument); only free a plain scratch.
            if (isel.live_registers.get(base.ra) == .allocating) isel.freeReg(base.ra);
        },
    };
    return true;
}

const DomInt = u8;

pub const Value = @import("Value.zig");
pub fn initValue(isel: *Select, ty: ZigType) Value.Index {
    const zcu = isel.pt.zcu;
    return isel.initValueAdvanced(ty.abiAlignment(zcu), 0, ty.abiSize(zcu));
}
pub fn initValueAdvanced(
    isel: *Select,
    parent_alignment: InternPool.Alignment,
    offset_from_parent: u64,
    size: u64,
) Value.Index {
    defer isel.values.addOneAssumeCapacity().* = .{
        .refs = 0,
        .flags = .{
            .alignment = .fromLog2Units(@min(parent_alignment.toLog2Units(), @ctz(offset_from_parent))),
            .parent_tag = .unallocated,
            .location_tag = if (size > 16) .large else .small,
            .parts_len_minus_one = 0,
        },
        .offset_from_parent = offset_from_parent,
        .parent_payload = .{ .unallocated = {} },
        .location_payload = if (size > 16) .{ .large = .{
            .size = size,
        } } else .{ .small = .{
            .size = @intCast(size),
            .signedness = .unsigned,
            .is_vector = false,
            .hint = .zr,
            .register = .zr,
        } },
        .parts = undefined,
    };
    return @fromBackingInt(@intCast(isel.values.items.len));
}
const WhichValues = enum { only_referenced, all };
pub fn dumpValues(isel: *Select, which: WhichValues) void {
    dumpValuesInner(isel, which) catch |err| @panic(@errorName(err));
}
fn dumpValuesInner(isel: *Select, which: WhichValues) !void {
    const zcu = isel.pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(isel.nav_index);

    const locked_stderr = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    const stderr = &locked_stderr.file_writer.interface;

    var reverse_live_values: std.array_hash_map.Auto(Value.Index, std.ArrayList(Air.Inst.Index)) = .empty;
    defer {
        for (reverse_live_values.values()) |*list| list.deinit(gpa);
        reverse_live_values.deinit(gpa);
    }
    {
        try reverse_live_values.ensureTotalCapacity(gpa, isel.live_values.count());
        var live_val_it = isel.live_values.iterator();
        while (live_val_it.next()) |live_val_entry| switch (live_val_entry.value_ptr.*) {
            _ => {
                const gop = reverse_live_values.getOrPutAssumeCapacity(live_val_entry.value_ptr.*);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(gpa, live_val_entry.key_ptr.*);
            },
            .allocating, .free => unreachable,
        };
    }

    var reverse_live_registers: std.AutoHashMapUnmanaged(Value.Index, Register.Alias) = .empty;
    defer reverse_live_registers.deinit(gpa);
    {
        try reverse_live_registers.ensureTotalCapacity(gpa, @typeInfo(Register.Alias).@"enum".field_names.len);
        var live_reg_it = isel.live_registers.iterator();
        while (live_reg_it.next()) |live_reg_entry| switch (live_reg_entry.value.*) {
            _ => reverse_live_registers.putAssumeCapacityNoClobber(live_reg_entry.value.*, live_reg_entry.key),
            .allocating, .free => {},
        };
    }

    var roots: std.array_hash_map.Auto(Value.Index, u32) = .empty;
    defer roots.deinit(gpa);
    {
        try roots.ensureTotalCapacity(gpa, isel.values.items.len);
        var vi: Value.Index = @fromBackingInt(@intCast(isel.values.items.len));
        while (@backingInt(vi) > 0) {
            vi = @fromBackingInt(@intCast(@backingInt(vi) - 1));
            if (which == .only_referenced and vi.get(isel).refs == 0) continue;
            while (true) switch (vi.parent(isel)) {
                .unallocated, .stack_slot, .constant, .stack_address => break,
                .value => |parent_vi| vi = parent_vi,
                .address => |address_vi| break roots.putAssumeCapacity(address_vi, 0),
            };
            roots.putAssumeCapacity(vi, 0);
        }
    }

    try stderr.print("# Begin {s} Value Dump: {f}:\n", .{ @typeName(Select), nav.fqn.fmt(ip) });
    while (roots.pop()) |root_entry| {
        const vi = root_entry.key;
        const value = vi.get(isel);
        try stderr.splatByteAll(' ', 2 * (@as(usize, 1) + root_entry.value));
        try stderr.print("${d}", .{@backingInt(vi)});
        {
            var first = true;
            if (reverse_live_values.get(vi)) |aiis| for (aiis.items) |aii| {
                if (aii == Block.main) {
                    try stderr.print("{s}%main", .{if (first) " <- " else ", "});
                } else {
                    try stderr.print("{s}%{d}", .{ if (first) " <- " else ", ", @backingInt(aii) });
                }
                first = false;
            };
            if (reverse_live_registers.get(vi)) |ra| {
                try stderr.print("{s}{t}", .{ if (first) " <- " else ", ", ra });
                first = false;
            }
        }
        try stderr.writeByte(':');
        switch (value.flags.parent_tag) {
            .unallocated => if (value.offset_from_parent != 0) try stderr.print(" +0x{x}", .{value.offset_from_parent}),
            .stack_slot => {
                try stderr.print(" [{t}, #{s}0x{x}", .{
                    value.parent_payload.stack_slot.base,
                    if (value.parent_payload.stack_slot.offset < 0) "-" else "",
                    @abs(value.parent_payload.stack_slot.offset),
                });
                if (value.offset_from_parent != 0) try stderr.print("+0x{x}", .{value.offset_from_parent});
                try stderr.writeByte(']');
            },
            .value => try stderr.print(" ${d}+0x{x}", .{ @backingInt(value.parent_payload.value), value.offset_from_parent }),
            .address => try stderr.print(" ${d}[0x{x}]", .{ @backingInt(value.parent_payload.address), value.offset_from_parent }),
            .stack_address => try stderr.print(" {t}+#0x{x}", .{ value.parent_payload.stack_address.base, value.parent_payload.stack_address.offset }),
            .constant => try stderr.print(" <{f}, {f}>", .{
                isel.fmtType(value.parent_payload.constant.typeOf(zcu)),
                isel.fmtConstant(value.parent_payload.constant),
            }),
        }
        try stderr.print(" align({t})", .{value.flags.alignment});
        switch (value.flags.location_tag) {
            .large => try stderr.print(" size=0x{x} large", .{value.location_payload.large.size}),
            .small => {
                const loc = value.location_payload.small;
                try stderr.print(" size=0x{x}", .{loc.size});
                switch (loc.signedness) {
                    .unsigned => {},
                    .signed => try stderr.writeAll(" signed"),
                }
                if (loc.hint != .zr) try stderr.print(" hint={t}", .{loc.hint});
                if (loc.register != .zr) try stderr.print(" loc={t}", .{loc.register});
            },
        }
        try stderr.print(" refs={d}\n", .{value.refs});

        var part_index = value.flags.parts_len_minus_one;
        if (part_index > 0) while (true) : (part_index -= 1) {
            roots.putAssumeCapacityNoClobber(
                @fromBackingInt(@intCast(@backingInt(value.parts) + part_index)),
                root_entry.value + 1,
            );
            if (part_index == 0) break;
        };
    }
    try stderr.print("# End {s} Value Dump: {f}\n\n", .{ @typeName(Select), nav.fqn.fmt(ip) });
}

fn hasRepeatedByteRepr(isel: *Select, constant: Constant) error{OutOfMemory}!?u8 {
    const zcu = isel.pt.zcu;
    const ty = constant.typeOf(zcu);
    const abi_size = std.math.cast(usize, ty.abiSize(zcu)) orelse return null;
    if (abi_size == 0) return null;
    const byte_buffer = try zcu.gpa.alloc(u8, abi_size);
    defer zcu.gpa.free(byte_buffer);
    @memset(byte_buffer, 0xaa);
    return if (try isel.writeToMemory(constant, byte_buffer) and
        std.mem.allEqual(u8, byte_buffer[1..], byte_buffer[0])) byte_buffer[0] else null;
}

pub fn writeToMemory(isel: *Select, constant: Constant, buffer: []u8) error{OutOfMemory}!bool {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    if (try isel.writeKeyToMemory(ip.indexToKey(constant.toIntern()), buffer)) return true;
    constant.writeToMemory(zcu, buffer) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ReinterpretDeclRef, error.IllDefinedMemoryLayout => return false,
    };
    return true;
}
fn writeKeyToMemory(isel: *Select, constant_key: InternPool.Key, buffer: []u8) error{OutOfMemory}!bool {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    switch (constant_key) {
        .int_type,
        .ptr_type,
        .array_type,
        .vector_type,
        .opt_type,
        .anyframe_type,
        .error_union_type,
        .simple_type,
        .struct_type,
        .tuple_type,
        .union_type,
        .opaque_type,
        .enum_type,
        .func_type,
        .error_set_type,
        .inferred_error_set_type,

        .enum_literal,
        .memoized_call,
        => unreachable, // not a runtime value
        .err => |err| {
            const error_int = ip.getErrorValueIfExists(err.name).?;
            switch (buffer.len) {
                else => unreachable,
                inline 1...4 => |size| std.mem.writeInt(
                    @Int(.unsigned, 8 * size),
                    buffer[0..size],
                    @intCast(error_int),
                    isel.target.cpu.arch.endian(),
                ),
            }
        },
        .error_union => |error_union| {
            const error_union_type = ip.indexToKey(error_union.ty).error_union_type;
            const error_set_ty: ZigType = .fromInterned(error_union_type.error_set_type);
            const payload_ty: ZigType = .fromInterned(error_union_type.payload_type);
            const error_set = buffer[@intCast(codegen.errUnionErrorOffset(payload_ty, zcu))..][0..@intCast(error_set_ty.abiSize(zcu))];
            switch (error_union.val) {
                .err_name => |err_name| if (!try isel.writeKeyToMemory(.{ .err = .{
                    .ty = error_set_ty.toIntern(),
                    .name = err_name,
                } }, error_set)) return false,
                .payload => |payload| {
                    if (!try isel.writeToMemory(
                        .fromInterned(payload),
                        buffer[@intCast(codegen.errUnionPayloadOffset(payload_ty, zcu))..][0..@intCast(payload_ty.abiSize(zcu))],
                    )) return false;
                    @memset(error_set, 0);
                },
            }
        },
        .opt => |opt| {
            const child_size: usize = @intCast(ZigType.fromInterned(ip.indexToKey(opt.ty).opt_type).abiSize(zcu));
            switch (opt.val) {
                .none => if (!ZigType.fromInterned(opt.ty).optionalReprIsPayload(zcu)) {
                    buffer[child_size] = @intFromBool(false);
                } else @memset(buffer[0..child_size], 0x00),
                else => |child_constant| {
                    if (!try isel.writeToMemory(.fromInterned(child_constant), buffer[0..child_size])) return false;
                    if (!ZigType.fromInterned(opt.ty).optionalReprIsPayload(zcu)) buffer[child_size] = @intFromBool(true);
                },
            }
        },
        .un => |un| {
            const loaded_union = ip.loadUnionType(un.ty);
            if (loaded_union.layout == .@"packed") return false;
            const union_layout = ZigType.getUnionLayout(loaded_union, zcu);
            @memset(buffer[0..@intCast(ZigType.fromInterned(un.ty).abiSize(zcu))], 0xaa);
            if (loaded_union.has_runtime_tag) {
                if (!try isel.writeToMemory(
                    .fromInterned(un.tag),
                    buffer[@intCast(union_layout.tagOffset())..][0..@intCast(union_layout.tag_size)],
                )) return false;
            }
            const payload_ty: ZigType = .fromInterned(ip.typeOf(un.val));
            if (payload_ty.hasRuntimeBits(zcu)) {
                if (!try isel.writeToMemory(
                    .fromInterned(un.val),
                    buffer[@intCast(union_layout.payloadOffset())..][0..@intCast(payload_ty.abiSize(zcu))],
                )) return false;
            }
        },
        .aggregate => |aggregate| switch (ip.indexToKey(aggregate.ty)) {
            else => unreachable,
            .array_type => |array_type| {
                var elem_offset: usize = 0;
                const elem_size: usize = @intCast(ZigType.fromInterned(array_type.child).abiSize(zcu));
                const len_including_sentinel: usize = @intCast(array_type.lenIncludingSentinel());
                switch (aggregate.storage) {
                    .bytes => |bytes| @memcpy(buffer[0..len_including_sentinel], bytes.toSlice(len_including_sentinel, ip)),
                    .elems => |elems| for (elems) |elem| {
                        if (!try isel.writeToMemory(.fromInterned(elem), buffer[elem_offset..][0..elem_size])) return false;
                        elem_offset += elem_size;
                    },
                    .repeated_elem => |repeated_elem| for (0..len_including_sentinel) |elem_index| {
                        // The sentinel is not repeated.
                        const elem = if (elem_index < array_type.len) repeated_elem else array_type.sentinel;
                        if (!try isel.writeToMemory(.fromInterned(elem), buffer[elem_offset..][0..elem_size])) return false;
                        elem_offset += elem_size;
                    },
                }
            },
            .vector_type => return false,
            .struct_type => {
                const loaded_struct = ip.loadStructType(aggregate.ty);
                switch (loaded_struct.layout) {
                    .auto => {
                        var field_offset: u64 = 0;
                        var field_it = loaded_struct.iterateRuntimeOrder(ip);
                        while (field_it.next()) |field_index| {
                            if (loaded_struct.field_is_comptime_bits.get(ip, field_index)) continue;
                            const field_ty: ZigType = .fromInterned(loaded_struct.field_types.get(ip)[field_index]);
                            field_offset = loaded_struct.field_offsets.get(ip)[field_index];
                            const field_size = field_ty.abiSize(zcu);
                            if (!try isel.writeToMemory(.fromInterned(switch (aggregate.storage) {
                                .bytes => unreachable,
                                .elems => |elems| elems[field_index],
                                .repeated_elem => |repeated_elem| repeated_elem,
                            }), buffer[@intCast(field_offset)..][0..@intCast(field_size)])) return false;
                            field_offset += field_size;
                        }
                    },
                    .@"extern", .@"packed" => return false,
                }
            },
            .tuple_type => |tuple_type| {
                var field_offset: u64 = 0;
                for (tuple_type.types.get(ip), tuple_type.values.get(ip), 0..) |field_type, field_value, field_index| {
                    if (field_value != .none) continue;
                    const field_ty: ZigType = .fromInterned(field_type);
                    field_offset = field_ty.abiAlignment(zcu).forward(field_offset);
                    const field_size = field_ty.abiSize(zcu);
                    if (!try isel.writeToMemory(.fromInterned(switch (aggregate.storage) {
                        .bytes => unreachable,
                        .elems => |elems| elems[field_index],
                        .repeated_elem => |repeated_elem| repeated_elem,
                    }), buffer[@intCast(field_offset)..][0..@intCast(field_size)])) return false;
                    field_offset += field_size;
                }
            },
        },
        else => return false,
    }
    return true;
}

const TryAllocRegResult = union(enum) {
    allocated: Register.Alias,
    fill_candidate: Register.Alias,
    out_of_registers,
};

pub fn tryAllocIntReg(isel: *Select) TryAllocRegResult {
    var failed_result: TryAllocRegResult = .out_of_registers;
    var ra: Register.Alias = .r0;
    while (true) : (ra = @fromBackingInt(@intCast(@backingInt(ra) + 1))) {
        if (ra == .r18) continue; // The Platform Register
        if (ra == Register.Alias.fp) continue;
        if (isel.promotion.pinned.contains(ra)) continue;
        const live_vi = isel.live_registers.getPtr(ra);
        switch (live_vi.*) {
            _ => switch (failed_result) {
                .allocated => unreachable,
                .fill_candidate => {},
                .out_of_registers => failed_result = .{ .fill_candidate = ra },
            },
            .allocating => {},
            .free => {
                live_vi.* = .allocating;
                isel.saved_registers.insert(ra);
                return .{ .allocated = ra };
            },
        }
        if (ra == Register.Alias.lr) return failed_result;
    }
}

pub fn allocIntReg(isel: *Select) !Register.Alias {
    switch (isel.tryAllocIntReg()) {
        .allocated => |ra| return ra,
        .fill_candidate => |ra| {
            assert(try isel.fillMemory(ra));
            isel.reserveReg(ra);
            return ra;
        },
        .out_of_registers => {
            if (isel.promotion.enabled) return error.RetryWithoutPromotion;
            return isel.fail("ran out of registers", .{});
        },
    }
}

pub fn tryAllocVecReg(isel: *Select) TryAllocRegResult {
    var failed_result: TryAllocRegResult = .out_of_registers;
    var ra: Register.Alias = .v0;
    while (true) : (ra = @fromBackingInt(@intCast(@backingInt(ra) + 1))) {
        if (isel.promotion.pinned.contains(ra)) continue;
        const live_vi = isel.live_registers.getPtr(ra);
        switch (live_vi.*) {
            _ => switch (failed_result) {
                .allocated => unreachable,
                .fill_candidate => {},
                .out_of_registers => failed_result = .{ .fill_candidate = ra },
            },
            .allocating => {},
            .free => {
                live_vi.* = .allocating;
                isel.saved_registers.insert(ra);
                return .{ .allocated = ra };
            },
        }
        if (ra == Register.Alias.v31) return failed_result;
    }
}

pub fn allocVecReg(isel: *Select) !Register.Alias {
    switch (isel.tryAllocVecReg()) {
        .allocated => |ra| return ra,
        .fill_candidate => |ra| {
            assert(try isel.fillMemory(ra));
            isel.reserveReg(ra);
            return ra;
        },
        .out_of_registers => {
            if (isel.promotion.enabled) return error.RetryWithoutPromotion;
            return isel.fail("ran out of registers", .{});
        },
    }
}

/// Reserves `ra`, which is free, for the caller: allocation and `fill` leave
/// it alone until `freeReg`.
pub fn reserveReg(isel: *Select, ra: Register.Alias) void {
    assert(ra != .zr);
    const live_vi = isel.live_registers.getPtr(ra);
    assert(live_vi.* == .free);
    live_vi.* = .allocating;
}

/// A register reserved for a scope, or none.
pub const RegLock = struct {
    ra: Register.Alias,
    pub const empty: RegLock = .{ .ra = .zr };
    pub fn unlock(lock: RegLock, isel: *Select) void {
        switch (lock.ra) {
            else => |ra| isel.freeReg(ra),
            .zr => {},
        }
    }
};
pub fn lockReg(isel: *Select, ra: Register.Alias) RegLock {
    isel.reserveReg(ra);
    return .{ .ra = ra };
}
/// Reserves `ra` if it is free; an already reserved register is left to
/// whoever reserved it.
pub fn tryLockReg(isel: *Select, ra: Register.Alias) RegLock {
    assert(ra != .zr);
    switch (isel.live_registers.get(ra)) {
        _ => unreachable,
        .allocating => return .empty,
        .free => return isel.lockReg(ra),
    }
}

pub fn freeReg(isel: *Select, ra: Register.Alias) void {
    assert(ra != .zr);
    const live_vi = isel.live_registers.getPtr(ra);
    assert(live_vi.* == .allocating);
    live_vi.* = .free;
}

pub fn use(isel: *Select, air_ref: Air.Inst.Ref) !Value.Index {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const vi, const ty = if (air_ref.toIndex()) |air_inst_index| vi_ty: {
        if (isel.live_values.get(air_inst_index)) |vi| return vi;
        const ty = isel.air.typeOf(air_ref, ip);
        // A `ret_ptr` returned through the caller's pointer was already given
        // that pointer's value during analysis, so it is not a local here.
        const stack_address: ?Value.Indirect = switch (isel.air.instructions.items(.tag)[@backingInt(air_inst_index)]) {
            .alloc, .ret_ptr => try isel.allocLocal(ty),
            else => try isel.derivedStackAddress(air_inst_index),
        };
        try isel.values.ensureUnusedCapacity(zcu.gpa, 1);
        const live_gop = try isel.live_values.getOrPut(zcu.gpa, air_inst_index);
        assert(!live_gop.found_existing);
        const vi = isel.initValue(ty);
        tracking_log.debug("${d} <- %{d}", .{
            @backingInt(vi),
            @backingInt(air_inst_index),
        });
        if (stack_address) |address| vi.setParent(isel, .{ .stack_address = address });
        // A load of a promoted local that no store separates from its uses
        // prefers the local's register: the load is then free.
        if (isel.promotion.enabled) {
            if (isel.promotion.local_loads.get(air_inst_index)) |load| if (load.aliasable) {
                const local = isel.promotion.locals.values()[load.local];
                if (local.ra != .zr) vi.setHint(isel, local.ra);
            };
            if (isel.promotion.pinned_value_regs.count() > 0) if (isel.promotion.pinned_values.get(air_inst_index)) |value| {
                if (value.ra != .zr) if (value.pair) {
                    // Split now so that each part has its register.
                    try isel.values.ensureUnusedCapacity(zcu.gpa, 2);
                    vi.setParts(isel, 2);
                    vi.addPart(isel, 0, 8).setPin(isel, value.ra);
                    vi.addPart(isel, 8, 8).setPin(isel, value.ra2);
                } else vi.setPin(isel, value.ra);
            };
        }
        live_gop.value_ptr.* = vi.ref(isel);
        break :vi_ty .{ vi, ty };
    } else vi_ty: {
        try isel.values.ensureUnusedCapacity(zcu.gpa, 1);
        const constant: Constant = .fromInterned(air_ref.toInterned().?);
        const ty = constant.typeOf(zcu);
        const vi = isel.initValue(ty);
        tracking_log.debug("${d} <- <{f}, {f}>", .{
            @backingInt(vi),
            isel.fmtType(ty),
            isel.fmtConstant(constant),
        });
        vi.setParent(isel, .{ .constant = constant });
        break :vi_ty .{ vi, ty };
    };
    if (ty.isAbiInt(zcu)) {
        const int_info = ty.intInfo(zcu);
        if (int_info.bits <= 16) vi.setSignedness(isel, int_info.signedness);
    } else if (Value.isVectorSize(vi.size(isel)) and
        CallAbiIterator.homogeneousAggregateBaseType(zcu, ty.toIntern()) != null) vi.setIsVector(isel);
    return vi;
}

/// Allocates the stack slot that an `alloc` or `ret_ptr` of type `ptr_ty` points to.
fn allocLocal(isel: *Select, ptr_ty: ZigType) !Value.Indirect {
    const zcu = isel.pt.zcu;
    const slot_size = ptr_ty.childType(zcu).abiSize(zcu);
    const slot_offset = ptr_ty.ptrAlignment(zcu).forward(isel.stack_size);
    isel.stack_size = std.math.cast(u24, slot_offset + slot_size) orelse
        return isel.fail("stack frame too large: {d} bytes", .{slot_offset + slot_size});
    tracking_log.debug("local -> [sp, #0x{x}]", .{slot_offset});
    return .{ .base = .sp, .offset = @intCast(slot_offset) };
}

/// An instruction that computes its operand plus a constant offset, without
/// side effects. If the operand is the address of a local, so is the result.
fn constantOffsetPointer(isel: *Select, inst: Air.Inst.Index) ?struct { Air.Inst.Ref, u64 } {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    const data = isel.air.instructions.items(.data)[@backingInt(inst)];
    switch (isel.air.instructions.items(.tag)[@backingInt(inst)]) {
        else => return null,
        .bit_cast, .ptr_cast, .int_from_ptr => {
            const dst_ty = data.ty_op.ty;
            const src_ty = isel.air.typeOf(data.ty_op.operand, ip);
            if (!src_ty.isPtrAtRuntime(zcu) or src_ty.abiSize(zcu) != 8) return null;
            if (!dst_ty.isPtrAtRuntime(zcu) and !dst_ty.isAbiInt(zcu)) return null;
            if (dst_ty.abiSize(zcu) != 8) return null;
            return .{ data.ty_op.operand, 0 };
        },
        .optional_payload_ptr, .ptr_slice_ptr_ptr => return .{ data.ty_op.operand, 0 },
        .ptr_slice_len_ptr => return .{ data.ty_op.operand, 8 },
        .struct_field_ptr => {
            const extra = isel.air.extraData(Air.StructField, data.ty_pl.payload).data;
            return .{ extra.struct_operand, codegen.fieldOffset(
                isel.air.typeOf(extra.struct_operand, ip),
                data.ty_pl.ty,
                extra.field_index,
                zcu,
            ) };
        },
        inline .struct_field_ptr_index_0,
        .struct_field_ptr_index_1,
        .struct_field_ptr_index_2,
        .struct_field_ptr_index_3,
        => |air_tag| return .{ data.ty_op.operand, codegen.fieldOffset(
            isel.air.typeOf(data.ty_op.operand, ip),
            data.ty_op.ty,
            switch (air_tag) {
                else => comptime unreachable,
                .struct_field_ptr_index_0 => 0,
                .struct_field_ptr_index_1 => 1,
                .struct_field_ptr_index_2 => 2,
                .struct_field_ptr_index_3 => 3,
            },
            zcu,
        ) },
    }
}

/// The stack address computed by `inst`, if it is a constant offset from a local.
fn derivedStackAddress(isel: *Select, inst: Air.Inst.Index) Error!?Value.Indirect {
    const operand, const offset = isel.constantOffsetPointer(inst) orelse return null;
    // Only create the operand's value early when it is rooted at a local.
    var root = operand.toIndex() orelse return null;
    while (true) switch (isel.air.instructions.items(.tag)[@backingInt(root)]) {
        .alloc, .ret_ptr => break,
        else => root = (isel.constantOffsetPointer(root) orelse return null)[0].toIndex() orelse return null,
    };
    const operand_vi = try isel.use(operand);
    return switch (operand_vi.parent(isel)) {
        else => null,
        .stack_address => |stack_address| if (std.math.cast(u24, @as(u64, @intCast(stack_address.offset)) + offset)) |total|
            .{ .base = stack_address.base, .offset = total }
        else
            null,
    };
}

/// Whether `loadReg`/`storeReg` of `size` bytes at `offset` from a base
/// register encode without a scratch address register.
fn memoryOffsetFits(size: u64, offset: i65) bool {
    return switch (size) {
        else => false,
        1 => std.math.cast(u12, offset) != null or std.math.cast(i9, offset) != null,
        2, 4, 8, 16 => if (std.math.cast(u24, offset)) |unsigned_offset|
            unsigned_offset % size == 0 and unsigned_offset / size <= std.math.maxInt(u12) or
                std.math.cast(i9, offset) != null
        else
            std.math.cast(i9, offset) != null,
        3 => memoryOffsetFits(2, offset) and memoryOffsetFits(1, offset + 2),
        5, 6 => memoryOffsetFits(4, offset) and memoryOffsetFits(size - 4, offset + 4),
        7 => memoryOffsetFits(4, offset) and memoryOffsetFits(2, offset + 4) and memoryOffsetFits(1, offset + 6),
    };
}

/// The base and offset to access memory through the pointer `ptr_vi`: a stack
/// address is folded into the access, anything else is materialized.
const MemoryBase = struct {
    ra: Register.Alias,
    offset: u64,
    mat: ?Value.Materialize,

    fn init(isel: *Select, ptr_vi: Value.Index) !MemoryBase {
        switch (ptr_vi.parent(isel)) {
            else => {},
            .stack_address => |stack_address| return .{
                .ra = stack_address.base,
                .offset = @intCast(stack_address.offset),
                .mat = null,
            },
        }
        const mat = try ptr_vi.matReg(isel);
        return .{ .ra = mat.ra, .offset = 0, .mat = mat };
    }

    fn finish(base: MemoryBase, isel: *Select) !void {
        if (base.mat) |mat| try mat.finish(isel);
    }
};

/// Emits `dst = base + offset` for a stack address.
pub fn stackAddress(isel: *Select, dst_ra: Register.Alias, stack_address: Value.Indirect) !void {
    try isel.addSubImmediate(
        .add,
        dst_ra.x(),
        stack_address.base.x(),
        @bitCast(@as(i64, stack_address.offset)),
        .{ .scratch = dst_ra.x() },
    );
}

pub fn fill(isel: *Select, dst_ra: Register.Alias) Error!bool {
    switch (dst_ra) {
        else => {},
        Register.Alias.fp, .zr, .sp, .pc, .fpcr, .fpsr, .ffr => return false,
    }
    const dst_live_vi = isel.live_registers.getPtr(dst_ra);
    const dst_vi = switch (dst_live_vi.*) {
        _ => |dst_vi| dst_vi,
        .allocating => return false,
        .free => return true,
    };
    const src_ra = src_ra: {
        if (dst_vi.hint(isel)) |hint_ra| {
            assert(dst_live_vi.* == dst_vi);
            dst_live_vi.* = .allocating;
            defer dst_live_vi.* = dst_vi;
            if (try isel.fill(hint_ra)) {
                isel.saved_registers.insert(hint_ra);
                break :src_ra hint_ra;
            }
        }
        switch (if (dst_vi.isVector(isel)) isel.tryAllocVecReg() else isel.tryAllocIntReg()) {
            .allocated => |ra| break :src_ra ra,
            .fill_candidate, .out_of_registers => return isel.fillMemory(dst_ra),
        }
    };
    try dst_vi.liveIn(isel, src_ra, comptime &.initFill(.free));
    const src_live_vi = isel.live_registers.getPtr(src_ra);
    assert(src_live_vi.* == .allocating);
    src_live_vi.* = dst_vi;
    return true;
}

/// Frees `ra`, which a branch reserved before selecting the path it skips, so
/// that the branch can reserve it again. A value which that path left live in `ra` is
/// moved elsewhere at the start of the path, the only one that uses it.
/// Unlike `fill`, this never displaces another live value, such as one in
/// the moved value's hint register: the moves are only emitted on that path,
/// so every other value must stay where both paths expect it.
fn vacateBranchReg(isel: *Select, ra: Register.Alias) !void {
    const live_vi = isel.live_registers.getPtr(ra);
    const vi = switch (live_vi.*) {
        _ => |vi| vi,
        .allocating => return isel.promotionBug("branch register {t} is not free", .{ra}),
        .free => return,
    };
    switch (if (vi.isVector(isel)) isel.tryAllocVecReg() else isel.tryAllocIntReg()) {
        .allocated => |new_ra| {
            try vi.liveIn(isel, new_ra, comptime &.initFill(.free));
            const new_live_vi = isel.live_registers.getPtr(new_ra);
            assert(new_live_vi.* == .allocating);
            new_live_vi.* = vi;
        },
        .fill_candidate, .out_of_registers => assert(try isel.fillMemory(ra)),
    }
    assert(live_vi.* == .free);
}

fn fillMemory(isel: *Select, dst_ra: Register.Alias) Error!bool {
    const dst_live_vi = isel.live_registers.getPtr(dst_ra);
    const dst_vi = switch (dst_live_vi.*) {
        _ => |dst_vi| dst_vi,
        .allocating => return false,
        .free => return true,
    };
    assert(dst_vi.get(isel).location_payload.small.register == dst_ra);
    const dst_size = dst_vi.size(isel);
    if (dst_vi.stackLocation(isel)) |location| if (memoryOffsetFits(dst_size, location.offset)) {
        // Reload straight from the stack slot: `ldr dst, [sp, #offset]`.
        dst_live_vi.* = .allocating;
        try isel.loadReg(dst_ra, dst_size, dst_vi.signedness(isel), location.base, location.offset);
        dst_vi.get(isel).location_payload.small.register = .zr;
        dst_live_vi.* = .free;
        return true;
    };
    const base_ra = if (dst_ra.isVector()) try isel.allocIntReg() else dst_ra;
    defer if (base_ra != dst_ra) isel.freeReg(base_ra);
    switch (dst_size) {
        3, 5, 6, 7 => {
            assert(!dst_ra.isVector());
            // Fragment loads allocate scratch registers. Keep the destination
            // and its aliased address base reserved until those are emitted.
            dst_live_vi.* = .allocating;
            defer dst_live_vi.* = dst_vi;
            try isel.loadReg(dst_ra, dst_size, dst_vi.signedness(isel), base_ra, 0);
        },
        else => try isel.emit(switch (dst_size) {
            else => unreachable,
            1 => if (dst_ra.isVector())
                .ldr(dst_ra.b(), .{ .base = base_ra.x() })
            else switch (dst_vi.signedness(isel)) {
                .signed => .ldrsb(dst_ra.w(), .{ .base = base_ra.x() }),
                .unsigned => .ldrb(dst_ra.w(), .{ .base = base_ra.x() }),
            },
            2 => if (dst_ra.isVector())
                .ldr(dst_ra.h(), .{ .base = base_ra.x() })
            else switch (dst_vi.signedness(isel)) {
                .signed => .ldrsh(dst_ra.w(), .{ .base = base_ra.x() }),
                .unsigned => .ldrh(dst_ra.w(), .{ .base = base_ra.x() }),
            },
            4 => .ldr(if (dst_ra.isVector()) dst_ra.s() else dst_ra.w(), .{ .base = base_ra.x() }),
            8 => .ldr(if (dst_ra.isVector()) dst_ra.d() else dst_ra.x(), .{ .base = base_ra.x() }),
            16 => if (dst_ra.isVector())
                .ldr(dst_ra.q(), .{ .base = base_ra.x() })
            else
                unreachable,
        }),
    }
    dst_vi.get(isel).location_payload.small.register = .zr;
    try dst_vi.address(isel, 0, base_ra);
    dst_live_vi.* = .free;
    return true;
}

/// Merges possibly differing value tracking into a consistent state.
///
/// At a conditional branch, if a value is expected in the same register on both
/// paths, or only expected in a register on only one path, tracking is updated:
///
///     $0 -> r0 // final state is now consistent with both paths
///      b.cond else
///     then:
///     $0 -> r0 // updated if not already consistent with else
///      ...
///      b end
///     else:
///     $0 -> r0
///      ...
///     end:
///
/// At a conditional branch, if a value is expected in different registers on
/// each path, mov instructions are emitted:
///
///     $0 -> r0 // final state is now consistent with both paths
///      b.cond else
///     then:
///     $0 -> r0 // updated to be consistent with else
///      mov x1, x0 // emitted to merge the inconsistent states
///     $0 -> r1
///      ...
///      b end
///     else:
///     $0 -> r0
///      ...
///     end:
///
/// At a loop, a value that is expected in a register at the repeats is updated:
///
///     $0 -> r0 // final state is now consistent with all paths
///     loop:
///     $0 -> r0 // updated to be consistent with the repeats
///      ...
///     $0 -> r0
///      b.cond loop
///      ...
///     $0 -> r0
///      b loop
///
/// At a loop, a value that is expected in a register at the top is filled:
///
///     $0 -> [sp, #A] // final state is now consistent with all paths
///     loop:
///     $0 -> [sp, #A] // updated to be consistent with the repeats
///      ldr x0, [sp, #A] // emitted to merge the inconsistent states
///     $0 -> r0
///      ...
///     $0 -> [sp, #A]
///      b.cond loop
///      ...
///     $0 -> [sp, #A]
///      b loop
///
/// At a loop, if a value that is expected in different registers on each path,
/// mov instructions are emitted:
///
///     $0 -> r0 // final state is now consistent with all paths
///     loop:
///     $0 -> r0 // updated to be consistent with the repeats
///      mov x1, x0 // emitted to merge the inconsistent states
///     $0 -> r1
///      ...
///     $0 -> r0
///      b.cond loop
///      ...
///     $0 -> r0
///      b loop
fn merge(
    isel: *Select,
    expected_live_registers: *const LiveRegisters,
    comptime opts: struct { fill_extra: bool = false },
) !void {
    // A pinned value's register holds nothing else, so the value is simply
    // live there before the merge if it is live on either side.
    var pinned_it = isel.promotion.pinned_value_regs.iterator();
    while (pinned_it.next()) |ra| {
        const actual_vi = isel.live_registers.getPtr(ra);
        const expected_vi = expected_live_registers.get(ra);
        // The register may also be taken (`.allocating`) by an operand that
        // is the value itself and becomes live there again.
        const locked = actual_vi.* == .allocating or expected_vi == .allocating;
        const vi: Value.Index = switch (actual_vi.*) {
            _ => |vi| vi,
            .allocating, .free => switch (expected_vi) {
                _ => |vi| vi,
                .allocating, .free => .free,
            },
        };
        // While the operand holds the register, the value is not live in it:
        // another use copies it out of the register (`matReg`), and the
        // operand makes it live there again when it finishes.
        if (vi != .free) vi.get(isel).location_payload.small.register = if (locked) .zr else ra;
        actual_vi.* = if (locked) .allocating else vi;
    }
    var live_reg_it = isel.live_registers.iterator();
    while (live_reg_it.next()) |live_reg_entry| {
        const ra = live_reg_entry.key;
        if (isel.promotion.pinned_value_regs.contains(ra)) continue;
        const actual_vi = live_reg_entry.value;
        const expected_vi = expected_live_registers.get(ra);
        switch (expected_vi) {
            else => switch (actual_vi.*) {
                _ => {},
                .allocating => unreachable,
                .free => actual_vi.* = .allocating,
            },
            .free => {},
        }
    }
    live_reg_it = isel.live_registers.iterator();
    while (live_reg_it.next()) |live_reg_entry| {
        const ra = live_reg_entry.key;
        if (isel.promotion.pinned_value_regs.contains(ra)) continue;
        const actual_vi = live_reg_entry.value;
        const expected_vi = expected_live_registers.get(ra);
        switch (expected_vi) {
            _ => {
                switch (actual_vi.*) {
                    _ => _ = if (opts.fill_extra) {
                        assert(try isel.fillMemory(ra));
                        assert(actual_vi.* == .free);
                    },
                    .allocating => actual_vi.* = .free,
                    .free => unreachable,
                }
                try expected_vi.liveIn(isel, ra, expected_live_registers);
            },
            .allocating => if (if (opts.fill_extra) try isel.fillMemory(ra) else try isel.fill(ra)) {
                assert(actual_vi.* == .free);
                actual_vi.* = .allocating;
            },
            .free => if (opts.fill_extra) assert(try isel.fillMemory(ra) and actual_vi.* == .free),
        }
    }
    live_reg_it = isel.live_registers.iterator();
    while (live_reg_it.next()) |live_reg_entry| {
        const ra = live_reg_entry.key;
        if (isel.promotion.pinned_value_regs.contains(ra)) continue;
        const actual_vi = live_reg_entry.value;
        const expected_vi = expected_live_registers.get(ra);
        switch (expected_vi) {
            _ => {
                assert(actual_vi.* == .allocating and expected_vi.register(isel) == ra);
                actual_vi.* = expected_vi;
            },
            .allocating => assert(actual_vi.* == .allocating),
            .free => if (opts.fill_extra) assert(actual_vi.* == .free),
        }
    }
}

const call = struct {
    const param_reg: Value.Index = @fromBackingInt(@intCast(@backingInt(Value.Index.allocating) - 2));
    const callee_clobbered_reg: Value.Index = @fromBackingInt(@intCast(@backingInt(Value.Index.allocating) - 1));
    const caller_saved_regs: LiveRegisters = .init(.{
        .r0 = param_reg,
        .r1 = param_reg,
        .r2 = param_reg,
        .r3 = param_reg,
        .r4 = param_reg,
        .r5 = param_reg,
        .r6 = param_reg,
        .r7 = param_reg,
        .r8 = param_reg,
        .r9 = callee_clobbered_reg,
        .r10 = callee_clobbered_reg,
        .r11 = callee_clobbered_reg,
        .r12 = callee_clobbered_reg,
        .r13 = callee_clobbered_reg,
        .r14 = callee_clobbered_reg,
        .r15 = callee_clobbered_reg,
        .r16 = callee_clobbered_reg,
        .r17 = callee_clobbered_reg,
        .r18 = callee_clobbered_reg,
        .r19 = .free,
        .r20 = .free,
        .r21 = .free,
        .r22 = .free,
        .r23 = .free,
        .r24 = .free,
        .r25 = .free,
        .r26 = .free,
        .r27 = .free,
        .r28 = .free,
        .r29 = .free,
        .r30 = callee_clobbered_reg,
        .zr = .free,
        .sp = .free,

        .pc = .free,

        .v0 = param_reg,
        .v1 = param_reg,
        .v2 = param_reg,
        .v3 = param_reg,
        .v4 = param_reg,
        .v5 = param_reg,
        .v6 = param_reg,
        .v7 = param_reg,
        .v8 = .free,
        .v9 = .free,
        .v10 = .free,
        .v11 = .free,
        .v12 = .free,
        .v13 = .free,
        .v14 = .free,
        .v15 = .free,
        .v16 = callee_clobbered_reg,
        .v17 = callee_clobbered_reg,
        .v18 = callee_clobbered_reg,
        .v19 = callee_clobbered_reg,
        .v20 = callee_clobbered_reg,
        .v21 = callee_clobbered_reg,
        .v22 = callee_clobbered_reg,
        .v23 = callee_clobbered_reg,
        .v24 = callee_clobbered_reg,
        .v25 = callee_clobbered_reg,
        .v26 = callee_clobbered_reg,
        .v27 = callee_clobbered_reg,
        .v28 = callee_clobbered_reg,
        .v29 = callee_clobbered_reg,
        .v30 = callee_clobbered_reg,
        .v31 = callee_clobbered_reg,

        .fpcr = .free,
        .fpsr = .free,

        .p0 = callee_clobbered_reg,
        .p1 = callee_clobbered_reg,
        .p2 = callee_clobbered_reg,
        .p3 = callee_clobbered_reg,
        .p4 = callee_clobbered_reg,
        .p5 = callee_clobbered_reg,
        .p6 = callee_clobbered_reg,
        .p7 = callee_clobbered_reg,
        .p8 = callee_clobbered_reg,
        .p9 = callee_clobbered_reg,
        .p10 = callee_clobbered_reg,
        .p11 = callee_clobbered_reg,
        .p12 = callee_clobbered_reg,
        .p13 = callee_clobbered_reg,
        .p14 = callee_clobbered_reg,
        .p15 = callee_clobbered_reg,

        .ffr = .free,
    });
    /// A call to the global function `name`, which returns nothing, up to
    /// its parameters: the caller moves them into place and then calls
    /// `finishParams`.
    fn prepareVoidGlobal(isel: *Select, name: [*:0]const u8) !void {
        try prepareReturn(isel);
        try finishReturn(isel);
        try prepareCallee(isel);
        try call.global(isel, name);
        try finishCallee(isel);
        try prepareParams(isel);
    }
    fn prepareReturn(isel: *Select) !void {
        var live_reg_it = isel.live_registers.iterator();
        while (live_reg_it.next()) |live_reg_entry| switch (caller_saved_regs.get(live_reg_entry.key)) {
            else => unreachable,
            param_reg, callee_clobbered_reg => switch (live_reg_entry.value.*) {
                _ => {},
                .allocating => unreachable,
                .free => live_reg_entry.value.* = .allocating,
            },
            .free => {},
        };
    }
    fn returnFill(isel: *Select, ra: Register.Alias) !void {
        if (try isel.fill(ra)) isel.reserveReg(ra);
        assert(isel.live_registers.get(ra) == .allocating);
    }
    fn returnLiveIn(isel: *Select, vi: Value.Index, ra: Register.Alias) !void {
        try vi.defLiveIn(isel, ra, &caller_saved_regs);
    }
    fn finishReturn(isel: *Select) !void {
        var live_reg_it = isel.live_registers.iterator();
        while (live_reg_it.next()) |live_reg_entry| {
            switch (live_reg_entry.value.*) {
                _ => |live_vi| switch (live_vi.size(isel)) {
                    else => unreachable,
                    1...8 => {},
                    16 => {
                        assert(try isel.fillMemory(live_reg_entry.key));
                        assert(live_reg_entry.value.* == .free);
                        switch (caller_saved_regs.get(live_reg_entry.key)) {
                            else => unreachable,
                            param_reg, callee_clobbered_reg => live_reg_entry.value.* = .allocating,
                            .free => {},
                        }
                        continue;
                    },
                },
                .allocating, .free => {},
            }
            switch (caller_saved_regs.get(live_reg_entry.key)) {
                else => unreachable,
                param_reg, callee_clobbered_reg => switch (live_reg_entry.value.*) {
                    _ => {
                        assert(try isel.fill(live_reg_entry.key));
                        assert(live_reg_entry.value.* == .free);
                        live_reg_entry.value.* = .allocating;
                    },
                    .allocating => {},
                    // Return stores can release a caller register used as an
                    // address scratch after spilling its previous live value.
                    .free => live_reg_entry.value.* = .allocating,
                },
                .free => {},
            }
        }
    }
    fn prepareCallee(isel: *Select) !void {
        var live_reg_it = isel.live_registers.iterator();
        while (live_reg_it.next()) |live_reg_entry| switch (caller_saved_regs.get(live_reg_entry.key)) {
            else => unreachable,
            param_reg => assert(live_reg_entry.value.* == .allocating),
            callee_clobbered_reg => isel.freeReg(live_reg_entry.key),
            .free => {},
        };
    }
    fn finishCallee(_: *Select) !void {}
    fn prepareParams(_: *Select) !void {}
    /// Between `prepareReturn` and `finishParams`, the caller-saved registers
    /// are reserved for the call: once the value moved into a parameter
    /// register is defined (selection runs backwards), the register is
    /// reserved again so that no other argument's selection takes it.
    fn reserveParamReg(isel: *Select, ra: Register.Alias) void {
        if (isel.live_registers.get(ra) == .free) isel.reserveReg(ra);
    }
    fn paramLiveOut(isel: *Select, vi: Value.Index, ra: Register.Alias) !void {
        isel.freeReg(ra);
        try vi.liveOut(isel, ra);
        reserveParamReg(isel, ra);
    }
    fn paramAddress(isel: *Select, vi: Value.Index, ra: Register.Alias) !void {
        try paramAddressAt(isel, vi, 0, ra);
    }
    fn paramAddressAt(isel: *Select, vi: Value.Index, offset: u64, ra: Register.Alias) !void {
        isel.freeReg(ra);
        try vi.address(isel, offset, ra);
        reserveParamReg(isel, ra);
    }
    /// Where `long double` is not f128 (Darwin), compiler-rt passes and returns
    /// f128 as `extern struct { lo: u64, hi: u64 }`: a pair of general registers.
    fn softF128(isel: *Select, bits: u16) bool {
        return bits == 128 and std.zig.target.compilerRtFloatAbi(isel.target, 128) == .soft;
    }
    /// For a soft f128 compiler-rt result, emitted after `finishReturn`: moves
    /// the x0/x1 result into v0, where `returnLiveIn` defines it.
    fn returnSoftF128(isel: *Select, bits: u16) !void {
        if (!softF128(isel, bits)) return;
        try isel.emit(.fmov(Register.Alias.v0.@"d[]"(1), .{ .register = .x1 }));
        try isel.emit(.fmov(Register.Alias.v0.d(), .{ .register = .x0 }));
    }
    /// For a soft f128 compiler-rt argument, emitted after `prepareParams` and
    /// before the `paramLiveOut` that stages it in `staging_ra`: moves it into
    /// the general register pair starting at `lo_ra` just before the call.
    fn paramSoftF128(isel: *Select, staging_ra: Register.Alias, lo_ra: Register.Alias) !void {
        const hi_ra: Register.Alias = @fromBackingInt(@intCast(@backingInt(lo_ra) + 1));
        try isel.emit(.fmov(hi_ra.x(), .{ .register = staging_ra.@"d[]"(1) }));
        try isel.emit(.fmov(lo_ra.x(), .{ .register = staging_ra.d() }));
    }
    /// Calls the global function `name`, between `prepareCallee` and
    /// `finishCallee`.
    fn global(isel: *Select, name: [*:0]const u8) !void {
        try isel.global_relocs.append(isel.pt.zcu.gpa, .{
            .name = name,
            .reloc = .{ .label = @intCast(isel.instructions.items.len) },
        });
        try isel.emit(.bl(0));
    }
    /// The registers in which a compiler-rt routine passes and returns a
    /// float or an integer of at most 128 bits: a SIMD register for a float,
    /// a pair of general registers for f80 (its 64-bit significand, then its
    /// sign and exponent) and integers of more than 64 bits, else one.
    const CompilerRtRegisters = enum { vector, general, general_pair };
    fn compilerRtRegisters(isel: *Select, ty: ZigType) CompilerRtRegisters {
        const zcu = isel.pt.zcu;
        if (ty.zigTypeTag(zcu) == .float) return switch (ty.floatBits(isel.target)) {
            else => unreachable,
            16, 32, 64, 128 => .vector,
            80 => .general_pair,
        };
        return switch (ty.intInfo(zcu).bits) {
            0 => unreachable,
            1...64 => .general,
            65...128 => .general_pair,
            else => unreachable,
        };
    }
    /// Defines `vi`, of type `ty`, as the result of a compiler-rt routine:
    /// `prepareReturn` through `finishReturn` (and `returnSoftF128`).
    fn compilerRtReturn(isel: *Select, vi: Value.Index, ty: ZigType) !void {
        try prepareReturn(isel);
        switch (compilerRtRegisters(isel, ty)) {
            .vector => try returnLiveIn(isel, vi, .v0),
            .general => try returnLiveIn(isel, vi, .r0),
            .general_pair => {
                var hi_it = vi.field(ty, 8, 8);
                try returnLiveIn(isel, (try hi_it.only(isel)).?, .r1);
                var lo_it = vi.field(ty, 0, 8);
                try returnLiveIn(isel, (try lo_it.only(isel)).?, .r0);
            },
        }
        try finishReturn(isel);
        if (ty.zigTypeTag(isel.pt.zcu) == .float) try returnSoftF128(isel, ty.floatBits(isel.target));
    }
    /// Passes `args` to a compiler-rt routine: `prepareParams` through
    /// `finishParams`. Each argument takes the next SIMD register or the
    /// next one or two general registers (`compilerRtRegisters`).
    fn compilerRtParams(isel: *Select, args: []const Air.Inst.Ref) !void {
        const ip = &isel.pt.zcu.intern_pool;
        var arg_buf: [3]CompilerRtArg = undefined;
        for (args, arg_buf[0..args.len]) |arg, *rt_arg| rt_arg.* = .{
            .vi = try isel.use(arg),
            .ty = isel.air.typeOf(arg, ip),
        };
        return compilerRtParamValues(isel, arg_buf[0..args.len]);
    }
    const CompilerRtArg = struct { vi: Value.Index, ty: ZigType };
    /// `compilerRtParams` of values.
    fn compilerRtParamValues(isel: *Select, args: []const CompilerRtArg) !void {
        try prepareParams(isel);
        var arg_regs: [3]Register.Alias = undefined;
        var next_vector: Register.Alias = .v0;
        var next_general: Register.Alias = .r0;
        for (args, arg_regs[0..args.len]) |arg, *arg_ra| switch (compilerRtRegisters(isel, arg.ty)) {
            .vector => {
                arg_ra.* = next_vector;
                next_vector = @fromBackingInt(@intCast(@backingInt(next_vector) + 1));
            },
            .general => {
                arg_ra.* = next_general;
                next_general = @fromBackingInt(@intCast(@backingInt(next_general) + 1));
            },
            .general_pair => {
                arg_ra.* = next_general;
                next_general = @fromBackingInt(@intCast(@backingInt(next_general) + 2));
            },
        };
        // A soft f128 staged in a SIMD register is moved to the general
        // register pair the routine takes it in.
        for (args, arg_regs[0..args.len]) |arg, arg_ra| {
            if (arg.ty.zigTypeTag(isel.pt.zcu) == .float and softF128(isel, arg.ty.floatBits(isel.target)))
                try paramSoftF128(isel, arg_ra, @fromBackingInt(@intCast(@backingInt(Register.Alias.r0) +
                    2 * (@backingInt(arg_ra) - @backingInt(Register.Alias.v0)))));
        }
        var index = args.len;
        while (index > 0) {
            index -= 1;
            const arg = args[index];
            const arg_ra = arg_regs[index];
            switch (compilerRtRegisters(isel, arg.ty)) {
                .vector, .general => try paramLiveOut(isel, arg.vi, arg_ra),
                .general_pair => {
                    var hi_it = arg.vi.field(arg.ty, 8, 8);
                    try paramLiveOut(isel, (try hi_it.only(isel)).?, @fromBackingInt(@intCast(@backingInt(arg_ra) + 1)));
                    var lo_it = arg.vi.field(arg.ty, 0, 8);
                    try paramLiveOut(isel, (try lo_it.only(isel)).?, arg_ra);
                },
            }
        }
        try finishParams(isel);
    }
    /// A call of the compiler-rt routine `name` that takes the floats or
    /// integers `args` and defines `res_vi`, of type `res_ty`.
    fn compilerRt(isel: *Select, name: [*:0]const u8, res_vi: Value.Index, res_ty: ZigType, args: []const Air.Inst.Ref) !void {
        try compilerRtReturn(isel, res_vi, res_ty);
        try prepareCallee(isel);
        try global(isel, name);
        try finishCallee(isel);
        try compilerRtParams(isel, args);
    }
    fn finishParams(isel: *Select) !void {
        var live_reg_it = isel.live_registers.iterator();
        while (live_reg_it.next()) |live_reg_entry| switch (caller_saved_regs.get(live_reg_entry.key)) {
            else => unreachable,
            param_reg => switch (live_reg_entry.value.*) {
                _ => {},
                .allocating => live_reg_entry.value.* = .free,
                // With every other register taken, staging an argument can
                // fill an argument register from memory to use it as a
                // scratch (`allocIntReg`), and the scratch is then released:
                // the fill reloads the argument after that use.
                .free => {},
            },
            callee_clobbered_reg, .free => {},
        };
    }
};

/// Where `long double` is not f128 (Darwin), the LLVM backend passes f128 in C
/// calling conventions as a pair of general registers, also in homogeneous
/// aggregates, while CallAbiIterator uses SIMD registers. Reject the mismatch.
pub fn checkSoftF128CallConv(isel: *Select, func_type: InternPool.Key.FuncType) !void {
    if (func_type.cc == .auto) return;
    if (std.zig.target.compilerRtFloatAbi(isel.target, 128) != .soft) return;
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    for (func_type.param_types.get(ip)) |param_ty| {
        if (CallAbiIterator.homogeneousAggregateBaseType(zcu, param_ty) == .quad) return isel.fail(
            "unsupported f128 parameter {f} in the {t} calling convention",
            .{ isel.fmtType(.fromInterned(param_ty)), func_type.cc },
        );
    }
    if (CallAbiIterator.homogeneousAggregateBaseType(zcu, func_type.return_type) == .quad) return isel.fail(
        "unsupported f128 return {f} in the {t} calling convention",
        .{ isel.fmtType(.fromInterned(func_type.return_type)), func_type.cc },
    );
}

/// LLVM lowers a vector whose lane count must be widened and whose lanes must
/// also be promoted (e.g. u8x3 or u1x3) differently from the register layout
/// chosen by vectorAbi. Zig-callconv code may use that layout; C calling
/// conventions must not silently disagree with LLVM-compiled code.
pub fn checkVectorCallConv(isel: *Select, func_type: InternPool.Key.FuncType) !void {
    if (func_type.cc == .auto) return;
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;
    for (func_type.param_types.get(ip)) |param_ty| if (!isel.vectorAbiMatchesLlvm(.fromInterned(param_ty)))
        return isel.fail("unsupported vector argument/return ABI {f} in the {t} calling convention", .{
            isel.fmtType(.fromInterned(param_ty)), func_type.cc,
        });
    if (!isel.vectorAbiMatchesLlvm(.fromInterned(func_type.return_type)))
        return isel.fail("unsupported vector argument/return ABI {f} in the {t} calling convention", .{
            isel.fmtType(.fromInterned(func_type.return_type)), func_type.cc,
        });
}

fn vectorAbiMatchesLlvm(isel: *Select, ty: ZigType) bool {
    const info = isel.vectorAbi(ty) orelse return true;
    if (std.math.isPowerOfTwo(info.lanes)) return true;
    return info.lane_bits == @max(8, std.math.ceilPowerOfTwo(u16, info.bits) catch unreachable);
}

pub const CallAbiIterator = @import("CallAbiIterator.zig");

const Air = @import("../../Air.zig");
const assert = std.debug.assert;
const codegen = @import("../../codegen.zig");
const Constant = @import("../../Value.zig");
const InternPool = @import("../../InternPool.zig");
const Module = @import("../../Module.zig");
const Register = codegen.aarch64.encoding.Register;
pub const Select = @This();
const std = @import("std");
const tracking_log = std.log.scoped(.tracking);
const wip_mir_log = std.log.scoped(.@"wip-mir");
const Zcu = @import("../../Zcu.zig");
const ZigType = @import("../../Type.zig");
