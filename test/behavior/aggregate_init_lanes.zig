const std = @import("std");
const expect = std.testing.expect;

// A UI library's style struct (nanoui's `Style`, without its methods): initializing it from a
// couple of runtime fields and the defaults composed a 16-byte part of it in a vector register
// from parts at offsets 0, 4 and 12, and the 8-byte part at offset 4 is not a lane of its own
// size. Its layout is what made the backend do that, so the fields stay as they are.

const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
};
const Point = struct { x: f32 = 0, y: f32 = 0 };
const Edges = struct { top: f32 = 0, right: f32 = 0, bottom: f32 = 0, left: f32 = 0 };
const Length = union(enum) { auto, px: f32, fill };
const Shadow = struct {
    color: Color = .{ .a = 0.18 },
    blur: f32 = 12,
    x: f32 = 0,
    y: f32 = 4,
    knockout: bool = false,
    spread: f32 = 0,
};
const Glass = struct {
    style: enum { regular, clear } = .regular,
    tint: Color = .{ .a = 0 },
};
const Scrollbar = union(enum) { always, overlay: Color };
const Spring = struct { response: f32, damping: f32 };
const Pulse = struct { period: f32, scale_amp: f32, alpha_low: f32 };

const Style = struct {
    direction: enum { row, column } = .column,
    gap: f32 = 0,
    padding: Edges = .{},
    width: Length = .auto,
    height: Length = .auto,
    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    max_height: f32 = std.math.inf(f32),
    grow: f32 = 0,
    align_items: enum { start, center, end, stretch } = .start,
    justify: enum { start, center, end, space_between } = .start,
    background: ?Color = null,
    border: ?Color = null,
    border_width: f32 = 1,
    border_dashed: bool = false,
    radius: f32 = 0,
    corner_circular: bool = false,
    shadow: ?Shadow = null,
    shadows: []const Shadow = &.{},
    glass: ?Glass = null,
    scroll: bool = false,
    wheel: bool = false,
    scrollbar: Scrollbar = .always,
    opacity: f32 = 1,
    offset: Point = .{},
    layout_motion: u64 = 0,
    absolute: bool = false,
    fixed: bool = false,
    layer: u8 = 0,
    clip: bool = false,
    follow_end: bool = false,
    selectable: bool = false,
    window_drag: bool = false,
    control: bool = false,
    scale: f32 = 1,
    scale_anchor: Point = .{ .x = 0.5, .y = 0.5 },
    scroll_x: bool = false,
    scroll_bar: bool = true,
    scroll_bar_fades: bool = false,
    settle_y: ?Spring = null,
    rotation: f32 = 0,
    rotation_anchor: Point = .{ .x = 0.5, .y = 0.5 },
    turn: f32 = 0,
    perspective: f32 = 0,
    face: enum(u2) { both, front, back } = .both,
    spin: f32 = 0,
    pulse: ?Pulse = .{ .period = 1.5, .scale_amp = 2.5, .alpha_low = 3.5 },
    motion_blur: bool = false,
    group: bool = false,
};

const Node = struct { id: u64, style: Style };
const Size = struct { w: f32 = 0, h: f32 = 0 };

noinline fn begin(nodes: *std.ArrayList(Node), gpa: std.mem.Allocator, size: Size, transparent: bool, background: Color) !void {
    try nodes.append(gpa, .{
        .id = 0x9e3779b97f4a7c15,
        .style = .{ .width = .{ .px = size.w }, .height = .{ .px = size.h }, .background = if (transparent) null else background },
    });
}

test "aggregate init composing a part across vector lanes" {
    const gpa = std.testing.allocator;
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(gpa);
    try begin(&nodes, gpa, .{ .w = 3, .h = 4 }, false, .{ .r = 0.5, .g = 0.25, .b = 0.125 });
    const node = nodes.items[0];
    const want: Style = .{ .width = .{ .px = 3 }, .height = .{ .px = 4 }, .background = .{ .r = 0.5, .g = 0.25, .b = 0.125 } };
    try expect(node.id == 0x9e3779b97f4a7c15);
    inline for (@typeInfo(Style).@"struct".field_names) |name| {
        try expect(std.meta.eql(@field(want, name), @field(node.style, name)));
    }
}
