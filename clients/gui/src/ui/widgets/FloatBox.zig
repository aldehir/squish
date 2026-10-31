//! A `float`: a floating tab's box over the tab shown, bordered and
//! shadowed as a pane is; its title is bold while it has the keys. Its
//! header, along the top, holds its title and, at the right, its buttons
//! (minimize, dock, close); dragging the header moves the box, and the
//! band around it, outside the box, resizes it. Under the header its
//! panes are drawn as the terminal area's are.
//!
//! The renderer draws a float's terminals between `paintBox` and its
//! panes' strips (`Ui.paintFloat`), so they come out over the tab
//! under it and under the strips.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");
const PaneStrip = @import("PaneStrip.zig");

const Node = Ui.Node;
const Rect = Ui.Rect;
const Id = Ui.Id;

// Sizes in DIPs.
/// The header's height: a pane's title strip's.
pub const header_height = PaneStrip.title_height;
/// Before the title's icon, and between it and the title.
const title_pad = 12;
const icon_size = 14;
const icon_gap = 8;
/// Between the last button and the box's right edge.
const margin = 5;
/// How much rounder the box is than a pane.
const extra_radius = 2;

/// The box's corners.
fn radius(ui: *const Ui) f32 {
    return ui.px(ui.pane_radius + extra_radius);
}

/// The header along the box's top.
fn headerRect(ui: *const Ui, node: *const Node) Rect {
    const b = node.kind.float.box;
    return .{ .x = b.x, .y = b.y, .w = b.w, .h = @min(b.h, ui.px(header_height)) };
}

/// The buttons at the header's right, a pane's button wide each.
pub fn layout(ui: *const Ui, node: *Node) void {
    const f = node.kind.float;
    const header = headerRect(ui, node);
    const size = ui.px(PaneStrip.button_size);
    const y = header.y + @round((header.h - size) / 2);
    for (f.buttons, 0..) |*b, i| {
        const from_right: f32 = @floatFromInt(f.buttons.len - 1 - i);
        b.rect = .{ .x = header.right() - ui.px(margin) - size - from_right * size, .y = y, .w = size, .h = size };
        ui.layoutNode(b);
    }
    for (f.children) |*child| ui.layoutNode(child);
}

/// A button, else the header (which moves it), else, outside the box,
/// the band that resizes it; inside, its panes, then the box itself.
pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    const f = node.kind.float;
    for (f.buttons) |*b| if (ui.hitNode(b, x, y)) |id| return id;
    if (headerRect(ui, node).contains(x, y)) return node.id.with(.title);
    if (!f.box.contains(x, y)) return node.id.with(.edge);
    return null;
}

/// All of it, for a pass that draws the whole tree at once.
pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    paintBox(ui, p, node);
    ui.paintChildren(p, node);
}

/// The shadow, the box, and its header, under its terminals.
pub fn paintBox(ui: *const Ui, p: *Painter, node: *const Node) void {
    const f = node.kind.float;
    const t = &ui.theme;
    const r = radius(ui);
    const box = f.box;
    // The shadow and border a pane has.
    ui.paintShadow(p, box, r);
    ui.fillBordered(p, box, r, t.surface, t.pane_border);

    const header = headerRect(ui, node);
    var x = header.x + ui.px(title_pad);
    const icon = ui.px(icon_size);
    ui.drawIcon(p, .app_window, .{ .x = x, .y = header.y + @round((header.h - icon) / 2), .w = icon, .h = icon }, if (f.focused) t.accent else t.text_muted);
    x += icon + ui.px(icon_gap);
    const right = if (f.buttons.len > 0) f.buttons[0].rect.x - ui.px(6) else header.right() - ui.px(title_pad);
    const text: Rect = .{ .x = x, .y = header.y, .w = @max(0, right - x), .h = header.h };
    p.text(f.title, ui.fonts.get(if (f.focused) .body_strong else .body), text, if (f.focused) t.text_strong else t.text_muted);
    for (f.buttons) |*b| ui.paintNode(p, b);
}

fn testButton(id: Id, part: Id.Part) Node {
    return .{ .id = id.with(part), .kind = .{ .icon_button = .{ .icon = .x, .size = 13, .style = .faint } } };
}

test "a float: buttons, then its header, then its panes, and the band outside" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const id: Id = .{ .target = .{ .float = 7 } };
    var buttons = [_]Node{ testButton(id, .minimize), testButton(id, .dock), testButton(id, .close) };
    const pane: Id = .{ .target = .{ .pane = 3 } };
    var panes = [_]Node{.{ .id = pane.with(.terminal), .kind = .hit_area, .rect = .{ .x = 105, .y = 130, .w = 190, .h = 165 } }};
    var node: Node = .{ .id = id, .kind = .{ .float = .{
        .box = .{ .x = 100, .y = 100, .w = 200, .h = 200 },
        .title = &.{},
        .focused = true,
        .buttons = &buttons,
        .children = &panes,
    } }, .rect = .{ .x = 94, .y = 94, .w = 212, .h = 212 } };
    ui.layoutNode(&node);
    const close = buttons[2].rect;
    try std.testing.expectEqual(@as(f32, 300 - margin), close.right());
    try std.testing.expect(close.bottom() <= 100 + header_height);
    try std.testing.expectEqual(id.with(.close), ui.hitNode(&node, close.x + 1, close.y + 1).?);
    try std.testing.expectEqual(id.with(.minimize), ui.hitNode(&node, buttons[0].rect.x + 1, buttons[0].rect.y + 1).?);
    try std.testing.expectEqual(id.with(.title), ui.hitNode(&node, 120, 110).?);
    try std.testing.expectEqual(pane.with(.terminal), ui.hitNode(&node, 200, 200).?);
    // Between its panes and its edge, the box; outside it, the band.
    try std.testing.expectEqual(id, ui.hitNode(&node, 102, 298).?);
    try std.testing.expectEqual(id.with(.edge), ui.hitNode(&node, 96, 200).?);
    try std.testing.expectEqual(id.with(.edge), ui.hitNode(&node, 304, 304).?);
    try std.testing.expect(ui.hitNode(&node, 90, 200) == null);
}
