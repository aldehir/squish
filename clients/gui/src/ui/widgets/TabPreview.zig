//! The preview of the hidden tab whose row the mouse has rested on
//! (`Tree.preview`): a picture of its panes as they stand, scaled into a
//! popup to the right of the row, over the terminal area, its top on the
//! row's, or under a tab of the title bar's strip, and kept inside the
//! window. The picture is the
//! renderer's copy of the tab drawn in its own area (`Frame.preview`);
//! a browser pane's box is empty in it, so its page's title stands in,
//! or its picture when the browser has one.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Rect = Ui.Rect;
const Tree = Ui.Tree;

// Sizes in DIPs.
/// The popup at most, keeping the tab's aspect.
pub const max_w = 320;
pub const max_h = 240;
/// From the row's right (or a strip tab's bottom) to the popup, and
/// from the window's edges.
const offset = 8;
const margin = 8;
const radius = 6;
/// A page's stand-in: its icon, the gap to its title, the line.
const icon_size = 14;
const icon_gap = 6;
const line_height = 20;
const page_pad = 8;

/// Where the popup goes for `preview` in `window`, at the scale `source`
/// takes to fit `max_w` by `max_h` (never grown): its top on the row's,
/// or its bottom on the row's where there's no room below, and inside
/// the window either way. Below a strip tab, its left on the tab's, and
/// over the tab where there's no room under it.
pub fn place(ui: *const Ui, preview: *const Tree.Preview, window: Rect) Rect {
    const src = preview.source;
    const scale = @min(1, @min(ui.px(max_w) / src.w, ui.px(max_h) / src.h));
    const w = @round(src.w * scale);
    const h = @round(src.h * scale);
    const m = ui.px(margin);
    const anchor = preview.anchor;
    var x = anchor.right() + ui.px(offset);
    var y = anchor.y;
    switch (preview.side) {
        .right => if (y + h > window.h - m) {
            y = anchor.bottom() - h;
        },
        .below => {
            x = anchor.x;
            y = anchor.bottom() + ui.px(offset);
            if (y + h > window.h - m) y = anchor.y - ui.px(offset) - h;
        },
    }
    return .{
        .x = @round(std.math.clamp(x, m, @max(m, window.w - m - w))),
        .y = @round(std.math.clamp(y, m, @max(m, window.h - m - h))),
        .w = w,
        .h = h,
    };
}

pub fn paint(ui: *const Ui, p: *Painter, tree: *const Tree, img: ?Painter.Image) void {
    const pv = &(tree.preview orelse return);
    const src = pv.source;
    if (src.w < 1 or src.h < 1) return;
    const r = place(ui, pv, tree.frame.window);
    const rad = ui.px(radius);
    ui.paintShadowCast(p, r, rad, false);
    // Without the copy, the popup alone says the row was rested on.
    if (img) |i| p.image(i, r, rad, 1) else p.fillRounded(r, rad, ui.theme.ground);
    const k = r.w / src.w;
    for (pv.pages) |page| {
        const box: Rect = .{
            .x = r.x + (page.rect.x - src.x) * k,
            .y = r.y + (page.rect.y - src.y) * k,
            .w = page.rect.w * k,
            .h = page.rect.h * k,
        };
        if (page.still) |still| {
            p.imageIn(still, box, r, rad, 1);
            continue;
        }
        paintStandIn(ui, p, page, box);
    }
    p.strokeRounded(r, rad, ui.stroke(), ui.theme.pane_border);
}

/// The page's icon (a globe without one) and its title, centered in its
/// box, the title cut to what fits.
fn paintStandIn(ui: *const Ui, p: *Painter, page: Tree.Preview.Page, box: Rect) void {
    const font = ui.fonts.get(.tip);
    const icon = ui.px(icon_size);
    const gap = ui.px(icon_gap);
    const pad = ui.px(page_pad);
    const line_h = ui.px(line_height);
    const title_w = @min(@ceil(ui.fonts.measure(page.title, font)), @max(0, box.w - icon - gap - 2 * pad));
    const x = box.x + @round((box.w - icon - gap - title_w) / 2);
    const y = box.y + @round((box.h - line_h) / 2);
    p.pushClip(box);
    defer p.popClip();
    const icon_r: Rect = .{ .x = x, .y = y + @round((line_h - icon) / 2), .w = icon, .h = icon };
    if (page.favicon) |f| p.image(f, icon_r, 0, 1) else ui.drawIcon(p, .globe, icon_r.inset(ui.px(1), ui.px(1)), ui.theme.text_muted);
    p.text(page.title, font, .{ .x = x + icon + gap, .y = y, .w = title_w, .h = line_h }, ui.theme.text_muted);
}

test "the popup sits right of the row, its top on the row's, at the tab's aspect within its bounds" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const window: Rect = .{ .w = 1200, .h = 800 };
    // A 4:3 area goes to the full size; a wide one is bounded by width.
    const square: Tree.Preview = .{ .anchor = .{ .x = 10, .y = 300, .w = 200, .h = 28 }, .source = .{ .x = 240, .y = 36, .w = 960, .h = 720 }, .pages = &.{} };
    const r = place(&ui, &square, window);
    try std.testing.expectEqual(@as(f32, 320), r.w);
    try std.testing.expectEqual(@as(f32, 240), r.h);
    try std.testing.expectEqual(@as(f32, 210 + offset), r.x);
    try std.testing.expectEqual(@as(f32, 300), r.y);
    const wide: Tree.Preview = .{ .anchor = square.anchor, .source = .{ .w = 1600, .h = 400 }, .pages = &.{} };
    const wr = place(&ui, &wide, window);
    try std.testing.expectEqual(@as(f32, 320), wr.w);
    try std.testing.expectEqual(@as(f32, 80), wr.h);
    // A small area isn't grown. Near the bottom, the popup's bottom goes
    // on the row's instead; at the very bottom it stays in the window.
    const low: Tree.Preview = .{ .anchor = .{ .x = 10, .y = 760, .w = 200, .h = 28 }, .source = .{ .w = 100, .h = 50 }, .pages = &.{} };
    const lr = place(&ui, &low, window);
    try std.testing.expectEqual(@as(f32, 100), lr.w);
    try std.testing.expectEqual(@as(f32, 760 + 28 - 50), lr.y);
    const lowest: Tree.Preview = .{ .anchor = .{ .x = 10, .y = 790, .w = 200, .h = 28 }, .source = low.source, .pages = &.{} };
    try std.testing.expectEqual(@as(f32, 800 - margin - 50), place(&ui, &lowest, window).y);
}

test "under a strip tab, the popup's left is on the tab's, kept in the window" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const window: Rect = .{ .w = 1200, .h = 800 };
    const mid: Tree.Preview = .{ .anchor = .{ .x = 400, .y = 4, .w = 160, .h = 28 }, .source = .{ .w = 960, .h = 720 }, .pages = &.{}, .side = .below };
    const r = place(&ui, &mid, window);
    try std.testing.expectEqual(@as(f32, 400), r.x);
    try std.testing.expectEqual(@as(f32, 32 + offset), r.y);
    const edge: Tree.Preview = .{ .anchor = .{ .x = 1100, .y = 4, .w = 96, .h = 28 }, .source = mid.source, .pages = &.{}, .side = .below };
    try std.testing.expectEqual(@as(f32, 1200 - margin - 320), place(&ui, &edge, window).x);
}
