//! A `tree`: rows one under another, each with the rows under it set in,
//! which fold away. Rows under a row are joined to it by a guide: a
//! trunk down from the parent's fold column with a branch to each child,
//! turning into the last one with a rounded corner. Rows under a section
//! header sit flush with it, unguided. The `fold` arrow a row shows is
//! a leaf of its own, so each row colors and hit-tests its own. Rows
//! past the bottom scroll (`TreeList.scroll`, in pixels, which the
//! owner keeps), with the overlay scrollbar along the right edge.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");
const TreeRow = @import("../Tree.zig").TreeRow;
const List = @import("../Tree.zig").TreeList;

const Node = Ui.Node;
const Size = Ui.Size;
const Rect = Ui.Rect;
const Id = Ui.Id;
const Scrollbar = Ui.Scrollbar;

/// The scrollbar's id: the sidebar's, the one tree there is.
const bar_id = Id.window(.sidebar_scrollbar);

// Sizes in DIPs.
/// A wheel notch scrolls this far: three rows.
pub const wheel_notch = 3 * 28;
/// Between rows, and between a section header and the section before.
pub const row_gap = 2;
pub const section_gap = 10;
/// How far each level under a row is set in from it: past the row's
/// fold arrow, with room for the guide's branch.
pub const indent = 22;
/// The fold arrow's column at a row's left. The guide's trunk runs down
/// its middle.
pub const fold_width = 18;
/// The guide's thickness, the radius of its corner into the last child,
/// and how short of the child's row its branch stops.
const guide_width = 2;
const guide_radius = 6;
const guide_gap = 4;

pub fn measure(ui: *const Ui, node: *const Node) Size {
    return switch (node.kind) {
        .fold => .{ .w = ui.px(fold_width) },
        else => .{},
    };
}

/// Place a tree's rows from its top less its scroll. The rows' height
/// is only known once they're placed, so a scroll past what it allows
/// (rows went away) places them again, clamped.
pub fn layout(ui: *const Ui, node: *Node) void {
    switch (node.kind) {
        .tree => |*t| {
            t.scroll = @max(0, @round(t.scroll));
            t.content_h = placeRows(ui, t, node.rect);
            const most = @max(0, @round(t.content_h - node.rect.h));
            if (t.scroll > most) {
                t.scroll = most;
                _ = placeRows(ui, t, node.rect);
            }
        },
        else => {},
    }
}

/// Place `t`'s rows in `rect` less the gutter, from its top less the
/// scroll, and return their height together.
fn placeRows(ui: *const Ui, t: *const List, rect: Rect) f32 {
    const top = rect.y - t.scroll;
    var y = top;
    var bottom = top;
    layoutRows(ui, t.rows, rect.x, @max(0, rect.w - ui.px(t.gutter)), &y, &bottom);
    return bottom - top;
}

/// Place `rows` from `y` down, each as tall as it measures, and the
/// rows under each, set in, after it. `bottom` ends as the last row's,
/// without the gap after it.
fn layoutRows(ui: *const Ui, rows: []TreeRow, x: f32, w: f32, y: *f32, bottom: *f32) void {
    for (rows, 0..) |*row, i| {
        if (row.section and i > 0) y.* += ui.px(section_gap);
        const h = ui.measure(&row.node).h orelse 0;
        row.node.rect = .{ .x = x, .y = y.*, .w = w, .h = h };
        ui.layoutNode(&row.node);
        y.* += h;
        bottom.* = y.*;
        if (!row.section) y.* += ui.px(row_gap);
        if (row.folded) continue;
        const in = if (row.section) 0 else ui.px(indent);
        layoutRows(ui, row.children, x + in, @max(0, w - in), y, bottom);
    }
}

/// What a laid-out tree's scrollbar measures, in pixels: the rows'
/// height, the tree's, and the scroll. Null while every row fits.
pub fn metrics(node: *const Node) ?Scrollbar.Metrics {
    const t = node.kind.tree;
    const m: Scrollbar.Metrics = .{
        .total = @intFromFloat(@max(0, @round(t.content_h))),
        .visible = @intFromFloat(@max(0, @round(node.rect.h))),
        .start = @intFromFloat(t.scroll),
    };
    return if (Scrollbar.needed(m)) m else null;
}

/// The scrollbar along a laid-out tree's right edge, while not every
/// row fits.
pub fn bar(ui: *const Ui, node: *const Node) ?Scrollbar.Layout {
    const m = metrics(node) orelse return null;
    return Scrollbar.layout(ui, node.rect, m, Scrollbar.stateOf(ui, bar_id));
}

/// The scroll `pixels` on from `node`'s, kept to what its rows allow.
pub fn scrolledBy(node: *const Node, pixels: f32) f32 {
    const t = node.kind.tree;
    const most = @max(0, @round(t.content_h - node.rect.h));
    return std.math.clamp(@round(t.scroll + pixels), 0, most);
}

/// The strip the mouse takes hold of the scrollbar in: the gutter,
/// where there is one, which the rows keep out of; else the bar's own,
/// over the rows' right ends.
fn strip(ui: *const Ui, node: *const Node) Rect {
    const gutter = ui.px(node.kind.tree.gutter);
    if (gutter == 0) return Scrollbar.strip(ui, node.rect);
    const r = node.rect;
    return .{ .x = r.right() - gutter, .y = r.y, .w = gutter, .h = r.h };
}

/// The scrollbar's strip, then the rows.
pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    return switch (node.kind) {
        .tree => |t| {
            if (metrics(node) != null and strip(ui, node).contains(x, y)) return bar_id;
            return hitRows(ui, t.rows, x, y);
        },
        else => null,
    };
}

fn hitRows(ui: *const Ui, rows: []const TreeRow, x: f32, y: f32) ?Id {
    for (rows) |*row| {
        if (ui.hitNode(&row.node, x, y)) |id| return id;
        if (!row.folded) if (hitRows(ui, row.children, x, y)) |id| return id;
    }
    return null;
}

/// The node with `id` among `rows`, shown or folded away.
pub fn find(rows: []const TreeRow, id: Id) ?*const Node {
    for (rows) |*row| {
        if (Ui.findIn(&row.node, id)) |n| return n;
        if (find(row.children, id)) |n| return n;
    }
    return null;
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    switch (node.kind) {
        .tree => |t| {
            paintRows(ui, p, t.rows, node.rect);
            if (bar(ui, node)) |b| Scrollbar.paint(ui, p, b, Scrollbar.stateOf(ui, bar_id));
        },
        .fold => |f| {
            // Centered: down while open, right while folded.
            const area = node.rect;
            const h = ui.px(3);
            const cx = @round(area.x + area.w / 2);
            const cy = @round(area.y + area.h / 2);
            const w = ui.stroke();
            if (f.folded) {
                p.line(cx - h / 2, cy - h, cx + h / 2, cy, w, f.color);
                p.line(cx + h / 2, cy, cx - h / 2, cy + h, w, f.color);
            } else {
                p.line(cx - h, cy - h / 2, cx, cy + h / 2, w, f.color);
                p.line(cx, cy + h / 2, cx + h, cy - h / 2, w, f.color);
            }
        },
        else => {},
    }
}

/// Draw the rows within `view` (the tree's rect, which clips), and the
/// guides, which may run through it from rows outside.
fn paintRows(ui: *const Ui, p: *Painter, rows: []const TreeRow, view: Rect) void {
    for (rows) |*row| {
        const r = row.node.rect;
        if (r.bottom() > view.y and r.y < view.bottom()) ui.paintNode(p, &row.node);
        if (row.folded) continue;
        if (!row.section) paintGuides(ui, p, &row.node, row.children);
        paintRows(ui, p, row.children, view);
    }
}

/// The guides from `parent` into each of `children`: the trunk down
/// from the parent's bottom in its fold column, from child to child,
/// and a branch toward each, stopping short of it. Into the last child
/// the trunk turns with a rounded corner.
fn paintGuides(ui: *const Ui, p: *Painter, parent: *const Node, children: []const TreeRow) void {
    const w = ui.px(guide_width);
    const color = ui.theme.outline;
    const x = Ui.crisp(parent.rect.x + ui.px(fold_width) / 2, w);
    const radius = ui.px(guide_radius);
    var from = parent.rect.bottom();
    for (children, 0..) |*child, i| {
        const r = child.node.rect;
        const cy = Ui.crisp(r.y + r.h / 2, w);
        const end = r.x - ui.px(guide_gap);
        if (i + 1 == children.len) {
            p.elbow(x, from, cy, radius, end, w, color);
        } else {
            p.line(x, from, x, cy, w, color);
            p.line(x, cy, end, cy, w, color);
        }
        from = cy;
    }
}

/// A row `h` DIPs tall about `target`, for the tests.
fn testRow(id: Id, h: f32, children: []TreeRow) TreeRow {
    return .{ .node = .{ .id = id, .kind = .{ .row = .{ .children = &.{}, .h = h } } }, .children = children };
}

test "sections, rows under rows, folding, and guides" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const local: Id = .{ .target = .local };
    const hidden: Id = .{ .target = .{ .workspace = 10 } };
    const shown: Id = .{ .target = .{ .workspace = 11 } };
    const first: Id = .{ .target = .{ .tab = 1 } };
    const second: Id = .{ .target = .{ .tab = 2 } };
    const host: Id = .{ .target = .{ .host = 0 } };
    const host_tab: Id = .{ .target = .{ .tab = 3 } };
    const forgotten: Id = .{ .target = .{ .host = 1 } };

    var first_panes = [_]TreeRow{testRow(.{ .target = .{ .pane = 1 } }, 28, &.{})};
    var second_panes = [_]TreeRow{ testRow(.{ .target = .{ .pane = 2 } }, 28, &.{}), testRow(.{ .target = .{ .pane = 3 } }, 28, &.{}) };
    var shown_tabs = [_]TreeRow{ testRow(first, 30, &first_panes), testRow(second, 30, &second_panes) };
    shown_tabs[0].folded = true;
    var local_rows = [_]TreeRow{ testRow(hidden, 28, &.{}), testRow(shown, 28, &shown_tabs) };
    local_rows[0].folded = true;
    var host_panes = [_]TreeRow{testRow(.{ .target = .{ .pane = 4 } }, 28, &.{})};
    var host_tabs = [_]TreeRow{testRow(host_tab, 30, &host_panes)};
    var sections = [_]TreeRow{ testRow(local, 28, &local_rows), testRow(host, 28, &host_tabs), testRow(forgotten, 28, &.{}) };
    for (&sections) |*s| s.section = true;
    var node: Node = .{ .kind = .{ .tree = .{ .rows = &sections } }, .rect = .{ .x = 12, .y = 40, .w = 216, .h = 500 } };
    ui.layoutNode(&node);

    // Local's header, then its workspaces flush under it; the shown
    // one's tabs set in and the open tab's panes deeper still.
    const local_r = sections[0].node.rect;
    try std.testing.expectEqual(Rect{ .x = 12, .y = 40, .w = 216, .h = 28 }, local_r);
    const hidden_r = local_rows[0].node.rect;
    try std.testing.expectEqual(Rect{ .x = 12, .y = 68, .w = 216, .h = 28 }, hidden_r);
    const shown_r = local_rows[1].node.rect;
    try std.testing.expectEqual(@as(f32, 68 + 28 + row_gap), shown_r.y);
    const first_r = shown_tabs[0].node.rect;
    try std.testing.expectEqual(shown_r.x + indent, first_r.x);
    try std.testing.expectEqual(shown_r.bottom() + row_gap, first_r.y);
    try std.testing.expectEqual(@as(f32, 216 - indent), first_r.w);
    // The folded tab's panes aren't placed; the open tab's are.
    const second_r = shown_tabs[1].node.rect;
    try std.testing.expectEqual(first_r.bottom() + row_gap, second_r.y);
    const pane_r = second_panes[0].node.rect;
    try std.testing.expectEqual(second_r.x + indent, pane_r.x);
    try std.testing.expectEqual(second_r.bottom() + row_gap, pane_r.y);
    const pane2_r = second_panes[1].node.rect;
    try std.testing.expectEqual(pane_r.bottom() + row_gap, pane2_r.y);
    // The host's header after a section gap, its tab flush under it.
    const host_r = sections[1].node.rect;
    try std.testing.expectEqual(pane2_r.bottom() + row_gap + section_gap, host_r.y);
    try std.testing.expectEqual(Rect{ .x = 12, .y = host_r.bottom(), .w = 216, .h = 30 }, host_tabs[0].node.rect);
    const forgotten_r = sections[2].node.rect;
    try std.testing.expectEqual(host_panes[0].node.rect.bottom() + row_gap + section_gap, forgotten_r.y);

    // Hit testing finds rows and skips folded ones and the gaps.
    try std.testing.expectEqual(shown, hitTest(&ui, &node, shown_r.x + 2, shown_r.y + 2).?);
    try std.testing.expectEqual(Id{ .target = .{ .pane = 2 } }, hitTest(&ui, &node, pane_r.x + 40, pane_r.y + 2).?);
    try std.testing.expect(hitTest(&ui, &node, pane_r.x - 5, pane_r.y + 2) == null);
    try std.testing.expect(hitTest(&ui, &node, second_r.x + 2, host_r.y - 5) == null);
    try std.testing.expect(hitTest(&ui, &node, 100, first_r.bottom() + 20) != null);
    try std.testing.expect(find(&sections, .{ .target = .{ .pane = 1 } }) != null);
    try std.testing.expect(find(&sections, .{ .target = .{ .pane = 9 } }) == null);
}

test "rows past the bottom scroll, clamped to what's left, under a scrollbar" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    var rows: [10]TreeRow = undefined;
    for (&rows, 0..) |*r, i| r.* = testRow(.{ .target = .{ .tab = @intCast(i) } }, 28, &.{});
    var node: Node = .{ .id = Id.window(.sidebar), .kind = .{ .tree = .{ .rows = &rows } }, .rect = .{ .x = 12, .y = 40, .w = 216, .h = 100 } };
    ui.layoutNode(&node);
    // Ten rows of 28 with nine gaps of 2: 298, of which 100 show.
    try std.testing.expectEqual(@as(f32, 298), node.kind.tree.content_h);
    try std.testing.expectEqual(@as(f32, 40), rows[0].node.rect.y);
    const m = metrics(&node).?;
    try std.testing.expectEqual(Scrollbar.Metrics{ .total = 298, .visible = 100, .start = 0 }, m);
    try std.testing.expectEqual(@as(usize, 198), m.most());
    // The strip along the right edge is the bar; the rows end short of it.
    try std.testing.expectEqual(Id.window(.sidebar_scrollbar), hitTest(&ui, &node, 220, 50).?);
    try std.testing.expectEqual(Id{ .target = .{ .tab = 0 } }, hitTest(&ui, &node, 100, 50).?);
    // Scrolled, the rows move up; the first is above the top.
    try std.testing.expectEqual(@as(f32, 60), scrolledBy(&node, 60));
    try std.testing.expectEqual(@as(f32, 198), scrolledBy(&node, 1000));
    try std.testing.expectEqual(@as(f32, 0), scrolledBy(&node, -1));
    node.kind.tree.scroll = 60;
    ui.layoutNode(&node);
    try std.testing.expectEqual(@as(f32, -20), rows[0].node.rect.y);
    try std.testing.expectEqual(@as(f32, 40), rows[2].node.rect.y);
    try std.testing.expectEqual(Id{ .target = .{ .tab = 2 } }, hitTest(&ui, &node, 100, 50).?);
    // A scroll past the end (rows went away) is clamped and re-placed.
    node.kind.tree.scroll = 1000;
    ui.layoutNode(&node);
    try std.testing.expectEqual(@as(f32, 198), node.kind.tree.scroll);
    try std.testing.expectEqual(node.rect.bottom(), rows[9].node.rect.bottom());
    // Every row fitting, there's no bar, and no scroll: the strip is
    // the rows' right ends again.
    node.rect.h = 400;
    ui.layoutNode(&node);
    try std.testing.expectEqual(@as(f32, 0), node.kind.tree.scroll);
    try std.testing.expect(metrics(&node) == null);
    try std.testing.expectEqual(Id{ .target = .{ .tab = 0 } }, hitTest(&ui, &node, 220, 50).?);
    // With a gutter, the rows stop short of it, and only it is the bar.
    node.rect.h = 100;
    node.kind.tree.gutter = 8;
    ui.layoutNode(&node);
    try std.testing.expectEqual(@as(f32, 208), rows[0].node.rect.w);
    try std.testing.expectEqual(Id.window(.sidebar_scrollbar), hitTest(&ui, &node, 222, 50).?);
    try std.testing.expectEqual(Id{ .target = .{ .tab = 0 } }, hitTest(&ui, &node, 219, 50).?);
    try std.testing.expectEqual(@as(f32, 228 - 3 - 3), bar(&ui, &node).?.thumb.x);
}
