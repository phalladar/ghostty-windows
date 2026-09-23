const SplitView = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const split_tree = @import("../../datastruct/split_tree.zig");
const Surface = @import("Surface.zig");
const c = @import("c.zig");

pub const Tree = split_tree.SplitTree(Surface);
pub const Handle = Tree.Node.Handle;
pub const Layout = Tree.Split.Layout;
pub const Direction = Tree.Split.Direction;

const gap_size = 5;
const line_size = 1;
const min_gaps = 4;

leaves: std.ArrayList(Leaf) = .empty,
dividers: std.ArrayList(Divider) = .empty,

pub const Leaf = struct {
    surface: *Surface,
    rect: c.RECT,
};

pub const Divider = struct {
    handle: Handle,
    layout: Layout,
    rect: c.RECT,
    bounds: c.RECT,
};

pub const Parts = struct {
    left: c.RECT,
    divider: c.RECT,
    right: c.RECT,
};

pub fn deinit(self: *SplitView, alloc: Allocator) void {
    self.leaves.deinit(alloc);
    self.dividers.deinit(alloc);
    self.* = .{};
}

pub fn clear(self: *SplitView) void {
    self.leaves.clearRetainingCapacity();
    self.dividers.clearRetainingCapacity();
}

pub fn gap(dpi: c.UINT) i32 {
    return @max(1, @as(i32, @intCast(@divTrunc(gap_size * dpi, 96))));
}

fn lineWidth(dpi: c.UINT) i32 {
    return @max(1, @as(i32, @intCast(@divTrunc(line_size * dpi, 96))));
}

pub fn compute(
    self: *SplitView,
    alloc: Allocator,
    tree: *const Tree,
    rect: c.RECT,
    gap_px: i32,
) Allocator.Error!void {
    self.clear();
    if (tree.isEmpty()) return;
    try self.visit(alloc, tree, tree.zoomed orelse .root, rect, gap_px);
}

fn visit(
    self: *SplitView,
    alloc: Allocator,
    tree: *const Tree,
    handle: Handle,
    rect: c.RECT,
    gap_px: i32,
) Allocator.Error!void {
    switch (tree.nodes[handle.idx()]) {
        .leaf => |surface| try self.leaves.append(alloc, .{
            .surface = surface,
            .rect = rect,
        }),
        .split => |s| {
            const parts = splitRect(rect, s.layout, s.ratio, gap_px);
            try self.dividers.append(alloc, .{
                .handle = handle,
                .layout = s.layout,
                .rect = parts.divider,
                .bounds = rect,
            });
            try self.visit(alloc, tree, s.left, parts.left, gap_px);
            try self.visit(alloc, tree, s.right, parts.right, gap_px);
        },
    }
}

pub fn splitRect(rect: c.RECT, layout: Layout, ratio: f16, gap_px: i32) Parts {
    const start, const end = switch (layout) {
        .horizontal => .{ rect.left, rect.right },
        .vertical => .{ rect.top, rect.bottom },
    };
    const span = @max(0, end - start);
    const g = @min(gap_px, span);
    const avail = span - g;
    const r: f32 = std.math.clamp(@as(f32, ratio), 0, 1);
    const first: i32 = std.math.clamp(
        @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(avail)) * r))),
        0,
        avail,
    );
    const a = start + first;
    const b = a + g;
    return switch (layout) {
        .horizontal => .{
            .left = .{ .left = rect.left, .top = rect.top, .right = a, .bottom = rect.bottom },
            .divider = .{ .left = a, .top = rect.top, .right = b, .bottom = rect.bottom },
            .right = .{ .left = b, .top = rect.top, .right = @max(b, rect.right), .bottom = rect.bottom },
        },
        .vertical => .{
            .left = .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = a },
            .divider = .{ .left = rect.left, .top = a, .right = rect.right, .bottom = b },
            .right = .{ .left = rect.left, .top = b, .right = rect.right, .bottom = @max(b, rect.bottom) },
        },
    };
}

pub fn newRect(rect: c.RECT, direction: Direction, gap_px: i32) c.RECT {
    const layout: Layout = switch (direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };
    const parts = splitRect(rect, layout, 0.5, gap_px);
    return switch (direction) {
        .left, .up => parts.left,
        .right, .down => parts.right,
    };
}

pub fn ratioAt(divider: Divider, pt: c.POINT, gap_px: i32) f16 {
    const start, const end, const pos = switch (divider.layout) {
        .horizontal => .{ divider.bounds.left, divider.bounds.right, pt.x },
        .vertical => .{ divider.bounds.top, divider.bounds.bottom, pt.y },
    };
    const avail = end - start - gap_px;
    if (avail <= 0) return 0.5;
    const min = @min(@divTrunc(avail, 2), gap_px * min_gaps);
    const offset = std.math.clamp(pos - start - @divTrunc(gap_px, 2), min, avail - min);
    return @floatCast(@as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(avail)));
}

pub fn rectOf(self: *const SplitView, surface: *const Surface) ?c.RECT {
    for (self.leaves.items) |leaf| {
        if (leaf.surface == surface) return leaf.rect;
    }
    return null;
}

pub fn find(self: *const SplitView, handle: Handle) ?Divider {
    for (self.dividers.items) |d| {
        if (d.handle == handle) return d;
    }
    return null;
}

pub fn hit(self: *const SplitView, pt: c.POINT) ?Divider {
    for (self.dividers.items) |d| {
        if (pt.x >= d.rect.left and pt.x < d.rect.right and
            pt.y >= d.rect.top and pt.y < d.rect.bottom) return d;
    }
    return null;
}

pub fn paint(
    self: *const SplitView,
    hdc: c.HDC,
    dirty: c.RECT,
    dpi: c.UINT,
    background: c.COLORREF,
    line: c.COLORREF,
) void {
    const bg_brush = c.CreateSolidBrush(background) orelse return;
    defer _ = c.DeleteObject(bg_brush);
    _ = c.FillRect(hdc, &dirty, bg_brush);
    if (self.dividers.items.len == 0) return;
    const line_brush = c.CreateSolidBrush(line) orelse return;
    defer _ = c.DeleteObject(line_brush);
    const width = lineWidth(dpi);
    for (self.dividers.items) |d| {
        var r = d.rect;
        switch (d.layout) {
            .horizontal => {
                r.left += @divTrunc(r.right - r.left - width, 2);
                r.right = @min(r.right, r.left + width);
            },
            .vertical => {
                r.top += @divTrunc(r.bottom - r.top - width, 2);
                r.bottom = @min(r.bottom, r.top + width);
            },
        }
        _ = c.FillRect(hdc, &r, line_brush);
    }
}

pub const Positioner = struct {
    hdwp: ?c.HDWP,

    pub fn begin(count: usize) Positioner {
        return .{ .hdwp = c.BeginDeferWindowPos(@intCast(@min(count, std.math.maxInt(c_int)))) };
    }

    pub fn move(self: *Positioner, hwnd: c.HWND, rect: c.RECT, flags: c.UINT) void {
        const w = @max(0, rect.right - rect.left);
        const h = @max(0, rect.bottom - rect.top);
        if (self.hdwp) |d| {
            self.hdwp = c.DeferWindowPos(d, hwnd, null, rect.left, rect.top, w, h, flags);
            if (self.hdwp != null) return;
        }
        _ = c.SetWindowPos(hwnd, null, rect.left, rect.top, w, h, flags);
    }

    pub fn end(self: *Positioner) void {
        if (self.hdwp) |d| _ = c.EndDeferWindowPos(d);
        self.hdwp = null;
    }
};

test "splitRect horizontal" {
    const testing = std.testing;
    const parts = splitRect(.{ .left = 0, .top = 10, .right = 105, .bottom = 50 }, .horizontal, 0.5, 5);
    try testing.expectEqual(@as(i32, 50), parts.left.right);
    try testing.expectEqual(@as(i32, 50), parts.divider.left);
    try testing.expectEqual(@as(i32, 55), parts.divider.right);
    try testing.expectEqual(@as(i32, 55), parts.right.left);
    try testing.expectEqual(@as(i32, 105), parts.right.right);
    try testing.expectEqual(@as(i32, 10), parts.right.top);
}

test "splitRect vertical clamps" {
    const testing = std.testing;
    const parts = splitRect(.{ .left = 0, .top = 0, .right = 10, .bottom = 3 }, .vertical, 1, 5);
    try testing.expectEqual(@as(i32, 0), parts.left.bottom);
    try testing.expectEqual(@as(i32, 3), parts.divider.bottom);
    try testing.expectEqual(@as(i32, 3), parts.right.top);
    try testing.expectEqual(@as(i32, 3), parts.right.bottom);
}
