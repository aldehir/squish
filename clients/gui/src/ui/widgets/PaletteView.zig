//! A `palette`: the command palette's box, raised over everything near
//! the top of the window, centered: the query's field under a search
//! icon (with a chip naming the step, in the host step), the results
//! under it one to a row, each an icon, its label and detail with the
//! units the query matched in the accent, and at the right the key
//! that does the same; captions name the sections while the query is
//! empty. A footer names the keys. The rows are the results from the
//! palette's `scroll`, as many as fit. Layout is one function, so
//! drawing and hit testing agree.
//!
//! The file step's box goes at the pane's cursor instead (`anchor`):
//! under the cursor's row when a few rows fit there, else over it,
//! its left at the cursor's column, kept inside the pane; its rows are
//! paths, the directory part muted, directories with a muted slash,
//! and its chip names the directory searched. A pane too narrow for a
//! useful box, or a cursor off the screen, gets the centered box.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Rect = Ui.Rect;
const Id = Ui.Id;
const Color = Ui.Color;
const Palette = Ui.Palette;
const Scrollbar = Ui.Scrollbar;
const withAlpha = @import("../theme.zig").withAlpha;

// Sizes in DIPs.
const width = 600;
/// The box stays this far inside the window's sides.
const side_margin = 32;
/// Under the title bar.
const top_gap = 32;
/// Under the box, at least.
const bottom_gap = 24;
/// The file step's box: its width, how far it stays inside the pane,
/// the gap between it and the cursor's row, how many rows must fit
/// under the row for it to go there, and the narrowest pane it goes at
/// the cursor in.
const file_width = 560;
const anchor_margin = 8;
const anchor_gap = 6;
const anchor_rows = 3;
const anchor_min_pane = 240;
const radius = 10;
const search_height = 44;
const search_pad_x = 14;
const search_icon = 16;
const search_gap = 10;
const chip_height = 24;
const chip_pad_x = 8;
const chip_icon = 14;
const list_pad = 6;
const caption_height = 24;
const caption_pad_x = 10;
const row_height = 32;
const row_pad_x = 10;
const row_radius = 6;
const icon_size = 16;
/// The icon's column, before the label.
const icon_column = 26;
/// Between the label and its detail, and before the key at the right.
const detail_gap = 8;
const right_gap = 16;
const footer_height = 30;
const footer_pad_x = 14;
/// Between the footer's notes.
const footer_gap = 14;
/// The most rows laid out, whatever the window's height.
pub const max_rows = 64;

pub const Row = struct {
    /// The result's index.
    result: usize,
    rect: Rect,
    /// The caption over it, where its section starts one.
    caption: ?Rect = null,
};

pub const Layout = struct {
    box: Rect,
    /// The search icon, the chip (empty but in the host step), and the
    /// field's inner rect.
    icon: Rect,
    chip: Rect = .{},
    field: Rect,
    /// Where the rows go, and the rows from the palette's `scroll` that
    /// fit; `empty` is the line that says nothing matched.
    list: Rect,
    rows: [max_rows]Row = undefined,
    row_count: usize = 0,
    empty: Rect = .{},
    footer: Rect,
    /// The list's rows: all of them, the ones drawn, and the first.
    metrics: Scrollbar.Metrics = .{ .total = 0, .visible = 0, .start = 0 },
    /// The scrollbar along the list's right edge, while not every row
    /// fits.
    bar: ?Scrollbar.Layout = null,
    /// The box is over the cursor's row (the file step).
    above: bool = false,
};

/// The chip before the query: what the step is for, or, in the file
/// step, the directory entered under the pane's own (none at the pane's
/// own, which the prompt names), or that there's none to search.
const Chip = struct { label: []const u16, icon: Painter.Lucide, danger: bool = false };

fn chipOf(pal: *const Palette) ?Chip {
    return switch (pal.step) {
        .commands => null,
        .host => .{ .label = L("Connect to host"), .icon = .plug },
        .float_tab => .{ .label = L("Float over this tab"), .icon = .app_window },
        .file => file: {
            const st = pal.file orelse break :file null;
            if (st.reason != null) break :file .{ .label = L("no directory"), .icon = .folder, .danger = true };
            if (st.root.len == 0) break :file null;
            break :file .{ .label = st.root, .icon = .folder };
        },
    };
}

/// The anchor the box goes at, if the step has one and the pane has
/// room for it.
fn anchored(ui: *const Ui, pal: *const Palette) ?Palette.Anchor {
    if (pal.step != .file) return null;
    const a = pal.anchor orelse return null;
    if (a.pane.w < ui.px(anchor_min_pane)) return null;
    return a;
}

/// Whether the rows get captions: with an empty query, but never in
/// the file step, whose rows are all of a kind.
fn captioned(pal: *const Palette) bool {
    return pal.queryText().len == 0 and pal.step != .file;
}

/// The box for `pal` in `frame`: centered under the title bar, with
/// the rows from `pal.scroll` that fit above the window's bottom; or at
/// the pane's cursor in the file step.
pub fn layoutIn(ui: *const Ui, frame: *const Ui.Frame, pal: *const Palette) Layout {
    const f = &ui.fonts;
    const window = frame.window;
    const search_h = ui.px(search_height);
    const footer_h = ui.px(footer_height);
    const pad = ui.px(list_pad);
    const row_h = ui.px(row_height);
    const caption_h = ui.px(caption_height);
    var w = @min(ui.px(width), @max(0, window.w - 2 * ui.px(side_margin)));
    var x = window.x + @round((window.w - w) / 2);
    // Under the title bar, but up from there in a window too short for
    // a row and its caption under it.
    const least = search_h + 2 * pad + caption_h + row_h + footer_h;
    var top = @max(frame.titlebar.bottom(), @min(frame.titlebar.bottom() + ui.px(top_gap), window.bottom() - ui.px(bottom_gap) - least));
    // Room for the rows: what's under the search row and over the footer.
    var most_list = @max(row_h, window.bottom() - ui.px(bottom_gap) - top - search_h - footer_h - 2 * pad);
    // Where the box ends when it goes over the cursor's row.
    var above: ?f32 = null;
    if (anchored(ui, pal)) |a| {
        const margin = ui.px(anchor_margin);
        const gap = ui.px(anchor_gap);
        w = @min(ui.px(file_width), a.pane.w - 2 * margin);
        x = std.math.clamp(a.cell.x, a.pane.x + margin, a.pane.right() - margin - w);
        const need = search_h + 2 * pad + anchor_rows * row_h + footer_h;
        const floor = @min(a.pane.bottom() - margin, window.bottom() - ui.px(bottom_gap));
        if (a.cell.bottom() + gap + need <= floor) {
            top = a.cell.bottom() + gap;
            most_list = @max(row_h, floor - top - search_h - footer_h - 2 * pad);
        } else {
            const bottom = a.cell.y - gap;
            const ceiling = @max(a.pane.y + margin, frame.titlebar.bottom());
            top = ceiling;
            most_list = @max(row_h, bottom - ceiling - search_h - footer_h - 2 * pad);
            above = bottom;
        }
    }

    var l: Layout = .{ .box = .{}, .icon = .{}, .field = .{}, .list = .{}, .footer = .{} };
    const left = x + ui.px(search_pad_x);
    const right = x + w - ui.px(search_pad_x);
    const icon = ui.px(search_icon);
    l.icon = .{ .x = left, .y = top + @round((search_h - icon) / 2), .w = icon, .h = icon };
    var field_x = l.icon.right() + ui.px(search_gap);
    if (chipOf(pal)) |chip| {
        const label = chip.label;
        // No wider than half the box: a deep directory is cut, not the query.
        const chip_w = @min(2 * ui.px(chip_pad_x) + ui.px(chip_icon) + ui.px(6) + @ceil(f.measure(label, f.get(.section))), @max(0, (right - field_x) / 2));
        const chip_h = ui.px(chip_height);
        l.chip = .{ .x = field_x, .y = top + @round((search_h - chip_h) / 2), .w = chip_w, .h = chip_h };
        field_x = l.chip.right() + ui.px(search_gap);
    }
    l.field = .{ .x = field_x, .y = top, .w = @max(0, right - field_x), .h = search_h };

    const list_x = x + pad;
    const list_w = w - 2 * pad;
    var y = top + search_h + pad;
    const list_top = y;
    const captions = captioned(pal);
    var i = pal.scroll;
    var last_section: ?Palette.Section = null;
    while (i < pal.count() and l.row_count < max_rows) : (i += 1) {
        const e = pal.entryOf(i).?;
        var row: Row = .{ .result = i, .rect = .{} };
        var h = row_h;
        if (captions and (last_section == null or last_section.? != e.section)) {
            row.caption = .{ .x = list_x, .y = y, .w = list_w, .h = caption_h };
            h += caption_h;
        }
        if (y + h > list_top + most_list and l.row_count > 0) break;
        if (row.caption) |c| row.rect = .{ .x = list_x, .y = c.bottom(), .w = list_w, .h = row_h } else row.rect = .{ .x = list_x, .y = y, .w = list_w, .h = row_h };
        y += h;
        last_section = e.section;
        l.rows[l.row_count] = row;
        l.row_count += 1;
    }
    if (pal.count() == 0) {
        l.empty = .{ .x = list_x, .y = y, .w = list_w, .h = row_h };
        y += row_h;
    }
    // Scrolled near the end, fewer rows are left to draw than fit; the
    // box keeps the height it has from the top, with room under them.
    const full = listHeight(ui, pal, most_list);
    l.list = .{ .x = list_x, .y = list_top, .w = list_w, .h = @max(y - list_top, full) };
    l.metrics = .{ .total = pal.count(), .visible = l.row_count, .start = pal.scroll };
    y = l.list.bottom() + pad;
    l.footer = .{ .x = x, .y = y, .w = w, .h = footer_h };
    y += footer_h;
    l.box = .{ .x = x, .y = top, .w = w, .h = y - top };
    // Over the cursor: the box was laid out from the top of its room;
    // it ends at the row.
    if (above) |bottom| {
        shift(&l, bottom - l.box.bottom());
        l.above = true;
    }
    l.bar = Scrollbar.layout(ui, l.list, l.metrics, barState(ui));
    return l;
}

/// Move everything laid out `dy` down.
fn shift(l: *Layout, dy: f32) void {
    l.box.y += dy;
    l.icon.y += dy;
    l.chip.y += dy;
    l.field.y += dy;
    l.list.y += dy;
    l.empty.y += dy;
    l.footer.y += dy;
    for (l.rows[0..l.row_count]) |*row| {
        row.rect.y += dy;
        if (row.caption) |*c| c.y += dy;
    }
}

/// The height of the rows from the top of the list that fit in `most`,
/// captions included.
fn listHeight(ui: *const Ui, pal: *const Palette, most: f32) f32 {
    const row_h = ui.px(row_height);
    const caption_h = ui.px(caption_height);
    const captions = captioned(pal);
    var h: f32 = 0;
    var last_section: ?Palette.Section = null;
    var n: usize = 0;
    for (0..pal.count()) |i| {
        const e = pal.entryOf(i).?;
        var row_total = row_h;
        if (captions and (last_section == null or last_section.? != e.section)) row_total += caption_h;
        if (h + row_total > most and n > 0) break;
        h += row_total;
        n += 1;
        last_section = e.section;
    }
    return h;
}

fn barState(ui: *const Ui) Scrollbar.State {
    return Scrollbar.stateOf(ui, Id.window(.scrollbar));
}

/// Where the box goes: the node's rect.
pub fn place(ui: *const Ui, frame: *const Ui.Frame, pal: *const Palette) Rect {
    return layoutIn(ui, frame, pal).box;
}

/// How many results are drawn from `pal.scroll`, for keeping the focus
/// among them.
pub fn visibleRows(ui: *const Ui, frame: *const Ui.Frame, pal: *const Palette) usize {
    return layoutIn(ui, frame, pal).row_count;
}

/// A result's row, the field, or the box itself.
pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    const v = node.kind.palette;
    const l = layoutIn(ui, v.frame, v.palette);
    // The strip along the edge wins over the rows' right ends.
    if (l.bar != null and Scrollbar.strip(ui, l.list).contains(x, y)) return Id.window(.scrollbar);
    for (l.rows[0..l.row_count]) |row| {
        if (row.rect.contains(x, y)) return .{ .target = .{ .palette = @intCast(row.result) } };
    }
    if (l.field.contains(x, y) or l.icon.contains(x, y) or l.chip.contains(x, y)) return Id.window(.field);
    return node.id;
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    // The messages' UTF-16, made at compile time.
    @setEvalBranchQuota(4000);
    const v = node.kind.palette;
    const pal = v.palette;
    const t = &ui.theme;
    const f = &ui.fonts;
    const l = layoutIn(ui, v.frame, pal);
    const r = l.box;
    ui.paintShadow(p, r, ui.px(radius));
    ui.fillBordered(p, r, ui.px(radius), t.dialog, t.pane_border);

    // The search row.
    ui.drawIcon(p, .search, l.icon, t.text_muted);
    if (chipOf(pal)) |chip| {
        const c = l.chip;
        const tint = if (chip.danger) t.danger else t.accent;
        p.fillRounded(c, ui.px(5), withAlpha(tint, 0.14));
        const ci = ui.px(chip_icon);
        ui.drawIcon(p, chip.icon, .{ .x = c.x + ui.px(chip_pad_x), .y = c.y + @round((c.h - ci) / 2), .w = ci, .h = ci }, tint);
        const label_x = c.x + ui.px(chip_pad_x) + ci + ui.px(6);
        p.text(chip.label, f.get(.section), .{ .x = label_x, .y = c.y, .w = @max(0, c.right() - ui.px(chip_pad_x) - label_x), .h = c.h }, tint);
    }
    if (pal.query.len == 0) {
        const placeholder = switch (pal.step) {
            .commands => L("Type a command or a tab name…"),
            .host => L("[user@]host[:port]"),
            .float_tab => L("Type a tab name…"),
            .file => L("Type part of a path…"),
        };
        p.text(placeholder, f.get(.body), l.field, t.text_inactive);
    }
    ui.paintEditText(p, l.field, &pal.query, .{ .caret = v.caret, .color = t.text_strong });
    const stroke = ui.stroke();
    const divider_y = Ui.crisp(l.field.bottom(), stroke);
    p.line(r.x + stroke, divider_y, r.right() - stroke, divider_y, stroke, t.dialog_outline);

    // The rows.
    const mouse_on_list = ui.hover.target == .palette;
    for (l.rows[0..l.row_count]) |row| {
        const e = pal.entryOf(row.result).?;
        const res = pal.results.items[row.result];
        if (row.caption) |c| {
            // Low in its line, close over the rows it names.
            const lift = ui.px(6);
            p.text(Palette.caption(e.section), f.get(.section), .{ .x = c.x + ui.px(caption_pad_x), .y = c.y + lift, .w = c.w - 2 * ui.px(caption_pad_x), .h = c.h - lift }, t.text_muted);
        }
        const id: Id = .{ .target = .{ .palette = @intCast(row.result) } };
        const state = ui.buttonState(id);
        const lit = state != .rest or (!mouse_on_list and pal.focus == row.result);
        const rr = row.rect;
        if (lit) p.fillRounded(rr, ui.px(row_radius), if (state == .pressed) t.button_pressed else t.button_hover);
        const inner = rr.inset(ui.px(row_pad_x), 0);
        const color = if (lit) t.text_strong else t.text;
        if (e.icon) |icon| {
            const column: Rect = .{ .x = inner.x, .y = inner.y, .w = ui.px(icon_column), .h = inner.h };
            // Folders in the warning color, as file managers tint them.
            const tint = if (e.dir) t.warning else if (lit) t.text_strong else t.text_muted;
            ui.drawIcon(p, icon, column.center(ui.px(icon_size), ui.px(icon_size)), tint);
        }
        var right_edge = inner.right();
        if (e.right.len > 0) {
            const rw = @ceil(f.measure(e.right, f.get(.tip)));
            p.text(e.right, f.get(.tip), .{ .x = inner.right() - rw, .y = inner.y, .w = rw, .h = inner.h }, t.text_muted);
            right_edge -= rw + ui.px(right_gap);
        }
        const text_x = inner.x + ui.px(icon_column);
        const text: Rect = .{ .x = text_x, .y = inner.y, .w = @max(0, right_edge - text_x), .h = inner.h };
        p.pushClip(text);
        defer p.popClip();
        var x = text.x;
        if (pal.step == .file) {
            x += paintPath(ui, p, e, res.label_hits, x, text, color);
            continue;
        }
        x += paintMarked(ui, p, e.label, res.label_hits, x, text, .body, .body_strong, color);
        if (e.detail.len > 0) {
            x += ui.px(detail_gap);
            _ = paintMarked(ui, p, e.detail, res.detail_hits, x, text, .tip, .tip_strong, t.text_muted);
        }
    }
    if (pal.count() == 0) {
        const line = l.empty.inset(ui.px(row_pad_x) + ui.px(icon_column), 0);
        var says: []const u16 = switch (pal.step) {
            .commands => L("Nothing matches"),
            .host => L("No hosts match"),
            .float_tab => L("No tabs match"),
            .file => L("Nothing matches"),
        };
        var color = t.text_inactive;
        if (pal.step == .file) {
            if (pal.file) |st| {
                if (st.reason) |why| {
                    says = switch (why) {
                        .no_pwd => L("The shell hasn't said where it is: set up slime shell-integration"),
                        .other_host => L("The shell is on another host"),
                        .gone => L("The directory is gone"),
                    };
                    color = t.danger;
                } else if (st.scanning and st.total == 0) {
                    says = L("Scanning…");
                } else if (st.truncated) {
                    says = L("Nothing matches in what was scanned: Tab into a directory");
                    color = t.warning;
                }
            } else says = L("Scanning…");
        }
        p.text(says, f.get(.body), line, color);
    }

    if (l.bar) |bar| Scrollbar.paint(ui, p, bar, barState(ui));

    // The footer.
    const fy = Ui.crisp(l.footer.y, stroke);
    p.line(r.x + stroke, fy, r.right() - stroke, fy, stroke, t.dialog_outline);
    const foot = l.footer.inset(ui.px(footer_pad_x), 0);
    const hints: []const u16 = switch (pal.step) {
        .commands => L("↑↓ move   ↵ run   Esc close"),
        .host => L("↑↓ move   ↵ connect   Esc back"),
        .float_tab => L("↑↓ move   ↵ float   Esc back"),
        .file => if (pal.file != null and pal.file.?.reason != null) L("Esc close") else L("↑↓ move   ↵ insert   ⇥ enter dir   Esc close"),
    };
    const hints_w = @ceil(f.measure(hints, f.get(.tip)));
    p.text(hints, f.get(.tip), foot, t.text_muted);
    var buf: [64]u8 = undefined;
    var units: [64]u16 = undefined;
    const digits = count: {
        if (pal.step == .file) {
            const st = pal.file orelse break :count "";
            if (st.reason != null) break :count "";
            var w: std.Io.Writer = .fixed(&buf);
            w.print("{f} of {f}", .{ thousands(st.matched), thousands(st.total) }) catch {};
            if (st.scanning) w.writeAll(" so far…") catch {};
            break :count w.buffered();
        }
        break :count if (pal.count() == 0) "" else std.fmt.bufPrint(&buf, "{d} of {d}", .{ pal.focus + 1, pal.count() }) catch "";
    };
    const n = std.unicode.utf8ToUtf16Le(&units, digits) catch 0;
    const count = units[0..n];
    const cw = @ceil(f.measure(count, f.get(.tip)));
    p.text(count, f.get(.tip), .{ .x = foot.right() - cw, .y = foot.y, .w = cw, .h = foot.h }, t.text_muted);
    // A note on the scan, between the hints and the count, while it fits.
    if (pal.step == .file) if (pal.file) |st| if (st.reason == null) {
        const note: ?struct { text: []const u16, color: Color } = if (st.truncated)
            .{ .text = L("stopped at the scan's budget"), .color = t.warning }
        else if (st.tool == .walk)
            .{ .text = L("no fd: .gitignore not read"), .color = t.text_muted }
        else
            null;
        if (note) |nt| {
            const nw = @ceil(f.measure(nt.text, f.get(.tip)));
            const nx = foot.right() - cw - ui.px(footer_gap) - nw;
            if (nx >= foot.x + hints_w + ui.px(footer_gap)) p.text(nt.text, f.get(.tip), .{ .x = nx, .y = foot.y, .w = nw, .h = foot.h }, nt.color);
        }
    };
}

/// A count with thousands separators: 18,204.
fn thousands(n: u32) std.fmt.Alt(u32, formatThousands) {
    return .{ .data = n };
}

fn formatThousands(n: u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var digits: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable;
    for (s, 0..) |d, i| {
        if (i > 0 and (s.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(d);
    }
}

/// Draw `text` from `x` in the row `line`, the units `hits` marks in
/// the accent and `strong`, the rest in `color` and `font`. Returns the
/// width drawn.
fn paintMarked(ui: *const Ui, p: *Painter, text: []const u16, hits: Palette.Hits, x: f32, line: Rect, font: Ui.Font, strong: Ui.Font, color: Color) f32 {
    const f = &ui.fonts;
    var at = x;
    var i: usize = 0;
    while (i < text.len) {
        const marked = i < Palette.max_text and hits.isSet(i);
        var end = i + 1;
        while (end < text.len and (end < Palette.max_text and hits.isSet(end)) == marked) end += 1;
        const run = text[i..end];
        const format = f.get(if (marked) strong else font);
        const w = f.measure(run, format);
        // Laid out wider than it is, so it's never trimmed; the row clips.
        p.text(run, format, .{ .x = at, .y = line.y, .w = w + ui.px(8), .h = line.h }, if (marked) ui.theme.accent else color);
        at += w;
        i = end;
    }
    return at - x;
}

/// Draw a file step's path: the directories muted, the name in `color`,
/// the units matched in the accent throughout, and a muted slash after
/// a directory. A path wider than the row loses directories from its
/// start, behind an ellipsis, so the name stays in view. Returns the
/// width drawn.
fn paintPath(ui: *const Ui, p: *Painter, e: *const Palette.Entry, hits: Palette.Hits, x: f32, line: Rect, color: Color) f32 {
    const f = &ui.fonts;
    const t = &ui.theme;
    const split = if (std.mem.lastIndexOfScalar(u16, e.label, '/')) |i| i + 1 else 0;
    const font = f.get(.path);
    const room = line.right() - x - (if (e.dir) f.measure(L("/"), font) else 0);
    // Drop whole directories from the start until the rest fits.
    var cut: usize = 0;
    if (f.measure(e.label, font) > room) {
        const dots = f.measure(L("…/"), font);
        while (cut < split) {
            const next = (std.mem.indexOfScalarPos(u16, e.label[0..split], cut, '/') orelse break) + 1;
            cut = next;
            if (dots + f.measure(e.label[cut..], font) <= room) break;
        }
    }
    var at = x;
    if (cut > 0) {
        const dots = L("…/");
        const w = f.measure(dots, font);
        p.text(dots, font, .{ .x = at, .y = line.y, .w = w + ui.px(8), .h = line.h }, t.text_muted);
        at += w;
    }
    at += paintMarked(ui, p, e.label[cut..split], shifted(hits, cut), at, line, .path, .path_strong, t.text_muted);
    const rest = shifted(hits, split);
    at += paintMarked(ui, p, e.label[split..], rest, at, line, .path, .path_strong, color);
    if (e.dir) {
        const slash = L("/");
        const w = f.measure(slash, f.get(.path));
        p.text(slash, f.get(.path), .{ .x = at, .y = line.y, .w = w + ui.px(8), .h = line.h }, t.text_muted);
        at += w;
    }
    return at - x;
}

/// The hits from `from` on, as hits on the text from there.
fn shifted(hits: Palette.Hits, from: usize) Palette.Hits {
    var out: Palette.Hits = .empty;
    var i = from;
    while (i < Palette.max_text) : (i += 1) {
        if (hits.isSet(i)) out.set(i - from);
    }
    return out;
}

const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "the box is centered under the title bar, its rows are hit, and the rest is the box" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const frame = ui.frame(1000, 600);
    var pal: Palette = .init(std.testing.allocator);
    defer pal.deinit();
    pal.beginRebuild();
    try pal.add(.{ .label = L("cmd"), .section = .tab, .action = .{ .tab = 1 } });
    try pal.add(.{ .label = L("New tab"), .section = .command, .action = .{ .binding = .new_tab } });
    try pal.add(.{ .label = L("New workspace"), .section = .command, .action = .{ .part = Id.window(.new_tab) } });
    try pal.endRebuild();
    const l = layoutIn(&ui, &frame, &pal);
    try std.testing.expectEqual(@as(f32, width), l.box.w);
    try std.testing.expectEqual(@as(f32, 200), l.box.x);
    try std.testing.expectEqual(frame.titlebar.bottom() + top_gap, l.box.y);
    // Three rows under two captions (the query is empty), then the footer.
    try std.testing.expectEqual(@as(usize, 3), l.row_count);
    try std.testing.expect(l.rows[0].caption != null);
    try std.testing.expect(l.rows[1].caption != null);
    try std.testing.expect(l.rows[2].caption == null);
    try std.testing.expectEqual(l.rows[1].rect.bottom(), l.rows[2].rect.y);
    try std.testing.expectEqual(l.box.bottom(), l.footer.bottom());

    const node: Node = .{ .id = Id.window(.palette), .kind = .{ .palette = .{ .palette = &pal, .frame = &frame, .caret = false } }, .rect = l.box };
    try std.testing.expectEqual(Id{ .target = .{ .palette = 1 } }, hitTest(&ui, &node, l.rows[1].rect.x + 5, l.rows[1].rect.y + 5).?);
    try std.testing.expectEqual(Id.window(.field), hitTest(&ui, &node, l.field.x + 5, l.field.y + 5).?);
    try std.testing.expectEqual(Id.window(.palette), hitTest(&ui, &node, l.footer.x + 5, l.footer.y + 5).?);
    try std.testing.expectEqual(Id.window(.palette), hitTest(&ui, &node, l.rows[0].caption.?.x + 5, l.rows[0].caption.?.y + 5).?);

    // A short window shows what fits, from the scroll: here two rows,
    // each under its section's caption.
    const short = ui.frame(1000, 36 + top_gap + search_height + 2 * list_pad + footer_height + bottom_gap + 2 * caption_height + 2 * row_height);
    const fit = layoutIn(&ui, &short, &pal);
    try std.testing.expectEqual(@as(usize, 2), fit.row_count);
    try std.testing.expectEqual(@as(usize, 2), visibleRows(&ui, &short, &pal));
    // Not every row fits: a bar along the list's edge, whose strip is hit
    // before the row under it; with every row shown, none.
    try std.testing.expect(l.bar == null);
    const bar = fit.bar.?;
    try std.testing.expectEqual(fit.list.right() - 3 - 3, bar.thumb.x);
    try std.testing.expectEqual(bar.track.y, bar.thumb.y);
    const short_node: Node = .{ .id = Id.window(.palette), .kind = .{ .palette = .{ .palette = &pal, .frame = &short, .caret = false } }, .rect = fit.box };
    try std.testing.expectEqual(Id.window(.scrollbar), hitTest(&ui, &short_node, fit.list.right() - 4, fit.rows[0].rect.y + 5).?);
    try std.testing.expectEqual(Id{ .target = .{ .palette = 0 } }, hitTest(&ui, &short_node, fit.list.right() - 30, fit.rows[0].rect.y + 5).?);
    pal.scroll = 2;
    const scrolled = layoutIn(&ui, &short, &pal);
    try std.testing.expectEqual(@as(usize, 1), scrolled.row_count);
    try std.testing.expectEqual(@as(usize, 2), scrolled.rows[0].result);
    // One row left to draw, but the box keeps its height.
    try std.testing.expectEqual(fit.box.h, scrolled.box.h);
    // Too short for the box under the title bar: it moves up to fit.
    const tiny = ui.frame(1000, 36 + 20 + search_height + 2 * list_pad + footer_height + bottom_gap + caption_height + row_height);
    const up = layoutIn(&ui, &tiny, &pal);
    try std.testing.expectEqual(@as(f32, 36 + 20), up.box.y);
    try std.testing.expectEqual(tiny.window.bottom() - bottom_gap, up.box.bottom());
    // With a query, no captions.
    pal.scroll = 0;
    pal.query.insert(L("new"));
    pal.beginRebuild();
    try pal.add(.{ .label = L("New tab"), .section = .command, .action = .{ .binding = .new_tab } });
    try pal.endRebuild();
    try std.testing.expect(layoutIn(&ui, &frame, &pal).rows[0].caption == null);
    // Nothing: a line saying so.
    pal.beginRebuild();
    try pal.endRebuild();
    const none = layoutIn(&ui, &frame, &pal);
    try std.testing.expectEqual(@as(usize, 0), none.row_count);
    try std.testing.expectEqual(@as(f32, row_height), none.empty.h);
}

test "the file step's box sits under the cursor, or over it near the bottom, inside the pane" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const frame = ui.frame(1000, 600);
    var pal: Palette = .init(std.testing.allocator);
    defer pal.deinit();
    pal.setStep(.file);
    pal.beginRebuild();
    for ([_][]const u16{ L("a.zig"), L("b/c.zig"), L("d"), L("e.zig") }) |path| {
        try pal.add(.{ .label = path, .icon = .file, .section = .file, .action = .{ .insert = "x" }, .marked = .empty });
    }
    try pal.endRebuild();
    const pane: Rect = .{ .x = 200, .y = 100, .w = 800, .h = 500 };
    // Near the top: under the row, the left at the cursor's column, no
    // captions in this step.
    pal.anchor = .{ .pane = pane, .cell = .{ .x = 300, .y = 150, .w = 9, .h = 18 } };
    const below = layoutIn(&ui, &frame, &pal);
    try std.testing.expect(!below.above);
    try std.testing.expectEqual(@as(f32, 150 + 18 + anchor_gap), below.box.y);
    try std.testing.expectEqual(@as(f32, 300), below.box.x);
    try std.testing.expectEqual(@as(f32, file_width), below.box.w);
    try std.testing.expectEqual(@as(usize, 4), below.row_count);
    try std.testing.expect(below.rows[0].caption == null);
    // Near the bottom: over the row, ending the gap above it.
    pal.anchor = .{ .pane = pane, .cell = .{ .x = 300, .y = 560, .w = 9, .h = 18 } };
    const above = layoutIn(&ui, &frame, &pal);
    try std.testing.expect(above.above);
    try std.testing.expectEqual(@as(f32, 560 - anchor_gap), above.box.bottom());
    try std.testing.expectEqual(above.box.bottom(), above.footer.bottom());
    try std.testing.expectEqual(above.box.y + search_height + list_pad, above.rows[0].rect.y);
    try std.testing.expectEqual(@as(usize, 4), above.row_count);
    // At the right edge: clamped inside the pane.
    pal.anchor = .{ .pane = pane, .cell = .{ .x = 980, .y = 150, .w = 9, .h = 18 } };
    const clamped = layoutIn(&ui, &frame, &pal);
    try std.testing.expectEqual(pane.right() - anchor_margin - file_width, clamped.box.x);
    // A narrow pane: the box is as wide as fits.
    pal.anchor = .{ .pane = .{ .x = 200, .y = 100, .w = 400, .h = 500 }, .cell = .{ .x = 210, .y = 150, .w = 9, .h = 18 } };
    const narrow = layoutIn(&ui, &frame, &pal);
    try std.testing.expectEqual(@as(f32, 400 - 2 * anchor_margin), narrow.box.w);
    try std.testing.expectEqual(@as(f32, 200 + anchor_margin), narrow.box.x);
    // Too narrow, or no anchor: centered under the title bar as the
    // commands step is.
    pal.anchor = .{ .pane = .{ .x = 200, .y = 100, .w = 200, .h = 500 }, .cell = .{ .x = 210, .y = 150, .w = 9, .h = 18 } };
    const centered = layoutIn(&ui, &frame, &pal);
    try std.testing.expectEqual(@as(f32, 200), centered.box.x);
    try std.testing.expectEqual(frame.titlebar.bottom() + top_gap, centered.box.y);
    pal.anchor = null;
    try std.testing.expectEqual(@as(f32, 200), layoutIn(&ui, &frame, &pal).box.x);
    // A hit on a row over the cursor finds the row where it was drawn.
    pal.anchor = .{ .pane = pane, .cell = .{ .x = 300, .y = 560, .w = 9, .h = 18 } };
    const node: Node = .{ .id = Id.window(.palette), .kind = .{ .palette = .{ .palette = &pal, .frame = &frame, .caret = false } }, .rect = above.box };
    try std.testing.expectEqual(Id{ .target = .{ .palette = 2 } }, hitTest(&ui, &node, above.rows[2].rect.x + 5, above.rows[2].rect.y + 5).?);
}

test "hits shift with the name's start" {
    var hits: Palette.Hits = .empty;
    hits.set(0);
    hits.set(9);
    hits.set(12);
    const rest = shifted(hits, 9);
    try std.testing.expect(rest.isSet(0) and rest.isSet(3));
    try std.testing.expectEqual(@as(usize, 2), rest.count());
}
