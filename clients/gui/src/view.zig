//! The app's state as widgets: the one place that knows both what squish
//! has (workspaces, tabs, panes, hosts) and what the UI draws (`ui/Tree`).
//! `build` makes a tree each frame, in an arena: the title bar, the
//! sidebar as a tree of sections, workspaces, tabs, and panes (or, with
//! the tabs on top, a strip of them in the title bar and the sidebar's
//! tree down to workspaces), the
//! terminal area's pane strips, the floats over them (the minimized ones
//! listed at the sidebar's bottom), a dialog over it, and a context menu
//! or the command palette over everything. What a row shows under the mouse (the buttons that
//! appear) is decided here, from the UI's hover.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const binding = @import("binding.zig");
const App = @import("App.zig");
const Hosts = @import("Hosts.zig");
const Tab = @import("Tab.zig");
const Session = @import("Session.zig");
const Placement = @import("Placement.zig");
const ProgramStatus = @import("ProgramStatus.zig");
const Painter = @import("renderer/Painter.zig");
const Ui = @import("ui/Ui.zig");
const tree = @import("ui/Tree.zig");
const TreeList = @import("ui/widgets/TreeList.zig");
const TabStrip = @import("ui/widgets/TabStrip.zig");
const PaneStrip = @import("ui/widgets/PaneStrip.zig");
const Popup = @import("ui/widgets/Popup.zig");
const PaletteView = @import("ui/widgets/PaletteView.zig");
const Web = @import("Web.zig");

const Id = Ui.Id;
const Menu = Ui.Menu;
const Tree = tree.Tree;
const Node = tree.Node;
const TreeRow = tree.TreeRow;
const Rect = Ui.Rect;
const Color = Ui.Color;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// The keys tooltips name.
/// The keys the buttons' tooltips name, from the bindings in force,
/// kept in the tree's arena since the nodes point into them.
const Labels = struct {
    new_tab: binding.Label,
    close_tab: binding.Label,
    split_right: binding.Label,
    split_down: binding.Label,
    zoom: binding.Label,

    fn of(keymap: *const binding.Keymap) Labels {
        return .{
            .new_tab = keymap.label(.new_tab),
            .close_tab = keymap.label(.close_surface),
            .split_right = keymap.label(.{ .new_split = .right }),
            .split_down = keymap.label(.{ .new_split = .down }),
            .zoom = keymap.label(.toggle_split_zoom),
        };
    }
};

// Sizes in DIPs.
const sidebar_pad_x = 12;
const sidebar_pad_top = 4;
const sidebar_pad_bottom = 12;
/// The right padding the rows' scrollbar sits in: the padding short of
/// the edge's grip.
const scrollbar_gutter = sidebar_pad_x - Ui.sidebar_edge_grip;
/// Between the rows and "Connect".
const connect_gap = 10;
const connect_height = 32;
/// The frame stats sit between the rows and "Connect", in line with the
/// section headers; this much under the rows.
const stats_gap = 10;
const header_height = 28;
const workspace_height = 28;
const tab_height = 30;
const pane_height = 28;
/// A row's buttons, from the right: the last ends this far from the
/// row's edge, with this much between buttons.
const button_margin = 5;
const button_gap = 2;
/// Between a label and the first button after it.
const label_gap = 4;

/// The tree for the app's state now.
pub fn build(app: *App, arena: Allocator) Allocator.Error!Tree {
    const labels = try arena.create(Labels);
    labels.* = .of(&app.keymap);
    var b: Builder = .{ .arena = arena, .app = app, .ui = app.ui, .frame = app.frame.*, .keys = labels };
    return b.build();
}

/// The hidden tab's preview beside the row the mouse rests on (under it,
/// for a tab in the title bar's strip), once `t` is laid out (the row's
/// place is known then): the tab's area, which the renderer copies, and
/// its browser panes, whose boxes the copy has empty. None while no
/// hidden tab's row is rested on.
pub fn preview(app: *App, arena: Allocator, t: *const Tree) Allocator.Error!?Tree.Preview {
    const tab = app.previewTab() orelse return null;
    const row = Ui.find(t, app.ui.tip) orelse return null;
    const placed = app.previewPlaced() orelse return null;
    var pages: std.ArrayList(Tree.Preview.Page) = .empty;
    for (placed.panes.items) |p| {
        const b = p.session.browser() orelse continue;
        try pages.append(arena, .{ .rect = p.rect, .title = p.session.title(), .favicon = b.favicon, .still = b.preview });
    }
    // A strip tab partly scrolled out of the strip is anchored by the
    // part of it that shows.
    const strip = Ui.find(t, .window(.tab_strip));
    const in_strip = if (strip) |s| Ui.findIn(s, app.ui.tip) != null else false;
    const anchor = if (in_strip) row.rect.intersect(strip.?.rect) else row.rect;
    return .{ .anchor = anchor, .source = app.tabArea(tab), .pages = pages.items, .side = if (in_strip) .below else .right };
}

const Builder = struct {
    arena: Allocator,
    app: *App,
    ui: *const Ui,
    frame: Ui.Frame,
    keys: *const Labels,

    fn nodes(self: *const Builder, items: []const Node) Allocator.Error![]Node {
        return self.arena.dupe(Node, items);
    }

    fn build(self: *Builder) Allocator.Error!Tree {
        var regions: std.ArrayList(Node) = .empty;
        // Fullscreen, the panes alone (and a notice, while there's one).
        if (!self.ui.fullscreen) try regions.append(self.arena, try self.titleBar());
        if (self.frame.notice.h > 0) try regions.append(self.arena, try self.notice());
        if (self.ui.sidebarVisible()) try regions.append(self.arena, try self.sidebar());
        try regions.append(self.arena, try self.terminal());
        // Each float over the panes, bottom to top.
        if (self.app.hasTabs()) {
            for (0..self.app.placed().floats.items.len) |k| try regions.append(self.arena, try self.floatNode(k));
        }
        // Over both, so the edge is taken hold of before anything under it.
        if (self.ui.sidebarVisible()) try regions.append(self.arena, self.sidebarEdge());
        if (self.dialog()) |d| try regions.append(self.arena, d);
        // A menu is over everything: the window under it is its scrim,
        // which takes the click that closes it.
        if (self.app.mode == .menu) {
            try regions.append(self.arena, .{ .id = .window(.scrim), .kind = .hit_area, .rect = self.frame.window });
            try regions.append(self.arena, self.menu(&self.app.mode.menu));
        }
        // So is the palette, which a click outside it closes.
        if (self.app.mode == .palette) {
            try regions.append(self.arena, .{ .id = .window(.scrim), .kind = .hit_area, .rect = self.frame.window });
            try regions.append(self.arena, self.palette(&self.app.mode.palette));
        }
        return .{
            .root = .{ .kind = .{ .canvas = regions.items } },
            .frame = self.frame,
            .drag = self.drag(),
        };
    }

    /// The app icon, the sidebar toggle, the active tab's title (or,
    /// with the tabs on top, the strip of them), and the caption buttons.
    /// The bar itself is the caption, which moves the window.
    fn titleBar(self: *const Builder) Allocator.Error!Node {
        const app = self.app;
        const t = &self.ui.theme;
        const maximized = app.shell.maximized();
        var children: std.ArrayList(Node) = .empty;
        try children.appendSlice(self.arena, &.{
            .{ .kind = .{ .spacer = 12 } },
            .{ .kind = .{ .icon = .{ .icon = null, .size = 18 } } },
            .{ .kind = .{ .spacer = 6 } },
            self.sidebarToggle(),
        });
        const captions = [_]Node{
            self.captionButton(.minimize, maximized),
            self.captionButton(.maximize, maximized),
            self.captionButton(.close, maximized),
        };
        if (self.ui.tabs == .top and app.hasTabs()) {
            // The strip starts in line with the panes' left edge, or just
            // past the toggle where that's further right (no sidebar); in
            // a window too narrow for that, as far right as leaves it a
            // tab's width and the button's.
            const strip = try self.tabStrip();
            const items = strip.kind.tab_strip.items;
            var lead: f32 = 0;
            for (children.items) |*c| lead += self.ui.measure(c).w.?;
            var rest = self.frame.titlebar.w - lead - self.ui.px(12);
            for (&captions) |*c| rest -= self.ui.measure(c).w.?;
            rest -= self.ui.px(TabStrip.min_tab_w) + self.ui.px(TabStrip.item_gap) + self.ui.measure(&items[items.len - 1]).w.?;
            const gap = @max(self.ui.px(4), @min(self.ui.paneArea(&self.frame).x - lead, rest));
            try children.appendSlice(self.arena, &.{
                .{ .kind = .{ .spacer = gap / self.ui.scale } },
                strip,
                // A sliver of caption past the strip, however full.
                .{ .kind = .{ .spacer = 12 } },
            });
        } else {
            const title: []const u16 = if (app.hasTabs()) app.activeTab().focus.title() else &.{};
            try children.append(self.arena, .{ .kind = .{ .label = .{ .text = title, .font = .title, .color = if (app.focused) t.text_muted else t.text_inactive, .pad_x = 8 } } });
        }
        try children.appendSlice(self.arena, &captions);
        return .{ .id = .window(.caption), .kind = .{ .row = .{ .children = children.items, .bg = t.ground } }, .rect = self.frame.titlebar };
    }

    /// The strip under the title bar that says what's wrong with the
    /// config, with a button that closes it.
    fn notice(self: *const Builder) Allocator.Error!Node {
        const t = &self.ui.theme;
        const children = try self.nodes(&.{
            .{ .kind = .{ .spacer = 14 } },
            .{ .kind = .{ .icon = .{ .icon = .shield_alert, .size = 16, .color = t.danger } } },
            .{ .kind = .{ .spacer = 10 } },
            .{ .kind = .{ .lines = .{ .text = self.app.notice, .font = .body, .color = t.text, .line_height = Ui.notice_line_height } } },
            .{ .kind = .{ .spacer = 8 } },
            .{ .id = .window(.dismiss), .kind = .{ .icon_button = .{ .icon = .x, .size = 16, .tip = L("Dismiss") } } },
            .{ .kind = .{ .spacer = 10 } },
        });
        return .{ .id = .window(.notice), .kind = .{ .row = .{ .children = children, .bg = t.notice } }, .rect = self.frame.notice };
    }

    fn sidebarToggle(self: *const Builder) Node {
        const t = &self.ui.theme;
        return .{ .id = .window(.toggle_sidebar), .kind = .{ .icon_button = .{
            .icon = .panel_left,
            .size = 20,
            .w = 40,
            .h = null,
            .style = .bar,
            .color = if (self.app.focused) t.text else t.text_inactive,
            .tip = if (self.ui.sidebar_shown) L("Hide sidebar") else L("Show sidebar"),
        } } };
    }

    /// The active workspace's tabs in the title bar: those in the group
    /// of the tab shown (a workspace, or a section's tabs in none), and
    /// the button for a new one. Floating tabs aren't listed, as in the
    /// sidebar.
    fn tabStrip(self: *const Builder) Allocator.Error!Node {
        const app = self.app;
        const t = &self.ui.theme;
        const shown = app.shownHost();
        const group = app.groupOf(shown);
        var items: std.ArrayList(Node) = .empty;
        var active: ?usize = null;
        for (app.tabs.items) |tab| {
            if (tab.float != null or app.groupOf(tab) != group) continue;
            if (tab == shown) active = items.items.len;
            try items.append(self.arena, try self.stripTab(tab));
        }
        // The active tab is brought into view as it becomes active;
        // scrolled away from after, it stays where the wheel left it.
        const key: ?u32 = if (active) |a| items.items[a].id.target.tab else null;
        // After the tabs, a button that opens one in their group.
        try items.append(self.arena, .{ .id = .window(.new_tab), .kind = .{ .icon_button = .{
            .icon = .plus,
            .size = 16,
            .w = 28,
            .h = null,
            .color = if (app.focused) t.text_muted else t.text_inactive,
            .tip = L("New tab"),
            .key = self.keys.new_tab.slice(),
        } } });
        return .{ .id = .window(.tab_strip), .kind = .{ .tab_strip = .{
            .items = items.items,
            .add = true,
            .active = active,
            .reveal = key == null or !std.meta.eql(key, self.ui.tab_strip_revealed),
            .scroll = self.ui.tab_strip_scroll,
        } }, .clip = true };
    }

    /// A tab in the strip: its icon and title, and at the right its close
    /// button while the mouse is over it; else its panes' most pressing
    /// status, or an activity dot, as a folded tab row shows. The active
    /// tab keeps the highlight.
    fn stripTab(self: *const Builder, tab: *Tab) Allocator.Error!Node {
        const app = self.app;
        const t = &self.ui.theme;
        const target: Id.Target = .{ .tab = tab.key };
        const id: Id = .{ .target = target };
        const active = app.shownHost() == tab;
        const hovered = self.ui.hover.on(target);
        var items: std.ArrayList(Node) = .empty;
        try items.append(self.arena, .{ .kind = .{ .spacer = 8 } });
        // Lucide's panels-top-left spans 18 of its 24 units: 12 DIPs here.
        try items.append(self.arena, .{ .kind = .{ .icon = .{ .icon = .panels_top_left, .size = 16, .color = if (active) t.text_strong else t.text_muted } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = 6 } });
        try items.append(self.arena, .{ .kind = .{ .label = .{
            .text = tab.focus.title(),
            .font = if (active) .body_strong else .body,
            .color = if (active) t.text_strong else t.text_muted,
        } } });
        try self.tabTrailing(&items, tab, active, hovered, mostPressing(tab));
        // A tab that's not on screen shows a picture of itself under it
        // (`Tree.preview`).
        return .{ .id = id, .kind = .{ .row = .{
            .children = items.items,
            .bg = if (hovered or active) t.row_hover else null,
            .radius = 6,
            .preview = !app.isShown(tab),
        } } };
    }

    /// What ends a tab's row, in the strip and in the sidebar: its close
    /// button while `hovered`; else `status`, the most pressing of its
    /// panes', if any; else an activity dot; else the margin alone.
    fn tabTrailing(self: *const Builder, items: *std.ArrayList(Node), tab: *const Tab, active: bool, hovered: bool, status: ?ProgramStatus.State) Allocator.Error!void {
        const id: Id = .{ .target = .{ .tab = tab.key } };
        if (hovered) {
            try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
            // Lucide's x spans 12 of its 24 units: 8 DIPs in this box.
            try items.append(self.arena, .{ .id = id.with(.close), .kind = .{ .icon_button = .{
                .icon = .x,
                .size = 16,
                .tip = L("Close tab"),
                .key = if (active) self.keys.close_tab.slice() else &.{},
            } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_margin } });
        } else if (status) |s| {
            try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
            try items.append(self.arena, .{ .kind = .{ .status = .{ .status = s, .spinner = self.app.spinner_step } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_margin } });
        } else if (tab.activity()) {
            try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
            try items.append(self.arena, .{ .kind = .{ .status = .{ .status = null, .activity = true } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_margin } });
        } else {
            try items.append(self.arena, .{ .kind = .{ .spacer = 8 } });
        }
    }

    fn captionButton(self: *const Builder, part: Id.Part, maximized: bool) Node {
        return .{ .id = .window(part), .kind = .{ .caption_button = .{ .part = part, .maximized = maximized, .focused = self.app.focused } } };
    }

    /// The sections, which scroll and take the height, then the frame
    /// stats when built with them, then "Connect" (or the host field).
    fn sidebar(self: *const Builder) Allocator.Error!Node {
        const app = self.app;
        const t = &self.ui.theme;
        const connect: Node = switch (app.mode) {
            .connect => |*f| .{ .id = .window(.connect), .kind = .{ .text_field = .{
                .field = f,
                .placeholder = L("user@host:port"),
                .caret = app.focused and app.blink_visible,
                .h = connect_height,
            } } },
            else => .{ .id = .window(.connect), .kind = .{ .button = .{ .label = L("Connect…"), .icon = .plug, .h = connect_height } } },
        };
        // The column's right padding stops at the gutter: the rows leave
        // it for their scrollbar, and the rest keep out of it themselves.
        var children: std.ArrayList(Node) = .empty;
        try children.append(self.arena, .{
            .id = .window(.sidebar),
            .kind = .{ .tree = .{ .rows = try self.sections(), .scroll = self.ui.sidebar_scroll, .gutter = scrollbar_gutter } },
            .clip = true,
        });
        if (try self.minimized()) |m| {
            try children.append(self.arena, .{ .kind = .{ .spacer = stats_gap } });
            try children.append(self.arena, m);
        }
        const stats = app.shell.stats();
        if (stats.len > 0) {
            try children.append(self.arena, .{ .kind = .{ .spacer = stats_gap } });
            // In line with the section headers' text.
            try children.append(self.arena, .{ .kind = .{ .column = .{
                .children = try self.nodes(&.{.{ .kind = .{ .lines = .{ .text = stats, .font = .mono, .color = t.text_muted } } }}),
                .pad = .{ .left = 2, .right = scrollbar_gutter },
            } } });
        }
        try children.append(self.arena, .{ .kind = .{ .spacer = connect_gap } });
        try children.append(self.arena, .{ .kind = .{ .row = .{ .children = try self.nodes(&.{connect}), .pad = .{ .right = scrollbar_gutter } } } });
        return .{ .kind = .{ .column = .{
            .children = children.items,
            .pad = .{ .left = sidebar_pad_x, .right = sidebar_pad_x - scrollbar_gutter, .top = sidebar_pad_top, .bottom = sidebar_pad_bottom },
            .bg = t.ground,
        } }, .rect = self.frame.sidebar };
    }

    /// The minimized floats, under a header of their own at the sidebar's
    /// bottom: each a row like a tab's, flush with the header,
    /// its title after a window icon, which shows it again. Null for none.
    fn minimized(self: *const Builder) Allocator.Error!?Node {
        const app = self.app;
        const t = &self.ui.theme;
        var rows: std.ArrayList(Node) = .empty;
        for (app.tabs.items) |tab| {
            const f = tab.float orelse continue;
            if (!f.minimized) continue;
            const target: Id.Target = .{ .float = tab.key };
            const hovered = self.ui.hover.on(target);
            // The icon in a row of its own, as a tab row's, so the title starts at a DIP rounded once.
            const items = try self.nodes(&.{
                .{ .kind = .{ .row = .{
                    .w = 32,
                    .children = try self.nodes(&.{
                        .{ .kind = .{ .spacer = 8 } },
                        .{ .kind = .{ .icon = .{ .icon = .app_window, .size = 16, .color = if (hovered) t.text_strong else t.text_muted } } },
                    }),
                } } },
                .{ .kind = .{ .label = .{ .text = tab.focus.title(), .color = if (hovered) t.text_strong else t.text_muted } } },
                .{ .kind = .{ .spacer = 8 } },
            });
            try rows.append(self.arena, .{
                .id = .{ .target = target, .part = .chip },
                .kind = .{ .row = .{ .children = items, .h = tab_height, .bg = if (hovered) t.row_hover else null, .radius = 6 } },
            });
        }
        if (rows.items.len == 0) return null;
        const head: Node = .{ .kind = .{ .row = .{
            .children = try self.nodes(&.{
                .{ .kind = .{ .spacer = 2 } },
                .{ .kind = .{ .label = .{ .text = L("Minimized"), .font = .section, .color = t.text_muted, .upper = true } } },
            }),
            .h = header_height,
        } } };
        const list: Node = .{ .kind = .{ .column = .{ .children = rows.items, .gap = TreeList.row_gap } } };
        return .{ .kind = .{ .column = .{ .children = try self.nodes(&.{ head, list }), .gap = TreeList.row_gap, .pad = .{ .right = scrollbar_gutter } } } };
    }

    /// The strip astride the sidebar's edge that drags its width: over
    /// the sidebar's padding and the terminal area's gap, nothing drawn.
    fn sidebarEdge(self: *const Builder) Node {
        const grip = self.ui.px(Ui.sidebar_edge_grip);
        const s = self.frame.sidebar;
        return .{ .id = .window(.sidebar_edge), .kind = .hit_area, .rect = .{ .x = s.right() - grip, .y = s.y, .w = 2 * grip, .h = s.h } };
    }

    /// Local, then each remembered host: each with its daemon's
    /// workspaces and then its tabs in no workspace (there while squish
    /// couldn't be reached, or standing in for a host's panes).
    fn sections(self: *const Builder) Allocator.Error![]TreeRow {
        const app = self.app;
        var rows: std.ArrayList(TreeRow) = .empty;
        const local = try self.sectionRows(0);
        try rows.append(self.arena, .{ .node = try self.header(.local, L("Local"), .local), .children = local, .section = true });
        for (app.hosts.items.items, 0..) |dest, h| {
            const children = try self.sectionRows(1 + h);
            const kind: HostKind = if (app.hostLive(h)) .connected else .disconnected;
            try rows.append(self.arena, .{ .node = try self.header(.{ .host = @intCast(h) }, Hosts.label(dest), kind), .children = children, .section = true });
        }
        return rows.items;
    }

    /// Section `s`'s rows: its workspaces, then its tabs in none.
    fn sectionRows(self: *const Builder, s: usize) Allocator.Error![]TreeRow {
        const app = self.app;
        var rows: std.ArrayList(TreeRow) = .empty;
        for (app.workspaces.items) |w| {
            if (app.sectionOf(w.conn) == s) try rows.append(self.arena, try self.workspaceRow(w));
        }
        // With the tabs on top, the strip lists them.
        if (self.ui.tabs == .top) return rows.items;
        const none = app.noneGroup(s);
        for (app.tabs.items) |t| {
            if (t.float == null and app.groupOf(t) == none) try rows.append(self.arena, try self.tabRow(t));
        }
        return rows.items;
    }

    const HostKind = enum {
        local,
        /// A host with a live connection, which new tabs join.
        connected,
        /// A remembered host that new tabs connect to.
        disconnected,
    };

    /// A section's header: its name in capitals, with a button at the
    /// right that makes a workspace on its daemon (a plug that connects
    /// a host first); a host nothing uses gets one to forget it while the
    /// mouse is over the header.
    fn header(self: *const Builder, target: Id.Target, label: []const u16, kind: HostKind) Allocator.Error!Node {
        const app = self.app;
        const t = &self.ui.theme;
        const id: Id = .{ .target = target };
        var items: std.ArrayList(Node) = .empty;
        try items.append(self.arena, .{ .kind = .{ .spacer = 2 } });
        try items.append(self.arena, .{ .kind = .{ .label = .{ .text = label, .font = .section, .color = t.text_muted, .upper = true } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
        // A newer build is waiting for the section's daemon.
        if (app.upgradeWaiting(if (kind == .local) null else target.host)) {
            // Lucide's circle spans 20 of its 24 units: 13 DIPs in this box.
            try items.append(self.arena, .{ .id = id.with(.upgrade), .kind = .{ .icon_button = .{ .icon = .circle_arrow_up, .size = 16, .tip = L("Upgrade squish") } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_gap } });
        }
        // A host nothing uses can be dropped from the list.
        if (kind != .local and !app.hostInUse(target.host) and self.ui.hover.on(target)) {
            // Lucide's x spans 12 of its 24 units: 8 DIPs in this box.
            try items.append(self.arena, .{ .id = id.with(.forget), .kind = .{ .icon_button = .{ .icon = .x, .size = 16, .tip = L("Forget host") } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_gap } });
        }
        const none: []const u16 = &.{};
        const tip, const key = switch (kind) {
            .local => if (app.sectionCount(0) > 0)
                .{ L("New workspace"), none }
            else
                .{ L("New tab"), if (self.activeGroupIs(target)) self.keys.new_tab.slice() else none },
            .disconnected => .{ L("Connect"), none },
            .connected => .{ L("New workspace"), none },
        };
        try items.append(self.arena, if (kind == .disconnected)
            // Lucide's plug spans 16 of its 24 units: 11 DIPs in this box,
            // about the plus's size. Its prongs land on pixel edges at
            // this size, so a half pixel moves them onto centers.
            .{ .id = id.with(.new_tab), .kind = .{ .icon_button = .{ .icon = .plug, .size = 16, .dx = 0.5, .tip = tip, .key = key } } }
        else
            // Lucide's plus spans 14 of its 24 units: 10 DIPs in this
            // box, whose odd size centers the lines on pixels.
            .{ .id = id.with(.new_tab), .kind = .{ .icon_button = .{ .icon = .plus, .size = 17, .tip = tip, .key = key } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = button_margin } });
        return .{ .id = id, .kind = .{ .row = .{ .children = items.items, .h = header_height } } };
    }

    /// Whether the active tab is in the group `target` names: a
    /// section's tabs in no workspace, or a workspace.
    fn activeGroupIs(self: *const Builder, target: Id.Target) bool {
        const app = self.app;
        if (!app.hasTabs()) return false;
        const g = app.groupOf(app.activeTab());
        return switch (target) {
            .local => g == app.noneGroup(0),
            .host => |h| g == app.noneGroup(1 + h),
            .workspace => |key| app.workspaceGroup(key) == g,
            else => false,
        };
    }

    /// Workspace `w`'s row: a fold arrow (its tabs are listed while
    /// shown; with the tabs on top, a space, and none are), its name, and at the right a button to open a tab in it,
    /// before which a hidden workspace shows how many tabs it has, and
    /// one other windows show, an eye. Hiding, renaming, and killing it
    /// are in its context menu. Being renamed, the row is the field.
    fn workspaceRow(self: *const Builder, w: App.Workspace) Allocator.Error!TreeRow {
        const app = self.app;
        const t = &self.ui.theme;
        const target: Id.Target = .{ .workspace = w.key };
        const id: Id = .{ .target = target };
        const group = app.workspaceGroup(w.key);
        const top = self.ui.tabs == .top;
        var tabs: std.ArrayList(TreeRow) = .empty;
        // Floating tabs aren't listed: they're over the tab they float
        // over, or its chips, and in the palette.
        if (!top) for (app.tabs.items) |tab| {
            if (tab.float == null and app.groupOf(tab) == group) try tabs.append(self.arena, try self.tabRow(tab));
        };

        if (app.mode == .rename and app.mode.rename.ws == w.key) {
            const children = try self.nodes(&.{
                if (top) .{ .kind = .{ .spacer = 4 } } else .{ .kind = .{ .fold = .{ .folded = !w.shown, .color = t.text_muted } } },
                .{ .id = id.with(.field), .kind = .{ .text_field = .{
                    .field = &app.mode.rename.field,
                    .placeholder = L("Workspace name"),
                    .caret = app.focused and app.blink_visible,
                } } },
            });
            return .{
                .node = .{ .id = id.with(.field), .kind = .{ .row = .{ .children = children, .h = workspace_height } } },
                .children = tabs.items,
                .folded = !w.shown,
            };
        }

        const hovered = self.ui.hover.on(target);
        // With the tabs on top, the row of the workspace whose tabs the
        // strip lists keeps the highlight.
        const active = top and self.activeGroupIs(target);
        const text = if (hovered or active) t.text_strong else if (w.shown) t.text_muted else t.text_inactive;
        var items: std.ArrayList(Node) = .empty;
        try items.append(self.arena, if (top) .{ .kind = .{ .spacer = 4 } } else .{ .kind = .{ .fold = .{ .folded = !w.shown, .color = text } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
        try items.append(self.arena, .{ .kind = .{ .label = .{ .text = w.name, .font = .body_strong, .color = text } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
        if (!w.shown and w.tabs > 0) {
            try items.append(self.arena, .{ .kind = .{ .label = .{ .text = try self.number(w.tabs), .color = t.text_inactive, .width = .{ .fit = 4 } } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_gap } });
        }
        const others = w.viewers -| @intFromBool(w.shown);
        if (others > 0) {
            // Lucide's eye spans 18 of its 24 units: about 13 DIPs in
            // this box.
            try items.append(self.arena, .{ .kind = .{ .icon = .{ .icon = .eye, .size = 17, .box = 20, .color = t.text_muted } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_gap } });
        }
        const key: []const u16 = if (self.activeGroupIs(target)) self.keys.new_tab.slice() else &.{};
        try items.append(self.arena, .{ .id = id.with(.new_tab), .kind = .{ .icon_button = .{ .icon = .plus, .size = 17, .tip = L("New tab"), .key = key } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = button_margin } });
        return .{
            .node = .{ .id = id, .kind = .{ .row = .{
                .children = items.items,
                .h = workspace_height,
                .bg = if (active or self.ui.hover.eql(id)) t.row_hover else null,
                .radius = 6,
            } } },
            .children = tabs.items,
            .folded = !w.shown,
        };
    }

    /// `n` as text.
    fn number(self: *const Builder, n: usize) Allocator.Error![]const u16 {
        var buf: [20]u8 = undefined;
        const digits = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
        const units = try self.arena.alloc(u16, digits.len);
        for (digits, units) |d, *u| u.* = d;
        return units;
    }

    /// A tab's row: a fold arrow for its panes, its icon and title, and
    /// at the right its close button while the mouse is over it; else an
    /// activity dot, or folded, its panes' most pressing status.
    fn tabRow(self: *const Builder, tab: *Tab) Allocator.Error!TreeRow {
        const app = self.app;
        const t = &self.ui.theme;
        const target: Id.Target = .{ .tab = tab.key };
        const id: Id = .{ .target = target };
        const active = app.hasTabs() and app.shownHost() == tab;
        const hovered = self.ui.hover.on(target);
        var items: std.ArrayList(Node) = .empty;
        // The fold arrow and the icon in a row of their own, so the title
        // starts at their DIPs rounded once: rounded one by one they can
        // land it a pixel off.
        try items.append(self.arena, .{
            .kind = .{
                .row = .{
                    .w = TreeList.fold_width + 24,
                    .children = try self.nodes(&.{
                        .{ .id = id.with(.fold), .kind = .{ .fold = .{
                            .folded = tab.folded,
                            .color = if (self.ui.hover.eql(id.with(.fold))) t.text_strong else t.text_muted,
                        } } },
                        // Lucide's panels-top-left spans 18 of its 24 units: 12 DIPs
                        // here.
                        .{ .kind = .{ .icon = .{ .icon = .panels_top_left, .size = 16, .color = if (active) t.text_strong else t.text_muted } } },
                    }),
                },
            },
        });
        try items.append(self.arena, .{ .kind = .{ .label = .{
            .text = tab.focus.title(),
            .font = if (active) .body_strong else .body,
            .color = if (active) t.text_strong else t.text_muted,
        } } });
        // Folded, its panes' most pressing status stands in for theirs.
        try self.tabTrailing(&items, tab, active, hovered, if (tab.folded) mostPressing(tab) else null);
        var panes: std.ArrayList(TreeRow) = .empty;
        var it = tab.iterator();
        const keys = app.hasTabs() and app.activeTab() == tab;
        while (it.next()) |s| try panes.append(self.arena, try self.paneRow(tab, s, keys));
        return .{
            .node = .{
                .id = id,
                .kind = .{
                    .row = .{
                        .children = items.items,
                        .h = tab_height,
                        // The active tab is told by its brighter text, and its
                        // focused pane's highlight; folded, it keeps the
                        // highlight itself.
                        .bg = if (hovered or (active and tab.folded)) t.row_hover else null,
                        .radius = 6,
                        // A tab that's not on screen shows a picture of
                        // itself beside the row (`Tree.preview`).
                        .preview = !app.isShown(tab),
                    },
                },
            },
            .children = panes.items,
            .folded = tab.folded,
        };
    }

    /// A pane's row under its tab: its icon and title, and what its
    /// programs report at its right.
    fn paneRow(self: *const Builder, tab: *const Tab, s: *Session, tab_active: bool) Allocator.Error!TreeRow {
        const t = &self.ui.theme;
        const id: Id = .{ .target = .{ .pane = s.id } };
        const focused = tab_active and s == tab.focus;
        const icon: Painter.Lucide = switch (s.content) {
            .terminal => .terminal,
            .browser => .globe,
        };
        const children = try self.nodes(&.{
            .{ .kind = .{ .spacer = 6 } },
            .{ .kind = .{ .icon = .{ .icon = icon, .size = 14, .color = if (focused) t.accent else t.text_muted } } },
            .{ .kind = .{ .spacer = 8 } },
            .{ .kind = .{ .label = .{ .text = s.title(), .color = if (focused) t.text_strong else t.text_muted } } },
            .{ .kind = .{ .spacer = label_gap } },
            .{ .kind = .{ .status = .{
                .status = if (s.statusSummary()) |summary| summary.state else null,
                .activity = s.activity,
                .spinner = self.app.spinner_step,
            } } },
            .{ .kind = .{ .spacer = button_margin } },
        });
        return .{ .node = .{ .id = id, .kind = .{ .row = .{
            .children = children,
            .h = pane_height,
            .bg = if (focused or self.ui.hover.eql(id)) t.row_hover else null,
            .radius = 6,
            // Its tab's preview, as the tab's own row shows.
            .preview = !self.app.isShown(tab),
        } } } };
    }

    /// The active tab's panes where the placement put them, each with
    /// its buttons, and the gaps between them; with nothing shown, what
    /// the sidebar is for.
    fn terminal(self: *const Builder) Allocator.Error!Node {
        const app = self.app;
        const t = &self.ui.theme;
        var items: std.ArrayList(Node) = .empty;
        if (app.hasTabs()) {
            const placed = app.placed();
            const end = placed.hostEnd();
            try self.paneNodes(&items, placed.panes.items[0..end.panes]);
            try self.gripNodes(&items, .{ 0, end.dividers }, .{ 0, end.corners });
        } else {
            const area = self.frame.terminal;
            const h = self.ui.px(20);
            try items.append(self.arena, .{ .kind = .{ .label = .{
                .text = if (self.ui.sidebarVisible()) L("Show a workspace from the list, or make one.") else L("No tabs. Show the sidebar to pick a workspace."),
                .font = .title,
                .color = t.text_inactive,
            } }, .rect = .{ .x = area.x, .y = area.y + @round((area.h - h) / 2), .w = area.w, .h = h } });
        }
        return .{ .kind = .{ .canvas = items.items }, .rect = self.frame.terminal, .clip = true };
    }

    /// Panes where the placement put them, each with its buttons: dimmed
    /// but the one with the keys, while more than one is shown.
    fn paneNodes(self: *const Builder, items: *std.ArrayList(Node), panes: []const Placement.Pane) Allocator.Error!void {
        const app = self.app;
        const keys = app.activeTab();
        const shown = app.placed().panes.items.len > 1;
        for (panes) |p| {
            const s = p.session;
            const tab = p.tab;
            const id: Id = .{ .target = .{ .pane = s.id } };
            const focused = tab == keys and s == tab.focus;
            const buttons = try self.paneButtons(id, s, tab, p.frame.w, tab.count() > 1);
            try items.append(self.arena, .{ .id = id.with(.terminal), .kind = .{ .pane = .{
                .title = s.title(),
                .badge = if (s.inCopyMode()) L("COPY") else &.{},
                .focused = focused,
                .dot = shown and focused,
                .dimmed = shown and !focused,
                .bg = toColor(s.background()),
                .buttons = buttons.nodes,
                .nav = buttons.nav,
                .browser = try self.browserPane(s, p),
                .search = self.searchView(s),
            } }, .rect = p.frame });
        }
    }

    /// The placement's dividers and corners in these ranges, where the
    /// mouse takes hold of them: the corners over the dividers' ends, so
    /// they win there.
    fn gripNodes(self: *const Builder, items: *std.ArrayList(Node), dividers: [2]usize, corners: [2]usize) Allocator.Error!void {
        const placed = self.app.placed();
        for (placed.dividers.items[dividers[0]..dividers[1]], dividers[0]..) |d, i| {
            try items.append(self.arena, .{ .id = .{ .target = .{ .divider = @intCast(i) } }, .kind = .hit_area, .rect = d.grip });
        }
        for (placed.corners.items[corners[0]..corners[1]], corners[0]..) |c, i| {
            try items.append(self.arena, .{ .id = .{ .target = .{ .corner = @intCast(i) } }, .kind = .hit_area, .rect = c.rect });
        }
    }

    /// Float `k` of the placement: its box and header with its buttons,
    /// its panes in it, and around it the band that resizes it, kept in
    /// the terminal area.
    fn floatNode(self: *const Builder, k: usize) Allocator.Error!Node {
        const app = self.app;
        const placed = app.placed();
        const f = placed.floats.items[k];
        const parts = placed.floatParts(k);
        var items: std.ArrayList(Node) = .empty;
        try self.paneNodes(&items, parts.panes);
        try self.gripNodes(&items, parts.dividers, parts.corners);
        const id: Id = .{ .target = .{ .float = f.tab.key } };
        // Lucide's minus spans 14 of its 24 units, the square 18, and the
        // cross 12: about 9, 11, and 8 DIPs in these boxes.
        const buttons = try self.nodes(&.{
            .{ .id = id.with(.minimize), .kind = .{ .icon_button = .{ .icon = .minus, .size = 15, .style = .faint, .tip = L("Minimize") } } },
            .{ .id = id.with(.dock), .kind = .{ .icon_button = .{ .icon = .square_arrow_down_left, .size = 14, .style = .faint, .tip = L("Dock as a tab") } } },
            .{ .id = id.with(.close), .kind = .{ .icon_button = .{ .icon = .x, .size = 16, .style = .faint, .tip = L("Close tab") } } },
        });
        const grip = app.geometry.grip;
        const area = self.frame.terminal;
        const out = f.frame.inset(-grip, -grip);
        const x0 = @max(out.x, area.x);
        const y0 = @max(out.y, area.y);
        const x1 = @min(out.right(), area.right());
        const y1 = @min(out.bottom(), area.bottom());
        return .{ .id = id, .kind = .{ .float = .{
            .box = f.frame,
            .title = f.tab.focus.title(),
            .focused = f.tab == app.activeTab(),
            .buttons = buttons,
            .children = items.items,
        } }, .rect = .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) } };
    }

    const PaneButtons = struct {
        nodes: []Node = &.{},
        /// The first this many are a browser's history buttons.
        nav: usize = 0,
    };

    /// A pane's buttons: split right and down, and zoom while the tab
    /// has several panes, if it runs in squish and is wide enough to hold
    /// them with room for some title. A browser's back, forward, and
    /// reload (stop while a page loads) come first, unlit while its
    /// browser can't use them; the strip drops them where they'd leave its
    /// URL bar too narrow.
    fn paneButtons(self: *const Builder, id: Id, s: *const Session, tab: *const Tab, frame_w: f32, several: bool) Allocator.Error!PaneButtons {
        if (s.daemonPane() == null) return .{};
        const nav: []const Id.Part = if (s.content == .browser) &.{ .back, .forward, .reload } else &.{};
        const parts: []const Id.Part = if (several) &.{ .split_right, .split_down, .zoom } else &.{ .split_right, .split_down };
        // The history buttons go first, as the strip lays them out.
        if (!PaneStrip.fits(self.ui, frame_w, parts.len)) return .{};
        const focused = s == tab.focus;
        const zoomed = tab.zoom == s;
        const buttons = try self.arena.alloc(Node, nav.len + parts.len);
        const off = self.ui.theme.text_strong;
        const web: Session.Browser = switch (s.content) {
            .browser => |br| br,
            .terminal => .{},
        };
        const live = web.live();
        for (buttons[0..nav.len], nav) |*b, part| {
            // The arrows span 14 of their 24 units, the circle 18, and
            // the cross 12: about 9, 10, and 8 DIPs in these boxes.
            const icon: Painter.Lucide, const size: f32, const tip: []const u16, const lit = switch (part) {
                .back => .{ .arrow_left, 15, L("Back"), web.can_go_back },
                .forward => .{ .arrow_right, 15, L("Forward"), web.can_go_forward },
                .reload => if (web.loading) .{ .x, 15, L("Stop"), true } else .{ .rotate_cw, 13, L("Reload"), true },
                else => unreachable,
            };
            b.* = if (live and lit)
                .{ .id = id.with(part), .kind = .{ .icon_button = .{ .icon = icon, .size = size, .style = .faint, .tip = tip } } }
            else
                .{ .id = id.with(part), .kind = .{ .icon = .{ .icon = icon, .size = size, .box = PaneStrip.button_size, .color = .{ off[0], off[1], off[2], 0.2 } } } };
        }
        for (buttons[nav.len..], parts) |*b, part| {
            const none: []const u16 = &.{};
            const icon: Painter.Lucide, const tip: []const u16, const key: []const u16 = switch (part) {
                .split_right => .{ .columns_2, L("Split right"), if (focused) self.keys.split_right.slice() else none },
                .split_down => .{ .rows_2, L("Split down"), if (focused) self.keys.split_down.slice() else none },
                .zoom => .{ if (zoomed) .minimize_2 else .maximize_2, if (zoomed) L("Unzoom") else L("Zoom"), if (focused) self.keys.zoom.slice() else none },
                else => unreachable,
            };
            // Each spans 18 of its 24 units: 10 DIPs in this box, whose
            // odd size centers the split's middle line on a pixel.
            b.* = .{ .id = id.with(part), .kind = .{ .icon_button = .{ .icon = icon, .size = 13, .style = .faint, .tip = tip, .key = key } } };
        }
        return .{ .nodes = buttons, .nav = nav.len };
    }

    /// A pane's search: the card while this window types its needle,
    /// else the pill with its count while a search is on. Null for
    /// neither.
    fn searchView(self: *const Builder, s: *Session) ?tree.SearchView {
        const app = self.app;
        const editing = app.mode == .search and app.mode.search.pane == s.id;
        const info = s.searchInfo();
        if (!editing and info == null) return null;
        // Copy mode's prompt counts nothing until Enter: it says which
        // way it searches, as tmux's does.
        if (editing) if (app.mode.search.prompt) |dir| return .{
            .field = &app.mode.search.field,
            .caret = app.focused and app.blink_visible,
            .hint = if (dir == .up) L("\u{2191} up") else L("\u{2193} down"),
        };
        const i = info orelse Session.SearchInfo{ .matches = 0, .current = 0, .partial = false };
        const typed = if (editing) app.mode.search.field.text().len > 0 else true;
        return .{
            .field = if (editing) &app.mode.search.field else null,
            .caret = editing and app.focused and app.blink_visible,
            .needle = if (editing) &.{} else s.liveSearchNeedle(),
            .matches = i.matches,
            .current = i.current,
            .partial = i.partial,
            .none = info != null and typed and i.matches == 0 and !i.partial,
        };
    }

    /// A browser pane's URL bar, and what stands in for its page under
    /// its strip: a picture of it while a float covers it. Null for a
    /// terminal.
    fn browserPane(self: *const Builder, s: *Session, placed: Placement.Pane) Allocator.Error!?tree.BrowserPane {
        const page = placed.rect;
        const url = s.pageUrl() orelse return null;
        const app = self.app;
        const editing = app.mode == .url and app.mode.url.pane == s.id;
        const b = s.browser().?;
        var ended: []const u16 = &.{};
        if (s.ended or b.failed != null) {
            const text = if (s.ended) try std.fmt.allocPrint(self.arena, "[{s}. Press any key to close.]", .{
                if (s.daemonLoss()) |loss| loss.text() else "ended",
            }) else b.failed.?;
            ended = std.unicode.utf8ToUtf16LeAlloc(self.arena, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => &.{},
            };
        }
        return .{
            .url = url,
            .field = if (editing) &app.mode.url.field else null,
            .caret = editing and app.focused and app.blink_visible,
            .page = page,
            .page_title = s.title(),
            .ended = ended,
            .live = b.live(),
            .favicon = b.favicon,
            .still = if (app.pageCovered(placed)) b.preview else null,
        };
    }

    /// The kill dialog, or the active session's login, over the
    /// terminal area.
    fn dialog(self: *const Builder) ?Node {
        const app = self.app;
        const focus_session = app.focusedSession();
        const d: *const Ui.Dialog = switch (app.mode) {
            .confirm => |*c| &c.dialog,
            else => if (focus_session) |s| (if (s.login) |l| &l.dialog else return null) else return null,
        };
        return .{ .id = .window(.scrim), .kind = .{ .dialog = .{
            .dialog = d,
            .caret = app.focused and app.blink_visible,
            .spinner = app.spinner_step,
            .terminal_bg = if (focus_session) |s| toColor(s.background()) else self.ui.theme.ground,
        } }, .rect = self.frame.terminal };
    }

    /// The open context menu's box, by its anchor, inside the window.
    fn menu(self: *const Builder, m: *const Menu) Node {
        const size = Popup.size(self.ui, m);
        return .{ .id = .window(.menu), .kind = .{ .menu = .{ .menu = m } }, .rect = Popup.place(self.ui, m, self.frame.window, size) };
    }

    /// The command palette's box, under the title bar. It places itself
    /// by the window's frame, which outlives the tree (the builder's copy
    /// doesn't).
    fn palette(self: *const Builder, p: *const Ui.Palette) Node {
        const app = self.app;
        return .{ .id = .window(.palette), .kind = .{ .palette = .{
            .palette = p,
            .frame = app.frame,
            .caret = app.focused and app.blink_visible,
        } }, .rect = PaletteView.place(self.ui, app.frame, p) };
    }

    /// A pane being dragged, once the mouse has moved enough.
    fn drag(self: *const Builder) ?Tree.Drag {
        const d = self.app.pane_drag orelse return null;
        const at = d.at orelse return null;
        const placed = self.app.placed().find(d.source);
        return .{
            .source = if (placed) |p| p.frame else null,
            .drop = if (d.drop) |drop| drop.rect else null,
            .mouse = .{ .x = @floatFromInt(at.x), .y = @floatFromInt(at.y) },
            .page = page: {
                const p = placed orelse break :page null;
                const b = d.source.browser() orelse break :page null;
                const img = b.preview orelse break :page null;
                // Where its browser shows it (`Window.placeBrowsers`).
                const r = Web.pageBounds(p.rect, self.ui.stroke());
                break :page .{ .image = img, .rect = .{
                    .x = @floatFromInt(r.left),
                    .y = @floatFromInt(r.top),
                    .w = @floatFromInt(r.right - r.left),
                    .h = @floatFromInt(r.bottom - r.top),
                } };
            },
        };
    }
};

/// The most pressing status among a tab's panes: waiting on the user,
/// then failed, working, and done. Null if none has one worth showing.
fn mostPressing(tab: *const Tab) ?ProgramStatus.State {
    var best: ?ProgramStatus.State = null;
    var best_rank: u8 = 0;
    var it = tab.iterator();
    while (it.next()) |s| {
        const summary = s.statusSummary() orelse continue;
        const r: u8 = switch (summary.state) {
            .idle => continue,
            .done => 1,
            .working => 2,
            .failed => 3,
            .blocked => 4,
        };
        if (r > best_rank) {
            best = summary.state;
            best_rank = r;
        }
    }
    return best;
}

fn toColor(c: ghostty_vt.color.RGB) Color {
    return Painter.rgb(@as(u24, c.r) << 16 | @as(u24, c.g) << 8 | c.b);
}

test "sections and their rows come in the sidebar's order, by id" {
    var shell: App.TestShell = .{};
    var t: App.TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;
    const k10 = try t.workspace(10, L("alpha"), 3, 1, false);
    const k11 = try t.workspace(11, L("beta"), 0, 2, true);
    _ = try app.hosts.add(L("ssh://devbox"));

    const built = app.view();
    const local = Ui.find(built, .{ .target = .local }).?;
    const hidden = Ui.find(built, .{ .target = .{ .workspace = k10 } }).?;
    const shown = Ui.find(built, .{ .target = .{ .workspace = k11 } }).?;
    const host = Ui.find(built, .{ .target = .{ .host = 0 } }).?;
    // Local's header, its workspaces flush under it, then the host.
    try std.testing.expectEqual(t.frame.sidebar.x + sidebar_pad_x, local.rect.x);
    try std.testing.expectEqual(t.frame.sidebar.y + sidebar_pad_top, local.rect.y);
    try std.testing.expectEqual(local.rect.bottom(), hidden.rect.y);
    try std.testing.expectEqual(local.rect.x, hidden.rect.x);
    try std.testing.expectEqual(hidden.rect.bottom() + TreeList.row_gap, shown.rect.y);
    try std.testing.expectEqual(shown.rect.bottom() + TreeList.row_gap + TreeList.section_gap, host.rect.y);
    // Each has its tab button; the host, not yet connected, a plug.
    try std.testing.expect(Ui.find(built, .{ .target = .{ .workspace = k10 }, .part = .new_tab }) != null);
    try std.testing.expectEqual(Painter.Lucide.plug, Ui.find(built, .{ .target = .{ .host = 0 }, .part = .new_tab }).?.kind.icon_button.icon);
    try std.testing.expectEqual(Painter.Lucide.plus, Ui.find(built, .{ .target = .local, .part = .new_tab }).?.kind.icon_button.icon);
    // A host nothing uses can be forgotten, once the mouse is over it.
    try std.testing.expect(Ui.find(built, .{ .target = .{ .host = 0 }, .part = .forget }) == null);
    app.ui.hover = .{ .target = .{ .host = 0 } };
    try std.testing.expect(Ui.find(app.view(), .{ .target = .{ .host = 0 }, .part = .forget }) != null);
    // A workspace's row lights under the mouse, with no buttons but its
    // tab button: its actions are in its menu.
    app.ui.hover = .{ .target = .{ .workspace = k11 } };
    const lit = app.view();
    try std.testing.expect(Ui.find(lit, .{ .target = .{ .workspace = k11 }, .part = .kill }) == null);
    try std.testing.expect(Ui.find(lit, .{ .target = .{ .workspace = k11 }, .part = .hide }) == null);
    // Hit testing finds the row and its button where they are.
    const plus = Ui.find(lit, .{ .target = .{ .workspace = k11 }, .part = .new_tab }).?;
    try std.testing.expectEqual(Id{ .target = .{ .workspace = k11 }, .part = .new_tab }, app.ui.hitTest(lit, plus.rect.x + 1, plus.rect.y + 1));
    // (`shown` was in the tree before this one, which the arena dropped.)
    const shown_lit = Ui.find(lit, .{ .target = .{ .workspace = k11 } }).?;
    try std.testing.expectEqual(Id{ .target = .{ .workspace = k11 } }, app.ui.hitTest(lit, shown_lit.rect.x + 25, shown_lit.rect.y + 2));
    try std.testing.expectEqual(Id.window(.connect), app.ui.hitTest(lit, t.frame.sidebar.x + 20, t.frame.sidebar.bottom() - sidebar_pad_bottom - 5));
    // With nothing shown, the terminal area says what the sidebar is for.
    try std.testing.expectEqual(Id.none, app.ui.hitTest(lit, t.frame.terminal.x + 100, t.frame.terminal.y + 100));
}

test "the rows end above the frame stats, which sit above Connect" {
    var shell: App.TestShell = .{};
    var t: App.TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;
    _ = try t.workspace(10, L("alpha"), 0, 1, false);
    // Without stats, the rows run down to the gap over Connect.
    const plain = app.view();
    // (Copied: the next view's arena drops these nodes.)
    const connect = Ui.find(plain, Id.window(.connect)).?.rect;
    const rows = Ui.find(plain, Id.window(.sidebar)).?.rect;
    try std.testing.expectEqual(t.frame.sidebar.y + sidebar_pad_top, rows.y);
    try std.testing.expectEqual(connect.y - connect_gap, rows.bottom());
    try std.testing.expectEqual(t.frame.sidebar.bottom() - sidebar_pad_bottom, connect.bottom());
    // With them, the rows stop short of the stats' two lines, which
    // keep the same place over Connect.
    shell.stats_text = L("60 fps\n0.0 MB/s");
    const stats = app.view();
    const connect_s = Ui.find(stats, Id.window(.connect)).?;
    const rows_s = Ui.find(stats, Id.window(.sidebar)).?;
    try std.testing.expectEqual(connect, connect_s.rect);
    try std.testing.expectEqual(connect_s.rect.y - connect_gap - 2 * 16 - stats_gap, rows_s.rect.bottom());
    try std.testing.expectEqual(rows.y, rows_s.rect.y);
}

test "a context menu is over everything, and the window under it is scrim" {
    var shell: App.TestShell = .{};
    var t: App.TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;
    const key = try t.workspace(5, L("alpha"), 0, 1, true);
    var m: Menu = .{ .target = .{ .workspace = key }, .anchor = .{ .point = .{ .x = 100, .y = 100 } } };
    m.add(.{ .label = L("New tab"), .action = .{ .part = .new_tab } });
    m.add(.{ .label = L("Kill"), .action = .{ .part = .kill }, .danger = true });
    try std.testing.expect(!app.ui.hasOver(app.view()));
    app.mode = .{ .menu = m };
    const built = app.view();
    // Drawn over what the renderer shows of its own, as a browser pane.
    try std.testing.expect(app.ui.hasOver(built));
    const box = Ui.find(built, .window(.menu)).?;
    try std.testing.expectEqual(@as(f32, 100), box.rect.x);
    try std.testing.expectEqual(@as(f32, 100), box.rect.y);
    try std.testing.expectEqual(Id{ .target = .{ .menu = 0 } }, app.ui.hitTest(built, box.rect.x + 20, box.rect.y + 10));
    try std.testing.expectEqual(Id{ .target = .{ .menu = 1 } }, app.ui.hitTest(built, box.rect.x + 20, box.rect.bottom() - 10));
    // The row it's about, and the title bar, are under the scrim.
    const row = Ui.find(built, .{ .target = .{ .workspace = key } }).?;
    try std.testing.expectEqual(Id.window(.scrim), app.ui.hitTest(built, row.rect.x + 2, row.rect.y + 2));
    try std.testing.expectEqual(Id.window(.scrim), app.ui.hitTest(built, 500, 5));
}

test "the command palette is over everything, and the window under it is scrim" {
    var shell: App.TestShell = .{};
    var t: App.TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;
    const key = try t.workspace(5, L("alpha"), 2, 0, false);
    app.openPalette();
    const built = app.view();
    try std.testing.expect(app.ui.hasOver(built));
    const box = Ui.find(built, .window(.palette)).?;
    // Centered under the title bar.
    try std.testing.expectEqual(t.frame.titlebar.bottom() + 32, box.rect.y);
    try std.testing.expectEqual(@as(f32, 200), box.rect.x);
    // The hidden workspace is listed, with the commands after it.
    const pal = &app.mode.palette;
    try std.testing.expect(pal.count() > 1);
    try std.testing.expectEqual(Ui.Palette.Action{ .show_workspace = key }, pal.entryOf(0).?.action);
    try std.testing.expectEqual(Id{ .target = .{ .palette = 0 } }, app.ui.hitTest(built, box.rect.x + 40, box.rect.y + 44 + 6 + 24 + 10));
    // The row it's about, and the title bar, are under the scrim.
    const row = Ui.find(built, .{ .target = .{ .workspace = key } }).?;
    try std.testing.expectEqual(Id.window(.scrim), app.ui.hitTest(built, row.rect.x + 2, row.rect.y + 2));
    try std.testing.expectEqual(Id.window(.scrim), app.ui.hitTest(built, 500, 5));
    app.closePalette();
    try std.testing.expect(!app.ui.hasOver(app.view()));
}

test "a workspace being renamed is all field" {
    var shell: App.TestShell = .{};
    var t: App.TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;
    const key = try t.workspace(5, L("alpha"), 0, 1, true);
    app.mode = .{ .rename = .{ .ws = key, .field = .{} } };
    const built = app.view();
    const field_id: Id = .{ .target = .{ .workspace = key }, .part = .field };
    const row = Ui.find(built, field_id).?;
    try std.testing.expectEqual(field_id, app.ui.hitTest(built, row.rect.x + 2, row.rect.y + 2));
    try std.testing.expectEqual(field_id, app.ui.hitTest(built, row.rect.right() - 10, row.rect.y + 5));
    try std.testing.expect(Ui.find(built, .{ .target = .{ .workspace = key }, .part = .new_tab }) == null);
}
