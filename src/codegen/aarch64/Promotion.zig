//! Promotion of values to callee-saved registers.
//!
//! An `alloc` of a scalar whose pointer is only the operand of whole-value
//! loads and stores (its address never escapes) can live in a register for
//! the whole function: a load reads the register and a store writes it. A
//! value defined outside a loop and used in it can likewise keep a register
//! of its own instead of being reloaded at every loop head. These registers
//! are reserved, so they need no merging at blocks and loops, and calls
//! preserve them.
//!
//! `Select.analyze` fills the tables and `promoteLocals`, called by
//! `Select.finishAnalysis`, assigns the registers; selection only reads the
//! result.

/// Promotable locals.
locals: std.array_hash_map.Auto(Air.Inst.Index, Local) = .empty,
/// Loads of promotable locals.
local_loads: std.AutoHashMapUnmanaged(Air.Inst.Index, LocalLoad) = .empty,
/// Values defined outside a loop and used in it.
pinned_values: std.array_hash_map.Auto(Air.Inst.Index, PinnedValue) = .empty,
/// Same-size integer bit casts and the instruction whose value each one
/// shares.
casts: std.AutoHashMapUnmanaged(Air.Inst.Index, Air.Inst.Index) = .empty,
/// Registers that inline assembly names or clobbers: never promotion's.
asm_registers: std.enums.EnumSet(Register.Alias) = .empty,

/// `finishAnalysis` was asked to promote: registers may be reserved for
/// promoted locals and pinned values, and running out of the rest is
/// `error.RetryWithoutPromotion`.
enabled: bool = false,
/// Registers assigned to promoted locals and pinned values.
pinned: std.enums.EnumSet(Register.Alias) = .empty,
/// Registers assigned to pinned values.
pinned_value_regs: std.enums.EnumSet(Register.Alias) = .empty,

pub const Local = struct {
    /// Uses weighted by loop depth.
    weight: u32,
    /// Stores so far, in the order of analysis.
    epoch: u32,
    escaped: bool,
    /// Some load or store of it is in a loop.
    in_loop: bool,
    is_vector: bool,
    /// Its register, or `.zr` when it is not promoted.
    ra: Register.Alias,
};
pub const LocalLoad = struct {
    local: u32,
    /// The local's `epoch` at the load.
    epoch: u32,
    /// No store to the local can happen between the load and a use of
    /// its result, so the result may stay in the local's register.
    aliasable: bool,
};
pub const PinnedValue = struct {
    /// Uses weighted by loop depth, or `maxInt` for a value that never
    /// gets a register.
    weight: u32,
    is_vector: bool,
    /// A slice: two 8-byte parts, the second in `ra2`.
    pair: bool,
    /// Its register, or `.zr` when it gets none.
    ra: Register.Alias,
    ra2: Register.Alias,
};

/// The callee-saved registers that promotion takes, highest first so
/// that the low ones stay available to the allocator: x21-x28, leaving
/// x19 and x20, and v8-v15, whose low 64 bits that a promoted scalar
/// uses are callee-saved.
const int_regs: std.enums.EnumSet(Register.Alias) = .initMany(&.{ .r21, .r22, .r23, .r24, .r25, .r26, .r27, .r28 });
const vec_regs: std.enums.EnumSet(Register.Alias) = .initMany(&.{ .v8, .v9, .v10, .v11, .v12, .v13, .v14, .v15 });

/// At most 16 candidates get a register; the rest of the 64 kept are for
/// those that `promoteLocals` turns down because of their parts.
const max_candidates = 64;

/// A use's weight grows by 4 per enclosing loop, and is the same beyond 6
/// loops, where the sum of a candidate's uses would soon saturate.
pub fn useWeight(loop_depth: usize) u32 {
    const depth: u5 = @intCast(@min(loop_depth, 6));
    return @as(u32, 1) << (2 * depth);
}

pub fn deinit(promotion: *Promotion, gpa: std.mem.Allocator) void {
    promotion.locals.deinit(gpa);
    promotion.local_loads.deinit(gpa);
    promotion.pinned_values.deinit(gpa);
    promotion.casts.deinit(gpa);
}

fn highestRegister(regs: std.enums.EnumSet(Register.Alias)) ?Register.Alias {
    var highest: ?Register.Alias = null;
    var it = regs.iterator();
    while (it.next()) |ra| highest = ra;
    return highest;
}

/// Assigns registers to the most used promotable locals.
pub fn promoteLocals(isel: *Select) void {
    const promotion = &isel.promotion;
    const locals = promotion.locals.values();
    const pinned_values = promotion.pinned_values.values();
    // Candidates by descending weight, keeping the heaviest: an index into
    // `locals`, or `locals.len` plus an index into `pinned_values`.
    var order_buf: [max_candidates]struct { index: u32, weight: u32 } = undefined;
    var order_len: usize = 0;
    for (0..locals.len + pinned_values.len) |index| {
        const weight = if (index < locals.len) weight: {
            const local = locals[index];
            if (local.escaped or !local.in_loop) continue;
            break :weight local.weight;
        } else weight: {
            const pinned_value = pinned_values[index - locals.len];
            if (pinned_value.weight == std.math.maxInt(u32)) continue;
            break :weight pinned_value.weight;
        };
        var pos = order_len;
        while (pos > 0 and order_buf[pos - 1].weight < weight) pos -= 1;
        if (pos == order_buf.len) continue;
        if (order_len < order_buf.len) order_len += 1;
        std.mem.copyBackwards(@TypeOf(order_buf[0]), order_buf[pos + 1 .. order_len], order_buf[pos .. order_len - 1]);
        order_buf[pos] = .{ .index = @intCast(index), .weight = weight };
    }
    var available_int_regs = int_regs.differenceWith(promotion.asm_registers);
    var available_vec_regs = vec_regs.differenceWith(promotion.asm_registers);
    for (order_buf[0..order_len]) |candidate| {
        const is_vector, const ra_ptr = if (candidate.index < locals.len) .{
            locals[candidate.index].is_vector, &locals[candidate.index].ra,
        } else .{
            pinned_values[candidate.index - locals.len].is_vector, &pinned_values[candidate.index - locals.len].ra,
        };
        const pair = candidate.index >= locals.len and pinned_values[candidate.index - locals.len].pair;
        const regs = if (is_vector) &available_vec_regs else &available_int_regs;
        const ra = highestRegister(regs.*) orelse continue;
        const ra2: Register.Alias = if (pair) ra2: {
            var rest = regs.*;
            rest.remove(ra);
            break :ra2 highestRegister(rest) orelse continue;
        } else .zr;
        if (candidate.index >= locals.len) {
            // A pinned_value created during analysis already has its parts.
            const inst = promotion.pinned_values.keys()[candidate.index - locals.len];
            if (isel.live_values.get(inst)) |vi| {
                if (vi.parent(isel) != .unallocated) continue;
                var part_it = vi.parts(isel);
                if (pair) {
                    if (part_it.only() != null) continue;
                    if (part_it.remaining != 2) continue;
                    const part0 = part_it.next().?;
                    const part1 = part_it.next().?;
                    if (part0.position(isel)[1] != 8 or part1.position(isel)[0] != 8 or
                        part1.position(isel)[1] != 8 or part0.isVector(isel) or part1.isVector(isel)) continue;
                    part0.setPin(isel, ra);
                    part1.setPin(isel, ra2);
                } else {
                    if (part_it.only() == null or vi.location(isel) != .small or
                        vi.isVector(isel) != is_vector) continue;
                    vi.setPin(isel, ra);
                }
            }
            promotion.pinned_value_regs.insert(ra);
            if (pair) {
                pinned_values[candidate.index - locals.len].ra2 = ra2;
                promotion.pinned_value_regs.insert(ra2);
                promotion.pinned.insert(ra2);
                isel.saved_registers.insert(ra2);
                regs.remove(ra2);
            }
        }
        regs.remove(ra);
        ra_ptr.* = ra;
        promotion.pinned.insert(ra);
        isel.saved_registers.insert(ra);
    }
}

const Air = @import("../../Air.zig");
const codegen = @import("../../codegen.zig");
const Promotion = @This();
const Register = codegen.aarch64.encoding.Register;
const Select = @import("Select.zig");
const std = @import("std");
