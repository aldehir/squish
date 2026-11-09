//! A `tab_strip`: the title bar's row of tabs, each the same width
//! within a range, and with `add` a button after the last one. Past what
//! fits they're scrolled sideways (`TabStrip.scroll`, in pixels, which
//! the owner keeps), clipped to the strip short of the button, which
//! stays at its end, and the active one is brought into view as it
//! becomes active. The tabs are the builder's rows; the strip only
//! places them, and its own id is what's between them.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Rect = Ui.Rect;
const Id = Ui.Id;
const Strip = @import("../Tree.zig").TabStrip;

// Sizes in DIPs.
/// A tab's width at the least and at the most.
pub const min_tab_w = 96;
pub const max_tab_w = 220;
/// Over and under the tabs, in the bar.
pub const strip_pad_y = 4;
/// Between two tabs, and between the last and the button.
pub const item_gap = 2;

/// The tabs among `s`'s items: all but the button, if any.
fn tabs(s: *const Strip) []Node {
    return if (s.add) s.items[0 .. s.items.len - 1] else s.items;
}

/// Place the tabs: as wide as the strip shares out, less the button's
/// room, within the range, from its start less the scroll, which is
/// clamped to what they run past the end, and moved to show the active
/// tab while `reveal`. The button follows the last tab, at most to the
/// strip's end.
pub fn layout(ui: *const Ui, node: *Node) void {
    const s = &node.kind.tab_strip;
    const r = node.rect;
    const gap = ui.px(item_gap);
    const pad = ui.px(strip_pad_y);
    const h = @max(0, r.h - 2 * pad);
    const add_w: f32 = if (s.add) ui.measure(&s.items[s.items.len - 1]).w orelse h else 0;
    s.view_w = if (s.add) @max(0, r.w - add_w - gap) else r.w;
    const items = tabs(s);
    if (items.len == 0) {
        s.scroll = 0;
        s.content_w = 0;
    } else {
        const n: f32 = @floatFromInt(items.len);
        const share = @floor(@max(0, s.view_w - gap * (n - 1)) / n);
        const w = std.math.clamp(share, ui.px(min_tab_w), ui.px(max_tab_w));
        s.content_w = w * n + gap * (n - 1);
        const most = @max(0, @round(s.content_w - s.view_w));
        var scroll = std.math.clamp(@round(s.scroll), 0, most);
        if (s.reveal) if (s.active) |a| if (a < items.len) {
            // Rounded, as the clamp above: a strip of a fractional width
            // (a flexible share of the bar at an odd scale) would put every
            // tab on a half pixel.
            const x0 = (w + gap) * @as(f32, @floatFromInt(a));
            if (x0 < scroll) scroll = @round(x0);
            if (x0 + w > scroll + s.view_w) scroll = @round(x0 + w - s.view_w);
            scroll = std.math.clamp(scroll, 0, most);
        };
        s.scroll = scroll;
        for (items, 0..) |*item, i| {
            const x0 = (w + gap) * @as(f32, @floatFromInt(i));
            item.rect = .{ .x = r.x - scroll + x0, .y = r.y + pad, .w = w, .h = h };
            ui.layoutNode(item);
        }
    }
    if (s.add) {
        const end = if (items.len == 0) 0 else s.content_w - s.scroll + gap;
        const add = &s.items[s.items.len - 1];
        add.rect = .{ .x = r.x + @max(0, @min(end, r.w - add_w)), .y = r.y + pad, .w = add_w, .h = h };
        ui.layoutNode(add);
    }
}

/// The tabs clipped to where they show, then the button past them.
pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    const s = &node.kind.tab_strip;
    p.pushClip(.{ .x = node.rect.x, .y = node.rect.y, .w = s.view_w, .h = node.rect.h });
    for (tabs(s)) |*item| ui.paintNode(p, item);
    p.popClip();
    if (s.add) ui.paintNode(p, &s.items[s.items.len - 1]);
}

/// The button, else past where the tabs show (a tab scrolled into the
/// button's room isn't there) the strip itself.
pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    const s = &node.kind.tab_strip;
    if (s.add) if (ui.hitNode(&s.items[s.items.len - 1], x, y)) |id| return id;
    if (x >= node.rect.x + s.view_w) return node.id;
    return null;
}

/// The scroll `pixels` on from `node`'s, kept to what its tabs allow.
pub fn scrolledBy(node: *const Node, pixels: f32) f32 {
    const s = node.kind.tab_strip;
    const most = @max(0, @round(s.content_w - s.view_w));
    return std.math.clamp(@round(s.scroll + pixels), 0, most);
}

/// Whether `x` is past `node`'s last tab (and its button): the strip's
/// run that is the caption's, unlike the gaps between two tabs.
pub fn pastTabs(node: *const Node, x: f32) bool {
    const s = &node.kind.tab_strip;
    if (s.add) return x >= s.items[s.items.len - 1].rect.right();
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

/// The button after the tabs, for the tests.
fn testAdd() Node {
    return .{ .id = Id.window(.new_tab), .kind = .{ .icon_button = .{ .icon = .plus, .size = 16, .w = 28, .h = null } } };
}

test "the button follows the last tab, and stays at the end once they scroll" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    var items = [_]Node{ testItem(1), testItem(2), testAdd() };
    var node: Node = .{ .id = Id.window(.tab_strip), .kind = .{ .tab_strip = .{ .items = &items, .add = true } }, .rect = .{ .x = 100, .y = 0, .w = 900, .h = 36 }, .clip = true };
    ui.layoutNode(&node);
    const add = items[2].rect;
    try std.testing.expectEqual(Rect{ .x = items[1].rect.right() + item_gap, .y = strip_pad_y, .w = 28, .h = 36 - 2 * strip_pad_y }, add);
    try std.testing.expectEqual(Id.window(.new_tab), ui.hitNode(&node, add.x + 5, 10).?);
    // Past the button is the caption's; the gap before it isn't.
    try std.testing.expect(!pastTabs(&node, add.x - 1));
    try std.testing.expect(!pastTabs(&node, add.right() - 1));
    try std.testing.expect(pastTabs(&node, add.right()));

    // Many tabs: they share the strip less the button's room, which is
    // at the strip's end, scrolled or not, and a tab under it isn't hit.
    var many: [21]Node = undefined;
    for (many[0..20], 0..) |*it, i| it.* = testItem(@intCast(i));
    many[20] = testAdd();
    var full: Node = .{ .id = Id.window(.tab_strip), .kind = .{ .tab_strip = .{ .items = &many, .add = true, .reveal = false } }, .rect = .{ .w = 600, .h = 36 }, .clip = true };
    ui.layoutNode(&full);
    const s = &full.kind.tab_strip;
    try std.testing.expectEqual(@as(f32, 600 - 28 - item_gap), s.view_w);
    try std.testing.expectEqual(@as(f32, 600 - 28), many[20].rect.x);
    try std.testing.expectEqual(Id.window(.new_tab), ui.hitNode(&full, 590, 10).?);
    try std.testing.expectEqual(Id.window(.tab_strip), ui.hitNode(&full, 600 - 28 - 1, 10).?);
    s.active = 19;
    s.reveal = true;
    ui.layoutNode(&full);
    try std.testing.expectEqual(s.content_w - s.view_w, s.scroll);
    try std.testing.expectEqual(s.view_w, many[19].rect.right());
    try std.testing.expectEqual(@as(f32, 600 - 28), many[20].rect.x);
    try std.testing.expectEqual(s.scroll, scrolledBy(&full, 1000));

    // No tabs: the button alone, at the start.
    var lone = [_]Node{testAdd()};
    var empty: Node = .{ .id = Id.window(.tab_strip), .kind = .{ .tab_strip = .{ .items = &lone, .add = true } }, .rect = .{ .x = 100, .w = 600, .h = 36 }, .clip = true };
    ui.layoutNode(&empty);
    try std.testing.expectEqual(@as(f32, 100), lone[0].rect.x);
}
