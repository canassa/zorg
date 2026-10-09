//! Automatic inlining of direct calls: an AIR-to-AIR pass that runs on a function after semantic
//! analysis and before its codegen task starts (see `Zcu.PerThread.inlineCalls`).
//!
//! An inlined call becomes a `dbg_inline_block` holding a copy of the callee's AIR, the shape Sema
//! produces for a call to an `inline fn`: the callee's `arg`s are the call's operands, its returns
//! break out of the block, and its result pointer is a local. AIR has already made every semantic
//! decision (defers, safety checks, generic instances), so the copy means what the call meant.
//!
//! The callee's AIR comes from a `Cached` entry: a compact copy of the function's AIR after this pass
//! ran on it, taken before the function's own codegen consumes its AIR. Analyzing callees before
//! their callers makes those copies post-inlining, which inlines nested calls.

pub const Error = Allocator.Error;

/// The threshold of `Mode` in optimized builds, unless `--debug-auto-inline` overrides it.
pub const default_threshold = 12;

/// The `--debug-auto-inline` setting, which overrides whether and how the pass runs. The pass
/// still only runs for backends that want it (`codegen.wantsInlining`).
pub const Override = union(enum) {
    off,
    /// Run in this mode in every optimization mode, Debug included.
    on: Mode,

    pub fn parse(arg: []const u8) ?Override {
        if (std.mem.eql(u8, arg, "off")) return .off;
        if (std.mem.eql(u8, arg, "all")) return .{ .on = .all };
        const threshold = std.fmt.parseInt(u32, arg, 10) catch return null;
        return .{ .on = .{ .threshold = threshold } };
    }
};

/// How the pass decides which calls to inline. Turning it off is the caller's job.
pub const Mode = union(enum) {
    /// Inline a callee at a call site when its cost is at most this (`loop_factor` times this in
    /// a loop), outside cold code, within the caller's growth budget.
    threshold: u32,
    /// Inline every call whose callee is eligible, whatever its cost and wherever the call is.
    /// Only callees of cost up to `all_limit` are cached. For testing the pass.
    all,

    /// A call site inside a loop accepts callees this many times as costly.
    pub const loop_factor = 3;
    /// The cost limit of a cached callee in `.all` mode, which bounds the size of nested copies.
    pub const all_limit = 1000;
    /// Every caller may grow by at least this much cost.
    pub const min_budget = 64;

    /// The most costly function that a call site may inline.
    pub fn cacheLimit(mode: Mode) u32 {
        return switch (mode) {
            .threshold => |threshold| threshold *| loop_factor,
            .all => all_limit,
        };
    }
};

/// A compact copy of the AIR of a function that may be inlined. It is immutable once created.
pub const Cached = struct {
    /// The function this is the AIR of. Never a coerced function.
    func: InternPool.Index,
    /// The function's main body and every instruction reachable from it, renumbered in body order.
    /// It still has the function's `arg`s and returns, which inlining rewrites.
    air: Air,
    /// One entry for each `arg` at the start of the main body, in order.
    params: []const Param,
    /// The type of the function's `ret_ptr` instructions, or `.none` if it has none.
    ret_ptr_ty: InternPool.Index,
    /// The module whose code generation options the copy was analyzed with.
    module: *const Module,
    /// The function's `@disableInstrumentation` and `@disableIntrinsics` state, which code
    /// generation of the caller would otherwise apply to the copy.
    disable_instrumentation: bool,
    disable_intrinsics: bool,
    /// The function has a `.cold` branch hint.
    cold: bool,
    /// The size estimate the heuristic compares with `Mode.threshold`. See `bodyCost`.
    cost: u32,
    /// Changes whenever the AIR changes. Incremental compilation compares it to decide whether
    /// the callers that inlined this function must be analyzed again.
    hash: u64,

    pub const Param = struct {
        /// The runtime parameter, i.e. the call operand, that the `arg` receives.
        index: u32,
        /// The parameter's name, a string in `air.extra`, for its `dbg_arg_inline`.
        name: Air.NullTerminatedString,
    };

    pub fn destroy(cached: *Cached, gpa: Allocator) void {
        cached.air.deinit(gpa);
        gpa.free(cached.params);
        gpa.destroy(cached);
    }

    fn mainBody(cached: *const Cached) []const Air.Inst.Index {
        return cached.air.getMainBody();
    }
};

/// Why a function was or was not cached. Reported by `--debug-inline-stats`.
pub const Verdict = union(enum) {
    cached,
    /// More costly than `Mode.cacheLimit`.
    too_costly,
    /// Not called with the `auto` calling convention, or variadic.
    calling_convention,
    @"noinline",
    @"export",
    noreturn,
    /// The AIR has an instruction whose meaning depends on being in this function, such as
    /// `ret_addr`.
    instruction: Air.Inst.Tag,
    /// The `arg`s of the AIR do not match the function's parameters.
    params,
};

/// Counters for `--debug-inline-stats`, keyed by callee.
pub const Stats = struct {
    funcs: std.array_hash_map.Auto(InternPool.Index, Func) = .empty,

    pub const Func = struct {
        verdict: ?Verdict = null,
        cost: u32 = 0,
        /// Direct call sites that reached the heuristic.
        sites: u32 = 0,
        inlined: u32 = 0,
        /// Sites not inlined because the callee had no cache entry when the caller was analyzed.
        uncached: u32 = 0,
        /// Sites in cold code, or calls to a cold function.
        cold: u32 = 0,
        /// Sites whose limit (`Mode.threshold`, larger in a loop) the callee exceeds.
        too_costly: u32 = 0,
        /// Sites the caller's growth budget did not allow.
        budget: u32 = 0,
        /// Sites whose caller is compiled with different code generation options.
        incompatible: u32 = 0,
    };

    pub fn deinit(stats: *Stats, gpa: Allocator) void {
        stats.funcs.deinit(gpa);
    }

    fn get(stats: *Stats, gpa: Allocator, func: InternPool.Index) Error!*Func {
        const gop = try stats.funcs.getOrPut(gpa, func);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    pub fn print(stats: *const Stats, zcu: *Zcu, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const ip = &zcu.intern_pool;
        var totals: Func = .{};
        for (stats.funcs.keys(), stats.funcs.values()) |func, s| {
            try w.print("inline-stats: {f} verdict={s} cost={d} sites={d} inlined={d} uncached={d} cold={d} too_costly={d} budget={d} incompatible={d}\n", .{
                ip.getNav(zcu.funcInfo(func).owner_nav).fqn.fmt(ip),
                if (s.verdict) |verdict| switch (verdict) {
                    .instruction => |tag| @tagName(tag),
                    else => @tagName(verdict),
                } else "unanalyzed",
                s.cost,
                s.sites,
                s.inlined,
                s.uncached,
                s.cold,
                s.too_costly,
                s.budget,
                s.incompatible,
            });
            inline for (@typeInfo(Func).@"struct".field_names) |name| switch (@FieldType(Func, name)) {
                u32 => @field(totals, name) += @field(s, name),
                else => {},
            };
        }
        try w.print("inline-stats: total functions={d} sites={d} inlined={d} uncached={d} cold={d} too_costly={d} budget={d} incompatible={d}\n", .{
            stats.funcs.count(),
            totals.sites,
            totals.inlined,
            totals.uncached,
            totals.cold,
            totals.too_costly,
            totals.budget,
            totals.incompatible,
        });
    }
};

/// Makes the cache entry of `func`, whose final AIR is `air`, if a call may inline it in `mode`.
pub fn cache(
    pt: Zcu.PerThread,
    func: InternPool.Index,
    air: *const Air,
    mode: Mode,
    stats: ?*Stats,
) Error!?*Cached {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const func_info = zcu.funcInfo(func);
    const func_ty = zcu.typeToFunc(.fromInterned(func_info.ty)).?;
    const analysis = func_info.analysisUnordered(ip);

    const stat = if (stats) |s| try s.get(gpa, func) else null;
    const cost = bodyCost(air, air.getMainBody());
    if (stat) |s| s.cost = cost;
    const verdict: Verdict = verdict: {
        if (func_ty.cc != .auto or func_ty.is_var_args) break :verdict .calling_convention;
        if (func_ty.is_noinline or analysis.is_noinline) break :verdict .@"noinline";
        if (Type.fromInterned(func_ty.return_type).isNoReturn(zcu)) break :verdict .noreturn;
        if (isExported(zcu, func)) break :verdict .@"export";
        if (cost > mode.cacheLimit()) break :verdict .too_costly;
        break :verdict .cached;
    };
    if (verdict != .cached) {
        if (stat) |s| s.verdict = verdict;
        return null;
    }

    var compact: Air = .{ .instructions = .empty, .extra = .empty };
    var compact_owned = true;
    defer if (compact_owned) compact.deinit(gpa);
    {
        var instructions: std.MultiArrayList(Air.Inst) = .empty;
        defer compact.instructions = instructions.slice();
        // The reserved extra entries come first, as in every `Air`.
        try compact.extra.appendNTimes(gpa, 0, @typeInfo(Air.ExtraIndex).@"enum".field_names.len);
        var copier: Copier = try .init(gpa, zcu, air, &instructions, &compact.extra, .compact);
        defer copier.deinit();
        const main_block = copier.copyMainBody(air.getMainBody()) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.Unsupported => {
                if (stat) |s| s.verdict = .{ .instruction = copier.unsupported.? };
                return null;
            },
        };
        compact.extra.items[@backingInt(Air.ExtraIndex.main_block)] = main_block;
    }

    const params = paramsOf(pt, func, &compact) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Unsupported => {
            if (stat) |s| s.verdict = .params;
            return null;
        },
    };
    errdefer gpa.free(params);

    var ret_ptr_ty: InternPool.Index = .none;
    for (compact.instructions.items(.tag), compact.instructions.items(.data)) |tag, data| {
        if (tag == .ret_ptr) ret_ptr_ty = data.ty.toIntern();
    }

    const cached = try gpa.create(Cached);
    cached.* = .{
        .func = func,
        .air = compact,
        .params = params,
        .ret_ptr_ty = ret_ptr_ty,
        .module = zcu.navFileScope(func_info.owner_nav).mod.?,
        .disable_instrumentation = analysis.disable_instrumentation,
        .disable_intrinsics = analysis.disable_intrinsics,
        .cold = analysis.branch_hint == .cold,
        .cost = cost,
        .hash = hashAir(&compact),
    };
    compact_owned = false;
    if (stat) |s| s.verdict = .cached;
    return cached;
}

/// Whether `func` is an `export fn`. Exporting makes the symbol interposable, so a direct call
/// does not necessarily reach this body.
fn isExported(zcu: *Zcu, func: InternPool.Index) bool {
    const ip = &zcu.intern_pool;
    const func_info = zcu.funcInfo(func);
    const nav = if (func_info.generic_owner == .none)
        func_info.owner_nav
    else
        zcu.funcInfo(func_info.generic_owner).owner_nav;
    const analysis = ip.getNav(nav).analysis orelse return false;
    const zir = zcu.fileByIndex(analysis.zir_index.resolveFile(ip)).zir orelse return true;
    const decl_inst = analysis.zir_index.resolve(ip) orelse return true;
    return zir.getDeclaration(decl_inst).linkage == .@"export";
}

/// Matches the `arg`s at the start of the main body to the function's runtime parameters, the
/// way `Zcu.PerThread.analyzeFuncBodyInner` created them: a parameter whose type has one possible
/// value has no `arg`.
fn paramsOf(pt: Zcu.PerThread, func: InternPool.Index, compact: *Air) (Error || error{Unsupported})![]const Cached.Param {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const func_info = zcu.funcInfo(func);
    const func_ty = zcu.typeToFunc(.fromInterned(func_info.ty)).?;
    const decl_analysis = if (func_info.generic_owner == .none)
        ip.getNav(func_info.owner_nav).analysis.?
    else
        ip.getNav(zcu.funcInfo(func_info.generic_owner).owner_nav).analysis.?;
    const zir = zcu.fileByIndex(decl_analysis.zir_index.resolveFile(ip)).zir orelse return error.Unsupported;
    const fn_zir_inst = func_info.zirBodyInstUnordered(ip).resolve(ip) orelse return error.Unsupported;

    // The main body is indexed through `extra` because adding names grows it.
    const main_block = compact.extra.items[@backingInt(Air.ExtraIndex.main_block)];
    const main_body_len = compact.extra.items[main_block];
    const tags = compact.instructions.items(.tag);
    const datas = compact.instructions.items(.data);
    var params: std.ArrayList(Cached.Param) = .empty;
    errdefer params.deinit(gpa);

    var runtime_index: u32 = 0;
    for (zir.getParamBody(fn_zir_inst), 0..) |zir_param_inst, zir_param_index| {
        const zir_name = zir.getParamName(zir_param_inst) orelse break;
        if (func_info.comptime_args.len != 0 and func_info.comptime_args.get(ip)[zir_param_index] != .none) continue;
        if (runtime_index == func_ty.param_types.len) return error.Unsupported;
        const param_ty: Type = .fromInterned(func_ty.param_types.get(ip)[runtime_index]);
        defer runtime_index += 1;
        if (try param_ty.onePossibleValue(pt) != null) continue;

        if (params.items.len == main_body_len) return error.Unsupported;
        const arg_inst: Air.Inst.Index = @fromBackingInt(compact.extra.items[main_block + 1 + params.items.len]);
        if (tags[@backingInt(arg_inst)] != .arg) return error.Unsupported;
        const arg = datas[@backingInt(arg_inst)].arg;
        if (arg.zir_param_index != zir_param_index or arg.ty.toIntern() != param_ty.toIntern()) {
            return error.Unsupported;
        }
        const name: Air.NullTerminatedString = switch (zir_name) {
            .empty => .none,
            else => try appendString(gpa, &compact.extra, zir.nullTerminatedString(zir_name)),
        };
        try params.append(gpa, .{ .index = runtime_index, .name = name });
    }
    if (runtime_index != func_ty.param_types.len) return error.Unsupported;
    if (params.items.len < main_body_len and tags[compact.extra.items[main_block + 1 + params.items.len]] == .arg) {
        return error.Unsupported;
    }
    return params.toOwnedSlice(gpa);
}

/// The functions that `air` calls directly at a site that `run` in `mode` may inline, each once,
/// in the order of their first call. In `.threshold` mode that leaves out calls in cold code,
/// such as safety panics, which also keeps the analysis of a callee ahead of its callers away
/// from cycles through the panic handler.
pub fn directCallees(gpa: Allocator, ip: *const InternPool, air: *const Air, mode: Mode) Error![]InternPool.Index {
    var survey: Survey = .{ .air = air, .ip = ip };
    defer survey.sites.deinit(gpa);
    try survey.body(gpa, air.getMainBody(), .{ .in_loop = false, .cold = false });
    var callees: std.array_hash_map.Auto(InternPool.Index, void) = .empty;
    defer callees.deinit(gpa);
    for (survey.sites.items) |site| {
        switch (mode) {
            .all => {},
            .threshold => if (site.cold) continue,
        }
        try callees.put(gpa, air.instructions.items(.data)[@backingInt(site.inst)].pl_op.operand.toInterned().?, {});
    }
    return gpa.dupe(InternPool.Index, callees.keys());
}

/// Inlines calls in `air`, the AIR of `caller`. Appends each function it inlined to `inlined`,
/// once.
pub fn run(
    pt: Zcu.PerThread,
    caller: InternPool.Index,
    air: *Air,
    entries: *const std.array_hash_map.Auto(InternPool.Index, *Cached),
    mode: Mode,
    stats: ?*Stats,
    inlined: *std.ArrayList(InternPool.Index),
) Error!void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const caller_info = zcu.funcInfo(caller);
    const caller_analysis = caller_info.analysisUnordered(ip);
    const caller_module = zcu.navFileScope(caller_info.owner_nav).mod.?;
    // `@disableInstrumentation` only changes the code of instrumented modules.
    const instrumented = caller_module.fuzz or caller_module.sanitize_thread;

    var survey: Survey = .{ .air = air, .ip = ip };
    defer survey.sites.deinit(gpa);
    try survey.body(gpa, air.getMainBody(), .{ .in_loop = false, .cold = false });
    if (survey.sites.items.len == 0) return;

    var budget: u32 = @max(Mode.min_budget, bodyCost(air, air.getMainBody()));
    var chosen: std.ArrayList(struct { Air.Inst.Index, *const Cached }) = .empty;
    defer chosen.deinit(gpa);
    for (survey.sites.items) |site| {
        const callee = air.instructions.items(.data)[@backingInt(site.inst)].pl_op.operand.toInterned().?;
        // Recursion: the caller's own AIR is what is being rewritten.
        if (callee == caller) continue;
        const stat = if (stats) |s| try s.get(gpa, callee) else null;
        if (stat) |s| s.sites += 1;
        const cached = entries.get(callee) orelse {
            if (stat) |s| s.uncached += 1;
            continue;
        };
        if (!compatible(caller_module, cached.module) or
            (instrumented and caller_analysis.disable_instrumentation != cached.disable_instrumentation) or
            caller_analysis.disable_intrinsics != cached.disable_intrinsics)
        {
            if (stat) |s| s.incompatible += 1;
            continue;
        }
        switch (mode) {
            .all => {},
            .threshold => |threshold| {
                if (site.cold or cached.cold) {
                    if (stat) |s| s.cold += 1;
                    continue;
                }
                const limit = if (site.in_loop) threshold *| Mode.loop_factor else threshold;
                if (cached.cost > limit) {
                    if (stat) |s| s.too_costly += 1;
                    continue;
                }
                if (cached.cost > budget) {
                    if (stat) |s| s.budget += 1;
                    continue;
                }
                budget -= cached.cost;
            },
        }
        if (stat) |s| s.inlined += 1;
        try chosen.append(gpa, .{ site.inst, cached });
    }
    if (chosen.items.len == 0) return;

    var instructions = air.instructions.toMultiArrayList();
    defer air.instructions = instructions.slice();
    const strip = caller_module.strip;
    for (chosen.items) |choice| {
        const call_inst, const cached = choice;
        try inlineCall(gpa, zcu, &instructions, &air.extra, call_inst, cached, strip);
        for (inlined.items) |func| {
            if (func == cached.func) break;
        } else try inlined.append(gpa, cached.func);
    }
}

/// Whether code from `callee_module` may be generated as part of a function of `caller_module`:
/// they agree on every option that changes how a backend lowers AIR.
fn compatible(caller_module: *const Module, callee_module: *const Module) bool {
    if (caller_module == callee_module) return true;
    const caller_target = &caller_module.resolved_target.result;
    const callee_target = &callee_module.resolved_target.result;
    return caller_target.cpu.arch == callee_target.cpu.arch and
        caller_target.cpu.model == callee_target.cpu.model and
        caller_target.cpu.features.eql(callee_target.cpu.features) and
        caller_module.code_model == callee_module.code_model and
        caller_module.single_threaded == callee_module.single_threaded and
        caller_module.valgrind == callee_module.valgrind and
        caller_module.pic == callee_module.pic and
        caller_module.omit_frame_pointer == callee_module.omit_frame_pointer and
        caller_module.stack_check == callee_module.stack_check and
        caller_module.stack_protector == callee_module.stack_protector and
        caller_module.red_zone == callee_module.red_zone and
        caller_module.sanitize_thread == callee_module.sanitize_thread and
        caller_module.fuzz == callee_module.fuzz and
        caller_module.unwind_tables == callee_module.unwind_tables and
        caller_module.no_builtin == callee_module.no_builtin;
}

/// Replaces `call_inst`, a call of `cached.func`, with a block holding a copy of its AIR.
fn inlineCall(
    gpa: Allocator,
    zcu: *Zcu,
    instructions: *std.MultiArrayList(Air.Inst),
    extra: *std.ArrayList(u32),
    call_inst: Air.Inst.Index,
    cached: *const Cached,
    strip: bool,
) Error!void {
    const call_data = instructions.items(.data)[@backingInt(call_inst)].pl_op;
    const call_args_len = extra.items[call_data.payload];
    // Copied because copying the body grows `extra`.
    const call_args = try gpa.dupe(Air.Inst.Ref, @ptrCast(extra.items[call_data.payload + 1 ..][0..call_args_len]));
    defer gpa.free(call_args);
    // The callee is called directly with its own type.
    const result_ty = zcu.typeToFunc(.fromInterned(zcu.funcInfo(cached.func).ty)).?.return_type;

    var copier: Copier = try .init(gpa, zcu, &cached.air, instructions, extra, .{ .inline_call = .{
        .block = call_inst,
        .result_ty = .fromInterned(result_ty),
    } });
    defer copier.deinit();

    const body_start = copier.scratch.items.len;
    const ret_ptr: Air.Inst.Ref = if (cached.ret_ptr_ty != .none) ret_ptr: {
        const alloc = try copier.addInst(.{ .tag = .alloc, .data = .{ .ty = .fromInterned(cached.ret_ptr_ty) } });
        try copier.scratch.append(gpa, alloc);
        break :ret_ptr alloc.toRef();
    } else .none;
    copier.mode.inline_call.ret_ptr = ret_ptr;

    const main_body = cached.mainBody();
    for (cached.params, main_body[0..cached.params.len]) |param, arg_inst| {
        const operand = call_args[param.index];
        copier.map[@backingInt(arg_inst)] = operand;
        if (strip or param.name == .none) continue;
        const name = try appendString(gpa, extra, param.name.toSlice(cached.air));
        const dbg_arg = try copier.addInst(.{ .tag = .dbg_arg_inline, .data = .{ .pl_op = .{
            .operand = operand,
            .payload = @backingInt(name),
        } } });
        try copier.scratch.append(gpa, dbg_arg);
    }
    copier.copyBodyInner(main_body[cached.params.len..]) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        // The cached AIR was copied once already.
        error.Unsupported => unreachable,
    };
    const body = copier.scratch.items[body_start..];

    const payload = if (strip) payload: {
        try extra.ensureUnusedCapacity(gpa, 1 + body.len);
        const payload: u32 = @intCast(extra.items.len);
        extra.appendAssumeCapacity(@intCast(body.len));
        extra.appendSliceAssumeCapacity(@ptrCast(body));
        break :payload payload;
    } else payload: {
        try extra.ensureUnusedCapacity(gpa, 2 + body.len);
        const payload: u32 = @intCast(extra.items.len);
        extra.appendAssumeCapacity(@backingInt(cached.func));
        extra.appendAssumeCapacity(@intCast(body.len));
        extra.appendSliceAssumeCapacity(@ptrCast(body));
        break :payload payload;
    };
    // The block replaces the call in place, so every use of the call's result now uses the block's.
    instructions.set(@backingInt(call_inst), .{
        .tag = if (strip) .block else .dbg_inline_block,
        .data = .{ .ty_pl = .{ .ty = .fromInterned(result_ty), .payload = payload } },
    });
}

/// The call sites of a function and where they are.
const Survey = struct {
    air: *const Air,
    ip: *const InternPool,
    sites: std.ArrayList(Site) = .empty,

    const Site = struct {
        inst: Air.Inst.Index,
        in_loop: bool,
        cold: bool,
    };

    const Context = struct {
        in_loop: bool,
        cold: bool,

        fn branch(context: Context, hint: std.lang.BranchHint) Context {
            return .{ .in_loop = context.in_loop, .cold = context.cold or hint == .cold };
        }
    };

    fn body(survey: *Survey, gpa: Allocator, insts: []const Air.Inst.Index, context: Context) Error!void {
        const air = survey.air;
        const tags = air.instructions.items(.tag);
        const datas = air.instructions.items(.data);
        for (insts) |inst| switch (tags[@backingInt(inst)]) {
            .call, .call_never_tail => {
                const callee = datas[@backingInt(inst)].pl_op.operand.toInterned() orelse continue;
                // A coerced function is called with a type other than its own.
                if (!survey.ip.isFuncBody(callee) or survey.ip.unwrapCoercedFunc(callee) != callee) continue;
                try survey.sites.append(gpa, .{ .inst = inst, .in_loop = context.in_loop, .cold = context.cold });
            },
            .block => try survey.body(gpa, air.unwrapBlock(inst).body, context),
            .dbg_inline_block => try survey.body(gpa, air.unwrapDbgBlock(inst).body, context),
            .loop => try survey.body(gpa, air.unwrapBlock(inst).body, .{ .in_loop = true, .cold = context.cold }),
            .cond_br => {
                const cond_br = air.unwrapCondBr(inst);
                try survey.body(gpa, cond_br.then_body, context.branch(cond_br.branch_hints.true));
                try survey.body(gpa, cond_br.else_body, context.branch(cond_br.branch_hints.false));
            },
            .switch_br, .loop_switch_br => |tag| {
                const switch_br = air.unwrapSwitch(inst);
                const case_context: Context = .{ .in_loop = context.in_loop or tag == .loop_switch_br, .cold = context.cold };
                var it = switch_br.iterateCases();
                while (it.next()) |case| {
                    try survey.body(gpa, case.body, case_context.branch(switch_br.getHint(case.idx)));
                }
                try survey.body(gpa, it.elseBody(), case_context.branch(switch_br.getElseHint()));
            },
            .@"try" => try survey.body(gpa, air.unwrapTry(inst).else_body, context),
            .try_cold => try survey.body(gpa, air.unwrapTry(inst).else_body, context.branch(.cold)),
            .try_ptr => try survey.body(gpa, air.unwrapTryPtr(inst).else_body, context),
            .try_ptr_cold => try survey.body(gpa, air.unwrapTryPtr(inst).else_body, context.branch(.cold)),
            else => {},
        };
    }
};

/// The size estimate of `body`, in roughly the number of machine instructions it adds to a caller.
/// Instructions that generate no code (debug info, blocks, breaks, returns, allocations) are free,
/// a call costs `call_cost`, and code that a branch hint marks cold is free: it is out of the way
/// of the hot path and usually ends in a panic.
pub fn bodyCost(air: *const Air, body: []const Air.Inst.Index) u32 {
    const tags = air.instructions.items(.tag);
    var cost: u32 = 0;
    for (body) |inst| {
        const tag = tags[@backingInt(inst)];
        cost +|= switch (tag) {
            .arg,
            .alloc,
            .ret_ptr,
            .block,
            .dbg_inline_block,
            .br,
            .ret,
            .ret_safe,
            .unreach,
            .dbg_stmt,
            .dbg_empty_stmt,
            .dbg_var_ptr,
            .dbg_var_val,
            .dbg_arg_inline,
            => 0,
            .call, .call_always_tail, .call_never_tail, .call_never_inline => call_cost,
            else => 1,
        };
        cost +|= switch (tag) {
            .block, .loop => bodyCost(air, air.unwrapBlock(inst).body),
            .dbg_inline_block => bodyCost(air, air.unwrapDbgBlock(inst).body),
            .cond_br => cost: {
                const cond_br = air.unwrapCondBr(inst);
                break :cost hintedCost(air, cond_br.then_body, cond_br.branch_hints.true) +|
                    hintedCost(air, cond_br.else_body, cond_br.branch_hints.false);
            },
            .switch_br, .loop_switch_br => cost: {
                const switch_br = air.unwrapSwitch(inst);
                var cases_cost: u32 = 0;
                var it = switch_br.iterateCases();
                while (it.next()) |case| {
                    cases_cost +|= hintedCost(air, case.body, switch_br.getHint(case.idx)) +| @as(u32, @intCast(case.items.len + case.ranges.len));
                }
                break :cost cases_cost +| hintedCost(air, it.elseBody(), switch_br.getElseHint());
            },
            .@"try" => bodyCost(air, air.unwrapTry(inst).else_body),
            .try_ptr => bodyCost(air, air.unwrapTryPtr(inst).else_body),
            else => 0,
        };
    }
    return cost;
}

/// The cost of a call left in an inlined body: the branch, argument and result moves, and the
/// registers it clobbers.
pub const call_cost = 5;

fn hintedCost(air: *const Air, body: []const Air.Inst.Index, hint: std.lang.BranchHint) u32 {
    return switch (hint) {
        .cold => 0,
        .none, .likely, .unlikely, .unpredictable => bodyCost(air, body),
    };
}

/// How an instruction stores its operands. Copying, remapping and hashing an instruction only
/// depends on this.
const Shape = enum {
    /// `no_op`.
    none,
    un_op,
    bin_op,
    ty,
    arg,
    ty_op,
    ty_nav,
    dbg_stmt,
    atomic_load,
    prefetch,
    reduce,
    br,
    repeat,
    /// `ty_pl` with an `Air.Bin` payload.
    ty_pl_bin,
    ty_pl_struct_field,
    ty_pl_field_parent_ptr,
    ty_pl_vector_cmp,
    ty_pl_cmpxchg,
    ty_pl_union_init,
    /// `ty_pl` whose payload is one `Inst.Ref` per element of the type.
    ty_pl_aggregate_init,
    ty_pl_shuffle_one,
    ty_pl_shuffle_two,
    ty_pl_asm,
    ty_pl_try_ptr,
    ty_pl_block,
    ty_pl_dbg_inline_block,
    /// `pl_op` with an `Air.Bin` payload.
    pl_op_bin,
    pl_op_call,
    pl_op_atomic_rmw,
    pl_op_cond_br,
    pl_op_switch_br,
    pl_op_try,
    /// `pl_op` whose payload is a string in `extra`: a variable name.
    pl_op_name,
    /// `pl_op` whose payload is an immediate.
    pl_op_immediate,
};

/// Returns `null` for instructions that inlining would change the meaning of, or that never
/// appear in the AIR Sema produces. A function containing one is not inlined.
fn shape(tag: Air.Inst.Tag) ?Shape {
    return switch (tag) {
        // These refer to the frame or the arguments of the function they appear in.
        .ret_addr,
        .frame_addr,
        .c_va_arg,
        .c_va_copy,
        .c_va_end,
        .c_va_start,
        // Returns from the function it appears in.
        .call_always_tail,
        // The error return trace belongs to the function's frame.
        .err_return_trace,
        .set_err_return_trace,
        .save_err_return_trace_index,
        // GPU kernels are not inlined.
        .work_item_id,
        .work_group_size,
        .work_group_id,
        .spirv_runtime_array_len,
        // Only exist during Sema, or are created by `Air.Legalize`, which runs after this pass.
        .inferred_alloc,
        .inferred_alloc_comptime,
        .legalize_vec_store_elem,
        .legalize_vec_elem_val,
        .legalize_compiler_rt_call,
        => null,

        .trap,
        .breakpoint,
        .unreach,
        .dbg_empty_stmt,
        => .none,

        .ret,
        .ret_safe,
        .ret_load,
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
        => .un_op,

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
        .store,
        .store_safe,
        .set_union_tag,
        .array_elem_val,
        .slice_elem_val,
        .ptr_elem_val,
        .memset,
        .memset_safe,
        .memcpy,
        .memmove,
        .atomic_store_unordered,
        .atomic_store_monotonic,
        .atomic_store_release,
        .atomic_store_seq_cst,
        => .bin_op,

        .alloc, .ret_ptr => .ty,

        .arg => .arg,

        .not,
        .bit_cast,
        .bit_cast_safe,
        .ptr_cast,
        .ptr_from_int,
        .int_from_ptr,
        .error_cast,
        .error_from_int,
        .int_from_error,
        .union_from_enum,
        .clz,
        .ctz,
        .popcount,
        .byte_swap,
        .bit_reverse,
        .abs,
        .load,
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
        .slice_len,
        .slice_ptr,
        .ptr_slice_len_ptr,
        .ptr_slice_ptr_ptr,
        .array_to_slice,
        .array_to_vector,
        .int_from_float,
        .int_from_float_optimized,
        .int_from_float_safe,
        .int_from_float_optimized_safe,
        .float_from_int,
        .splat,
        .error_set_has_value,
        .addrspace_cast,
        => .ty_op,

        .runtime_nav_ptr => .ty_nav,
        .dbg_stmt => .dbg_stmt,
        .atomic_load => .atomic_load,
        .prefetch => .prefetch,
        .reduce, .reduce_optimized => .reduce,
        .br, .switch_dispatch => .br,
        .repeat => .repeat,

        .ptr_add,
        .ptr_sub,
        .add_with_overflow,
        .sub_with_overflow,
        .mul_with_overflow,
        .shl_with_overflow,
        .slice,
        .slice_elem_ptr,
        .ptr_elem_ptr,
        => .ty_pl_bin,

        .struct_field_ptr, .agg_field_val => .ty_pl_struct_field,
        .field_parent_ptr => .ty_pl_field_parent_ptr,
        .cmp_vector, .cmp_vector_optimized => .ty_pl_vector_cmp,
        .cmpxchg_weak, .cmpxchg_strong => .ty_pl_cmpxchg,
        .union_init => .ty_pl_union_init,
        .aggregate_init => .ty_pl_aggregate_init,
        .shuffle_one => .ty_pl_shuffle_one,
        .shuffle_two => .ty_pl_shuffle_two,
        .assembly => .ty_pl_asm,
        .try_ptr, .try_ptr_cold => .ty_pl_try_ptr,
        .block, .loop => .ty_pl_block,
        .dbg_inline_block => .ty_pl_dbg_inline_block,

        .select, .mul_add => .pl_op_bin,
        .call, .call_never_tail, .call_never_inline => .pl_op_call,
        .atomic_rmw => .pl_op_atomic_rmw,
        .cond_br => .pl_op_cond_br,
        .switch_br, .loop_switch_br => .pl_op_switch_br,
        .@"try", .try_cold => .pl_op_try,
        .dbg_var_ptr, .dbg_var_val, .dbg_arg_inline => .pl_op_name,
        .wasm_memory_size, .wasm_memory_grow => .pl_op_immediate,
    };
}

/// Copies bodies of one `Air` into another, renumbering instructions and remapping operands.
const Copier = struct {
    gpa: Allocator,
    zcu: *Zcu,
    src: *const Air,
    instructions: *std.MultiArrayList(Air.Inst),
    extra: *std.ArrayList(u32),
    /// The copy of each source instruction, `.none` until it is copied.
    map: []Air.Inst.Ref,
    /// The instructions of the bodies being copied, innermost last.
    scratch: std.ArrayList(Air.Inst.Index),
    /// The instruction that made the copy fail with `error.Unsupported`, if it was its tag.
    unsupported: ?Air.Inst.Tag = null,
    mode: union(enum) {
        /// An exact copy.
        compact,
        /// A copy that replaces a call: the callee's returns break out of `block`.
        inline_call: struct {
            block: Air.Inst.Index,
            result_ty: Type,
            /// What the callee's `ret_ptr`s become.
            ret_ptr: Air.Inst.Ref = .none,
        },
    },

    const CopyError = Error || error{Unsupported};

    fn init(
        gpa: Allocator,
        zcu: *Zcu,
        src: *const Air,
        instructions: *std.MultiArrayList(Air.Inst),
        extra: *std.ArrayList(u32),
        mode: @FieldType(Copier, "mode"),
    ) Error!Copier {
        const map = try gpa.alloc(Air.Inst.Ref, src.instructions.len);
        @memset(map, .none);
        return .{
            .gpa = gpa,
            .zcu = zcu,
            .src = src,
            .instructions = instructions,
            .extra = extra,
            .map = map,
            .scratch = .empty,
            .mode = mode,
        };
    }

    fn deinit(c: *Copier) void {
        c.gpa.free(c.map);
        c.scratch.deinit(c.gpa);
    }

    /// Copies `body` as the main body, returning the payload index of its `Air.Block`.
    fn copyMainBody(c: *Copier, body: []const Air.Inst.Index) CopyError!u32 {
        return c.copyBlockBody(body, &.{});
    }

    /// Copies `body` and appends `header` and the copied body to `extra`. Returns the index of
    /// `header`.
    fn copyBlockBody(c: *Copier, body: []const Air.Inst.Index, header: []const u32) CopyError!u32 {
        const start = c.scratch.items.len;
        defer c.scratch.shrinkRetainingCapacity(start);
        try c.copyBodyInner(body);
        const copied = c.scratch.items[start..];
        try c.extra.ensureUnusedCapacity(c.gpa, header.len + 1 + copied.len);
        const payload: u32 = @intCast(c.extra.items.len);
        c.extra.appendSliceAssumeCapacity(header);
        c.extra.appendAssumeCapacity(@intCast(copied.len));
        c.extra.appendSliceAssumeCapacity(@ptrCast(copied));
        return payload;
    }

    /// Appends the copy of each instruction of `body` to `scratch`.
    fn copyBodyInner(c: *Copier, body: []const Air.Inst.Index) CopyError!void {
        for (body) |inst| try c.copyInst(inst);
    }

    fn addInst(c: *Copier, inst: Air.Inst) Error!Air.Inst.Index {
        const index: Air.Inst.Index = @fromBackingInt(@intCast(c.instructions.len));
        try c.instructions.append(c.gpa, inst);
        return index;
    }

    /// Adds `inst` as the copy of `src_inst`.
    fn emit(c: *Copier, src_inst: Air.Inst.Index, inst: Air.Inst) Error!void {
        const index = try c.addInst(inst);
        c.map[@backingInt(src_inst)] = index.toRef();
        try c.scratch.append(c.gpa, index);
    }

    fn ref(c: *const Copier, src_ref: Air.Inst.Ref) error{Unsupported}!Air.Inst.Ref {
        if (src_ref == .none) return .none;
        const src_inst = src_ref.toIndex() orelse return src_ref;
        const copied = c.map[@backingInt(src_inst)];
        // Only reachable for AIR that uses a value outside the bodies that define it.
        if (copied == .none) return error.Unsupported;
        return copied;
    }

    fn blockInst(c: *const Copier, src_inst: Air.Inst.Index) error{Unsupported}!Air.Inst.Index {
        return (try c.ref(src_inst.toRef())).toIndex().?;
    }

    /// Copies the `extra` payload of type `T` at `index`, remapping its operands, and returns the
    /// index of the copy.
    fn copyExtra(c: *Copier, comptime T: type, index: u32) CopyError!u32 {
        const data = c.src.extraData(T, index).data;
        const fields = @typeInfo(T).@"struct";
        try c.extra.ensureUnusedCapacity(c.gpa, fields.field_names.len);
        const payload: u32 = @intCast(c.extra.items.len);
        inline for (fields.field_names) |name| {
            const value = @field(data, name);
            c.extra.appendAssumeCapacity(switch (@TypeOf(value)) {
                u32 => value,
                Air.Inst.Ref => @backingInt(try c.ref(value)),
                InternPool.Index => @backingInt(value),
                Air.CondBr.BranchHints, Air.Asm.Flags => @bitCast(value),
                else => |Field| @compileError("unhandled field type " ++ @typeName(Field)),
            });
        }
        return payload;
    }

    fn appendRefs(c: *Copier, refs: []const Air.Inst.Ref) CopyError!void {
        try c.extra.ensureUnusedCapacity(c.gpa, refs.len);
        for (refs) |src_ref| c.extra.appendAssumeCapacity(@backingInt(try c.ref(src_ref)));
    }

    /// Appends the bodies to `scratch`, returning the end of each.
    fn copyBodies(c: *Copier, comptime n: usize, bodies: [n][]const Air.Inst.Index) CopyError![n]usize {
        var ends: [n]usize = undefined;
        for (bodies, &ends) |body, *end| {
            try c.copyBodyInner(body);
            end.* = c.scratch.items.len;
        }
        return ends;
    }

    fn copyInst(c: *Copier, src_inst: Air.Inst.Index) CopyError!void {
        const src = c.src;
        const tag = src.instructions.items(.tag)[@backingInt(src_inst)];
        const data = src.instructions.items(.data)[@backingInt(src_inst)];
        const gpa = c.gpa;

        switch (c.mode) {
            .compact => {},
            .inline_call => |inline_call| switch (tag) {
                .ret, .ret_safe => return c.emit(src_inst, .{ .tag = .br, .data = .{ .br = .{
                    .block_inst = inline_call.block,
                    .operand = try c.ref(data.un_op),
                } } }),
                .ret_load => {
                    const load = try c.addInst(.{ .tag = .load, .data = .{ .ty_op = .{
                        .ty = inline_call.result_ty,
                        .operand = try c.ref(data.un_op),
                    } } });
                    try c.scratch.append(gpa, load);
                    return c.emit(src_inst, .{ .tag = .br, .data = .{ .br = .{
                        .block_inst = inline_call.block,
                        .operand = load.toRef(),
                    } } });
                },
                .ret_ptr => {
                    // Every `ret_ptr` is the same pointer: the local created at the start of the
                    // inlined body.
                    c.map[@backingInt(src_inst)] = inline_call.ret_ptr;
                    return;
                },
                // Replaced by the call's operands before the body is copied.
                .arg => return error.Unsupported,
                else => {},
            },
        }

        const inst_shape = shape(tag) orelse {
            c.unsupported = tag;
            return error.Unsupported;
        };
        const new_data: Air.Inst.Data = switch (inst_shape) {
            .none, .ty, .arg, .ty_nav, .dbg_stmt => data,
            .un_op => .{ .un_op = try c.ref(data.un_op) },
            .bin_op => .{ .bin_op = .{ .lhs = try c.ref(data.bin_op.lhs), .rhs = try c.ref(data.bin_op.rhs) } },
            .ty_op => .{ .ty_op = .{ .ty = data.ty_op.ty, .operand = try c.ref(data.ty_op.operand) } },
            .atomic_load => .{ .atomic_load = .{ .ptr = try c.ref(data.atomic_load.ptr), .order = data.atomic_load.order } },
            .prefetch => prefetch: {
                var prefetch = data.prefetch;
                prefetch.ptr = try c.ref(prefetch.ptr);
                break :prefetch .{ .prefetch = prefetch };
            },
            .reduce => .{ .reduce = .{ .operand = try c.ref(data.reduce.operand), .operation = data.reduce.operation } },
            .br => .{ .br = .{ .block_inst = try c.blockInst(data.br.block_inst), .operand = try c.ref(data.br.operand) } },
            .repeat => .{ .repeat = .{ .loop_inst = try c.blockInst(data.repeat.loop_inst) } },
            .ty_pl_bin => .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = try c.copyExtra(Air.Bin, data.ty_pl.payload) } },
            .ty_pl_struct_field => .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = try c.copyExtra(Air.StructField, data.ty_pl.payload) } },
            .ty_pl_field_parent_ptr => .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = try c.copyExtra(Air.FieldParentPtr, data.ty_pl.payload) } },
            .ty_pl_vector_cmp => .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = try c.copyExtra(Air.VectorCmp, data.ty_pl.payload) } },
            .ty_pl_cmpxchg => .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = try c.copyExtra(Air.Cmpxchg, data.ty_pl.payload) } },
            .ty_pl_union_init => .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = try c.copyExtra(Air.UnionInit, data.ty_pl.payload) } },
            .ty_pl_aggregate_init => aggregate_init: {
                const len: usize = @intCast(data.ty_pl.ty.arrayLenIp(&c.zcu.intern_pool));
                const payload: u32 = @intCast(c.extra.items.len);
                try c.appendRefs(@ptrCast(src.extra.items[data.ty_pl.payload..][0..len]));
                break :aggregate_init .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = payload } };
            },
            .ty_pl_shuffle_one => shuffle_one: {
                const unwrapped = src.unwrapShuffleOne(c.zcu, src_inst);
                const operand = try c.ref(unwrapped.operand);
                const payload: u32 = @intCast(c.extra.items.len);
                try c.extra.ensureUnusedCapacity(gpa, unwrapped.mask.len + 1);
                c.extra.appendSliceAssumeCapacity(@ptrCast(unwrapped.mask));
                c.extra.appendAssumeCapacity(@backingInt(operand));
                break :shuffle_one .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = payload } };
            },
            .ty_pl_shuffle_two => shuffle_two: {
                const unwrapped = src.unwrapShuffleTwo(c.zcu, src_inst);
                const operand_a = try c.ref(unwrapped.operand_a);
                const operand_b = try c.ref(unwrapped.operand_b);
                const payload: u32 = @intCast(c.extra.items.len);
                try c.extra.ensureUnusedCapacity(gpa, unwrapped.mask.len + 2);
                c.extra.appendSliceAssumeCapacity(@ptrCast(unwrapped.mask));
                c.extra.appendAssumeCapacity(@backingInt(operand_a));
                c.extra.appendAssumeCapacity(@backingInt(operand_b));
                break :shuffle_two .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = payload } };
            },
            .ty_pl_asm => .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = try c.copyAsm(src_inst) } },
            .pl_op_bin => .{ .pl_op = .{ .operand = try c.ref(data.pl_op.operand), .payload = try c.copyExtra(Air.Bin, data.pl_op.payload) } },
            .pl_op_atomic_rmw => .{ .pl_op = .{ .operand = try c.ref(data.pl_op.operand), .payload = try c.copyExtra(Air.AtomicRmw, data.pl_op.payload) } },
            .pl_op_call => call: {
                const call = src.unwrapCall(src_inst);
                const callee = try c.ref(call.callee);
                const payload = try c.copyExtra(Air.Call, data.pl_op.payload);
                try c.appendRefs(call.args);
                break :call .{ .pl_op = .{ .operand = callee, .payload = payload } };
            },
            .pl_op_name => name: {
                const operand = try c.ref(data.pl_op.operand);
                const name: Air.NullTerminatedString = @fromBackingInt(data.pl_op.payload);
                const payload = try appendString(gpa, c.extra, name.toSlice(src.*));
                break :name .{ .pl_op = .{ .operand = operand, .payload = @backingInt(payload) } };
            },
            .pl_op_immediate => .{ .pl_op = .{ .operand = try c.ref(data.pl_op.operand), .payload = data.pl_op.payload } },

            // Instructions with bodies are added before their bodies, which may refer to them.
            .ty_pl_block => return c.copyBlock(src_inst, tag, data.ty_pl.ty, src.unwrapBlock(src_inst).body, &.{}),
            .ty_pl_dbg_inline_block => {
                const dbg_block = src.unwrapDbgBlock(src_inst);
                return c.copyBlock(src_inst, tag, dbg_block.ty, dbg_block.body, &.{@backingInt(dbg_block.func)});
            },
            .ty_pl_try_ptr => {
                const try_ptr = src.unwrapTryPtr(src_inst);
                const ptr = try c.ref(try_ptr.error_union_ptr);
                const index = try c.reserve(src_inst, tag);
                const payload = try c.copyBlockBody(try_ptr.else_body, &.{@backingInt(ptr)});
                c.instructions.items(.data)[@backingInt(index)] = .{ .ty_pl = .{ .ty = data.ty_pl.ty, .payload = payload } };
                return;
            },
            .pl_op_try => {
                const operand = try c.ref(data.pl_op.operand);
                const index = try c.reserve(src_inst, tag);
                const payload = try c.copyBlockBody(src.unwrapTry(src_inst).else_body, &.{});
                c.instructions.items(.data)[@backingInt(index)] = .{ .pl_op = .{ .operand = operand, .payload = payload } };
                return;
            },
            .pl_op_cond_br => {
                const cond_br = src.unwrapCondBr(src_inst);
                const condition = try c.ref(cond_br.condition);
                const index = try c.reserve(src_inst, tag);
                const start = c.scratch.items.len;
                defer c.scratch.shrinkRetainingCapacity(start);
                const then_end, const else_end = try c.copyBodies(2, .{ cond_br.then_body, cond_br.else_body });
                const payload = try c.copyExtraValue(Air.CondBr, .{
                    .then_body_len = @intCast(then_end - start),
                    .else_body_len = @intCast(else_end - then_end),
                    .branch_hints = cond_br.branch_hints,
                });
                try c.extra.appendSlice(gpa, @ptrCast(c.scratch.items[start..else_end]));
                c.instructions.items(.data)[@backingInt(index)] = .{ .pl_op = .{ .operand = condition, .payload = payload } };
                return;
            },
            .pl_op_switch_br => return c.copySwitch(src_inst, tag),
        };
        try c.emit(src_inst, .{ .tag = tag, .data = new_data });
    }

    /// Adds the copy of `src_inst`, whose data is filled in once its bodies are copied.
    fn reserve(c: *Copier, src_inst: Air.Inst.Index, tag: Air.Inst.Tag) Error!Air.Inst.Index {
        const index = try c.addInst(.{ .tag = tag, .data = undefined });
        c.map[@backingInt(src_inst)] = index.toRef();
        try c.scratch.append(c.gpa, index);
        return index;
    }

    fn copyBlock(
        c: *Copier,
        src_inst: Air.Inst.Index,
        tag: Air.Inst.Tag,
        ty: Type,
        body: []const Air.Inst.Index,
        header: []const u32,
    ) CopyError!void {
        const index = try c.reserve(src_inst, tag);
        const payload = try c.copyBlockBody(body, header);
        c.instructions.items(.data)[@backingInt(index)] = .{ .ty_pl = .{ .ty = ty, .payload = payload } };
    }

    fn copyExtraValue(c: *Copier, comptime T: type, value: T) Error!u32 {
        const fields = @typeInfo(T).@"struct";
        try c.extra.ensureUnusedCapacity(c.gpa, fields.field_names.len);
        const payload: u32 = @intCast(c.extra.items.len);
        inline for (fields.field_names) |name| {
            const field = @field(value, name);
            c.extra.appendAssumeCapacity(switch (@TypeOf(field)) {
                u32 => field,
                Air.CondBr.BranchHints => @bitCast(field),
                else => |Field| @compileError("unhandled field type " ++ @typeName(Field)),
            });
        }
        return payload;
    }

    fn copySwitch(c: *Copier, src_inst: Air.Inst.Index, tag: Air.Inst.Tag) CopyError!void {
        const gpa = c.gpa;
        const switch_br = c.src.unwrapSwitch(src_inst);
        const operand = try c.ref(switch_br.operand);
        const index = try c.reserve(src_inst, tag);

        // The copied bodies, one after the other in `scratch`: `starts[i]` is where case `i`
        // begins, and the else body runs from `starts[cases_len]` to the end.
        const start = c.scratch.items.len;
        defer c.scratch.shrinkRetainingCapacity(start);
        const starts = try gpa.alloc(usize, switch_br.cases_len + 1);
        defer gpa.free(starts);
        var it = switch_br.iterateCases();
        while (it.next()) |case| {
            starts[case.idx] = c.scratch.items.len;
            try c.copyBodyInner(case.body);
        }
        starts[switch_br.cases_len] = c.scratch.items.len;
        try c.copyBodyInner(it.elseBody());
        const bodies = c.scratch.items[start..];

        const payload = try c.copyExtraValue(Air.SwitchBr, .{
            .cases_len = switch_br.cases_len,
            .else_body_len = @intCast(c.scratch.items.len - starts[switch_br.cases_len]),
        });
        try c.extra.appendSlice(gpa, c.src.extra.items[switch_br.branch_hints_start..switch_br.cases_start]);
        it = switch_br.iterateCases();
        while (it.next()) |case| {
            const case_start = starts[case.idx] - start;
            const case_end = starts[case.idx + 1] - start;
            _ = try c.copyExtraValue(Air.SwitchBr.Case, .{
                .items_len = @intCast(case.items.len),
                .ranges_len = @intCast(case.ranges.len),
                .body_len = @intCast(case_end - case_start),
            });
            try c.appendRefs(case.items);
            try c.appendRefs(@ptrCast(case.ranges));
            try c.extra.appendSlice(gpa, @ptrCast(bodies[case_start..case_end]));
        }
        try c.extra.appendSlice(gpa, @ptrCast(bodies[starts[switch_br.cases_len] - start ..]));
        c.instructions.items(.data)[@backingInt(index)] = .{ .pl_op = .{ .operand = operand, .payload = payload } };
    }

    /// Copies the `Air.Asm` payload of `src_inst`: the operands, remapped, then the source and the
    /// constraints and names of the operands.
    fn copyAsm(c: *Copier, src_inst: Air.Inst.Index) CopyError!u32 {
        const unwrapped = c.src.unwrapAsm(src_inst);
        const src_payload = c.src.instructions.items(.data)[@backingInt(src_inst)].ty_pl.payload;
        const payload = try c.copyExtra(Air.Asm, src_payload);
        try c.appendRefs(unwrapped.outputs);
        try c.appendRefs(unwrapped.inputs);
        try appendStrings(c.gpa, c.extra, &.{unwrapped.source});
        inline for (.{ unwrapped.iterateOutputs(), unwrapped.iterateInputs() }) |iterator| {
            var it = iterator;
            while (it.next()) |operand| try appendStrings(c.gpa, c.extra, &.{ operand.constraint, operand.name });
        }
        return payload;
    }
};

/// Appends each string followed by a zero byte to `extra`, padded with zero bytes to whole words.
fn appendStrings(gpa: Allocator, extra: *std.ArrayList(u32), strings: []const []const u8) Error!void {
    var len: usize = 0;
    for (strings) |string| len += string.len + 1;
    const start = extra.items.len;
    try extra.appendNTimes(gpa, 0, @divCeil(len, 4));
    var bytes: []u8 = std.mem.sliceAsBytes(extra.items[start..]);
    for (strings) |string| {
        @memcpy(bytes[0..string.len], string);
        bytes = bytes[string.len + 1 ..];
    }
}

/// Like `Sema.appendAirString`, with the padding zeroed so that `hashAir` is deterministic.
fn appendString(gpa: Allocator, extra: *std.ArrayList(u32), str: []const u8) Error!Air.NullTerminatedString {
    if (str.len == 0) return .none;
    const index: Air.NullTerminatedString = @fromBackingInt(@intCast(extra.items.len));
    try appendStrings(gpa, extra, &.{str});
    return index;
}

/// Hashes AIR made by `Copier` in `.compact` mode, whose `extra` is fully defined.
fn hashAir(air: *const Air) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    for (air.instructions.items(.tag), air.instructions.items(.data)) |tag, data| {
        const words: [2]u32 = switch (shape(tag).?) {
            .none => .{ 0, 0 },
            .un_op => .{ @backingInt(data.un_op), 0 },
            .bin_op => .{ @backingInt(data.bin_op.lhs), @backingInt(data.bin_op.rhs) },
            .ty => .{ @backingInt(data.ty.toIntern()), 0 },
            .arg => .{ @backingInt(data.arg.ty.toIntern()), data.arg.zir_param_index },
            .ty_op => .{ @backingInt(data.ty_op.ty.toIntern()), @backingInt(data.ty_op.operand) },
            .ty_nav => .{ @backingInt(data.ty_nav.ty.toIntern()), @backingInt(data.ty_nav.nav) },
            .dbg_stmt => .{ data.dbg_stmt.line, data.dbg_stmt.column },
            .atomic_load => .{ @backingInt(data.atomic_load.ptr), @backingInt(data.atomic_load.order) },
            .prefetch => .{ @backingInt(data.prefetch.ptr), @as(u32, @backingInt(data.prefetch.rw)) |
                @as(u32, data.prefetch.locality) << 1 |
                @as(u32, @backingInt(data.prefetch.cache)) << 3 },
            .reduce => .{ @backingInt(data.reduce.operand), @backingInt(data.reduce.operation) },
            .br => .{ @backingInt(data.br.block_inst), @backingInt(data.br.operand) },
            .repeat => .{ @backingInt(data.repeat.loop_inst), 0 },
            .ty_pl_bin,
            .ty_pl_struct_field,
            .ty_pl_field_parent_ptr,
            .ty_pl_vector_cmp,
            .ty_pl_cmpxchg,
            .ty_pl_union_init,
            .ty_pl_aggregate_init,
            .ty_pl_shuffle_one,
            .ty_pl_shuffle_two,
            .ty_pl_asm,
            .ty_pl_try_ptr,
            .ty_pl_block,
            .ty_pl_dbg_inline_block,
            => .{ @backingInt(data.ty_pl.ty.toIntern()), data.ty_pl.payload },
            .pl_op_bin,
            .pl_op_call,
            .pl_op_atomic_rmw,
            .pl_op_cond_br,
            .pl_op_switch_br,
            .pl_op_try,
            .pl_op_name,
            .pl_op_immediate,
            => .{ @backingInt(data.pl_op.operand), data.pl_op.payload },
        };
        hasher.update(std.mem.asBytes(&tag));
        hasher.update(std.mem.asBytes(&words));
    }
    hasher.update(std.mem.sliceAsBytes(air.extra.items));
    return hasher.final();
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const Air = @import("../Air.zig");
const InternPool = @import("../InternPool.zig");
const Module = @import("../Module.zig");
const Type = @import("../Type.zig");
const Zcu = @import("../Zcu.zig");
