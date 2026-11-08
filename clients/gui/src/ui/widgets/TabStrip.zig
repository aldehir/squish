//! A `tab_strip`: the title bar's row of tabs, each the same width
//! within a range. Past what fits they're scrolled sideways
//! (`TabStrip.scroll`, in pixels, which the owner keeps), clipped to the
//! strip, and the active one is brought into view as it becomes active.
//! The tabs are the builder's rows; the strip only places them, and its
//! own id is what's between them.

const std = @import("std");
const Ui = @import("../Ui.zig");

const Node = Ui.Node;
const Rect = Ui.Rect;
const Id = Ui.Id;

// Sizes in DIPs.
/// A tab's width at the least and at the most.
pub const min_tab_w = 96;
pub const max_tab_w = 220;
/// Over and under the tabs, in the bar.
pub const strip_pad_y = 4;
/// Between two tabs.
pub const item_gap = 2;

/// Place the tabs: as wide as the strip shares out, within the range,
/// from its start less the scroll, which is clamped to what they run
/// past the end, and moved to show the active tab while `reveal`.
pub fn layout(ui: *const Ui, node: *Node) void {
    const s = &node.kind.tab_strip;
    const r = node.rect;
    const n: f32 = @floatFromInt(s.items.len);
    if (s.items.len == 0) {
        s.scroll = 0;
        s.content_w = 0;
        return;
    }
    const gap = ui.px(item_gap);
    const share = @floor(@max(0, r.w - gap * (n - 1)) / n);
    const w = std.math.clamp(share, ui.px(min_tab_w), ui.px(max_tab_w));
    s.content_w = w * n + gap * (n - 1);
    const most = @max(0, @round(s.content_w - r.w));
    var scroll = std.math.clamp(@round(s.scroll), 0, most);
    if (s.reveal) if (s.active) |a| if (a < s.items.len) {
        // Rounded, as the clamp above: a strip of a fractional width
        // (a flexible share of the bar at an odd scale) would put every
        // tab on a half pixel.
        const x0 = (w + gap) * @as(f32, @floatFromInt(a));
        if (x0 < scroll) scroll = @round(x0);
        if (x0 + w > scroll + r.w) scroll = @round(x0 + w - r.w);
        scroll = std.math.clamp(scroll, 0, most);
    };
    s.scroll = scroll;
    const pad = ui.px(strip_pad_y);
    for (s.items, 0..) |*item, i| {
        const x0 = (w + gap) * @as(f32, @floatFromInt(i));
        item.rect = .{ .x = r.x - scroll + x0, .y = r.y + pad, .w = w, .h = @max(0, r.h - 2 * pad) };
        ui.layoutNode(item);
    }
}

/// The scroll `pixels` on from `node`'s, kept to what its tabs allow.
pub fn scrolledBy(node: *const Node, pixels: f32) f32 {
    const s = node.kind.tab_strip;
    const most = @max(0, @round(s.content_w - node.rect.w));
    return std.math.clamp(@round(s.scroll + pixels), 0, most);
}

/// Whether `x` is past `node`'s last tab: the strip's run that is the
/// caption's, unlike the gaps between two tabs.
pub fn pastTabs(node: *const Node, x: f32) bool {
    const s = node.kind.tab_strip;
    return x >= node.rect.x - s.scroll + s.content_w;
}

/// A tab about tab `key`, for the tests.
fn testItem(key: u32) Node {
    return .{ .id = .{ .target = .{ .tab = key } }, .kind = .{ .row = .{ .children = &.{} } } };
}

test "tabs share the strip within their range, a gap apart" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    var items = [_]Node{ testItem(1), testItem(2), testItem(3) };
    var node: Node = .{ .id = Id.window(.tab_strip), .kind = .{ .tab_strip = .{ .items = &items } }, .rect = .{ .x = 100, .y = 0, .w = 900, .h = 36 }, .clip = true };
    ui.layoutNode(&node);
    // Room for more: each at the most.
    try std.testing.expectEqual(Rect{ .x = 100, .y = strip_pad_y, .w = max_tab_w, .h = 36 - 2 * strip_pad_y }, items[0].rect);
    try std.testing.expectEqual(@as(f32, 100 + max_tab_w + item_gap), items[1].rect.x);
    try std.testing.expectEqual(@as(f32, 0), node.kind.tab_strip.scroll);
    // Hit testing finds a tab; between two is the strip; past the last,
    // the strip still, which is where it's the caption.
    try std.testing.expectEqual(Id{ .target = .{ .tab = 2 } }, ui.hitNode(&node, items[1].rect.x + 5, 10).?);
    try std.testing.expectEqual(Id.window(.tab_strip), ui.hitNode(&node, items[1].rect.x - 1, 10).?);
    try std.testing.expect(!pastTabs(&node, items[1].rect.x - 1));
    try std.testing.expectEqual(Id.window(.tab_strip), ui.hitNode(&node, 990, 10).?);
    try std.testing.expect(pastTabs(&node, 990));
    try std.testing.expect(pastTabs(&node, items[2].rect.right()));
    try std.testing.expect(!pastTabs(&node, items[2].rect.right() - 1));
    try std.testing.expect(Ui.findIn(&node, .{ .target = .{ .tab = 3 } }) != null);
}

test "tabs past the end scroll, and the active one is brought into view" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    var items: [20]Node = undefined;
    for (&items, 0..) |*it, i| it.* = testItem(@intCast(i));
    var node: Node = .{ .id = Id.window(.tab_strip), .kind = .{ .tab_strip = .{ .items = &items, .reveal = false } }, .rect = .{ .w = 600, .h = 36 }, .clip = true };
    ui.layoutNode(&node);
    const s = &node.kind.tab_strip;
    try std.testing.expectEqual(@as(f32, min_tab_w), items[0].rect.w);
    try std.testing.expectEqual(@as(f32, 20 * min_tab_w + 19 * item_gap), s.content_w);
    try std.testing.expect(s.content_w > 600);
    try std.testing.expectEqual(@as(f32, 0), s.scroll);
    // Active, the last is brought fully into view.
    s.active = 19;
    s.reveal = true;
    ui.layoutNode(&node);
    try std.testing.expectEqual(s.content_w - 600, s.scroll);
    try std.testing.expect(items[19].rect.x >= 0 and items[19].rect.right() <= 600);
    try std.testing.expectEqual(Id{ .target = .{ .tab = 19 } }, ui.hitNode(&node, 595, 10).?);
    // Scrolled out of the strip, the first is still found by id.
    try std.testing.expect(items[0].rect.right() < 0);
    try std.testing.expect(Ui.findIn(&node, .{ .target = .{ .tab = 0 } }) != null);
    // Without `reveal`, a scroll is kept, clamped to what's past the end.
    s.reveal = false;
    s.scroll = 10_000;
    ui.layoutNode(&node);
    try std.testing.expectEqual(s.content_w - 600, s.scroll);
    s.scroll = 50;
    ui.layoutNode(&node);
    try std.testing.expectEqual(@as(f32, 50), s.scroll);
    try std.testing.expectEqual(@as(f32, -50), items[0].rect.x);
    try std.testing.expectEqual(@as(f32, 49), scrolledBy(&node, -1));
    // Scrolled, the run past the tabs starts where the last one ends.
    try std.testing.expect(pastTabs(&node, items[19].rect.right()));
    try std.testing.expect(!pastTabs(&node, items[19].rect.right() - 1));
}

test "revealing in a strip of a fractional width lands the tabs on whole pixels" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    var items: [20]Node = undefined;
    for (&items, 0..) |*it, i| it.* = testItem(@intCast(i));
    var node: Node = .{ .id = Id.window(.tab_strip), .kind = .{ .tab_strip = .{ .items = &items, .active = 19, .reveal = true } }, .rect = .{ .w = 731.5, .h = 36 }, .clip = true };
    ui.layoutNode(&node);
    const s = &node.kind.tab_strip;
    try std.testing.expectEqual(@round(s.scroll), s.scroll);
    try std.testing.expectEqual(@round(items[19].rect.x), items[19].rect.x);
    try std.testing.expect(items[19].rect.right() <= 731.5 + 0.5);
    // The first likewise.
    s.active = 0;
    ui.layoutNode(&node);
    try std.testing.expectEqual(@as(f32, 0), node.kind.tab_strip.scroll);
}
