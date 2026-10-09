prologue: []const Instruction,
body: []const Instruction,
epilogue: []const Instruction,
literals: []const u32,
debug_events: []const Debug,
nav_relocs: []const Reloc.Nav,
uav_relocs: []const Reloc.Uav,
lazy_relocs: []const Reloc.Lazy,
global_relocs: []const Reloc.Global,
literal_relocs: []const Reloc.Literal,

pub const Debug = struct {
    section: enum { body, prologue, epilogue },
    offset: u32,
    /// The position of the event in the order Select emitted it.
    seq: u32,
    info: union(enum) {
        line_column: struct { line: u32, column: u32 },
        enter_inline_func: InternPool.Index,
        leave_inline_func: InternPool.Index,
        prologue_end,
        epilogue_begin,
        cfi: union(enum) {
            def_cfa: struct { reg: u32, off: i64 },
            def_cfa_offset: i64,
            offset: struct { reg: u32, off: i64 },
            restore: u32,
            undefined: u32,
            remember_state,
            restore_state,
        },
    },

    /// Events at the same offset sort in program order: the prologue, which
    /// is emitted forwards, in emission order and before the rest; the body
    /// and epilogue, which are emitted backwards, in reverse.
    pub fn lessThan(_: void, lhs: Debug, rhs: Debug) bool {
        if (lhs.offset != rhs.offset) return lhs.offset < rhs.offset;
        return lhs.programOrder() < rhs.programOrder();
    }

    fn programOrder(debug: Debug) u32 {
        return switch (debug.section) {
            .prologue => debug.seq,
            .body, .epilogue => std.math.maxInt(u32) - debug.seq,
        };
    }
};

pub const Reloc = struct {
    label: u32,
    addend: u64 align(@alignOf(u32)) = 0,

    pub const Nav = struct {
        nav: InternPool.Nav.Index,
        reloc: Reloc,
        tls: bool = false,
    };

    pub const Uav = struct {
        uav: InternPool.Key.Ptr.BaseAddr.Uav,
        reloc: Reloc,
    };

    pub const Lazy = struct {
        symbol: link.File.LazySymbol,
        reloc: Reloc,
    };

    pub const Global = struct {
        name: [*:0]const u8,
        reloc: Reloc,
    };

    pub const Literal = struct {
        label: u32,
    };
};

pub fn deinit(mir: *Mir, gpa: std.mem.Allocator) void {
    assert(mir.body.ptr + mir.body.len == mir.prologue.ptr);
    assert(mir.prologue.ptr + mir.prologue.len == mir.epilogue.ptr);
    gpa.free(mir.body.ptr[0 .. mir.body.len + mir.prologue.len + mir.epilogue.len]);
    gpa.free(mir.literals);
    gpa.free(mir.debug_events);
    gpa.free(mir.nav_relocs);
    gpa.free(mir.uav_relocs);
    gpa.free(mir.lazy_relocs);
    gpa.free(mir.global_relocs);
    gpa.free(mir.literal_relocs);
    mir.* = undefined;
}

pub fn emit(
    mir: Mir,
    lf: *link.File,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    atom_index: link.File.AtomId,
    w: *std.Io.Writer,
    debug_output: link.File.DebugInfoOutput,
) link.EmitError!void {
    mir.emitInner(lf, pt, func_index, atom_index, w, debug_output) catch |err| switch (err) {
        error.OutOfMemory, error.AlreadyReported, error.Canceled, error.WriteFailed => |e| return e,
        else => return pt.zcu.codegenFail(pt.zcu.funcInfo(func_index).owner_nav, "emit MIR failed: {s}", .{@errorName(err)}),
    };
}

fn emitInner(
    mir: Mir,
    lf: *link.File,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    atom_index: link.File.AtomId,
    w: *std.Io.Writer,
    debug_output: link.File.DebugInfoOutput,
) !void {
    const zcu = pt.zcu;
    const ip = &zcu.intern_pool;
    const func = zcu.funcInfo(func_index);
    const nav = ip.getNav(func.owner_nav);
    const mod = zcu.navFileScope(func.owner_nav).mod.?;
    const target = &mod.resolved_target.result;
    mir_log.debug("{f}:", .{nav.fqn.fmt(ip)});

    const func_align = switch (nav.resolved.?.@"align") {
        .none => switch (mod.optimize_mode) {
            .debug, .safe, .fast => target_util.defaultFunctionAlignment(target),
            .small => target_util.minFunctionAlignment(target),
        },
        else => |a| a.maxStrict(target_util.minFunctionAlignment(target)),
    };
    const code_len = mir.prologue.len + mir.body.len + mir.epilogue.len;
    const literals_align_gap = -%code_len & (@divExact(
        @as(u5, @intCast(func_align.minStrict(.@"16").toByteUnits().?)),
        Instruction.size,
    ) - 1);
    try w.rebase(w.end, Instruction.size * (code_len + literals_align_gap + mir.literals.len));
    emitInstructionsForward(w, mir.prologue) catch unreachable;
    emitInstructionsBackward(w, mir.body) catch unreachable;
    const body_end: u32 = @intCast(w.end);
    emitInstructionsBackward(w, mir.epilogue) catch unreachable;
    w.splatByteAll(0, Instruction.size * literals_align_gap) catch unreachable;
    w.writeAll(@ptrCast(mir.literals)) catch unreachable;
    mir_log.debug("", .{});

    var prev_line = func.lbrace_line;
    var prev_column = func.lbrace_column;
    var prev_pc: u32 = 0;
    for (mir.debug_events) |event| switch (event.info) {
        .line_column => |lc| switch (debug_output) {
            inline .dwarf, .dwarf2 => |dw| {
                if (lc.column != prev_column) try dw.setColumn(lc.column);
                try dw.advanceLineAndPc(@as(i33, lc.line) - prev_line, event.offset - prev_pc, false);
                prev_line = lc.line;
                prev_column = lc.column;
                prev_pc = event.offset;
            },
            .eh_frame, .none => {},
        },
        .enter_inline_func => |inline_func| switch (debug_output) {
            inline .dwarf, .dwarf2 => |dw| try dw.enterInlineFunc(inline_func, event.offset, prev_line, prev_column),
            .eh_frame, .none => {},
        },
        .leave_inline_func => |parent_func| switch (debug_output) {
            inline .dwarf, .dwarf2 => |dw| try dw.leaveInlineFunc(parent_func, event.offset),
            .eh_frame, .none => {},
        },
        .prologue_end, .epilogue_begin => switch (debug_output) {
            inline .dwarf, .dwarf2 => |dw| {
                if (event.info == .prologue_end) try dw.setPrologueEnd() else try dw.setEpilogueBegin();
                try dw.advanceLineAndPc(0, event.offset - prev_pc, false);
                prev_pc = event.offset;
            },
            .eh_frame, .none => {},
        },
        .cfi => |cfi| switch (debug_output) {
            inline .dwarf, .dwarf2, .eh_frame => |dw| switch (cfi) {
                .def_cfa => |rule| try dw.genDebugFrame(event.offset, .{ .def_cfa = .{ .reg = rule.reg, .off = rule.off } }),
                .def_cfa_offset => |off| try dw.genDebugFrame(event.offset, .{ .def_cfa_offset = off }),
                .offset => |rule| try dw.genDebugFrame(event.offset, .{ .offset = .{ .reg = rule.reg, .off = rule.off } }),
                .restore => |reg| try dw.genDebugFrame(event.offset, .{ .restore = reg }),
                .undefined => |reg| try dw.genDebugFrame(event.offset, .{ .undefined = reg }),
                .remember_state => try dw.genDebugFrame(event.offset, .remember_state),
                .restore_state => try dw.genDebugFrame(event.offset, .restore_state),
            },
            .none => {},
        },
    };
    switch (debug_output) {
        inline .dwarf, .dwarf2 => |dw| try dw.advanceLineAndPc(
            0,
            Instruction.size * code_len - prev_pc,
            true,
        ),
        .eh_frame, .none => {},
    }

    for (mir.nav_relocs) |nav_reloc| {
        const reloc_nav = ip.getNav(nav_reloc.nav);
        if (nav_reloc.tls) {
            try emitTlsReloc(
                lf,
                zcu,
                atom_index,
                try lf.navSymbol(nav_reloc.nav),
                mir.body[nav_reloc.reloc.label],
                body_end - Instruction.size * (1 + nav_reloc.reloc.label),
                nav_reloc.reloc.addend,
                reloc_nav.getExtern(ip) != null,
            );
            continue;
        }
        try emitReloc(
            lf,
            zcu,
            atom_index,
            try lf.navSymbol(nav_reloc.nav),
            mir.body[nav_reloc.reloc.label],
            body_end - Instruction.size * (1 + nav_reloc.reloc.label),
            nav_reloc.reloc.addend,
            if (ip.getNav(nav_reloc.nav).getExtern(ip)) |_| .got_load else .direct,
        );
    }
    for (mir.uav_relocs) |uav_reloc| try emitReloc(
        lf,
        zcu,
        atom_index,
        try lf.uavSymbol(
            pt,
            uav_reloc.uav.val,
            ZigType.fromInterned(uav_reloc.uav.orig_ty).ptrAlignment(zcu),
        ),
        mir.body[uav_reloc.reloc.label],
        body_end - Instruction.size * (1 + uav_reloc.reloc.label),
        uav_reloc.reloc.addend,
        .direct,
    );
    for (mir.lazy_relocs) |lazy_reloc| try emitReloc(
        lf,
        zcu,
        atom_index,
        if (lf.cast(.elf)) |ef|
            @fromBackingInt(@intCast(ef.zigObjectPtr().?.getOrCreateMetadataForLazySymbol(ef, pt, lazy_reloc.symbol) catch |err|
                return zcu.codegenFail(func.owner_nav, "{s} creating lazy symbol", .{@errorName(err)})))
        else if (lf.cast(.macho)) |mf|
            @fromBackingInt(@intCast(mf.getZigObject().?.getOrCreateMetadataForLazySymbol(mf, pt, lazy_reloc.symbol) catch |err|
                return zcu.codegenFail(func.owner_nav, "{s} creating lazy symbol", .{@errorName(err)})))
        else
            return zcu.codegenFail(func.owner_nav, "external symbols unimplemented for {t}", .{lf.tag}),
        mir.body[lazy_reloc.reloc.label],
        body_end - Instruction.size * (1 + lazy_reloc.reloc.label),
        lazy_reloc.reloc.addend,
        .direct,
    );
    for (mir.global_relocs) |global_reloc| try emitReloc(
        lf,
        zcu,
        atom_index,
        if (lf.cast(.elf)) |ef|
            @fromBackingInt(@intCast(try ef.getGlobalSymbol(std.mem.span(global_reloc.name), null)))
        else if (lf.cast(.macho)) |mf|
            @fromBackingInt(@intCast(try mf.getGlobalSymbol(std.mem.span(global_reloc.name), null)))
        else
            return zcu.codegenFail(func.owner_nav, "external symbols unimplemented for {t}", .{lf.tag}),
        mir.body[global_reloc.reloc.label],
        body_end - Instruction.size * (1 + global_reloc.reloc.label),
        global_reloc.reloc.addend,
        .direct,
    );
    const literal_reloc_offset: i19 = @intCast(mir.epilogue.len + literals_align_gap);
    for (mir.literal_relocs) |literal_reloc| {
        var instruction = mir.body[literal_reloc.label];
        instruction.load_store.register_literal.group.imm19 += literal_reloc_offset;
        instruction.write(
            w.buffered()[body_end - Instruction.size * (1 + literal_reloc.label) ..][0..Instruction.size],
        );
    }
}

fn emitInstructionsForward(w: *std.Io.Writer, instructions: []const Instruction) !void {
    for (instructions) |instruction| try emitInstruction(w, instruction);
}
fn emitInstructionsBackward(w: *std.Io.Writer, instructions: []const Instruction) !void {
    var instruction_index = instructions.len;
    while (instruction_index > 0) {
        instruction_index -= 1;
        try emitInstruction(w, instructions[instruction_index]);
    }
}
fn emitInstruction(w: *std.Io.Writer, instruction: Instruction) !void {
    mir_log.debug("    {f}", .{instruction});
    instruction.write(try w.writableArray(Instruction.size));
}

fn emitTlsReloc(
    lf: *link.File,
    zcu: *Zcu,
    atom_index: link.File.AtomId,
    sym_index: link.File.SymbolId,
    instruction: Instruction,
    offset: u32,
    addend: u64,
    imported: bool,
) !void {
    if (lf.cast(.macho)) |mf| {
        // Select emits `adrp`/`ldr` pairs addressing the variable's descriptor.
        const zo = mf.getZigObject().?;
        const atom = zo.symbols.items[@backingInt(atom_index)].getAtom(mf).?;
        const pcrel = switch (instruction.decode()) {
            .data_processing_immediate => true,
            .load_store => false,
            else => unreachable,
        };
        return atom.addReloc(mf, .{
            .tag = .@"extern",
            .offset = offset,
            .target = @backingInt(sym_index),
            .addend = @bitCast(addend),
            .type = if (pcrel) .tlvp_page else .tlvp_pageoff,
            .meta = .{
                .pcrel = pcrel,
                .has_subtractor = false,
                .length = 2,
                .symbolnum = @intCast(@backingInt(sym_index)),
            },
        });
    }
    // Select rejects TLS models that this ELF-only lowering cannot represent.
    const ef = lf.cast(.elf).?;
    const zo = ef.zigObjectPtr().?;
    const atom = zo.symbol(@backingInt(atom_index)).atom(ef).?;
    const r_type: std.elf.R_AARCH64 = switch (instruction.decode()) {
        .data_processing_immediate => |decoded| switch (decoded.decode()) {
            .pc_relative_addressing => |pc_relative| tls: {
                assert(imported and pc_relative.group.op == .adrp);
                break :tls .TLSIE_ADR_GOTTPREL_PAGE21;
            },
            .add_subtract_immediate => |add| tls: {
                assert(!imported and add.group.op == .add);
                break :tls switch (add.group.sh) {
                    .@"0" => .TLSLE_ADD_TPREL_LO12_NC,
                    .@"12" => .TLSLE_ADD_TPREL_HI12,
                };
            },
            else => unreachable,
        },
        .load_store => tls: {
            assert(imported);
            break :tls .TLSIE_LD64_GOTTPREL_LO12_NC;
        },
        else => unreachable,
    };
    try atom.addReloc(zcu.gpa, .{
        .r_offset = offset,
        .r_info = @as(u64, @backingInt(sym_index)) << 32 | @backingInt(r_type),
        .r_addend = @bitCast(addend),
    }, zo);
}

fn emitReloc(
    lf: *link.File,
    zcu: *Zcu,
    atom_index: link.File.AtomId,
    sym_index: link.File.SymbolId,
    instruction: Instruction,
    offset: u32,
    addend: u64,
    kind: enum { direct, got_load },
) !void {
    const gpa = zcu.gpa;
    switch (instruction.decode()) {
        else => unreachable,
        .data_processing_immediate => |decoded| if (lf.cast(.elf)) |ef| {
            const zo = ef.zigObjectPtr().?;
            const atom = zo.symbol(@backingInt(atom_index)).atom(ef).?;
            const r_type: std.elf.R_AARCH64 = switch (decoded.decode()) {
                else => unreachable,
                .pc_relative_addressing => |pc_relative_addressing| switch (pc_relative_addressing.group.op) {
                    .adr => switch (kind) {
                        .direct => .ADR_PREL_LO21,
                        .got_load => unreachable,
                    },
                    .adrp => switch (kind) {
                        .direct => .ADR_PREL_PG_HI21,
                        .got_load => .ADR_GOT_PAGE,
                    },
                },
                .add_subtract_immediate => |add_subtract_immediate| switch (add_subtract_immediate.group.op) {
                    .add => switch (kind) {
                        .direct => .ADD_ABS_LO12_NC,
                        .got_load => unreachable,
                    },
                    .sub => unreachable,
                },
            };
            try atom.addReloc(gpa, .{
                .r_offset = offset,
                .r_info = @as(u64, @backingInt(sym_index)) << 32 | @backingInt(r_type),
                .r_addend = @bitCast(addend),
            }, zo);
        } else if (lf.cast(.macho)) |mf| {
            const zo = mf.getZigObject().?;
            const atom = zo.symbols.items[@backingInt(atom_index)].getAtom(mf).?;
            switch (decoded.decode()) {
                else => unreachable,
                .pc_relative_addressing => |pc_relative_addressing| switch (pc_relative_addressing.group.op) {
                    .adr => unreachable,
                    .adrp => try atom.addReloc(mf, .{
                        .tag = .@"extern",
                        .offset = offset,
                        .target = @backingInt(sym_index),
                        .addend = @bitCast(addend),
                        .type = switch (kind) {
                            .direct => .page,
                            .got_load => .got_load_page,
                        },
                        .meta = .{
                            .pcrel = true,
                            .has_subtractor = false,
                            .length = 2,
                            .symbolnum = @intCast(@backingInt(sym_index)),
                        },
                    }),
                },
                .add_subtract_immediate => |add_subtract_immediate| switch (add_subtract_immediate.group.op) {
                    .add => try atom.addReloc(mf, .{
                        .tag = .@"extern",
                        .offset = offset,
                        .target = @backingInt(sym_index),
                        .addend = @bitCast(addend),
                        .type = switch (kind) {
                            .direct => .pageoff,
                            .got_load => .got_load_pageoff,
                        },
                        .meta = .{
                            .pcrel = false,
                            .has_subtractor = false,
                            .length = 2,
                            .symbolnum = @intCast(@backingInt(sym_index)),
                        },
                    }),
                    .sub => unreachable,
                },
            }
        },
        .branch_exception_generating_system => |decoded| if (lf.cast(.elf)) |ef| {
            const zo = ef.zigObjectPtr().?;
            const atom = zo.symbol(@backingInt(atom_index)).atom(ef).?;
            const r_type: std.elf.R_AARCH64 = switch (decoded.decode().unconditional_branch_immediate.group.op) {
                .b => .JUMP26,
                .bl => .CALL26,
            };
            try atom.addReloc(gpa, .{
                .r_offset = offset,
                .r_info = @as(u64, @backingInt(sym_index)) << 32 | @backingInt(r_type),
                .r_addend = @bitCast(addend),
            }, zo);
        } else if (lf.cast(.macho)) |mf| {
            const zo = mf.getZigObject().?;
            const atom = zo.symbols.items[@backingInt(atom_index)].getAtom(mf).?;
            try atom.addReloc(mf, .{
                .tag = .@"extern",
                .offset = offset,
                .target = @backingInt(sym_index),
                .addend = @bitCast(addend),
                .type = .branch,
                .meta = .{
                    .pcrel = true,
                    .has_subtractor = false,
                    .length = 2,
                    .symbolnum = @intCast(@backingInt(sym_index)),
                },
            });
        },
        .load_store => |decoded| if (lf.cast(.elf)) |ef| {
            const zo = ef.zigObjectPtr().?;
            const atom = zo.symbol(@backingInt(atom_index)).atom(ef).?;
            const r_type: std.elf.R_AARCH64 = switch (decoded.decode().register_unsigned_immediate.decode()) {
                .integer => |integer| switch (integer.decode()) {
                    .unallocated, .prfm => unreachable,
                    .strb, .ldrb, .ldrsb => switch (kind) {
                        .direct => .LDST8_ABS_LO12_NC,
                        .got_load => unreachable,
                    },
                    .strh, .ldrh, .ldrsh => switch (kind) {
                        .direct => .LDST16_ABS_LO12_NC,
                        .got_load => unreachable,
                    },
                    .ldrsw => switch (kind) {
                        .direct => .LDST32_ABS_LO12_NC,
                        .got_load => unreachable,
                    },
                    inline .str, .ldr => |encoded, mnemonic| switch (encoded.sf) {
                        .word => .LDST32_ABS_LO12_NC,
                        .doubleword => switch (kind) {
                            .direct => .LDST64_ABS_LO12_NC,
                            .got_load => switch (mnemonic) {
                                else => comptime unreachable,
                                .str => unreachable,
                                .ldr => .LD64_GOT_LO12_NC,
                            },
                        },
                    },
                },
                .vector => |vector| switch (kind) {
                    .direct => switch (vector.group.opc1.decode(vector.group.size)) {
                        .byte => .LDST8_ABS_LO12_NC,
                        .half => .LDST16_ABS_LO12_NC,
                        .single => .LDST32_ABS_LO12_NC,
                        .double => .LDST64_ABS_LO12_NC,
                        .quad => .LDST128_ABS_LO12_NC,
                    },
                    .got_load => unreachable,
                },
            };
            try atom.addReloc(gpa, .{
                .r_offset = offset,
                .r_info = @as(u64, @backingInt(sym_index)) << 32 | @backingInt(r_type),
                .r_addend = @bitCast(addend),
            }, zo);
        } else if (lf.cast(.macho)) |mf| {
            const zo = mf.getZigObject().?;
            const atom = zo.symbols.items[@backingInt(atom_index)].getAtom(mf).?;
            try atom.addReloc(mf, .{
                .tag = .@"extern",
                .offset = offset,
                .target = @backingInt(sym_index),
                .addend = @bitCast(addend),
                .type = switch (kind) {
                    .direct => .pageoff,
                    .got_load => .got_load_pageoff,
                },
                .meta = .{
                    .pcrel = false,
                    .has_subtractor = false,
                    .length = 2,
                    .symbolnum = @intCast(@backingInt(sym_index)),
                },
            });
        },
    }
}

const Air = @import("../../Air.zig");
const assert = std.debug.assert;
const mir_log = std.log.scoped(.mir);
const Instruction = @import("encoding.zig").Instruction;
const InternPool = @import("../../InternPool.zig");
const link = @import("../../link.zig");
const Mir = @This();
const std = @import("std");
const target_util = @import("../../target.zig");
const Zcu = @import("../../Zcu.zig");
const ZigType = @import("../../Type.zig");
