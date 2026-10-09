//! A value tracked by instruction selection (`Select`): the result of an AIR
//! instruction, a part of one, or a temporary, with where it lives (a register,
//! a stack slot, a part of another value, a constant, an address) and how it
//! is defined, used, split into parts and materialized in registers.

refs: u32,
flags: Flags,
offset_from_parent: u64,
parent_payload: Parent.Payload,
location_payload: Location.Payload,
parts: Value.Index,

/// Must be at least 16 to compute call abi.
/// Must be at least 16, the largest hardware alignment.
pub const max_parts = 16;
pub const PartsLen = std.math.IntFittingRange(0, Value.max_parts);

pub fn isVectorSize(value_size: u64) bool {
    return switch (value_size) {
        1, 2, 4, 8, 16 => true,
        else => false,
    };
}

/// Adjacent groups cannot be combined, so their total span exceeds the stride.
/// A stride of at least size / (max_parts / 2) bounds the number of groups.
pub fn partLog2Stride(value_size: u64) u6 {
    const min_stride: u6 = if (value_size > 16) 4 else if (value_size > 8) 3 else 0;
    return @max(min_stride, @as(u6, @intCast(std.math.log2_int_ceil(u64, @max(@divCeil(value_size, max_parts / 2), 1)))));
}

comptime {
    if (!std.debug.runtime_safety) assert(@sizeOf(Value) == 32);
}

pub const Flags = packed struct(u32) {
    alignment: InternPool.Alignment,
    parent_tag: Parent.Tag,
    location_tag: Location.Tag,
    parts_len_minus_one: std.math.IntFittingRange(0, Value.max_parts - 1),
    is_padding: bool = false,
    /// The register reserved for this value for the whole function
    /// (`Promotion`), as the backing integer of its alias; 0 for none.
    pin: u7 = 0,
    unused: u10 = 0,
};

pub const Parent = union(enum(u3)) {
    unallocated: void,
    stack_slot: Indirect,
    address: Value.Index,
    value: Value.Index,
    constant: Constant,
    /// The value is the address `base + offset` of a stack slot (an `alloc`
    /// or `ret_ptr` result). Like a constant, it is rematerialized at each
    /// use instead of being kept live in a register, so it is never spilled.
    stack_address: Indirect,

    pub const Tag = @typeInfo(Parent).@"union".tag_type.?;
    pub const Payload = Payload: {
        const info = @typeInfo(Parent).@"union";
        break :Payload @Union(.auto, null, info.field_names, info.field_types[0..], &@splat(.{}));
    };
};

pub const Location = union(enum(u1)) {
    large: struct {
        size: u64,
    },
    small: struct {
        size: u5,
        signedness: std.lang.Signedness,
        is_vector: bool,
        hint: Register.Alias,
        register: Register.Alias,
    },

    pub const Tag = @typeInfo(Location).@"union".tag_type.?;
    pub const Payload = Payload: {
        const info = @typeInfo(Location).@"union";
        break :Payload @Union(.auto, null, info.field_names, info.field_types[0..], &@splat(.{}));
    };
};

pub const Indirect = packed struct(u32) {
    base: Register.Alias,
    offset: i25,

    pub fn withOffset(ind: Indirect, offset: i25) Indirect {
        return .{
            .base = ind.base,
            .offset = ind.offset + offset,
        };
    }
};

pub const Index = enum(u32) {
    allocating = std.math.maxInt(u32) - 1,
    free = std.math.maxInt(u32) - 0,
    _,

    pub fn get(vi: Value.Index, isel: *Select) *Value {
        return &isel.values.items[@backingInt(vi)];
    }

    pub fn setAlignment(vi: Value.Index, isel: *Select, new_alignment: InternPool.Alignment) void {
        vi.get(isel).flags.alignment = new_alignment;
    }

    pub fn alignment(vi: Value.Index, isel: *Select) InternPool.Alignment {
        return vi.get(isel).flags.alignment;
    }

    pub fn setParent(vi: Value.Index, isel: *Select, new_parent: Parent) void {
        const value = vi.get(isel);
        assert(value.flags.parent_tag == .unallocated);
        value.flags.parent_tag = new_parent;
        value.parent_payload = switch (new_parent) {
            .unallocated => unreachable,
            inline else => |payload, tag| @unionInit(Parent.Payload, @tagName(tag), payload),
        };
        if (value.refs > 0) switch (new_parent) {
            .unallocated => unreachable,
            .stack_slot, .constant, .stack_address => {},
            .address, .value => |parent_vi| _ = parent_vi.ref(isel),
        };
    }

    pub fn changeStackSlot(vi: Value.Index, isel: *Select, new_stack_slot: Indirect) void {
        const value = vi.get(isel);
        assert(value.flags.parent_tag == .stack_slot);
        value.flags.parent_tag = .unallocated;
        vi.setParent(isel, .{ .stack_slot = new_stack_slot });
    }

    pub fn parent(vi: Value.Index, isel: *Select) Parent {
        const value = vi.get(isel);
        return switch (value.flags.parent_tag) {
            inline else => |tag| @unionInit(
                Parent,
                @tagName(tag),
                @field(value.parent_payload, @tagName(tag)),
            ),
        };
    }

    pub fn valueParent(initial_vi: Value.Index, isel: *Select) struct { u64, Value.Index } {
        var offset: u64 = 0;
        var vi = initial_vi;
        parent: switch (vi.parent(isel)) {
            else => return .{ offset, vi },
            .value => |parent_vi| {
                offset += vi.position(isel)[0];
                vi = parent_vi;
                continue :parent parent_vi.parent(isel);
            },
        }
    }

    pub fn location(vi: Value.Index, isel: *Select) Location {
        const value = vi.get(isel);
        return switch (value.flags.location_tag) {
            inline else => |tag| @unionInit(
                Location,
                @tagName(tag),
                @field(value.location_payload, @tagName(tag)),
            ),
        };
    }

    pub fn position(vi: Value.Index, isel: *Select) struct { u64, u64 } {
        return .{ vi.get(isel).offset_from_parent, vi.size(isel) };
    }

    pub fn size(vi: Value.Index, isel: *Select) u64 {
        return switch (vi.location(isel)) {
            inline else => |loc| loc.size,
        };
    }

    pub fn setHint(vi: Value.Index, isel: *Select, new_hint: Register.Alias) void {
        vi.get(isel).location_payload.small.hint = new_hint;
    }

    pub fn setPin(vi: Value.Index, isel: *Select, pin_ra: Register.Alias) void {
        assert(@backingInt(pin_ra) != 0);
        vi.get(isel).flags.pin = @backingInt(pin_ra);
    }

    /// The register this value always lives in, if it has one.
    pub fn pin(vi: Value.Index, isel: *Select) ?Register.Alias {
        return switch (vi.get(isel).flags.pin) {
            0 => null,
            else => |pin_ra| @fromBackingInt(pin_ra),
        };
    }

    pub fn hint(vi: Value.Index, isel: *Select) ?Register.Alias {
        return switch (vi.location(isel)) {
            .large => null,
            .small => |loc| switch (loc.hint) {
                .zr => null,
                else => |hint_reg| hint_reg,
            },
        };
    }

    pub fn setSignedness(vi: Value.Index, isel: *Select, new_signedness: std.lang.Signedness) void {
        const value = vi.get(isel);
        assert(value.location_payload.small.size <= 2);
        value.location_payload.small.signedness = new_signedness;
    }

    pub fn signedness(vi: Value.Index, isel: *Select) std.lang.Signedness {
        const value = vi.get(isel);
        return switch (value.flags.location_tag) {
            .large => .unsigned,
            .small => value.location_payload.small.signedness,
        };
    }

    pub fn setIsVector(vi: Value.Index, isel: *Select) void {
        const is_vector = &vi.get(isel).location_payload.small.is_vector;
        assert(!is_vector.*);
        is_vector.* = true;
    }

    pub fn isVector(vi: Value.Index, isel: *Select) bool {
        const value = vi.get(isel);
        return switch (value.flags.location_tag) {
            .large => false,
            .small => value.location_payload.small.is_vector,
        };
    }

    pub fn register(vi: Value.Index, isel: *Select) ?Register.Alias {
        return switch (vi.location(isel)) {
            .large => null,
            .small => |loc| switch (loc.register) {
                .zr => null,
                else => |reg| reg,
            },
        };
    }

    pub fn isUsed(vi: Value.Index, isel: *Select) bool {
        return vi.valueParent(isel)[1].parent(isel) != .unallocated or vi.hasRegisterRecursive(isel);
    }

    pub fn hasRegisterRecursive(vi: Value.Index, isel: *Select) bool {
        if (vi.register(isel)) |_| return true;
        var part_it = vi.parts(isel);
        if (part_it.only() == null) while (part_it.next()) |part_vi| if (part_vi.hasRegisterRecursive(isel)) return true;
        return false;
    }

    pub fn setParts(vi: Value.Index, isel: *Select, parts_len: Value.PartsLen) void {
        assert(parts_len > 1);
        const value = vi.get(isel);
        assert(value.flags.parts_len_minus_one == 0);
        value.parts = @fromBackingInt(@intCast(isel.values.items.len));
        value.flags.parts_len_minus_one = @intCast(parts_len - 1);
    }

    pub fn addPart(vi: Value.Index, isel: *Select, part_offset: u64, part_size: u64) Value.Index {
        const part_vi = isel.initValueAdvanced(vi.alignment(isel), part_offset, part_size);
        tracking_log.debug("${d} <- ${d}[{d}]", .{
            @backingInt(part_vi),
            @backingInt(vi),
            part_offset,
        });
        part_vi.setParent(isel, .{ .value = vi });
        return part_vi;
    }

    pub fn parts(vi: Value.Index, isel: *Select) Value.PartIterator {
        const value = vi.get(isel);
        return switch (value.flags.parts_len_minus_one) {
            0 => .initOne(vi),
            else => |parts_len_minus_one| .{
                .vi = value.parts,
                .remaining = @as(Value.PartsLen, parts_len_minus_one) + 1,
            },
        };
    }

    pub fn containingParts(vi: Value.Index, isel: *Select, part_offset: u64, part_size: u64) Value.PartIterator {
        const start_vi = vi.partAtOffset(isel, part_offset);
        const start_offset, const start_size = start_vi.position(isel);
        if (part_offset >= start_offset and part_size <= start_size) return .initOne(start_vi);
        const end_vi = vi.partAtOffset(isel, part_size - 1 + part_offset);
        return .{
            .vi = start_vi,
            .remaining = @intCast(@backingInt(end_vi) - @backingInt(start_vi) + 1),
        };
    }
    comptime {
        _ = containingParts;
    }

    pub fn partAtOffset(vi: Value.Index, isel: *Select, offset: u64) Value.Index {
        const SearchPartIndex = std.math.IntFittingRange(0, Value.max_parts * 2 - 1);
        const value = vi.get(isel);
        var last: SearchPartIndex = value.flags.parts_len_minus_one;
        if (last == 0) return vi;
        var first: SearchPartIndex = 0;
        last += 1;
        while (true) {
            const mid = (first + last) / 2;
            const mid_vi: Value.Index = @fromBackingInt(@intCast(@backingInt(value.parts) + mid));
            if (mid == first) return mid_vi;
            if (offset < mid_vi.get(isel).offset_from_parent) last = mid else first = mid;
        }
    }

    pub fn field(
        vi: Value.Index,
        ty: ZigType,
        field_offset: u64,
        field_size: u64,
    ) Value.FieldPartIterator {
        assert(field_size > 0);
        return .{
            .vi = vi,
            .ty = ty,
            .field_offset = field_offset,
            .field_size = field_size,
            .next_offset = 0,
        };
    }

    pub fn ref(initial_vi: Value.Index, isel: *Select) Value.Index {
        var vi = initial_vi;
        while (true) {
            const refs = &vi.get(isel).refs;
            refs.* += 1;
            if (refs.* > 1) return initial_vi;
            switch (vi.parent(isel)) {
                .unallocated, .stack_slot, .constant, .stack_address => {},
                .address, .value => |parent_vi| {
                    vi = parent_vi;
                    continue;
                },
            }
            return initial_vi;
        }
    }

    pub fn deref(initial_vi: Value.Index, isel: *Select) void {
        var vi = initial_vi;
        while (true) {
            const refs = &vi.get(isel).refs;
            refs.* -= 1;
            if (refs.* > 0) return;
            switch (vi.parent(isel)) {
                .unallocated, .constant, .stack_address => {},
                .stack_slot => {
                    // reuse stack slot
                },
                .address, .value => |parent_vi| {
                    vi = parent_vi;
                    continue;
                },
            }
            return;
        }
    }

    pub fn move(dst_vi: Value.Index, isel: *Select, src_ref: Air.Inst.Ref) !void {
        try dst_vi.copy(
            isel,
            isel.air.typeOf(src_ref, &isel.pt.zcu.intern_pool),
            try isel.use(src_ref),
        );
    }

    pub fn copy(dst_vi: Value.Index, isel: *Select, ty: ZigType, src_vi: Value.Index) !void {
        try dst_vi.copyAdvanced(isel, src_vi, .{
            .ty = ty,
            .dst_vi = dst_vi,
            .dst_offset = 0,
            .src_vi = src_vi,
            .src_offset = 0,
        });
    }

    pub fn copyField(
        dst_vi: Value.Index,
        isel: *Select,
        dst_ty: ZigType,
        dst_offset: u64,
        src_vi: Value.Index,
        src_ty: ZigType,
        src_offset: u64,
        copy_size: u64,
    ) !void {
        if (dst_vi == src_vi and dst_offset == src_offset) return;
        var offset: u64 = 0;
        while (offset < copy_size) {
            var part_size = copy_size - offset;
            const dst_part_vi, const src_part_vi = parts: while (true) {
                var dst_field_it = dst_vi.field(dst_ty, dst_offset + offset, part_size);
                var src_field_it = src_vi.field(src_ty, src_offset + offset, part_size);
                const dst_field = try dst_field_it.next(isel) orelse return;
                const src_field = try src_field_it.next(isel) orelse return;
                const padding_size = @max(dst_field.offset, src_field.offset);
                if (padding_size > 0) {
                    offset += padding_size;
                    part_size = copy_size - offset;
                    continue;
                }
                var dst_part = dst_field.vi;
                var src_part = src_field.vi;
                while (dst_part.partAtOffset(isel, 0) != dst_part) {
                    dst_part = dst_part.partAtOffset(isel, 0);
                    assert(dst_part.get(isel).offset_from_parent == 0);
                }
                while (src_part.partAtOffset(isel, 0) != src_part) {
                    src_part = src_part.partAtOffset(isel, 0);
                    assert(src_part.get(isel).offset_from_parent == 0);
                }
                const next_size = @min(dst_part.size(isel), src_part.size(isel));
                assert(next_size > 0);
                if (next_size < part_size) {
                    part_size = next_size;
                    continue;
                }
                const register_size: u64 = if (dst_part.isVector(isel) and src_part.isVector(isel)) 16 else 8;
                if (part_size > register_size) {
                    part_size = register_size;
                    continue;
                }
                break :parts .{ dst_part, src_part };
            };
            if (try dst_part_vi.defReg(isel)) |dst_ra| try src_part_vi.liveOut(isel, dst_ra);
            offset += part_size;
        }
    }

    pub fn copyAdvanced(dst_vi: Value.Index, isel: *Select, src_vi: Value.Index, root: struct {
        ty: ZigType,
        dst_vi: Value.Index,
        dst_offset: u64,
        src_vi: Value.Index,
        src_offset: u64,
    }) !void {
        if (dst_vi == src_vi) return;
        var dst_part_it = dst_vi.parts(isel);
        if (dst_part_it.only()) |dst_part_vi| {
            var src_part_it = src_vi.parts(isel);
            if (src_part_it.only()) |src_part_vi| only: {
                const src_part_size = src_part_vi.size(isel);
                if (src_part_size > @as(@TypeOf(src_part_size), if (src_part_vi.isVector(isel)) 16 else 8)) {
                    var subpart_it = root.src_vi.field(root.ty, root.src_offset, src_part_size - 1);
                    _ = try subpart_it.next(isel);
                    src_part_it = src_vi.parts(isel);
                    assert(src_part_it.only() == null);
                    break :only;
                }
                return src_part_vi.liveOut(isel, try dst_part_vi.defReg(isel) orelse return);
            }
            while (src_part_it.next()) |src_part_vi| {
                const src_part_offset, const src_part_size = src_part_vi.position(isel);
                var dst_field_it = root.dst_vi.field(root.ty, root.dst_offset + src_part_offset, src_part_size);
                const dst_field_vi = try dst_field_it.only(isel);
                if (dst_field_vi == null) {
                    try root.dst_vi.copyField(
                        isel,
                        root.ty,
                        root.dst_offset + src_part_offset,
                        root.src_vi,
                        root.ty,
                        root.src_offset + src_part_offset,
                        src_part_size,
                    );
                    continue;
                }
                try dst_field_vi.?.copyAdvanced(isel, src_part_vi, .{
                    .ty = root.ty,
                    .dst_vi = root.dst_vi,
                    .dst_offset = root.dst_offset + src_part_offset,
                    .src_vi = root.src_vi,
                    .src_offset = root.src_offset + src_part_offset,
                });
            }
        } else while (dst_part_it.next()) |dst_part_vi| {
            const dst_part_offset, const dst_part_size = dst_part_vi.position(isel);
            var src_field_it = root.src_vi.field(root.ty, root.src_offset + dst_part_offset, dst_part_size);
            const src_part_vi = try src_field_it.only(isel);
            if (src_part_vi == null) {
                try root.dst_vi.copyField(
                    isel,
                    root.ty,
                    root.dst_offset + dst_part_offset,
                    root.src_vi,
                    root.ty,
                    root.src_offset + dst_part_offset,
                    dst_part_size,
                );
                continue;
            }
            try dst_part_vi.copyAdvanced(isel, src_part_vi.?, .{
                .ty = root.ty,
                .dst_vi = root.dst_vi,
                .dst_offset = root.dst_offset + dst_part_offset,
                .src_vi = root.src_vi,
                .src_offset = root.src_offset + dst_part_offset,
            });
        }
    }

    pub const AddOrSubtractOptions = struct {
        overflow: Overflow,

        pub const Overflow = union(enum) {
            @"unreachable",
            panic: Zcu.SimplePanicId,
            wrap,
            ra: Register.Alias,

            pub fn defCond(overflow: Overflow, isel: *Select, cond: codegen.aarch64.encoding.ConditionCode) !void {
                switch (overflow) {
                    .@"unreachable" => unreachable,
                    .panic => |panic_id| {
                        const skip_label = isel.instructions.items.len;
                        try isel.emitPanic(panic_id);
                        try isel.emit(.@"b."(
                            cond.invert(),
                            @intCast((isel.instructions.items.len + 1 - skip_label) << 2),
                        ));
                    },
                    .wrap => {},
                    .ra => |overflow_ra| try isel.emit(.csinc(overflow_ra.w(), .wzr, .wzr, cond.invert())),
                }
            }
        };
    };
    pub fn addOrSubtract(
        res_vi: Value.Index,
        isel: *Select,
        ty: ZigType,
        lhs_vi: Value.Index,
        op: codegen.aarch64.encoding.Instruction.AddSubtractOp,
        rhs_vi: Value.Index,
        opts: AddOrSubtractOptions,
    ) !void {
        const zcu = isel.pt.zcu;
        if (!ty.isAbiInt(zcu)) return isel.fail("bad {t} {f}", .{ op, isel.fmtType(ty) });
        const int_info = ty.intInfo(zcu);
        if (int_info.bits > Value.max_parts * 64)
            return isel.fail("too big {t} {f}", .{ op, isel.fmtType(ty) });
        const overflow_result_lock: RegLock = switch (opts.overflow) {
            .ra => |ra| isel.lockReg(ra),
            else => .empty,
        };
        defer overflow_result_lock.unlock(isel);
        var part_offset: u64 = if (int_info.bits > 64)
            @as(u64, @divCeil(int_info.bits, 64)) * 8
        else
            res_vi.size(isel);
        var need_wrap = switch (opts.overflow) {
            .@"unreachable" => false,
            .panic, .wrap, .ra => true,
        };
        var need_carry = switch (opts.overflow) {
            .@"unreachable", .wrap => false,
            .panic, .ra => true,
        };
        while (part_offset > 0) : (need_wrap = false) {
            const part_size = @min(part_offset, 8);
            part_offset -= part_size;
            var wrapped_res_part_it = res_vi.field(ty, part_offset, part_size);
            const wrapped_res_part_vi = try wrapped_res_part_it.only(isel);
            const wrapped_res_part_ra = try wrapped_res_part_vi.?.defReg(isel) orelse
                if (need_carry) .zr else continue;
            const unwrapped_res_part_ra = unwrapped_res_part_ra: {
                if (!need_wrap) break :unwrapped_res_part_ra wrapped_res_part_ra;
                if (int_info.bits % @as(u8, if (part_size <= 4) 32 else 64) == 0) {
                    try opts.overflow.defCond(isel, switch (int_info.signedness) {
                        .signed => .vs,
                        .unsigned => switch (op) {
                            .add => .cs,
                            .sub => .cc,
                        },
                    });
                    break :unwrapped_res_part_ra wrapped_res_part_ra;
                }
                need_carry = false;
                const wrapped_part_ra, const unwrapped_part_ra = part_ra: switch (opts.overflow) {
                    .@"unreachable" => unreachable,
                    .panic, .ra => switch (int_info.signedness) {
                        .signed => {
                            try opts.overflow.defCond(isel, .ne);
                            const wrapped_part_ra = switch (wrapped_res_part_ra) {
                                else => |res_part_ra| res_part_ra,
                                .zr => try isel.allocIntReg(),
                            };
                            errdefer if (wrapped_part_ra != wrapped_res_part_ra) isel.freeReg(wrapped_part_ra);
                            const unwrapped_part_ra = unwrapped_part_ra: {
                                const wrapped_res_part_lock: RegLock = switch (wrapped_res_part_ra) {
                                    else => |res_part_ra| isel.lockReg(res_part_ra),
                                    .zr => .empty,
                                };
                                defer wrapped_res_part_lock.unlock(isel);
                                break :unwrapped_part_ra try isel.allocIntReg();
                            };
                            errdefer isel.freeReg(unwrapped_part_ra);
                            switch (part_size) {
                                else => unreachable,
                                1...4 => try isel.emit(.subs(.wzr, wrapped_part_ra.w(), .{ .register = unwrapped_part_ra.w() })),
                                5...8 => try isel.emit(.subs(.xzr, wrapped_part_ra.x(), .{ .register = unwrapped_part_ra.x() })),
                            }
                            break :part_ra .{ wrapped_part_ra, unwrapped_part_ra };
                        },
                        .unsigned => {
                            const unwrapped_part_ra = unwrapped_part_ra: {
                                const wrapped_res_part_lock: RegLock = switch (wrapped_res_part_ra) {
                                    else => |res_part_ra| isel.lockReg(res_part_ra),
                                    .zr => .empty,
                                };
                                defer wrapped_res_part_lock.unlock(isel);
                                break :unwrapped_part_ra try isel.allocIntReg();
                            };
                            errdefer isel.freeReg(unwrapped_part_ra);
                            const bit: u6 = @truncate(int_info.bits);
                            switch (opts.overflow) {
                                .@"unreachable", .wrap => unreachable,
                                .panic => |panic_id| {
                                    const skip_label = isel.instructions.items.len;
                                    try isel.emitPanic(panic_id);
                                    try isel.emit(.tbz(
                                        switch (bit) {
                                            0 => unreachable,
                                            1...31 => unwrapped_part_ra.w(),
                                            32...63 => unwrapped_part_ra.x(),
                                        },
                                        bit,
                                        @intCast((isel.instructions.items.len + 1 - skip_label) << 2),
                                    ));
                                },
                                .ra => |overflow_ra| try isel.emit(switch (bit) {
                                    0 => unreachable,
                                    1...31 => .ubfm(overflow_ra.w(), unwrapped_part_ra.w(), .{
                                        .N = .word,
                                        .immr = bit,
                                        .imms = bit,
                                    }),
                                    32...63 => .ubfm(overflow_ra.x(), unwrapped_part_ra.x(), .{
                                        .N = .doubleword,
                                        .immr = bit,
                                        .imms = bit,
                                    }),
                                }),
                            }
                            break :part_ra .{ wrapped_res_part_ra, unwrapped_part_ra };
                        },
                    },
                    .wrap => .{ wrapped_res_part_ra, wrapped_res_part_ra },
                };
                defer if (wrapped_part_ra != wrapped_res_part_ra) isel.freeReg(wrapped_part_ra);
                errdefer if (unwrapped_part_ra != wrapped_res_part_ra) isel.freeReg(unwrapped_part_ra);
                if (wrapped_part_ra != .zr) try isel.emit(switch (part_size) {
                    else => unreachable,
                    1...4 => switch (int_info.signedness) {
                        .signed => .sbfm(wrapped_part_ra.w(), unwrapped_part_ra.w(), .{
                            .N = .word,
                            .immr = 0,
                            .imms = @truncate(int_info.bits - 1),
                        }),
                        .unsigned => .ubfm(wrapped_part_ra.w(), unwrapped_part_ra.w(), .{
                            .N = .word,
                            .immr = 0,
                            .imms = @truncate(int_info.bits - 1),
                        }),
                    },
                    5...8 => switch (int_info.signedness) {
                        .signed => .sbfm(wrapped_part_ra.x(), unwrapped_part_ra.x(), .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = @truncate(int_info.bits - 1),
                        }),
                        .unsigned => .ubfm(wrapped_part_ra.x(), unwrapped_part_ra.x(), .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = @truncate(int_info.bits - 1),
                        }),
                    },
                });
                break :unwrapped_res_part_ra unwrapped_part_ra;
            };
            defer if (unwrapped_res_part_ra != wrapped_res_part_ra) isel.freeReg(unwrapped_res_part_ra);
            if (int_info.bits <= 64) {
                // A constant operand is an immediate (either operand of an addition).
                var imm_lhs_vi = lhs_vi;
                var imm_rhs_vi = rhs_vi;
                if (op == .add and isel.constantImmediate(imm_rhs_vi) == null)
                    std.mem.swap(Value.Index, &imm_lhs_vi, &imm_rhs_vi);
                const sf: codegen.aarch64.encoding.Register.GeneralSize = if (part_size <= 4) .word else .doubleword;
                if (isel.constantImmediate(imm_rhs_vi)) |imm| if (AddSubtractImmediate.encode(op, imm, sf)) |enc| {
                    var lhs_part_it = imm_lhs_vi.field(ty, 0, part_size);
                    const lhs_part_mat = try (try lhs_part_it.only(isel)).?.matReg(isel);
                    try enc.emit(isel, need_carry, switch (sf) {
                        .word => unwrapped_res_part_ra.w(),
                        .doubleword => unwrapped_res_part_ra.x(),
                    }, switch (sf) {
                        .word => lhs_part_mat.ra.w(),
                        .doubleword => lhs_part_mat.ra.x(),
                    });
                    try lhs_part_mat.finish(isel);
                    return;
                };
            }
            var lhs_part_it = lhs_vi.field(ty, part_offset, part_size);
            const lhs_part_vi = try lhs_part_it.only(isel);
            const lhs_part_mat = try lhs_part_vi.?.matReg(isel);
            var rhs_part_it = rhs_vi.field(ty, part_offset, part_size);
            const rhs_part_vi = try rhs_part_it.only(isel);
            const rhs_part_mat = try rhs_part_vi.?.matReg(isel);
            try isel.emit(switch (part_size) {
                else => unreachable,
                1...4 => switch (op) {
                    .add => switch (part_offset) {
                        0 => switch (need_carry) {
                            false => .add(unwrapped_res_part_ra.w(), lhs_part_mat.ra.w(), .{ .register = rhs_part_mat.ra.w() }),
                            true => .adds(unwrapped_res_part_ra.w(), lhs_part_mat.ra.w(), .{ .register = rhs_part_mat.ra.w() }),
                        },
                        else => switch (need_carry) {
                            false => .adc(unwrapped_res_part_ra.w(), lhs_part_mat.ra.w(), rhs_part_mat.ra.w()),
                            true => .adcs(unwrapped_res_part_ra.w(), lhs_part_mat.ra.w(), rhs_part_mat.ra.w()),
                        },
                    },
                    .sub => switch (part_offset) {
                        0 => switch (need_carry) {
                            false => .sub(unwrapped_res_part_ra.w(), lhs_part_mat.ra.w(), .{ .register = rhs_part_mat.ra.w() }),
                            true => .subs(unwrapped_res_part_ra.w(), lhs_part_mat.ra.w(), .{ .register = rhs_part_mat.ra.w() }),
                        },
                        else => switch (need_carry) {
                            false => .sbc(unwrapped_res_part_ra.w(), lhs_part_mat.ra.w(), rhs_part_mat.ra.w()),
                            true => .sbcs(unwrapped_res_part_ra.w(), lhs_part_mat.ra.w(), rhs_part_mat.ra.w()),
                        },
                    },
                },
                5...8 => switch (op) {
                    .add => switch (part_offset) {
                        0 => switch (need_carry) {
                            false => .add(unwrapped_res_part_ra.x(), lhs_part_mat.ra.x(), .{ .register = rhs_part_mat.ra.x() }),
                            true => .adds(unwrapped_res_part_ra.x(), lhs_part_mat.ra.x(), .{ .register = rhs_part_mat.ra.x() }),
                        },
                        else => switch (need_carry) {
                            false => .adc(unwrapped_res_part_ra.x(), lhs_part_mat.ra.x(), rhs_part_mat.ra.x()),
                            true => .adcs(unwrapped_res_part_ra.x(), lhs_part_mat.ra.x(), rhs_part_mat.ra.x()),
                        },
                    },
                    .sub => switch (part_offset) {
                        0 => switch (need_carry) {
                            false => .sub(unwrapped_res_part_ra.x(), lhs_part_mat.ra.x(), .{ .register = rhs_part_mat.ra.x() }),
                            true => .subs(unwrapped_res_part_ra.x(), lhs_part_mat.ra.x(), .{ .register = rhs_part_mat.ra.x() }),
                        },
                        else => switch (need_carry) {
                            false => .sbc(unwrapped_res_part_ra.x(), lhs_part_mat.ra.x(), rhs_part_mat.ra.x()),
                            true => .sbcs(unwrapped_res_part_ra.x(), lhs_part_mat.ra.x(), rhs_part_mat.ra.x()),
                        },
                    },
                },
            });
            if (part_offset > 0 and part_offset * 8 + 64 > int_info.bits) {
                const top_bits: u6 = @intCast(int_info.bits - part_offset * 8 - 1);
                // ABI padding in the top limb is not part of the integer.
                // Canonicalize it before propagating the lower-limb carry,
                // in place: the operands' registers may be where they
                // live, but only bits that are not part of the value and
                // that every use extends change.
                for ([_]Register.Alias{ lhs_part_mat.ra, rhs_part_mat.ra }) |operand_ra| {
                    try isel.emit(switch (int_info.signedness) {
                        .signed => .sbfm(operand_ra.x(), operand_ra.x(), .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = top_bits,
                        }),
                        .unsigned => .ubfm(operand_ra.x(), operand_ra.x(), .{
                            .N = .doubleword,
                            .immr = 0,
                            .imms = top_bits,
                        }),
                    });
                }
            }
            try rhs_part_mat.finish(isel);
            try lhs_part_mat.finish(isel);
            need_carry = true;
        }
    }

    /// The value of type `root_ty` that a value being accessed is a part
    /// of, and the part's offset in it, by which a part too large for a
    /// register is split along the fields of `root_ty`.
    pub const Root = struct { vi: Value.Index, offset: u64 };

    pub const MemoryAccessOptions = struct {
        /// Null when the value is the root itself.
        root: ?Root = null,
        offset: u64 = 0,
        @"volatile": bool = false,
        split: bool = true,
        wrap: ?std.lang.Type.Int = null,
        expected_live_registers: *const LiveRegisters = &.initFill(.free),
        /// The memory is the value's own stack slot: a loaded part is not
        /// stored back to it, and a part not live in a register is not loaded.
        in_place: bool = false,
    };

    pub fn load(
        vi: Value.Index,
        isel: *Select,
        root_ty: ZigType,
        base_ra: Register.Alias,
        opts: MemoryAccessOptions,
    ) !bool {
        const root: Root = opts.root orelse .{ .vi = vi, .offset = 0 };
        var part_it = vi.parts(isel);
        if (part_it.only()) |part_vi| only: {
            const part_size = part_vi.size(isel);
            const part_is_vector = part_vi.isVector(isel);
            if (part_size > @as(@TypeOf(part_size), if (part_is_vector) 16 else 8)) {
                if (!opts.split) return false;
                var subpart_it = root.vi.field(root_ty, root.offset, part_size - 1);
                _ = try subpart_it.next(isel);
                part_it = vi.parts(isel);
                assert(part_it.only() == null);
                break :only;
            }
            const part_ra = if (try part_vi.defRegAdvanced(isel, .{ .store_home = !opts.in_place })) |part_ra|
                part_ra
            else if (opts.@"volatile")
                .zr
            else
                return false;
            const part_lock: RegLock = switch (part_ra) {
                else => isel.lockReg(part_ra),
                .zr => .empty,
            };
            defer switch (opts.expected_live_registers.get(part_ra)) {
                _ => {},
                .allocating => unreachable,
                .free => part_lock.unlock(isel),
            };
            // A part that the integer fills exactly is already extended by the load;
            // otherwise the bits above its width are undefined in memory.
            if (opts.wrap) |int_info| if (int_info.bits < 8 * part_size) {
                const imms: u6 = @intCast(int_info.bits - 1);
                try isel.emit(if (part_size <= 4) switch (int_info.signedness) {
                    .signed => .sbfm(part_ra.w(), part_ra.w(), .{ .N = .word, .immr = 0, .imms = imms }),
                    .unsigned => .ubfm(part_ra.w(), part_ra.w(), .{ .N = .word, .immr = 0, .imms = imms }),
                } else switch (int_info.signedness) {
                    .signed => .sbfm(part_ra.x(), part_ra.x(), .{ .N = .doubleword, .immr = 0, .imms = imms }),
                    .unsigned => .ubfm(part_ra.x(), part_ra.x(), .{ .N = .doubleword, .immr = 0, .imms = imms }),
                });
            };
            try isel.loadReg(part_ra, part_size, part_vi.signedness(isel), base_ra, opts.offset);
            return true;
        }
        var used = false;
        while (part_it.next()) |part_vi| used |= try part_vi.load(isel, root_ty, base_ra, .{
            .root = .{ .vi = root.vi, .offset = root.offset + part_vi.get(isel).offset_from_parent },
            .offset = opts.offset + part_vi.get(isel).offset_from_parent,
            .@"volatile" = opts.@"volatile",
            .split = opts.split,
            .wrap = switch (part_it.remaining) {
                else => null,
                0 => if (opts.wrap) |wrap| .{
                    .signedness = wrap.signedness,
                    .bits = @intCast(wrap.bits - 8 * part_vi.position(isel)[0]),
                } else null,
            },
            .expected_live_registers = opts.expected_live_registers,
            .in_place = opts.in_place,
        });
        return used;
    }

    pub fn store(
        vi: Value.Index,
        isel: *Select,
        root_ty: ZigType,
        base_ra: Register.Alias,
        opts: MemoryAccessOptions,
    ) !void {
        const root: Root = opts.root orelse .{ .vi = vi, .offset = 0 };
        var part_it = vi.parts(isel);
        if (part_it.only()) |part_vi| only: {
            const part_size = part_vi.size(isel);
            const part_is_vector = part_vi.isVector(isel);
            if (part_size > @as(@TypeOf(part_size), if (part_is_vector) 16 else 8)) {
                if (!opts.split) return;
                var subpart_it = root.vi.field(root_ty, root.offset, part_size - 1);
                _ = try subpart_it.next(isel);
                part_it = vi.parts(isel);
                assert(part_it.only() == null);
                break :only;
            }
            const part_mat = try part_vi.matReg(isel);
            try isel.storeReg(part_mat.ra, part_size, base_ra, opts.offset);
            return part_mat.finish(isel);
        }
        while (part_it.next()) |part_vi| try part_vi.store(isel, root_ty, base_ra, .{
            .root = .{ .vi = root.vi, .offset = root.offset + part_vi.get(isel).offset_from_parent },
            .offset = opts.offset + part_vi.get(isel).offset_from_parent,
            .@"volatile" = opts.@"volatile",
            .split = opts.split,
            .wrap = switch (part_it.remaining) {
                else => null,
                0 => if (opts.wrap) |wrap| .{
                    .signedness = wrap.signedness,
                    .bits = @intCast(wrap.bits - 8 * part_vi.position(isel)[0]),
                } else null,
            },
            .expected_live_registers = opts.expected_live_registers,
        });
    }

    pub fn mat(vi: Value.Index, isel: *Select) !void {
        if (false) {
            var part_it: Value.PartIterator = if (vi.size(isel) > 8) vi.parts(isel) else .initOne(vi);
            if (part_it.only()) |part_vi| only: {
                const mat_ra = mat_ra: {
                    if (part_vi.register(isel)) |mat_ra| {
                        part_vi.get(isel).location_payload.small.register = .zr;
                        const live_vi = isel.live_registers.getPtr(mat_ra);
                        assert(live_vi.* == part_vi);
                        live_vi.* = .allocating;
                        break :mat_ra mat_ra;
                    }
                    if (part_vi.hint(isel)) |hint_ra| {
                        const live_vi = isel.live_registers.getPtr(hint_ra);
                        if (live_vi.* == .free) {
                            live_vi.* = .allocating;
                            isel.saved_registers.insert(hint_ra);
                            break :mat_ra hint_ra;
                        }
                    }
                    const part_size = part_vi.size(isel);
                    const part_is_vector = part_vi.isVector(isel);
                    if (part_size <= @as(@TypeOf(part_size), if (part_is_vector) 16 else 8))
                        switch (if (part_is_vector) isel.tryAllocVecReg() else isel.tryAllocIntReg()) {
                            .allocated => |ra| break :mat_ra ra,
                            .fill_candidate, .out_of_registers => {},
                        };
                    _, const parent_vi = vi.valueParent(isel);
                    switch (parent_vi.parent(isel)) {
                        .unallocated => parent_vi.setParent(isel, .{ .stack_slot = parent_vi.allocStackSlot(isel) }),
                        else => {},
                    }
                    break :only;
                };
                assert(isel.live_registers.get(mat_ra) == .allocating);
                try Value.Materialize.finish(.{ .vi = part_vi, .ra = mat_ra }, isel);
            } else while (part_it.next()) |part_vi| try part_vi.mat(isel);
        } else {
            _, const parent_vi = vi.valueParent(isel);
            switch (parent_vi.parent(isel)) {
                .unallocated => parent_vi.setParent(isel, .{ .stack_slot = parent_vi.allocStackSlot(isel) }),
                else => {},
            }
        }
    }

    pub fn matReg(vi: Value.Index, isel: *Select) !Value.Materialize {
        const mat_ra = mat_ra: {
            if (vi.register(isel)) |mat_ra| {
                vi.get(isel).location_payload.small.register = .zr;
                const live_vi = isel.live_registers.getPtr(mat_ra);
                assert(live_vi.* == vi);
                live_vi.* = .allocating;
                break :mat_ra mat_ra;
            }
            // Taken already by another operand that is this value: the
            // value is copied for this one (see `Materialize.finish`).
            if (vi.pin(isel)) |pin_ra| switch (isel.live_registers.get(pin_ra)) {
                _ => return isel.promotionBug("pinned register {t} is not free", .{pin_ra}),
                .allocating => {},
                .free => {
                    isel.reserveReg(pin_ra);
                    break :mat_ra pin_ra;
                },
            };
            if (vi.hint(isel)) |hint_ra| if (isel.live_registers.get(hint_ra) == .free) {
                isel.reserveReg(hint_ra);
                isel.saved_registers.insert(hint_ra);
                break :mat_ra hint_ra;
            };
            break :mat_ra if (vi.isVector(isel)) try isel.allocVecReg() else try isel.allocIntReg();
        };
        assert(isel.live_registers.get(mat_ra) == .allocating);
        return .{ .vi = vi, .ra = mat_ra };
    }

    pub fn defAddr(
        def_vi: Value.Index,
        isel: *Select,
        root_ty: ZigType,
        opts: struct {
            wrap: ?std.lang.Type.Int = null,
            expected_live_registers: *const LiveRegisters = &.initFill(.free),
        },
    ) !?void {
        if (!def_vi.isUsed(isel)) return null;
        const offset_from_parent: i65, const parent_vi = def_vi.valueParent(isel);
        const stack_slot = switch (parent_vi.parent(isel)) {
            .unallocated => slot: {
                const new_slot = parent_vi.allocStackSlot(isel);
                // Loading tracked parts can materialize another part's
                // address; publish the slot before that can reenter.
                parent_vi.setParent(isel, .{ .stack_slot = new_slot });
                break :slot new_slot;
            },
            .stack_slot => |stack_slot| stack_slot,
            else => unreachable,
        };
        _ = try def_vi.load(isel, root_ty, stack_slot.base, .{
            .offset = @intCast(stack_slot.offset + offset_from_parent),
            .split = false,
            .wrap = opts.wrap,
            .expected_live_registers = opts.expected_live_registers,
            // Normalizing an integer's top part also normalizes its memory.
            .in_place = if (opts.wrap) |wrap| wrap.bits == 8 * def_vi.size(isel) else true,
        });
    }

    pub fn defReg(def_vi: Value.Index, isel: *Select) !?Register.Alias {
        return def_vi.defRegAdvanced(isel, .{});
    }

    pub fn defRegAdvanced(def_vi: Value.Index, isel: *Select, opts: struct {
        /// Store the definition to the stack slot that holds the value. Off when
        /// the definition is loaded from that slot: memory already holds it.
        store_home: bool = true,
    }) !?Register.Alias {
        var vi = def_vi;
        var offset: i65 = 0;
        var def_ra: ?Register.Alias = null;
        while (true) {
            if (vi.register(isel)) |ra| {
                if (vi == def_vi) {
                    // An ancestor that is also live in a register reads
                    // this definition too: compose the outermost one
                    // from its parts first, then define this part.
                    var outer_vi: ?Value.Index = null;
                    var ancestor_vi = def_vi;
                    while (true) switch (ancestor_vi.parent(isel)) {
                        .value => |parent_vi| {
                            if (parent_vi.register(isel) != null) outer_vi = parent_vi;
                            ancestor_vi = parent_vi;
                        },
                        else => break,
                    };
                    if (outer_vi) |ancestor_with_ra| {
                        vi = ancestor_with_ra;
                        continue;
                    }
                }
                vi.get(isel).location_payload.small.register = .zr;
                const live_vi = isel.live_registers.getPtr(ra);
                assert(live_vi.* == vi);
                if (def_ra == null and vi != def_vi) {
                    var part_it = vi.parts(isel);
                    assert(part_it.only() == null);

                    const first_part_vi = part_it.next().?;
                    const first_part_value = first_part_vi.get(isel);
                    assert(first_part_value.offset_from_parent == 0);
                    // A first part already live in its own register is
                    // inserted like the others.
                    const insert_first_part = !first_part_value.flags.is_padding and
                        first_part_vi.register(isel) != null;
                    if (insert_first_part) part_it = vi.parts(isel);
                    const first_part_ra = if (insert_first_part or first_part_value.flags.is_padding or
                        first_part_vi.isVector(isel) == ra.isVector()) ra else first_part_ra: {
                        live_vi.* = .allocating;
                        break :first_part_ra if (first_part_vi.isVector(isel)) try isel.allocVecReg() else try isel.allocIntReg();
                    };
                    if (insert_first_part or first_part_value.flags.is_padding) {
                        live_vi.* = .allocating;
                    } else {
                        first_part_value.location_payload.small.register = first_part_ra;
                        isel.live_registers.set(first_part_ra, first_part_vi);
                    }

                    const vi_size = vi.size(isel);
                    while (part_it.next()) |part_vi| {
                        if (part_vi.get(isel).flags.is_padding) continue;
                        const part_offset, const part_size = part_vi.position(isel);
                        const part_mat = try part_vi.matReg(isel);
                        const part_int_ra = if (!ra.isVector() and part_mat.ra.isVector()) try isel.allocIntReg() else part_mat.ra;
                        defer if (part_int_ra != part_mat.ra) isel.freeReg(part_int_ra);
                        try isel.emit(if (ra.isVector()) emit: {
                            assert(part_offset + part_size <= vi_size);
                            assert(part_offset % part_size == 0);
                            break :emit switch (part_size) {
                                else => unreachable,
                                1 => .ins(
                                    ra.@"b[]"(@intCast(part_offset)),
                                    if (part_mat.ra.isVector()) part_mat.ra.@"b[]"(0) else part_mat.ra.w(),
                                ),
                                2 => .ins(
                                    ra.@"h[]"(@intCast(part_offset / 2)),
                                    if (part_mat.ra.isVector()) part_mat.ra.@"h[]"(0) else part_mat.ra.w(),
                                ),
                                4 => .ins(
                                    ra.@"s[]"(@intCast(part_offset / 4)),
                                    if (part_mat.ra.isVector()) part_mat.ra.@"s[]"(0) else part_mat.ra.w(),
                                ),
                                8 => .ins(
                                    ra.@"d[]"(@intCast(part_offset / 8)),
                                    if (part_mat.ra.isVector()) part_mat.ra.@"d[]"(0) else part_mat.ra.x(),
                                ),
                                16 => if (part_mat.ra.isVector())
                                    .orr(ra.@"16b"(), part_mat.ra.@"16b"(), .{ .register = part_mat.ra.@"16b"() })
                                else
                                    unreachable,
                            };
                        } else switch (vi_size) {
                            else => unreachable,
                            1...4 => .bfm(ra.w(), part_int_ra.w(), .{
                                .N = .word,
                                .immr = @as(u5, @truncate(32 - 8 * part_offset)),
                                .imms = @intCast(8 * part_size - 1),
                            }),
                            5...8 => .bfm(ra.x(), part_int_ra.x(), .{
                                .N = .doubleword,
                                .immr = @as(u6, @truncate(64 - 8 * part_offset)),
                                .imms = @intCast(8 * part_size - 1),
                            }),
                        });
                        if (part_int_ra != part_mat.ra) try isel.emit(switch (part_size) {
                            else => unreachable,
                            1 => .umov(part_int_ra.w(), part_mat.ra.@"b[]"(0)),
                            2 => .umov(part_int_ra.w(), part_mat.ra.@"h[]"(0)),
                            4 => .fmov(part_int_ra.w(), .{ .register = part_mat.ra.s() }),
                            8 => .fmov(part_int_ra.x(), .{ .register = part_mat.ra.d() }),
                        });
                        try part_mat.finish(isel);
                    }
                    if (first_part_ra != ra) {
                        try isel.emit(if (ra.isVector()) size: switch (first_part_vi.size(isel)) {
                            else => unreachable,
                            2 => if (isel.target.cpu.has(.aarch64, .fullfp16))
                                .fmov(ra.h(), .{ .register = first_part_ra.w() })
                            else
                                continue :size 4,
                            4 => .fmov(ra.s(), .{ .register = first_part_ra.w() }),
                            8 => .fmov(ra.d(), .{ .register = first_part_ra.x() }),
                        } else switch (first_part_vi.size(isel)) {
                            else => unreachable,
                            1 => .umov(ra.w(), first_part_ra.@"b[]"(0)),
                            2 => .umov(ra.w(), first_part_ra.@"h[]"(0)),
                            4 => .fmov(ra.w(), .{ .register = first_part_ra.s() }),
                            8 => .fmov(ra.x(), .{ .register = first_part_ra.d() }),
                        });
                        isel.freeReg(ra);
                    }
                    if (insert_first_part or first_part_vi.get(isel).flags.is_padding) isel.freeReg(ra);
                    vi = def_vi;
                    offset = 0;
                    continue;
                }
                live_vi.* = .free;
                def_ra = ra;
            }
            offset += vi.get(isel).offset_from_parent;
            switch (vi.parent(isel)) {
                else => unreachable,
                // Uses rematerialize stack addresses, so the definition is unused.
                .unallocated, .stack_address => return def_ra,
                .stack_slot => |stack_slot| {
                    if (!opts.store_home) return def_ra;
                    offset += stack_slot.offset;
                    const def_is_vector = def_vi.isVector(isel);
                    const ra = def_ra orelse if (def_is_vector) try isel.allocVecReg() else try isel.allocIntReg();
                    defer if (def_ra == null) isel.freeReg(ra);
                    const ra_lock = if (def_ra != null) isel.tryLockReg(ra) else RegLock.empty;
                    defer ra_lock.unlock(isel);
                    try isel.storeReg(ra, def_vi.size(isel), stack_slot.base, offset);
                    return ra;
                },
                .value => |parent_vi| vi = parent_vi,
            }
        }
    }

    pub fn defUndef(def_vi: Value.Index, isel: *Select, root_ty: ZigType, opts: struct {
        /// Null when `def_vi` is the root itself.
        root: ?Root = null,
        split: bool = true,
    }) !void {
        const root: Root = opts.root orelse .{ .vi = def_vi, .offset = 0 };
        var part_it = def_vi.parts(isel);
        if (part_it.only()) |part_vi| only: {
            const part_size = part_vi.size(isel);
            const part_is_vector = part_vi.isVector(isel);
            if (part_size > @as(@TypeOf(part_size), if (part_is_vector) 16 else 8)) {
                if (!opts.split) return;
                var subpart_it = root.vi.field(root_ty, root.offset, part_size - 1);
                _ = try subpart_it.next(isel);
                part_it = def_vi.parts(isel);
                assert(part_it.only() == null);
                break :only;
            }
            // A vector part can live in a general register, e.g. as part
            // of a value returned in general registers.
            return if (try part_vi.defReg(isel)) |part_ra| try isel.emit(if (part_ra.isVector())
                .movi(switch (part_size) {
                    else => unreachable,
                    1...8 => part_ra.@"8b"(),
                    9...16 => part_ra.@"16b"(),
                }, 0xaa, .{ .lsl = 0 })
            else switch (part_size) {
                else => unreachable,
                1...4 => .orr(part_ra.w(), .wzr, .{ .immediate = .{
                    .N = .word,
                    .immr = 0b000001,
                    .imms = 0b111100,
                } }),
                5...8 => .orr(part_ra.x(), .xzr, .{ .immediate = .{
                    .N = .word,
                    .immr = 0b000001,
                    .imms = 0b111100,
                } }),
            });
        }
        while (part_it.next()) |part_vi| try part_vi.defUndef(isel, root_ty, .{
            .root = .{ .vi = root.vi, .offset = root.offset + part_vi.get(isel).offset_from_parent },
        });
    }

    pub fn liveIn(
        vi: Value.Index,
        isel: *Select,
        src_ra: Register.Alias,
        expected_live_registers: *const LiveRegisters,
    ) !void {
        const src_live_vi = isel.live_registers.getPtr(src_ra);
        if (vi.register(isel)) |dst_ra| {
            const dst_live_vi = isel.live_registers.getPtr(dst_ra);
            assert(dst_live_vi.* == vi);
            if (dst_ra == src_ra) {
                src_live_vi.* = .allocating;
                return;
            }
            dst_live_vi.* = .allocating;
            if (try isel.fill(src_ra)) {
                assert(src_live_vi.* == .free);
                src_live_vi.* = .allocating;
            }
            assert(src_live_vi.* == .allocating);
            try isel.emit(switch (dst_ra.isVector()) {
                false => switch (src_ra.isVector()) {
                    false => switch (vi.size(isel)) {
                        else => unreachable,
                        1...4 => .orr(dst_ra.w(), .wzr, .{ .register = src_ra.w() }),
                        5...8 => .orr(dst_ra.x(), .xzr, .{ .register = src_ra.x() }),
                    },
                    true => switch (vi.size(isel)) {
                        else => unreachable,
                        1 => .umov(dst_ra.w(), src_ra.@"b[]"(0)),
                        2 => if (isel.target.cpu.has(.aarch64, .fullfp16))
                            .fmov(dst_ra.w(), .{ .register = src_ra.h() })
                        else
                            .umov(dst_ra.w(), src_ra.@"h[]"(0)),
                        4 => .fmov(dst_ra.w(), .{ .register = src_ra.s() }),
                        8 => .fmov(dst_ra.x(), .{ .register = src_ra.d() }),
                    },
                },
                true => switch (src_ra.isVector()) {
                    false => size: switch (vi.size(isel)) {
                        else => unreachable,
                        1 => continue :size 4,
                        2 => if (isel.target.cpu.has(.aarch64, .fullfp16))
                            .fmov(dst_ra.h(), .{ .register = src_ra.w() })
                        else
                            continue :size 4,
                        4 => .fmov(dst_ra.s(), .{ .register = src_ra.w() }),
                        8 => .fmov(dst_ra.d(), .{ .register = src_ra.x() }),
                    },
                    true => switch (vi.size(isel)) {
                        else => unreachable,
                        1 => .dup(dst_ra.b(), src_ra.@"b[]"(0)),
                        2 => if (isel.target.cpu.has(.aarch64, .fullfp16))
                            .fmov(dst_ra.h(), .{ .register = src_ra.h() })
                        else
                            .dup(dst_ra.h(), src_ra.@"h[]"(0)),
                        4 => .fmov(dst_ra.s(), .{ .register = src_ra.s() }),
                        8 => .fmov(dst_ra.d(), .{ .register = src_ra.d() }),
                        16 => .orr(dst_ra.@"16b"(), src_ra.@"16b"(), .{ .register = src_ra.@"16b"() }),
                    },
                },
            });
            assert(dst_live_vi.* == .allocating);
            dst_live_vi.* = switch (expected_live_registers.get(dst_ra)) {
                _ => .allocating,
                .allocating => .allocating,
                .free => .free,
            };
        } else if (try isel.fill(src_ra)) {
            assert(src_live_vi.* == .free);
            src_live_vi.* = .allocating;
        }
        assert(src_live_vi.* == .allocating);
        vi.get(isel).location_payload.small.register = src_ra;
    }

    pub fn defLiveIn(
        vi: Value.Index,
        isel: *Select,
        src_ra: Register.Alias,
        expected_live_registers: *const LiveRegisters,
    ) !void {
        try vi.liveIn(isel, src_ra, expected_live_registers);
        const offset_from_parent, const parent_vi = vi.valueParent(isel);
        switch (parent_vi.parent(isel)) {
            .unallocated => {},
            .stack_slot => |stack_slot| if (stack_slot.base != Register.Alias.fp) try isel.storeReg(
                src_ra,
                vi.size(isel),
                stack_slot.base,
                @as(i65, stack_slot.offset) + offset_from_parent,
            ),
            else => unreachable,
        }
        try vi.spillReg(isel, src_ra, 0, expected_live_registers);
    }

    pub fn spillReg(
        vi: Value.Index,
        isel: *Select,
        src_ra: Register.Alias,
        start_offset: u64,
        expected_live_registers: *const LiveRegisters,
    ) !void {
        assert(isel.live_registers.get(src_ra) == .allocating);
        var part_it = vi.parts(isel);
        if (part_it.only() == null) {
            while (part_it.next()) |part_vi| try part_vi.spillReg(
                isel,
                src_ra,
                start_offset + part_vi.get(isel).offset_from_parent,
                expected_live_registers,
            );
            // A value with parts can also be live in a register of its own.
            part_it = .initOne(vi);
        }
        if (part_it.only()) |part_vi| {
            const dst_ra = part_vi.register(isel) orelse return;
            if (dst_ra == src_ra) return;
            const part_size = part_vi.size(isel);
            if (src_ra.isVector()) {
                assert(start_offset % part_size == 0);
                assert(start_offset + part_size <= 16);
                try isel.emit(switch (part_size) {
                    else => unreachable,
                    1 => if (dst_ra.isVector())
                        .dup(dst_ra.b(), src_ra.@"b[]"(@intCast(start_offset)))
                    else switch (part_vi.signedness(isel)) {
                        .unsigned => .umov(dst_ra.w(), src_ra.@"b[]"(@intCast(start_offset))),
                        .signed => .smov(dst_ra.w(), src_ra.@"b[]"(@intCast(start_offset))),
                    },
                    2 => if (dst_ra.isVector())
                        .dup(dst_ra.h(), src_ra.@"h[]"(@intCast(start_offset / 2)))
                    else switch (part_vi.signedness(isel)) {
                        .unsigned => .umov(dst_ra.w(), src_ra.@"h[]"(@intCast(start_offset / 2))),
                        .signed => .smov(dst_ra.w(), src_ra.@"h[]"(@intCast(start_offset / 2))),
                    },
                    4 => if (dst_ra.isVector())
                        .dup(dst_ra.s(), src_ra.@"s[]"(@intCast(start_offset / 4)))
                    else
                        .umov(dst_ra.w(), src_ra.@"s[]"(@intCast(start_offset / 4))),
                    8 => if (dst_ra.isVector())
                        .dup(dst_ra.d(), src_ra.@"d[]"(@intCast(start_offset / 8)))
                    else
                        .umov(dst_ra.x(), src_ra.@"d[]"(@intCast(start_offset / 8))),
                    16 => if (dst_ra.isVector())
                        .orr(dst_ra.@"16b"(), src_ra.@"16b"(), .{ .register = src_ra.@"16b"() })
                    else
                        unreachable,
                });
                const dst_live_vi = isel.live_registers.getPtr(dst_ra);
                assert(dst_live_vi.* == part_vi);
                dst_live_vi.* = switch (expected_live_registers.get(dst_ra)) {
                    _ => .allocating,
                    .allocating => .allocating,
                    .free => .free,
                };
                part_vi.get(isel).location_payload.small.register = .zr;
                return;
            }
            const part_ra = if (dst_ra.isVector()) try isel.allocIntReg() else dst_ra;
            defer if (part_ra != dst_ra) isel.freeReg(part_ra);
            if (part_ra != dst_ra) try isel.emit(part_size: switch (part_size) {
                else => unreachable,
                1 => continue :part_size 4,
                2 => if (isel.target.cpu.has(.aarch64, .fullfp16))
                    .fmov(dst_ra.h(), .{ .register = part_ra.w() })
                else
                    continue :part_size 4,
                4 => .fmov(dst_ra.s(), .{ .register = part_ra.w() }),
                8 => .fmov(dst_ra.d(), .{ .register = part_ra.x() }),
            });
            try isel.emit(switch (start_offset + part_size) {
                else => unreachable,
                1...4 => |end_offset| switch (part_vi.signedness(isel)) {
                    .signed => .sbfm(part_ra.w(), src_ra.w(), .{
                        .N = .word,
                        .immr = @intCast(8 * start_offset),
                        .imms = @intCast(8 * end_offset - 1),
                    }),
                    .unsigned => .ubfm(part_ra.w(), src_ra.w(), .{
                        .N = .word,
                        .immr = @intCast(8 * start_offset),
                        .imms = @intCast(8 * end_offset - 1),
                    }),
                },
                5...8 => |end_offset| switch (part_vi.signedness(isel)) {
                    .signed => .sbfm(part_ra.x(), src_ra.x(), .{
                        .N = .doubleword,
                        .immr = @intCast(8 * start_offset),
                        .imms = @intCast(8 * end_offset - 1),
                    }),
                    .unsigned => .ubfm(part_ra.x(), src_ra.x(), .{
                        .N = .doubleword,
                        .immr = @intCast(8 * start_offset),
                        .imms = @intCast(8 * end_offset - 1),
                    }),
                },
            });
            const value_ra = &part_vi.get(isel).location_payload.small.register;
            assert(value_ra.* == dst_ra);
            value_ra.* = .zr;
            const dst_live_vi = isel.live_registers.getPtr(dst_ra);
            assert(dst_live_vi.* == part_vi);
            dst_live_vi.* = switch (expected_live_registers.get(dst_ra)) {
                _ => .allocating,
                .allocating => unreachable,
                .free => .free,
            };
        }
    }

    /// Whether `Materialize.finish` produces this value where it is
    /// called, rather than making it live in the register back to its
    /// definition.
    pub fn isMaterializedAt(initial_vi: Value.Index, isel: *Select) bool {
        var vi = initial_vi;
        while (true) {
            if (vi.register(isel) != null) return true;
            switch (vi.parent(isel)) {
                .unallocated => return false,
                .value => |parent_vi| vi = parent_vi,
                .stack_slot, .address, .constant, .stack_address => return true,
            }
        }
    }

    pub fn liveOut(vi: Value.Index, isel: *Select, ra: Register.Alias) !void {
        return Value.Materialize.liveOut(.{ .vi = vi, .ra = ra }, isel);
    }

    /// `liveOut` of the value that a store to the promoted local in `ra`
    /// defines there.
    pub fn liveOutToPromotedLocal(vi: Value.Index, isel: *Select, ra: Register.Alias) !void {
        return Value.Materialize.liveOut(.{ .vi = vi, .ra = ra, .defines_promoted_local = true }, isel);
    }

    pub fn allocStackSlot(vi: Value.Index, isel: *Select) Value.Indirect {
        const offset = vi.alignment(isel).forward(isel.stack_size);
        isel.stack_size = @intCast(offset + vi.size(isel));
        tracking_log.debug("${d} -> [sp, #0x{x}]", .{ @backingInt(vi), @abs(offset) });
        return .{
            .base = .sp,
            .offset = @intCast(offset),
        };
    }

    /// The memory location of a value that lives in a stack slot,
    /// allocating the slot if necessary, or null for any other memory.
    pub fn stackLocation(initial_vi: Value.Index, isel: *Select) ?struct { base: Register.Alias, offset: i65 } {
        var vi = initial_vi;
        var offset: i65 = vi.get(isel).offset_from_parent;
        parent: switch (vi.parent(isel)) {
            .unallocated => {
                const stack_slot = vi.allocStackSlot(isel);
                vi.setParent(isel, .{ .stack_slot = stack_slot });
                continue :parent .{ .stack_slot = stack_slot };
            },
            .stack_slot => |stack_slot| return .{ .base = stack_slot.base, .offset = offset + stack_slot.offset },
            .value => |parent_vi| {
                vi = parent_vi;
                offset += vi.get(isel).offset_from_parent;
                continue :parent vi.parent(isel);
            },
            .address, .constant, .stack_address => return null,
        }
    }

    pub fn address(initial_vi: Value.Index, isel: *Select, initial_offset: u64, ptr_ra: Register.Alias) !void {
        var vi = initial_vi;
        var offset: i65 = vi.get(isel).offset_from_parent + initial_offset;
        parent: switch (vi.parent(isel)) {
            .unallocated => {
                const stack_slot = vi.allocStackSlot(isel);
                vi.setParent(isel, .{ .stack_slot = stack_slot });
                continue :parent .{ .stack_slot = stack_slot };
            },
            .stack_slot => |stack_slot| {
                offset += stack_slot.offset;
                try isel.addSubImmediate(
                    .add,
                    ptr_ra.x(),
                    stack_slot.base.x(),
                    @truncate(@as(u65, @bitCast(offset))),
                    .{ .scratch = ptr_ra.x() },
                );
            },
            .address => |address_vi| {
                // An indirect value: offset the pointer to it.
                const unsigned_offset = std.math.cast(u24, offset) orelse
                    return isel.fail("unsupported indirect value offset {d}", .{offset});
                try isel.addSubImmediate(.add, ptr_ra.x(), ptr_ra.x(), unsigned_offset, .{});
                try address_vi.liveOut(isel, ptr_ra);
            },
            .value => |parent_vi| {
                vi = parent_vi;
                offset += vi.get(isel).offset_from_parent;
                continue :parent vi.parent(isel);
            },
            .stack_address => |stack_address| {
                // The address has no memory of its own: store it to a new
                // stack slot for this use.
                const stack_slot = vi.allocStackSlot(isel);
                offset += stack_slot.offset;
                try isel.addSubImmediate(
                    .add,
                    ptr_ra.x(),
                    stack_slot.base.x(),
                    @truncate(@as(u65, @bitCast(offset))),
                    .{ .scratch = ptr_ra.x() },
                );
                try isel.storeReg(ptr_ra, 8, stack_slot.base, stack_slot.offset);
                try isel.stackAddress(ptr_ra, stack_address);
            },
            .constant => |constant| {
                const pt = isel.pt;
                const zcu = pt.zcu;
                switch (true) {
                    false => {
                        try isel.uav_relocs.append(zcu.gpa, .{
                            .uav = .{
                                .val = constant.toIntern(),
                                .orig_ty = (try pt.singleConstPtrType(constant.typeOf(zcu))).toIntern(),
                            },
                            .reloc = .{
                                .label = @intCast(isel.instructions.items.len),
                                .addend = @intCast(offset),
                            },
                        });
                        try isel.emit(.adr(ptr_ra.x(), 0));
                    },
                    true => {
                        try isel.uav_relocs.append(zcu.gpa, .{
                            .uav = .{
                                .val = constant.toIntern(),
                                .orig_ty = (try pt.singleConstPtrType(constant.typeOf(zcu))).toIntern(),
                            },
                            .reloc = .{
                                .label = @intCast(isel.instructions.items.len),
                                .addend = @intCast(offset),
                            },
                        });
                        try isel.emit(.add(ptr_ra.x(), ptr_ra.x(), .{ .immediate = 0 }));
                        try isel.uav_relocs.append(zcu.gpa, .{
                            .uav = .{
                                .val = constant.toIntern(),
                                .orig_ty = (try pt.singleConstPtrType(constant.typeOf(zcu))).toIntern(),
                            },
                            .reloc = .{
                                .label = @intCast(isel.instructions.items.len),
                                .addend = @intCast(offset),
                            },
                        });
                        try isel.emit(.adrp(ptr_ra.x(), 0));
                    },
                }
            },
        }
    }
};

pub const PartIterator = struct {
    vi: Value.Index,
    remaining: Value.PartsLen,

    pub fn initOne(vi: Value.Index) PartIterator {
        return .{ .vi = vi, .remaining = 1 };
    }

    pub fn next(it: *PartIterator) ?Value.Index {
        if (it.remaining == 0) return null;
        it.remaining -= 1;
        defer it.vi = @fromBackingInt(@intCast(@backingInt(it.vi) + 1));
        return it.vi;
    }

    pub fn peek(it: PartIterator) ?Value.Index {
        var it_mut = it;
        return it_mut.next();
    }

    pub fn only(it: PartIterator) ?Value.Index {
        return if (it.remaining == 1) it.vi else null;
    }
};

pub const FieldPartIterator = struct {
    vi: Value.Index,
    ty: ZigType,
    field_offset: u64,
    field_size: u64,
    next_offset: u64,

    pub fn splitParts(isel: *Select, vi: Value.Index, offset: u64, parts: anytype) bool {
        if (parts.len == 0) return false;
        const before_size = if (parts.len == 1) parts[0].offset - offset else 0;
        const after_offset = if (parts.len == 1) before_size + parts[0].size else vi.size(isel);
        const after_size = vi.size(isel) - after_offset;
        assert(parts.len != 1 or before_size > 0 or after_size > 0);
        // A single runtime field can leave padding in the tracked value. Keep
        // that span in separate parts so the field has its exact width.
        vi.setParts(isel, @as(Value.PartsLen, @intCast(parts.len)) +
            @as(Value.PartsLen, @intFromBool(before_size > 0)) +
            @as(Value.PartsLen, @intFromBool(after_size > 0)));
        if (before_size > 0) vi.addPart(isel, 0, before_size).get(isel).flags.is_padding = true;
        for (parts) |part| {
            const subpart_vi = vi.addPart(isel, part.offset - offset, part.size);
            if (@hasField(@TypeOf(part), "signedness")) {
                if (part.signedness) |signedness| subpart_vi.setSignedness(isel, signedness);
            }
            if (@hasField(@TypeOf(part), "is_vector")) {
                if (part.is_vector) subpart_vi.setIsVector(isel);
            }
        }
        if (after_size > 0) vi.addPart(isel, after_offset, after_size).get(isel).flags.is_padding = true;
        return true;
    }

    /// Parts of the span `offset..offset + size` of an aggregate that
    /// follow its fields, which are added in increasing offset order. A
    /// field that would make a part no larger than `max_part_size` joins
    /// the part before it. A part keeps its field's signedness only when
    /// it is exactly that field, and is in a vector register when all of
    /// its fields are and it has a vector register's size.
    pub const Partition = struct {
        offset: u64,
        size: u64,
        max_part_size: u64,
        parts: [Value.max_parts]Part = undefined,
        len: Value.PartsLen = 0,

        pub const Part = struct {
            offset: u64,
            size: u64,
            signedness: ?std.lang.Signedness,
            is_vector: bool,
        };

        pub fn init(offset: u64, size: u64) Partition {
            const min_part_log2_stride = Value.partLog2Stride(size);
            assert(@divCeil(size, @as(u64, 1) << min_part_log2_stride) <= Value.max_parts);
            return .{ .offset = offset, .size = size, .max_part_size = @as(u64, 1) << min_part_log2_stride };
        }

        /// Adds the field `field_begin..field_end`, which overlaps the
        /// span without containing it.
        pub fn add(
            partition: *Partition,
            field_begin: u64,
            field_end: u64,
            signedness: ?std.lang.Signedness,
            is_vector: bool,
        ) void {
            const span_end = partition.offset + partition.size;
            const covered = field_begin >= partition.offset and field_end <= span_end;
            if (partition.len > 0) {
                const prev_part = &partition.parts[partition.len - 1];
                const combined_size = @min(field_end, span_end) - prev_part.offset;
                if (combined_size <= partition.max_part_size) {
                    prev_part.size = combined_size;
                    prev_part.signedness = null;
                    prev_part.is_vector = prev_part.is_vector and is_vector and covered;
                    return;
                }
            }
            assert(partition.len < partition.parts.len);
            const part_begin = @max(field_begin, partition.offset);
            partition.parts[partition.len] = .{
                .offset = part_begin,
                .size = @min(field_end, span_end) - part_begin,
                .signedness = if (covered) signedness else null,
                .is_vector = is_vector and covered,
            };
            partition.len += 1;
        }

        pub fn split(partition: *Partition, isel: *Select, vi: Value.Index) bool {
            const parts = partition.parts[0..partition.len];
            for (parts) |*part| part.is_vector = part.is_vector and Value.isVectorSize(part.size);
            return splitParts(isel, vi, partition.offset, parts);
        }
    };

    /// The signedness a part holding exactly one value of `ty` is loaded
    /// with: that of an integer of at most 16 bits, as an array element
    /// would be.
    pub fn smallIntSignedness(ty: ZigType, zcu: *Zcu) ?std.lang.Signedness {
        if (!ty.isAbiInt(zcu)) return null;
        const int_info = ty.intInfo(zcu);
        return if (int_info.bits <= 16) int_info.signedness else null;
    }

    /// Whether a part holding exactly one value of `ty` lives in a vector
    /// register: a homogeneous floating-point or vector aggregate that
    /// fits one.
    pub fn isVectorField(ty: ZigType, size: u64, zcu: *Zcu) bool {
        return Value.isVectorSize(size) and
            CallAbiIterator.homogeneousAggregateBaseType(zcu, ty.toIntern()) != null;
    }

    pub fn next(it: *FieldPartIterator, isel: *Select) !?struct { offset: u64, vi: Value.Index } {
        var next_offset = it.next_offset;
        var next_part_size = it.field_size - next_offset;
        if (next_part_size == 0) return null;
        var next_part_offset = it.field_offset + next_offset;

        const zcu = isel.pt.zcu;
        const ip = &zcu.intern_pool;
        var vi = it.vi;
        var ty = it.ty;
        var ty_size = vi.size(isel);
        assert(ty_size == ty.abiSize(zcu));
        var offset: u64 = 0;
        var size = ty_size;
        assert(next_part_offset <= size);
        assert(next_part_size <= size - next_part_offset);
        while (next_part_offset > 0 or next_part_size < size) {
            const part_vi = vi.partAtOffset(isel, next_part_offset);
            if (part_vi != vi) {
                const part_offset, size = part_vi.position(isel);
                if (part_offset > next_part_offset or next_part_offset - part_offset >= size) {
                    var next_offset_in_parent = vi.size(isel);
                    var part_it = vi.parts(isel);
                    while (part_it.next()) |next_part_vi| {
                        const next_part_begin = next_part_vi.get(isel).offset_from_parent;
                        if (next_part_begin > next_part_offset) {
                            next_offset_in_parent = next_part_begin;
                            break;
                        }
                    }
                    assert(next_offset_in_parent > next_part_offset);
                    const padding_size = next_offset_in_parent - next_part_offset;
                    if (padding_size >= next_part_size) {
                        it.next_offset = it.field_size;
                        return null;
                    }
                    it.next_offset += padding_size;
                    next_offset = it.next_offset;
                    next_part_size = it.field_size - next_offset;
                    next_part_offset = it.field_offset + next_offset;
                    vi = it.vi;
                    ty = it.ty;
                    ty_size = vi.size(isel);
                    offset = 0;
                    size = ty_size;
                    continue;
                }
                vi = part_vi;
                offset += part_offset;
                next_part_offset -= part_offset;
                continue;
            }
            try isel.values.ensureUnusedCapacity(zcu.gpa, Value.max_parts);
            var skip_padding = false;
            type_key: switch (ip.indexToKey(ty.toIntern())) {
                else => return isel.fail("Value.FieldPartIterator.next({f})", .{isel.fmtType(ty)}),
                .int_type => |int_type| switch (int_type.bits) {
                    0 => unreachable,
                    // A part boundary of the enclosing value falls inside the
                    // integer, as for an 8-byte field at offset 4 of an extern
                    // struct passed in two registers: split it there.
                    1...64 => {
                        const boundary = if (next_part_offset > 0) next_part_offset else next_part_size;
                        assert(boundary > 0 and boundary < size);
                        vi.setParts(isel, 2);
                        _ = vi.addPart(isel, 0, boundary);
                        _ = vi.addPart(isel, boundary, size - boundary);
                    },
                    65...(Value.max_parts * 64) => |bits| if (offset == 0 and size == ty_size) {
                        const parts_len = @divCeil(bits, 64);
                        vi.setParts(isel, @intCast(parts_len));
                        for (0..parts_len) |part_index| _ = vi.addPart(isel, 8 * part_index, 8);
                    },
                    else => return isel.fail("Value.FieldPartIterator.next({f})", .{isel.fmtType(ty)}),
                },
                .ptr_type => |ptr_type| switch (ptr_type.flags.size) {
                    .one, .many, .c => unreachable,
                    .slice => if (offset == 0 and size == ty_size) {
                        vi.setParts(isel, 2);
                        _ = vi.addPart(isel, 0, 8);
                        _ = vi.addPart(isel, 8, 8);
                    } else unreachable,
                },
                .opt_type => |child_type| if (ty.optionalReprIsPayload(zcu)) continue :type_key ip.indexToKey(child_type) else {
                    const child_ty: ZigType = .fromInterned(child_type);
                    const child_size = child_ty.abiSize(zcu);
                    if (offset <= child_size and size <= child_size - offset) {
                        ty = child_ty;
                        ty_size = child_size;
                        continue :type_key ip.indexToKey(child_type);
                    }
                    var partition: Partition = .init(offset, size);
                    if (offset < child_size) partition.add(
                        0,
                        child_size,
                        smallIntSignedness(child_ty, zcu),
                        isVectorField(child_ty, child_size, zcu),
                    );
                    if (offset <= child_size and child_size < offset + size)
                        partition.add(child_size, child_size + 1, null, false);
                    skip_padding = !partition.split(isel, vi);
                },
                .vector_type => {
                    // Vector lanes may share bytes, so partition their memory representation.
                    const stride = @as(u64, 1) << Value.partLog2Stride(size);
                    const parts_len = @divCeil(size, stride);
                    assert(parts_len > 1 and parts_len <= Value.max_parts);
                    // A part holding exactly one byte-aligned small integer lane is
                    // loaded with that lane's signedness, as an array element would be.
                    const elem_ty = ty.childType(zcu);
                    const elem_size = elem_ty.abiSize(zcu);
                    const elem_signedness = if (elem_ty.isAbiInt(zcu) and
                        isel.vectorLaneBits(elem_ty) == 8 * elem_size)
                    elem_signedness: {
                        const elem_int_info = elem_ty.intInfo(zcu);
                        break :elem_signedness if (elem_int_info.bits <= 16) elem_int_info.signedness else null;
                    } else null;
                    vi.setParts(isel, @intCast(parts_len));
                    for (0..@intCast(parts_len)) |part_index| {
                        const part_offset = stride * part_index;
                        const part_size = @min(stride, size - part_offset);
                        const subpart_vi = vi.addPart(isel, part_offset, part_size);
                        if (Value.isVectorSize(part_size)) subpart_vi.setIsVector(isel);
                        if (part_size == elem_size and part_offset % elem_size == 0) {
                            if (elem_signedness) |signedness| subpart_vi.setSignedness(isel, signedness);
                        }
                    }
                },
                .array_type => |array_type| {
                    var partition: Partition = .init(offset, size);
                    const array_len = array_type.lenIncludingSentinel();
                    const elem_ty: ZigType = .fromInterned(array_type.child);
                    const elem_size = elem_ty.abiSize(zcu);
                    const elem_signedness = smallIntSignedness(elem_ty, zcu);
                    const elem_is_vector = isVectorField(elem_ty, elem_size, zcu);
                    var elem_end: u64 = 0;
                    for (0..@intCast(array_len)) |_| {
                        const elem_begin = elem_end;
                        if (elem_begin >= offset + size) break;
                        elem_end = elem_begin + elem_size;
                        if (elem_end <= offset) continue;
                        if (offset >= elem_begin and offset + size <= elem_begin + elem_size) {
                            ty = elem_ty;
                            ty_size = elem_size;
                            offset -= elem_begin;
                            continue :type_key ip.indexToKey(elem_ty.toIntern());
                        }
                        partition.add(elem_begin, elem_end, elem_signedness, elem_is_vector);
                    }
                    skip_padding = !partition.split(isel, vi);
                },
                .anyframe_type => unreachable,
                .error_union_type => |error_union_type| {
                    var partition: Partition = .init(offset, size);
                    const payload_ty: ZigType = .fromInterned(error_union_type.payload_type);
                    const error_set_offset = codegen.errUnionErrorOffset(payload_ty, zcu);
                    const payload_offset = codegen.errUnionPayloadOffset(payload_ty, zcu);
                    var field_end: u64 = 0;
                    for (0..2) |field_index| {
                        const field_ty: ZigType, const field_begin = switch (@as(enum { error_set, payload }, switch (field_index) {
                            0 => if (error_set_offset < payload_offset) .error_set else .payload,
                            1 => if (error_set_offset < payload_offset) .payload else .error_set,
                            else => unreachable,
                        })) {
                            .error_set => .{ .fromInterned(error_union_type.error_set_type), error_set_offset },
                            .payload => .{ payload_ty, payload_offset },
                        };
                        if (field_begin >= offset + size) break;
                        const field_size = field_ty.abiSize(zcu);
                        if (field_size == 0) continue;
                        field_end = field_begin + field_size;
                        if (field_end <= offset) continue;
                        if (offset >= field_begin and offset + size <= field_begin + field_size) {
                            ty = field_ty;
                            ty_size = field_size;
                            offset -= field_begin;
                            continue :type_key ip.indexToKey(field_ty.toIntern());
                        }
                        partition.add(
                            field_begin,
                            field_end,
                            smallIntSignedness(field_ty, zcu),
                            isVectorField(field_ty, field_size, zcu),
                        );
                    }
                    skip_padding = !partition.split(isel, vi);
                },
                .simple_type => |simple_type| switch (simple_type) {
                    .f16, .f32, .f64, .f128, .c_longdouble => return isel.fail("Value.FieldPartIterator.next({f})", .{isel.fmtType(ty)}),
                    .f80 => continue :type_key .{ .int_type = .{ .signedness = .unsigned, .bits = 80 } },
                    .usize,
                    .isize,
                    .c_char,
                    .c_short,
                    .c_ushort,
                    .c_int,
                    .c_uint,
                    .c_long,
                    .c_ulong,
                    .c_longlong,
                    .c_ulonglong,
                    => continue :type_key .{ .int_type = ty.intInfo(zcu) },
                    .anyopaque,
                    .void,
                    .type,
                    .comptime_int,
                    .comptime_float,
                    .noreturn,
                    .null,
                    .undefined,
                    .enum_literal,
                    .adhoc_inferred_error_set,
                    .generic_poison,
                    => unreachable,
                    .bool => continue :type_key .{ .int_type = .{ .signedness = .unsigned, .bits = 1 } },
                    .anyerror => continue :type_key .{ .int_type = .{
                        .signedness = .unsigned,
                        .bits = zcu.errorSetBits(),
                    } },
                },
                .struct_type => {
                    const loaded_struct = ip.loadStructType(ty.toIntern());
                    switch (loaded_struct.layout) {
                        .auto, .@"extern" => {},
                        .@"packed" => continue :type_key .{
                            .int_type = ip.indexToKey(loaded_struct.packed_backing_int_type).int_type,
                        },
                    }
                    var partition: Partition = .init(offset, size);
                    var field_end: u64 = 0;
                    var field_it = loaded_struct.iterateRuntimeOrder(ip);
                    while (field_it.next()) |field_index| {
                        const field_ty: ZigType = .fromInterned(loaded_struct.field_types.get(ip)[field_index]);
                        const field_begin = switch (loaded_struct.field_aligns.getOrNone(ip, field_index)) {
                            .none => field_ty.abiAlignment(zcu),
                            else => |field_align| field_align,
                        }.forward(field_end);
                        if (field_begin >= offset + size) break;
                        const field_size = field_ty.abiSize(zcu);
                        if (field_size == 0) continue;
                        field_end = field_begin + field_size;
                        if (field_end <= offset) continue;
                        if (offset >= field_begin and offset + size <= field_begin + field_size) {
                            ty = field_ty;
                            ty_size = field_size;
                            offset -= field_begin;
                            continue :type_key ip.indexToKey(field_ty.toIntern());
                        }
                        partition.add(
                            field_begin,
                            field_end,
                            smallIntSignedness(field_ty, zcu),
                            isVectorField(field_ty, field_size, zcu),
                        );
                    }
                    skip_padding = !partition.split(isel, vi);
                },
                .tuple_type => |tuple_type| {
                    var partition: Partition = .init(offset, size);
                    var field_end: u64 = 0;
                    for (tuple_type.types.get(ip), tuple_type.values.get(ip)) |field_type, field_value| {
                        if (field_value != .none) continue;
                        const field_ty: ZigType = .fromInterned(field_type);
                        const field_begin = field_ty.abiAlignment(zcu).forward(field_end);
                        if (field_begin >= offset + size) break;
                        const field_size = field_ty.abiSize(zcu);
                        if (field_size == 0) continue;
                        field_end = field_begin + field_size;
                        if (field_end <= offset) continue;
                        if (offset >= field_begin and offset + size <= field_begin + field_size) {
                            ty = field_ty;
                            ty_size = field_size;
                            offset -= field_begin;
                            continue :type_key ip.indexToKey(field_ty.toIntern());
                        }
                        partition.add(field_begin, field_end, null, isVectorField(field_ty, field_size, zcu));
                    }
                    skip_padding = !partition.split(isel, vi);
                },
                .union_type => {
                    const loaded_union = ip.loadUnionType(ty.toIntern());
                    switch (loaded_union.layout) {
                        .auto, .@"extern" => {},
                        .@"packed" => continue :type_key .{ .int_type = .{
                            .signedness = .unsigned,
                            .bits = @intCast(ty.bitSize(zcu)),
                        } },
                    }
                    var partition: Partition = .init(offset, size);
                    const union_layout = ZigType.getUnionLayout(loaded_union, zcu);
                    const tag_offset = union_layout.tagOffset();
                    const payload_offset = union_layout.payloadOffset();
                    var field_end: u64 = 0;
                    for (0..2) |field_index| {
                        const field: enum { tag, payload } = switch (field_index) {
                            0 => if (tag_offset < payload_offset) .tag else .payload,
                            1 => if (tag_offset < payload_offset) .payload else .tag,
                            else => unreachable,
                        };
                        const field_size, const field_begin = switch (field) {
                            .tag => .{ union_layout.tag_size, tag_offset },
                            .payload => .{ union_layout.payload_size, payload_offset },
                        };
                        if (field_begin >= offset + size) break;
                        if (field_size == 0) continue;
                        field_end = field_begin + field_size;
                        if (field_end <= offset) continue;
                        const field_signedness = field_signedness: switch (field) {
                            .tag => {
                                if (offset >= field_begin and offset + size <= field_begin + field_size) {
                                    ty = .fromInterned(loaded_union.enum_tag_type);
                                    ty_size = field_size;
                                    offset -= field_begin;
                                    continue :type_key ip.indexToKey(loaded_union.enum_tag_type);
                                }
                                const loaded_enum = ip.loadEnumType(loaded_union.enum_tag_type);
                                break :field_signedness smallIntSignedness(.fromInterned(loaded_enum.int_tag_type), zcu);
                            },
                            .payload => {
                                if (offset >= field_begin and offset + size <= field_end) {
                                    ty = try isel.pt.arrayType(.{ .len = field_size, .child = .u8_type });
                                    ty_size = field_size;
                                    offset -= field_begin;
                                    continue :type_key ip.indexToKey(ty.toIntern());
                                }
                                break :field_signedness null;
                            },
                        };
                        partition.add(field_begin, field_end, field_signedness, false);
                    }
                    skip_padding = !partition.split(isel, vi);
                },
                .opaque_type, .func_type => continue :type_key .{ .simple_type = .anyopaque },
                .enum_type => continue :type_key ip.indexToKey(ip.loadEnumType(ty.toIntern()).int_tag_type),
                .error_set_type,
                .inferred_error_set_type,
                => continue :type_key .{ .simple_type = .anyerror },
                .undef,
                .simple_value,
                .@"extern",
                .func,
                .int,
                .err,
                .error_union,
                .enum_literal,
                .enum_tag,
                .float,
                .ptr,
                .slice,
                .opt,
                .aggregate,
                .un,
                .memoized_call,
                => unreachable, // values, not types
            }
            if (!skip_padding) continue;
            const padding_size = size - next_part_offset;
            assert(padding_size > 0);
            if (padding_size >= next_part_size) {
                it.next_offset = it.field_size;
                return null;
            }
            it.next_offset += padding_size;
            next_offset = it.next_offset;
            next_part_size = it.field_size - next_offset;
            next_part_offset = it.field_offset + next_offset;
            vi = it.vi;
            ty = it.ty;
            ty_size = vi.size(isel);
            offset = 0;
            size = ty_size;
        }
        it.next_offset = next_offset + size;
        return .{ .offset = next_offset - next_part_offset, .vi = vi };
    }

    pub fn only(it: *FieldPartIterator, isel: *Select) !?Value.Index {
        const part = (try it.next(isel)) orelse return null;
        if (part.offset != 0) return null;
        return if (try it.next(isel)) |_| null else part.vi;
    }
};

pub const Materialize = struct {
    vi: Value.Index,
    ra: Register.Alias,
    /// `ra` is a promoted local's register and `vi` the value that a
    /// store to the local defines there (`storeToPromotedLocal`), which
    /// besides the local's own loads is the only value that may live in it.
    defines_promoted_local: bool = false,

    pub fn emitUndefined(mat: Value.Materialize, isel: *Select, size: u64) !void {
        try isel.emit(if (mat.ra.isVector()) .movi(switch (size) {
            else => unreachable,
            1...8 => mat.ra.@"8b"(),
            9...16 => mat.ra.@"16b"(),
        }, 0xaa, .{ .lsl = 0 }) else switch (size) {
            else => unreachable,
            1...4 => .orr(mat.ra.w(), .wzr, .{ .immediate = .{
                .N = .word,
                .immr = 0b000001,
                .imms = 0b111100,
            } }),
            5...8 => .orr(mat.ra.x(), .xzr, .{ .immediate = .{
                .N = .word,
                .immr = 0b000001,
                .imms = 0b111100,
            } }),
        });
    }

    /// Makes `mat.vi` live in `mat.ra`, which is free.
    pub fn liveOut(mat: Value.Materialize, isel: *Select) !void {
        assert(try isel.fill(mat.ra));
        isel.reserveReg(mat.ra);
        try mat.finish(isel);
    }

    pub fn finish(mat: Value.Materialize, isel: *Select) Error!void {
        const live_vi = isel.live_registers.getPtr(mat.ra);
        assert(live_vi.* == .allocating);
        var vi = mat.vi;
        var offset: u64 = 0;
        const size = mat.vi.size(isel);
        free: while (true) {
            if (vi.get(isel).flags.is_padding) break :free try mat.emitUndefined(isel, size);
            if (vi.register(isel)) |ra| {
                if (ra != mat.ra) break :free try isel.emit(if (vi == mat.vi) if (mat.ra.isVector()) switch (size) {
                    else => unreachable,
                    1 => if (ra.isVector())
                        .dup(mat.ra.b(), ra.@"b[]"(0))
                    else
                        .fmov(mat.ra.s(), .{ .register = ra.w() }),
                    2 => if (!ra.isVector())
                        .fmov(mat.ra.s(), .{ .register = ra.w() })
                    else if (isel.target.cpu.has(.aarch64, .fullfp16))
                        .fmov(mat.ra.h(), .{ .register = ra.h() })
                    else
                        .dup(mat.ra.h(), ra.@"h[]"(0)),
                    4 => if (ra.isVector())
                        .fmov(mat.ra.s(), .{ .register = ra.s() })
                    else
                        .fmov(mat.ra.s(), .{ .register = ra.w() }),
                    8 => if (ra.isVector())
                        .fmov(mat.ra.d(), .{ .register = ra.d() })
                    else
                        .fmov(mat.ra.d(), .{ .register = ra.x() }),
                    16 => .orr(mat.ra.@"16b"(), ra.@"16b"(), .{ .register = ra.@"16b"() }),
                } else if (ra.isVector()) switch (size) {
                    else => unreachable,
                    1 => .umov(mat.ra.w(), ra.@"b[]"(0)),
                    2 => .umov(mat.ra.w(), ra.@"h[]"(0)),
                    4 => .fmov(mat.ra.w(), .{ .register = ra.s() }),
                    8 => .fmov(mat.ra.x(), .{ .register = ra.d() }),
                } else switch (size) {
                    else => unreachable,
                    1...4 => .orr(mat.ra.w(), .wzr, .{ .register = ra.w() }),
                    5...8 => .orr(mat.ra.x(), .xzr, .{ .register = ra.x() }),
                } else switch (offset + size) {
                    else => unreachable,
                    1...4 => |end_offset| switch (mat.vi.signedness(isel)) {
                        .signed => .sbfm(mat.ra.w(), ra.w(), .{
                            .N = .word,
                            .immr = @intCast(8 * offset),
                            .imms = @intCast(8 * end_offset - 1),
                        }),
                        .unsigned => .ubfm(mat.ra.w(), ra.w(), .{
                            .N = .word,
                            .immr = @intCast(8 * offset),
                            .imms = @intCast(8 * end_offset - 1),
                        }),
                    },
                    5...8 => |end_offset| switch (mat.vi.signedness(isel)) {
                        .signed => .sbfm(mat.ra.x(), ra.x(), .{
                            .N = .doubleword,
                            .immr = @intCast(8 * offset),
                            .imms = @intCast(8 * end_offset - 1),
                        }),
                        .unsigned => .ubfm(mat.ra.x(), ra.x(), .{
                            .N = .doubleword,
                            .immr = @intCast(8 * offset),
                            .imms = @intCast(8 * end_offset - 1),
                        }),
                    },
                });
                mat.vi.get(isel).location_payload.small.register = mat.ra;
                live_vi.* = mat.vi;
                return;
            }
            offset += vi.get(isel).offset_from_parent;
            switch (vi.parent(isel)) {
                .unallocated => {
                    // A value with a register of its own lives only there.
                    if (mat.vi.pin(isel)) |pin_ra| if (pin_ra != mat.ra) {
                        const pin_live_vi = isel.live_registers.getPtr(pin_ra);
                        try isel.pinnedMove(mat.ra, pin_ra, size);
                        live_vi.* = .free;
                        switch (pin_live_vi.*) {
                            _ => return isel.promotionBug("pinned register {t} is not free", .{pin_ra}),
                            // Another operand that is this value holds the
                            // register and makes the value live there.
                            .allocating => {},
                            .free => {
                                mat.vi.get(isel).location_payload.small.register = pin_ra;
                                pin_live_vi.* = mat.vi;
                            },
                        }
                        return;
                    };
                    // A value defined later in a promoted local's register
                    // would hide the local from here back to its definition.
                    // Only the local's own loads, and the value a store
                    // defines right before it, may live there.
                    if (isel.promotion.pinned.contains(mat.ra) and mat.vi.hint(isel) != mat.ra and
                        mat.vi.pin(isel) != mat.ra and !mat.defines_promoted_local)
                    {
                        const ra = if (mat.vi.isVector(isel)) try isel.allocVecReg() else try isel.allocIntReg();
                        try isel.pinnedMove(mat.ra, ra, size);
                        live_vi.* = .free;
                        mat.vi.get(isel).location_payload.small.register = ra;
                        isel.live_registers.set(ra, mat.vi);
                        return;
                    }
                    // A float or vector value of its own (not a part of
                    // another value) is defined in a vector register (the
                    // float field of a struct passed in general
                    // registers); this use reads a copy.
                    if (vi == mat.vi and mat.vi.isVector(isel) and !mat.ra.isVector()) {
                        const ra = try isel.allocVecReg();
                        try isel.pinnedMove(mat.ra, ra, size);
                        live_vi.* = .free;
                        mat.vi.get(isel).location_payload.small.register = ra;
                        isel.live_registers.set(ra, mat.vi);
                        return;
                    }
                    mat.vi.get(isel).location_payload.small.register = mat.ra;
                    live_vi.* = mat.vi;
                    return;
                },
                .stack_slot => |stack_slot| break :free try isel.loadReg(
                    mat.ra,
                    size,
                    mat.vi.signedness(isel),
                    stack_slot.base,
                    @as(i65, stack_slot.offset) + offset,
                ),
                .address => |base_vi| {
                    const base_mat = try base_vi.matReg(isel);
                    try isel.loadReg(mat.ra, size, mat.vi.signedness(isel), base_mat.ra, offset);
                    break :free try base_mat.finish(isel);
                },
                .value => |parent_vi| vi = parent_vi,
                .stack_address => |stack_address| {
                    if (mat.ra.isVector()) return isel.fail("unsupported stack address in a vector register", .{});
                    if (offset != 0 or size != 8) try isel.emit(.ubfm(mat.ra.x(), mat.ra.x(), .{
                        .N = .doubleword,
                        .immr = @intCast(8 * offset),
                        .imms = @intCast(8 * (offset + size) - 1),
                    }));
                    break :free try isel.stackAddress(mat.ra, stack_address);
                },
                .constant => |initial_constant| {
                    const zcu = isel.pt.zcu;
                    const ip = &zcu.intern_pool;
                    var constant = initial_constant.toIntern();
                    var constant_key = ip.indexToKey(constant);
                    while (true) {
                        constant_key: switch (constant_key) {
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
                            .undef => break :free try mat.emitUndefined(isel, size),
                            .simple_value => |simple_value| switch (simple_value) {
                                .void, .null, .@"unreachable" => unreachable,
                                .true => continue :constant_key .{ .int = .{
                                    .ty = .bool_type,
                                    .storage = .{ .u64 = 1 },
                                } },
                                .false => continue :constant_key .{ .int = .{
                                    .ty = .bool_type,
                                    .storage = .{ .u64 = 0 },
                                } },
                            },
                            .int => |int| break :free switch (int.storage) {
                                .u64 => |imm| try isel.movImmediate(switch (size) {
                                    else => unreachable,
                                    1...4 => mat.ra.w(),
                                    5...8 => mat.ra.x(),
                                }, @bitCast(std.math.shr(u64, imm, 8 * offset))),
                                .i64 => |imm| switch (size) {
                                    else => unreachable,
                                    1...4 => try isel.movImmediate(mat.ra.w(), @as(u32, @bitCast(@as(i32, @truncate(std.math.shr(i64, imm, 8 * offset)))))),
                                    5...8 => try isel.movImmediate(mat.ra.x(), @bitCast(std.math.shr(i64, imm, 8 * offset))),
                                },
                                .big_int => |big_int| {
                                    assert(size == 8);
                                    var imm: u64 = 0;
                                    const limb_bits = @bitSizeOf(std.math.big.Limb);
                                    const limbs = @divExact(64, limb_bits);
                                    var limb_index: usize = @intCast(@divExact(offset, @divExact(limb_bits, 8)) + limbs);
                                    for (0..limbs) |_| {
                                        limb_index -= 1;
                                        if (limb_index >= big_int.limbs.len) continue;
                                        if (limb_bits < 64) imm <<= limb_bits;
                                        imm |= big_int.limbs[limb_index];
                                    }
                                    if (!big_int.positive) {
                                        limb_index = @min(limb_index, big_int.limbs.len);
                                        imm = while (limb_index > 0) {
                                            limb_index -= 1;
                                            if (big_int.limbs[limb_index] != 0) break ~imm;
                                        } else -%imm;
                                    }
                                    try isel.movImmediate(mat.ra.x(), imm);
                                },
                            },
                            .err => |err| continue :constant_key .{ .int = .{
                                .ty = err.ty,
                                .storage = .{ .u64 = ip.getErrorValueIfExists(err.name).? },
                            } },
                            .error_union => |error_union| {
                                const error_union_type = ip.indexToKey(error_union.ty).error_union_type;
                                const error_set_ty: ZigType = .fromInterned(error_union_type.error_set_type);
                                const payload_ty: ZigType = .fromInterned(error_union_type.payload_type);
                                const error_set_offset = codegen.errUnionErrorOffset(payload_ty, zcu);
                                const error_set_size = error_set_ty.abiSize(zcu);
                                if (offset >= error_set_offset and offset + size <= error_set_offset + error_set_size) {
                                    offset -= error_set_offset;
                                    continue :constant_key switch (error_union.val) {
                                        .err_name => |err_name| .{ .err = .{
                                            .ty = error_union_type.error_set_type,
                                            .name = err_name,
                                        } },
                                        .payload => .{ .int = .{
                                            .ty = error_union_type.error_set_type,
                                            .storage = .{ .u64 = 0 },
                                        } },
                                    };
                                }
                                const payload_offset = codegen.errUnionPayloadOffset(payload_ty, zcu);
                                const payload_size = payload_ty.abiSize(zcu);
                                if (offset >= payload_offset and offset + size <= payload_offset + payload_size) {
                                    offset -= payload_offset;
                                    switch (error_union.val) {
                                        .err_name => continue :constant_key .{ .undef = error_union_type.payload_type },
                                        .payload => |payload| {
                                            constant = payload;
                                            constant_key = ip.indexToKey(constant);
                                            continue :constant_key constant_key;
                                        },
                                    }
                                }
                            },
                            .enum_tag => |enum_tag| continue :constant_key .{ .int = ip.indexToKey(enum_tag.int).int },
                            .float => |float| storage: switch (float.storage) {
                                .f16 => |imm| {
                                    if (!mat.ra.isVector()) continue :constant_key .{ .int = .{
                                        .ty = .u16_type,
                                        .storage = .{ .u64 = @as(u16, @bitCast(imm)) },
                                    } };
                                    const feat_fp16 = isel.target.cpu.has(.aarch64, .fullfp16);
                                    if (feat_fp16) {
                                        const Repr = std.math.FloatRepr(f16);
                                        const repr: Repr = @bitCast(imm);
                                        if (repr.mantissa & std.math.maxInt(Repr.Mantissa) >> 5 == 0 and switch (repr.exponent) {
                                            .denormal, .infinite => false,
                                            else => std.math.cast(i3, repr.exponent.unbias() - 1) != null,
                                        }) break :free try isel.emit(.fmov(mat.ra.h(), .{ .immediate = imm }));
                                    }
                                    const bits: u16 = @bitCast(imm);
                                    if (bits == 0) break :free try isel.emit(.movi(mat.ra.d(), 0b00000000, .replicate));
                                    if (bits & std.math.maxInt(u8) == 0) break :free try isel.emit(.movi(
                                        mat.ra.@"4h"(),
                                        @intCast(@shrExact(bits, 8)),
                                        .{ .lsl = 8 },
                                    ));
                                    const temp_ra = try isel.allocIntReg();
                                    defer isel.freeReg(temp_ra);
                                    try isel.emit(.fmov(if (feat_fp16) mat.ra.h() else mat.ra.s(), .{ .register = temp_ra.w() }));
                                    break :free try isel.movImmediate(temp_ra.w(), bits);
                                },
                                .f32 => |imm| {
                                    if (!mat.ra.isVector()) continue :constant_key .{ .int = .{
                                        .ty = .u32_type,
                                        .storage = .{ .u64 = @as(u32, @bitCast(imm)) },
                                    } };
                                    const Repr = std.math.FloatRepr(f32);
                                    const repr: Repr = @bitCast(imm);
                                    if (repr.mantissa & std.math.maxInt(Repr.Mantissa) >> 5 == 0 and switch (repr.exponent) {
                                        .denormal, .infinite => false,
                                        else => std.math.cast(i3, repr.exponent.unbias() - 1) != null,
                                    }) break :free try isel.emit(.fmov(mat.ra.s(), .{ .immediate = @floatCast(imm) }));
                                    const bits: u32 = @bitCast(imm);
                                    if (bits == 0) break :free try isel.emit(.movi(mat.ra.d(), 0b00000000, .replicate));
                                    if (bits & std.math.maxInt(u24) == 0) break :free try isel.emit(.movi(
                                        mat.ra.@"2s"(),
                                        @intCast(@shrExact(bits, 24)),
                                        .{ .lsl = 24 },
                                    ));
                                    const temp_ra = try isel.allocIntReg();
                                    defer isel.freeReg(temp_ra);
                                    try isel.emit(.fmov(mat.ra.s(), .{ .register = temp_ra.w() }));
                                    break :free try isel.movImmediate(temp_ra.w(), bits);
                                },
                                .f64 => |imm| {
                                    if (!mat.ra.isVector()) continue :constant_key .{ .int = .{
                                        .ty = .u64_type,
                                        .storage = .{ .u64 = @as(u64, @bitCast(imm)) },
                                    } };
                                    const Repr = std.math.FloatRepr(f64);
                                    const repr: Repr = @bitCast(imm);
                                    if (repr.mantissa & std.math.maxInt(Repr.Mantissa) >> 5 == 0 and switch (repr.exponent) {
                                        .denormal, .infinite => false,
                                        else => std.math.cast(i3, repr.exponent.unbias() - 1) != null,
                                    }) break :free try isel.emit(.fmov(mat.ra.d(), .{ .immediate = @floatCast(imm) }));
                                    const bits: u64 = @bitCast(imm);
                                    if (bits == 0) break :free try isel.emit(.movi(mat.ra.d(), 0b00000000, .replicate));
                                    const temp_ra = try isel.allocIntReg();
                                    defer isel.freeReg(temp_ra);
                                    try isel.emit(.fmov(mat.ra.d(), .{ .register = temp_ra.x() }));
                                    break :free try isel.movImmediate(temp_ra.x(), bits);
                                },
                                .f80 => |imm| break :free try isel.movImmediate(
                                    mat.ra.x(),
                                    @truncate(std.math.shr(u80, @bitCast(imm), 8 * offset)),
                                ),
                                .f128 => |imm| switch (ZigType.fromInterned(float.ty).floatBits(isel.target)) {
                                    else => unreachable,
                                    16 => continue :storage .{ .f16 = @floatCast(imm) },
                                    32 => continue :storage .{ .f32 = @floatCast(imm) },
                                    64 => continue :storage .{ .f64 = @floatCast(imm) },
                                    128 => {
                                        const bits: u128 = @bitCast(imm);
                                        const hi64: u64 = @intCast(bits >> 64);
                                        const lo64: u64 = @truncate(bits >> 0);
                                        const temp_ra = try isel.allocIntReg();
                                        defer isel.freeReg(temp_ra);
                                        switch (hi64) {
                                            0 => {},
                                            else => {
                                                try isel.emit(.fmov(mat.ra.@"d[]"(1), .{ .register = temp_ra.x() }));
                                                try isel.movImmediate(temp_ra.x(), hi64);
                                            },
                                        }
                                        break :free switch (lo64) {
                                            0 => try isel.emit(.movi(switch (hi64) {
                                                else => mat.ra.d(),
                                                0 => mat.ra.@"2d"(),
                                            }, 0b00000000, .replicate)),
                                            else => {
                                                try isel.emit(.fmov(mat.ra.d(), .{ .register = temp_ra.x() }));
                                                try isel.movImmediate(temp_ra.x(), lo64);
                                            },
                                        };
                                    },
                                },
                            },
                            .ptr => |ptr| {
                                assert(offset == 0 and size == 8);
                                break :free switch (ptr.base_addr) {
                                    .nav => |nav| nav_ptr: {
                                        const nav_value = ip.getNav(nav);
                                        if (zcu.comp.config.any_non_single_threaded and nav_value.resolved.?.@"threadlocal")
                                            break :nav_ptr try isel.tlsNavAddress(mat.ra, nav, ptr.byte_offset);
                                        const nav_type = ZigType.fromInterned(nav_value.resolved.?.type);
                                        const has_runtime_address = nav_value.getExtern(ip) != null or
                                            nav_type.isRuntimeFnOrHasRuntimeBits(zcu);
                                        break :nav_ptr if (has_runtime_address) switch (true) {
                                            false => {
                                                try isel.nav_relocs.append(zcu.gpa, .{
                                                    .nav = nav,
                                                    .reloc = .{
                                                        .label = @intCast(isel.instructions.items.len),
                                                        .addend = ptr.byte_offset,
                                                    },
                                                });
                                                try isel.emit(.adr(mat.ra.x(), 0));
                                            },
                                            true => {
                                                try isel.nav_relocs.append(zcu.gpa, .{
                                                    .nav = nav,
                                                    .reloc = .{
                                                        .label = @intCast(isel.instructions.items.len),
                                                        .addend = ptr.byte_offset,
                                                    },
                                                });
                                                if (nav_value.getExtern(ip)) |_| {
                                                    try isel.emit(.ldr(mat.ra.x(), .{ .unsigned_offset = .{
                                                        .base = mat.ra.x(),
                                                        .offset = 0,
                                                    } }));
                                                } else try isel.emit(.add(mat.ra.x(), mat.ra.x(), .{ .immediate = 0 }));
                                                try isel.nav_relocs.append(zcu.gpa, .{
                                                    .nav = nav,
                                                    .reloc = .{
                                                        .label = @intCast(isel.instructions.items.len),
                                                        .addend = ptr.byte_offset,
                                                    },
                                                });
                                                try isel.emit(.adrp(mat.ra.x(), 0));
                                            },
                                        } else continue :constant_key .{ .int = .{
                                            .ty = .usize_type,
                                            .storage = .{ .u64 = zcu.navAlignment(nav).forward(0xaaaaaaaaaaaaaaaa) },
                                        } };
                                    },
                                    .uav => |uav| if (ZigType.fromInterned(ip.typeOf(uav.val)).isRuntimeFnOrHasRuntimeBits(zcu)) switch (true) {
                                        false => {
                                            try isel.uav_relocs.append(zcu.gpa, .{
                                                .uav = uav,
                                                .reloc = .{
                                                    .label = @intCast(isel.instructions.items.len),
                                                    .addend = ptr.byte_offset,
                                                },
                                            });
                                            try isel.emit(.adr(mat.ra.x(), 0));
                                        },
                                        true => {
                                            try isel.uav_relocs.append(zcu.gpa, .{
                                                .uav = uav,
                                                .reloc = .{
                                                    .label = @intCast(isel.instructions.items.len),
                                                    .addend = ptr.byte_offset,
                                                },
                                            });
                                            try isel.emit(.add(mat.ra.x(), mat.ra.x(), .{ .immediate = 0 }));
                                            try isel.uav_relocs.append(zcu.gpa, .{
                                                .uav = uav,
                                                .reloc = .{
                                                    .label = @intCast(isel.instructions.items.len),
                                                    .addend = ptr.byte_offset,
                                                },
                                            });
                                            try isel.emit(.adrp(mat.ra.x(), 0));
                                        },
                                    } else continue :constant_key .{ .int = .{
                                        .ty = .usize_type,
                                        .storage = .{ .u64 = ZigType.fromInterned(uav.orig_ty).ptrAlignment(zcu).forward(0xaaaaaaaaaaaaaaaa) },
                                    } },
                                    .int => continue :constant_key .{ .int = .{
                                        .ty = .usize_type,
                                        .storage = .{ .u64 = ptr.byte_offset },
                                    } },
                                    .eu_payload => |base| {
                                        var base_ptr = ip.indexToKey(base).ptr;
                                        const eu_ty = ip.indexToKey(base_ptr.ty).ptr_type.child;
                                        const payload_ty = ip.indexToKey(eu_ty).error_union_type.payload_type;
                                        base_ptr.byte_offset += codegen.errUnionPayloadOffset(.fromInterned(payload_ty), zcu) + ptr.byte_offset;
                                        continue :constant_key .{ .ptr = base_ptr };
                                    },
                                    .opt_payload => |base| {
                                        var base_ptr = ip.indexToKey(base).ptr;
                                        base_ptr.byte_offset += ptr.byte_offset;
                                        continue :constant_key .{ .ptr = base_ptr };
                                    },
                                    .field => |field| {
                                        var base_ptr = ip.indexToKey(field.base).ptr;
                                        const agg_ty: ZigType = .fromInterned(ip.indexToKey(base_ptr.ty).ptr_type.child);
                                        const field_offset: u64 = switch (agg_ty.zigTypeTag(zcu)) {
                                            .pointer => slice: {
                                                assert(agg_ty.isSlice(zcu));
                                                break :slice switch (field.index) {
                                                    Constant.slice_ptr_index => 0,
                                                    Constant.slice_len_index => @divExact(isel.target.ptrBitWidth(), 8),
                                                    else => unreachable,
                                                };
                                            },
                                            else => agg_ty.structFieldOffset(@intCast(field.index), zcu),
                                        };
                                        base_ptr.byte_offset += field_offset + ptr.byte_offset;
                                        continue :constant_key .{ .ptr = base_ptr };
                                    },
                                    .comptime_alloc, .comptime_field, .arr_elem => unreachable,
                                };
                            },
                            .slice => |slice| switch (offset) {
                                0 => continue :constant_key switch (ip.indexToKey(slice.ptr)) {
                                    else => unreachable,
                                    .undef => |undef| .{ .undef = undef },
                                    .ptr => |ptr| .{ .ptr = ptr },
                                },
                                else => {
                                    assert(offset == @divExact(isel.target.ptrBitWidth(), 8));
                                    offset = 0;
                                    continue :constant_key .{ .int = ip.indexToKey(slice.len).int };
                                },
                            },
                            .opt => |opt| {
                                const child_ty = ip.indexToKey(opt.ty).opt_type;
                                const child_size = ZigType.fromInterned(child_ty).abiSize(zcu);
                                if (offset == child_size and size == 1) {
                                    offset = 0;
                                    continue :constant_key .{ .simple_value = switch (opt.val) {
                                        .none => .false,
                                        else => .true,
                                    } };
                                }
                                const opt_ty: ZigType = .fromInterned(opt.ty);
                                if (offset + size <= child_size) continue :constant_key switch (opt.val) {
                                    .none => if (opt_ty.optionalReprIsPayload(zcu)) .{ .int = .{
                                        .ty = opt.ty,
                                        .storage = .{ .u64 = 0 },
                                    } } else .{ .undef = child_ty },
                                    else => |child| {
                                        constant = child;
                                        constant_key = ip.indexToKey(constant);
                                        continue :constant_key constant_key;
                                    },
                                };
                            },
                            .aggregate => |aggregate| switch (ip.indexToKey(aggregate.ty)) {
                                else => unreachable,
                                .array_type => |array_type| {
                                    const elem_size = ZigType.fromInterned(array_type.child).abiSize(zcu);
                                    const elem_offset = @mod(offset, elem_size);
                                    if (size <= elem_size - elem_offset) {
                                        defer offset = elem_offset;
                                        continue :constant_key switch (aggregate.storage) {
                                            .bytes => |bytes| .{ .int = .{ .ty = .u8_type, .storage = .{
                                                .u64 = bytes.toSlice(array_type.lenIncludingSentinel(), ip)[@intCast(@divFloor(offset, elem_size))],
                                            } } },
                                            .elems => |elems| {
                                                constant = elems[@intCast(@divFloor(offset, elem_size))];
                                                constant_key = ip.indexToKey(constant);
                                                continue :constant_key constant_key;
                                            },
                                            .repeated_elem => |repeated_elem| {
                                                // The sentinel is not repeated.
                                                constant = if (@divFloor(offset, elem_size) < array_type.len)
                                                    repeated_elem
                                                else
                                                    array_type.sentinel;
                                                constant_key = ip.indexToKey(constant);
                                                continue :constant_key constant_key;
                                            },
                                        };
                                    }
                                },
                                .vector_type => {},
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
                                                if (offset >= field_offset and offset + size <= field_offset + field_size) {
                                                    offset -= field_offset;
                                                    constant = switch (aggregate.storage) {
                                                        .bytes => unreachable,
                                                        .elems => |elems| elems[field_index],
                                                        .repeated_elem => |repeated_elem| repeated_elem,
                                                    };
                                                    constant_key = ip.indexToKey(constant);
                                                    continue :constant_key constant_key;
                                                }
                                                field_offset += field_size;
                                            }
                                        },
                                        .@"extern", .@"packed" => {},
                                    }
                                },
                                .tuple_type => |tuple_type| {
                                    var field_offset: u64 = 0;
                                    for (tuple_type.types.get(ip), tuple_type.values.get(ip), 0..) |field_type, field_value, field_index| {
                                        if (field_value != .none) continue;
                                        const field_ty: ZigType = .fromInterned(field_type);
                                        field_offset = field_ty.abiAlignment(zcu).forward(field_offset);
                                        const field_size = field_ty.abiSize(zcu);
                                        if (offset >= field_offset and offset + size <= field_offset + field_size) {
                                            offset -= field_offset;
                                            constant = switch (aggregate.storage) {
                                                .bytes => unreachable,
                                                .elems => |elems| elems[field_index],
                                                .repeated_elem => |repeated_elem| repeated_elem,
                                            };
                                            constant_key = ip.indexToKey(constant);
                                            continue :constant_key constant_key;
                                        }
                                        field_offset += field_size;
                                    }
                                },
                            },
                            .un => |un| {
                                const loaded_union = ip.loadUnionType(un.ty);
                                const union_layout = ZigType.getUnionLayout(loaded_union, zcu);
                                if (loaded_union.has_runtime_tag) {
                                    const tag_offset = union_layout.tagOffset();
                                    if (offset >= tag_offset and offset + size <= tag_offset + union_layout.tag_size) {
                                        offset -= tag_offset;
                                        continue :constant_key switch (ip.indexToKey(un.tag)) {
                                            else => unreachable,
                                            .int => |int| .{ .int = int },
                                            .enum_tag => |enum_tag| .{ .enum_tag = enum_tag },
                                        };
                                    }
                                }
                                const payload_offset = union_layout.payloadOffset();
                                if (offset >= payload_offset and offset + size <= payload_offset + union_layout.payload_size) {
                                    // The active field may be smaller than the payload.
                                    const val_size = ZigType.fromInterned(ip.typeOf(un.val)).abiSize(zcu);
                                    if (offset - payload_offset >= val_size) {
                                        offset -= payload_offset;
                                        continue :constant_key .{ .undef = un.ty };
                                    }
                                    if (offset - payload_offset + size <= val_size) {
                                        offset -= payload_offset;
                                        constant = un.val;
                                        constant_key = ip.indexToKey(constant);
                                        continue :constant_key constant_key;
                                    }
                                }
                            },
                            else => {},
                        }
                        var buffer: [16]u8 = @splat(0);
                        if (ZigType.fromInterned(constant_key.typeOf()).abiSize(zcu) <= buffer.len and
                            try isel.writeToMemory(.fromInterned(constant), &buffer))
                        {
                            constant_key = if (mat.ra.isVector()) .{ .float = switch (size) {
                                else => unreachable,
                                2 => .{ .ty = .f16_type, .storage = .{ .f16 = @bitCast(std.mem.readInt(
                                    u16,
                                    buffer[@intCast(offset)..][0..2],
                                    isel.target.cpu.arch.endian(),
                                )) } },
                                4 => .{ .ty = .f32_type, .storage = .{ .f32 = @bitCast(std.mem.readInt(
                                    u32,
                                    buffer[@intCast(offset)..][0..4],
                                    isel.target.cpu.arch.endian(),
                                )) } },
                                8 => .{ .ty = .f64_type, .storage = .{ .f64 = @bitCast(std.mem.readInt(
                                    u64,
                                    buffer[@intCast(offset)..][0..8],
                                    isel.target.cpu.arch.endian(),
                                )) } },
                                16 => .{ .ty = .f128_type, .storage = .{ .f128 = @bitCast(std.mem.readInt(
                                    u128,
                                    buffer[@intCast(offset)..][0..16],
                                    isel.target.cpu.arch.endian(),
                                )) } },
                            } } else .{ .int = .{
                                .ty = .u64_type,
                                .storage = .{ .u64 = switch (size) {
                                    else => unreachable,
                                    inline 1...8 => |ct_size| std.mem.readInt(
                                        @Int(.unsigned, 8 * ct_size),
                                        buffer[@intCast(offset)..][0..ct_size],
                                        isel.target.cpu.arch.endian(),
                                    ),
                                } },
                            } };
                            offset = 0;
                            continue;
                        }
                        if (mat.ra.isVector()) switch (size) {
                            1, 2, 4, 8, 16 => {},
                            else => unreachable,
                        } else assert(size <= 8);
                        const base_ra = try isel.allocIntReg();
                        defer isel.freeReg(base_ra);
                        try isel.loadReg(mat.ra, size, mat.vi.signedness(isel), base_ra, 0);
                        break :free try mat.vi.address(isel, 0, base_ra);
                    }
                },
            }
        }
        live_vi.* = .free;
    }
};

const AddSubtractImmediate = Select.AddSubtractImmediate;
const Air = @import("../../Air.zig");
const assert = std.debug.assert;
const CallAbiIterator = Select.CallAbiIterator;
const codegen = @import("../../codegen.zig");
const Constant = @import("../../Value.zig");
const Error = Select.Error;
const InternPool = @import("../../InternPool.zig");
const LiveRegisters = Select.LiveRegisters;
const Register = codegen.aarch64.encoding.Register;
const RegLock = Select.RegLock;
const Select = @import("Select.zig");
const std = @import("std");
const tracking_log = std.log.scoped(.tracking);
const Value = @This();
const Zcu = @import("../../Zcu.zig");
const ZigType = @import("../../Type.zig");
