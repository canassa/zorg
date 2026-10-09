//! Assigns the parameters and the return value of a call to registers and
//! stack slots as the procedure call standard (AAPCS64, with Apple's
//! deviations) passes them, as `Value`s that selection moves arguments into or
//! defines results from.

/// Next General-purpose Register Number
ngrn: Register.Alias,
/// Next SIMD and Floating-point Register Number
nsrn: Register.Alias,
/// next stacked argument address
nsaa: u24,
/// Set while classifying a variadic argument passed on the stack.
var_arg: bool,
/// Apple arm64: named stack arguments other than non-homogeneous
/// composites use their natural size and alignment instead of
/// 8-byte slots.
stack_natural: bool,

pub const ngrn_start: Register.Alias = .r0;
pub const ngrn_end: Register.Alias = .r8;
pub const nsrn_start: Register.Alias = .v0;
pub const nsrn_end: Register.Alias = .v8;
pub const nsaa_start: u42 = 0;

pub const init: CallAbiIterator = .{
    // A.1
    .ngrn = ngrn_start,
    // A.2
    .nsrn = nsrn_start,
    // A.3
    .nsaa = nsaa_start,
    .var_arg = false,
    .stack_natural = false,
};

/// The size of the stacked argument area. Apple arm64 pads packed
/// stack arguments to a multiple of 8 bytes, which variadic arguments
/// start after; otherwise every slot is already a multiple of 8 bytes.
pub fn stackSize(it: CallAbiIterator) u24 {
    return std.mem.alignForward(u24, it.nsaa, 8);
}

pub fn param(it: *CallAbiIterator, isel: *Select, ty: ZigType) !?Value.Index {
    const zcu = isel.pt.zcu;
    const ip = &zcu.intern_pool;

    if (!ty.hasRuntimeBits(zcu)) return null;
    try isel.values.ensureUnusedCapacity(zcu.gpa, Value.max_parts);
    const wip_vi = isel.initValue(ty);
    it.stack_natural = isel.target.os.tag.isDarwin() and !it.var_arg and switch (ip.indexToKey(ty.toIntern())) {
        .array_type, .tuple_type, .error_union_type => false,
        .struct_type => ip.loadStructType(ty.toIntern()).layout == .@"packed",
        .union_type => ip.loadUnionType(ty.toIntern()).layout == .@"packed",
        .opt_type => ty.optionalReprIsPayload(zcu),
        else => true,
    };
    type_key: switch (ip.indexToKey(ty.toIntern())) {
        else => return isel.fail("CallAbiIterator.param({f})", .{isel.fmtType(ty)}),
        .int_type => |int_type| switch (int_type.bits) {
            0 => unreachable,
            1...16 => {
                wip_vi.setSignedness(isel, int_type.signedness);
                // C.7
                it.integer(isel, wip_vi);
            },
            // C.7
            17...64 => it.integer(isel, wip_vi),
            // C.9
            65...128 => it.integers(isel, wip_vi, @splat(@divExact(wip_vi.size(isel), 2))),
            else => it.indirect(isel, wip_vi),
        },
        .vector_type => {
            const info = isel.vectorAbi(ty) orelse {
                // Vectors wider than 128 bits are passed in memory, as for the C ABI.
                if (ty.bitSize(zcu) > 128) {
                    it.indirect(isel, wip_vi);
                    break :type_key;
                }
                // LLVM passes single-lane vectors of bool, f80 and f128 as
                // the scalar they hold; so are the other single lanes.
                if (ty.vectorLen(zcu) == 1) continue :type_key ip.indexToKey(ty.childType(zcu).toIntern());
                return isel.fail("unsupported vector argument/return ABI {f}", .{isel.fmtType(ty)});
            };
            if (isel.target.cpu.arch.endian() != .little)
                return isel.fail("vector argument/return ABI on a big-endian target", .{});
            // A stacked argument occupies a slot of the expanded register's
            // size and natural alignment, e.g. @Vector(16, u4) as 16 x u8.
            wip_vi.setAlignment(isel, wip_vi.alignment(isel).maxStrict(.fromByteUnits(info.register_size)));
            it.vector(isel, wip_vi);
            // The slot may already be padded to 8 bytes; it ends after the register size.
            switch (wip_vi.parent(isel)) {
                else => {},
                .stack_slot => |stack_slot| it.nsaa = @max(it.nsaa, @as(u24, @intCast(stack_slot.offset)) + info.register_size),
            }
        },
        .array_type => switch (wip_vi.size(isel)) {
            0 => unreachable,
            1...8 => it.integer(isel, wip_vi),
            9...16 => |size| it.integers(isel, wip_vi, .{ 8, size - 8 }),
            else => it.indirect(isel, wip_vi),
        },
        .ptr_type => |ptr_type| switch (ptr_type.flags.size) {
            .one, .many, .c => continue :type_key .{ .int_type = .{
                .signedness = .unsigned,
                .bits = 64,
            } },
            .slice => it.integers(isel, wip_vi, @splat(8)),
        },
        .opt_type => |child_type| if (ty.optionalReprIsPayload(zcu))
            continue :type_key ip.indexToKey(child_type)
        else switch (ZigType.fromInterned(child_type).abiSize(zcu)) {
            0 => continue :type_key .{ .simple_type = .bool },
            1...7 => it.integer(isel, wip_vi),
            8...15 => |child_size| it.integers(isel, wip_vi, .{ 8, child_size - 7 }),
            else => it.indirect(isel, wip_vi),
        },
        .anyframe_type => unreachable,
        .error_union_type => |error_union_type| switch (wip_vi.size(isel)) {
            0 => unreachable,
            1...8 => it.integer(isel, wip_vi),
            9...16 => {
                var sizes: [2]u64 = @splat(0);
                const payload_ty: ZigType = .fromInterned(error_union_type.payload_type);
                {
                    const error_set_ty: ZigType = .fromInterned(error_union_type.error_set_type);
                    const offset = codegen.errUnionErrorOffset(payload_ty, zcu);
                    const end = offset % 8 + error_set_ty.abiSize(zcu);
                    const part_index: usize = @intCast(offset / 8);
                    sizes[part_index] = @max(sizes[part_index], @min(end, 8));
                    if (end > 8) sizes[part_index + 1] = @max(sizes[part_index + 1], end - 8);
                }
                {
                    const offset = codegen.errUnionPayloadOffset(payload_ty, zcu);
                    const end = offset % 8 + payload_ty.abiSize(zcu);
                    const part_index: usize = @intCast(offset / 8);
                    sizes[part_index] = @max(sizes[part_index], @min(end, 8));
                    if (end > 8) sizes[part_index + 1] = @max(sizes[part_index + 1], end - 8);
                }
                it.integers(isel, wip_vi, sizes);
            },
            else => it.indirect(isel, wip_vi),
        },
        .simple_type => |simple_type| switch (simple_type) {
            .f16, .f32, .f64, .f128, .c_longdouble => it.vector(isel, wip_vi),
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
            // B.1
            .anyopaque => it.indirect(isel, wip_vi),
            .bool => continue :type_key .{ .int_type = .{ .signedness = .unsigned, .bits = 1 } },
            .anyerror => continue :type_key .{ .int_type = .{
                .signedness = .unsigned,
                .bits = zcu.errorSetBits(),
            } },
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
        },
        .struct_type => {
            const loaded_struct = ip.loadStructType(ty.toIntern());
            switch (loaded_struct.layout) {
                .auto, .@"extern" => {},
                .@"packed" => continue :type_key ip.indexToKey(loaded_struct.packed_backing_int_type),
            }
            const size = wip_vi.size(isel);
            if (size <= 16 * 4) homogeneous_aggregate: {
                const fdt = homogeneousStructBaseType(zcu, &loaded_struct) orelse break :homogeneous_aggregate;
                const parts_len = @shrExact(size, fdt.log2Size());
                if (parts_len > 4) break :homogeneous_aggregate;
                it.vectors(isel, wip_vi, fdt, @intCast(parts_len));
                break :type_key;
            }
            switch (size) {
                0 => unreachable,
                1...8 => it.integer(isel, wip_vi),
                9...16 => {
                    var part_offset: u64 = 0;
                    var part_sizes: [2]u64 = undefined;
                    var parts_len: Value.PartsLen = 0;
                    var next_field_end: u64 = 0;
                    var field_it = loaded_struct.iterateRuntimeOrder(ip);
                    while (part_offset < size) {
                        const field_end = next_field_end;
                        const next_field_begin = if (field_it.next()) |field_index| next_field_begin: {
                            const field_ty: ZigType = .fromInterned(loaded_struct.field_types.get(ip)[field_index]);
                            const next_field_begin = switch (loaded_struct.field_aligns.getOrNone(ip, field_index)) {
                                .none => field_ty.abiAlignment(zcu),
                                else => |field_align| field_align,
                            }.forward(field_end);
                            next_field_end = next_field_begin + field_ty.abiSize(zcu);
                            break :next_field_begin next_field_begin;
                        } else std.mem.alignForward(u64, size, 8);
                        while (next_field_begin - part_offset >= 8) {
                            const part_size = @min(field_end - part_offset, 8);
                            assert(parts_len < part_sizes.len);
                            part_sizes[parts_len] = part_size;
                            assert(part_offset + part_size <= size);
                            parts_len += 1;
                            part_offset += part_size;
                            if (part_offset >= field_end) part_offset = next_field_begin;
                        }
                    }
                    // Fields that end within the first eight bytes, as in
                    // `struct { a: u8 align(16) }`, leave the second
                    // register only padding.
                    const padding = parts_len < part_sizes.len;
                    if (padding) part_sizes[1] = size - 8;
                    it.integers(isel, wip_vi, part_sizes);
                    if (padding) if (wip_vi.parts(isel).only() == null) {
                        var part_it = wip_vi.parts(isel);
                        _ = part_it.next();
                        part_it.next().?.get(isel).flags.is_padding = true;
                    };
                },
                else => it.indirect(isel, wip_vi),
            }
        },
        .tuple_type => |tuple_type| {
            const size = wip_vi.size(isel);
            if (size <= 16 * 4) homogeneous_aggregate: {
                const fdt = homogeneousTupleBaseType(zcu, tuple_type) orelse break :homogeneous_aggregate;
                const parts_len = @shrExact(size, fdt.log2Size());
                if (parts_len > 4) break :homogeneous_aggregate;
                it.vectors(isel, wip_vi, fdt, @intCast(parts_len));
                break :type_key;
            }
            switch (size) {
                0 => unreachable,
                1...8 => it.integer(isel, wip_vi),
                9...16 => {
                    var part_offset: u64 = 0;
                    var part_sizes: [2]u64 = undefined;
                    var parts_len: Value.PartsLen = 0;
                    var next_field_end: u64 = 0;
                    var field_index: usize = 0;
                    while (part_offset < size) {
                        const field_end = next_field_end;
                        const next_field_begin = while (field_index < tuple_type.types.len) {
                            defer field_index += 1;
                            if (tuple_type.values.get(ip)[field_index] != .none) continue;
                            const field_ty: ZigType = .fromInterned(tuple_type.types.get(ip)[field_index]);
                            const next_field_begin = field_ty.abiAlignment(zcu).forward(field_end);
                            next_field_end = next_field_begin + field_ty.abiSize(zcu);
                            break next_field_begin;
                        } else std.mem.alignForward(u64, size, 8);
                        while (next_field_begin - part_offset >= 8) {
                            const part_size = @min(field_end - part_offset, 8);
                            assert(parts_len < part_sizes.len);
                            part_sizes[parts_len] = part_size;
                            assert(part_offset + part_size <= size);
                            parts_len += 1;
                            part_offset += part_size;
                            if (part_offset >= field_end) part_offset = next_field_begin;
                        }
                    }
                    assert(parts_len == part_sizes.len);
                    it.integers(isel, wip_vi, part_sizes);
                },
                else => it.indirect(isel, wip_vi),
            }
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
            switch (wip_vi.size(isel)) {
                0 => unreachable,
                1...8 => it.integer(isel, wip_vi),
                9...16 => {
                    const union_layout = ZigType.getUnionLayout(loaded_union, zcu);
                    var sizes: [2]u64 = @splat(0);
                    // An untagged union has no tag bytes, and its nominal tag offset may lie
                    // past the end of the union.
                    if (union_layout.tag_size > 0) {
                        const offset = union_layout.tagOffset();
                        const end = offset % 8 + union_layout.tag_size;
                        const part_index: usize = @intCast(offset / 8);
                        sizes[part_index] = @max(sizes[part_index], @min(end, 8));
                        if (end > 8) sizes[part_index + 1] = @max(sizes[part_index + 1], end - 8);
                    }
                    if (union_layout.payload_size > 0) {
                        const offset = union_layout.payloadOffset();
                        const end = offset % 8 + union_layout.payload_size;
                        const part_index: usize = @intCast(offset / 8);
                        sizes[part_index] = @max(sizes[part_index], @min(end, 8));
                        if (end > 8) sizes[part_index + 1] = @max(sizes[part_index + 1], end - 8);
                    }
                    it.integers(isel, wip_vi, sizes);
                },
                else => it.indirect(isel, wip_vi),
            }
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
    return wip_vi.ref(isel);
}

pub fn nonSysvVarArg(it: *CallAbiIterator, isel: *Select, ty: ZigType) !?Value.Index {
    const ngrn = it.ngrn;
    defer it.ngrn = ngrn;
    it.ngrn = ngrn_end;
    const nsrn = it.nsrn;
    defer it.nsrn = nsrn;
    it.nsrn = nsrn_end;
    it.var_arg = true;
    defer it.var_arg = false;
    return it.param(isel, ty);
}

pub fn ret(it: *CallAbiIterator, isel: *Select, ty: ZigType) !?Value.Index {
    const wip_vi = try it.param(isel, ty) orelse return null;
    switch (wip_vi.parent(isel)) {
        .unallocated, .stack_slot => {},
        .value, .constant, .stack_address => unreachable,
        .address => |address_vi| {
            assert(address_vi.hint(isel) == ngrn_start);
            address_vi.setHint(isel, ngrn_end);
        },
    }
    return wip_vi;
}

pub const FundamentalDataType = enum {
    half,
    single,
    double,
    quad,
    vector64,
    vector128,
    pub fn log2Size(fdt: FundamentalDataType) u3 {
        return switch (fdt) {
            .half => 1,
            .single => 2,
            .double, .vector64 => 3,
            .quad, .vector128 => 4,
        };
    }
    pub fn size(fdt: FundamentalDataType) u64 {
        return @as(u64, 1) << fdt.log2Size();
    }
};
pub fn homogeneousAggregateBaseType(zcu: *Zcu, initial_ty: InternPool.Index) ?FundamentalDataType {
    const ip = &zcu.intern_pool;
    var ty = initial_ty;
    return type_key: switch (ip.indexToKey(ty)) {
        else => null,
        .array_type => |array_type| {
            ty = array_type.child;
            continue :type_key ip.indexToKey(ty);
        },
        .vector_type => switch (ZigType.fromInterned(ty).abiSize(zcu)) {
            else => null,
            8 => .vector64,
            16 => .vector128,
        },
        .simple_type => |simple_type| switch (simple_type) {
            .f16 => .half,
            .f32 => .single,
            .f64 => .double,
            .f128 => .quad,
            .c_longdouble => switch (zcu.getTarget().cTypeBitSize(.longdouble).?) {
                else => unreachable,
                64 => .double,
                80 => null,
                128 => .quad,
            },
            else => null,
        },
        .struct_type => homogeneousStructBaseType(zcu, &ip.loadStructType(ty)),
        .tuple_type => |tuple_type| homogeneousTupleBaseType(zcu, tuple_type),
    };
}
pub fn homogeneousStructBaseType(zcu: *Zcu, loaded_struct: *const InternPool.LoadedStructType) ?FundamentalDataType {
    const ip = &zcu.intern_pool;
    var common_fdt: ?FundamentalDataType = null;
    for (0.., loaded_struct.field_types.get(ip)) |field_index, field_ty| {
        if (loaded_struct.field_is_comptime_bits.get(ip, field_index)) continue;
        if (loaded_struct.field_aligns.getOrNone(ip, field_index) != .none) return null;
        if (!ZigType.fromInterned(field_ty).hasRuntimeBits(zcu)) continue;
        const fdt = homogeneousAggregateBaseType(zcu, field_ty) orelse return null;
        if (common_fdt == null) common_fdt = fdt else if (fdt != common_fdt) return null;
    }
    return common_fdt;
}
pub fn homogeneousTupleBaseType(zcu: *Zcu, tuple_type: InternPool.Key.TupleType) ?FundamentalDataType {
    const ip = &zcu.intern_pool;
    var common_fdt: ?FundamentalDataType = null;
    for (tuple_type.values.get(ip), tuple_type.types.get(ip)) |field_val, field_ty| {
        if (field_val != .none) continue;
        const fdt = homogeneousAggregateBaseType(zcu, field_ty) orelse return null;
        if (common_fdt == null) common_fdt = fdt else if (fdt != common_fdt) return null;
    }
    return common_fdt;
}

pub const Spec = struct {
    offset: u64,
    size: u64,
};

pub fn stack(it: *CallAbiIterator, isel: *Select, wip_vi: Value.Index) void {
    // C.12
    it.nsaa = @intCast(wip_vi.alignment(isel).forward(it.nsaa));
    // C.16: composite slots are padded to a multiple of 8 bytes. Without packed
    // arguments, every alignment is at least 8, so this changes nothing.
    defer if (!it.stack_natural) {
        it.nsaa = std.mem.alignForward(u24, it.nsaa, 8);
    };
    const parent_vi = switch (wip_vi.parent(isel)) {
        .unallocated, .stack_slot => wip_vi,
        .address, .constant, .stack_address => unreachable,
        .value => |parent_vi| parent_vi,
    };
    switch (parent_vi.parent(isel)) {
        .unallocated => parent_vi.setParent(isel, .{ .stack_slot = .{
            .base = .sp,
            .offset = it.nsaa,
        } }),
        .stack_slot => {},
        .address, .value, .constant, .stack_address => unreachable,
    }
    it.nsaa += @intCast(wip_vi.size(isel));
}

pub fn integer(it: *CallAbiIterator, isel: *Select, wip_vi: Value.Index) void {
    assert(wip_vi.size(isel) <= 8);
    const natural_alignment = wip_vi.alignment(isel);
    assert(natural_alignment.order(.@"16").compare(.lte));
    wip_vi.setAlignment(isel, natural_alignment.maxStrict(.@"8"));
    if (it.ngrn == ngrn_end) {
        if (it.stack_natural) wip_vi.setAlignment(isel, natural_alignment);
        return it.stack(isel, wip_vi);
    }
    wip_vi.setHint(isel, it.ngrn);
    it.ngrn = @fromBackingInt(@intCast(@backingInt(it.ngrn) + 1));
}

pub fn integers(it: *CallAbiIterator, isel: *Select, wip_vi: Value.Index, part_sizes: [2]u64) void {
    assert(wip_vi.size(isel) <= 16);
    const natural_alignment = wip_vi.alignment(isel);
    assert(natural_alignment.order(.@"16").compare(.lte));
    wip_vi.setAlignment(isel, natural_alignment.maxStrict(.@"8"));
    // C.10, which Apple arm64 omits
    if (natural_alignment == .@"16" and !isel.target.os.tag.isDarwin()) it.ngrn = @fromBackingInt(@intCast(std.mem.alignForward(
        @typeInfo(Register.Alias).@"enum".tag_type,
        @backingInt(it.ngrn),
        2,
    )));
    // C.11-C.15: a two-register argument must fit entirely in the remaining
    // general-purpose registers. Otherwise, pass the whole value on the stack.
    if (@backingInt(ngrn_end) - @backingInt(it.ngrn) < part_sizes.len) {
        it.ngrn = ngrn_end;
        return it.stack(isel, wip_vi);
    }
    wip_vi.setParts(isel, part_sizes.len);
    for (0.., part_sizes) |part_index, part_size|
        it.integer(isel, wip_vi.addPart(isel, 8 * part_index, part_size));
}

pub fn vector(it: *CallAbiIterator, isel: *Select, wip_vi: Value.Index) void {
    assert(wip_vi.size(isel) <= 16);
    const natural_alignment = wip_vi.alignment(isel);
    assert(natural_alignment.order(.@"16").compare(.lte));
    wip_vi.setAlignment(isel, natural_alignment.maxStrict(.@"8"));
    wip_vi.setIsVector(isel);
    if (it.nsrn == nsrn_end) {
        if (it.stack_natural) wip_vi.setAlignment(isel, natural_alignment);
        return it.stack(isel, wip_vi);
    }
    wip_vi.setHint(isel, it.nsrn);
    it.nsrn = @fromBackingInt(@intCast(@backingInt(it.nsrn) + 1));
}

pub fn vectors(
    it: *CallAbiIterator,
    isel: *Select,
    wip_vi: Value.Index,
    fdt: FundamentalDataType,
    parts_len: Value.PartsLen,
) void {
    const fdt_log2_size = fdt.log2Size();
    assert(wip_vi.size(isel) == @shlExact(@as(u9, parts_len), fdt_log2_size));
    const natural_alignment = wip_vi.alignment(isel);
    assert(natural_alignment.order(.@"16").compare(.lte));
    wip_vi.setAlignment(isel, natural_alignment.maxStrict(.@"8"));
    if (@backingInt(it.nsrn) > @backingInt(nsrn_end) - parts_len) {
        it.nsrn = nsrn_end;
        // Apple arm64 packs homogeneous aggregates at their natural alignment.
        if (isel.target.os.tag.isDarwin() and !it.var_arg) {
            it.stack_natural = true;
            wip_vi.setAlignment(isel, natural_alignment);
        }
        return it.stack(isel, wip_vi);
    }
    if (parts_len == 1) return it.vector(isel, wip_vi);
    wip_vi.setParts(isel, parts_len);
    const fdt_size = @as(u64, 1) << fdt_log2_size;
    for (0..parts_len) |part_index|
        it.vector(isel, wip_vi.addPart(isel, part_index << fdt_log2_size, fdt_size));
}

pub fn indirect(it: *CallAbiIterator, isel: *Select, wip_vi: Value.Index) void {
    const wip_address_vi = isel.initValue(.usize);
    wip_vi.setParent(isel, .{ .address = wip_address_vi });
    it.integer(isel, wip_address_vi);
}

const assert = std.debug.assert;
const CallAbiIterator = @This();
const codegen = @import("../../codegen.zig");
const InternPool = @import("../../InternPool.zig");
const Register = codegen.aarch64.encoding.Register;
const Select = @import("Select.zig");
const std = @import("std");
const Value = @import("Value.zig");
const Zcu = @import("../../Zcu.zig");
const ZigType = @import("../../Type.zig");
