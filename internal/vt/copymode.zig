//! Copy mode: tmux's, with its vi keys. Entering takes a snapshot of the
//! pane, as tmux's does: a terminal of copy mode's own, holding a clone
//! of the screen and its scrollback, which frames show while the mode is
//! on. The keys move a cursor over it, select in it, and search it; the
//! program's output goes on into the pane's terminal unseen until the
//! mode ends. A resize reflows the snapshot with the pane.
//!
//! The keys are tmux's copy-mode-vi table (its `send -X` command names,
//! with underscores; tmux's spelling with hyphens binds too), which
//! init.lua rebinds with slime.bind("copy-mode:v", "begin_selection");
//! the daemon hands the result to `Table.apply`. A key is the character
//! it types ("v", "G", "$"), a name (escape, enter, space, tab,
//! backspace, up, down, left, right, home, end, pageup, pagedown, delete,
//! insert), or ctrl with a key ("ctrl+v"). Digits count: "3w" is three
//! words.
//!
//! The motions are tmux's (window-copy.c, grid-reader.c) over the
//! snapshot's rows: words split at tmux's `word-separators`, `0 ^ $`,
//! `f t F T` and `%` take a wrapped line as one, and the cursor never
//! sits past a row's last character. Search (`/ ?` ask the window for a
//! needle, `n N` repeat) is tmux's too: it runs when the needle is
//! entered, not as it's typed, ignores case for an all-lowercase needle,
//! starts from the cursor, wraps at the ends, and lands on a match's
//! start; every match is marked, the one under the cursor as current.
//! The needle outlives the mode, so the next one's `n` searches up for
//! it, as tmux's does.

const std = @import("std");
const vt = @import("root");
const search = @import("search.zig");

const Terminal = vt.Terminal;
const Screen = vt.Screen;
const PageList = vt.PageList;
const Pin = vt.Pin;
const Selection = vt.Selection;
const Cell = vt.Cell;
const RenderState = vt.RenderState;
const KeyEvent = vt.input.KeyEvent;
const Key = vt.input.Key;

const alloc = std.heap.smp_allocator;

/// What a key does: tmux's copy-mode commands.
pub const Action = enum {
    begin_selection,
    select_line,
    rectangle_toggle,
    other_end,
    clear_selection,
    cancel,
    copy_selection,
    copy_selection_and_cancel,
    copy_end_of_line,
    copy_end_of_line_and_cancel,
    cursor_left,
    cursor_right,
    cursor_up,
    cursor_down,
    start_of_line,
    back_to_indentation,
    end_of_line,
    top_line,
    middle_line,
    bottom_line,
    history_top,
    history_bottom,
    next_word,
    next_word_end,
    previous_word,
    next_space,
    next_space_end,
    previous_space,
    next_paragraph,
    previous_paragraph,
    next_matching_bracket,
    previous_matching_bracket,
    page_up,
    page_down,
    halfpage_up,
    halfpage_down,
    scroll_up,
    scroll_down,
    scroll_middle,
    jump_forward,
    jump_backward,
    jump_to_forward,
    jump_to_backward,
    jump_again,
    jump_reverse,
    /// Ask the window for a needle (tmux's / and ?, which prompt and then
    /// run search-forward or search-backward).
    search_forward,
    search_backward,
    search_again,
    search_reverse,
    /// The word under the cursor, down or up (tmux's * and #).
    search_word_forward,
    search_word_backward,
};

/// tmux's names for commands that do what one of ours does: a copy-pipe
/// with no command is a copy.
const aliases = .{
    .{ "copy_pipe", Action.copy_selection },
    .{ "copy_pipe_and_cancel", Action.copy_selection_and_cancel },
    .{ "copy_pipe_end_of_line", Action.copy_end_of_line },
    .{ "copy_pipe_end_of_line_and_cancel", Action.copy_end_of_line_and_cancel },
};

/// The action a name is: ours, or tmux's with hyphens or an alias.
pub fn actionNamed(name: []const u8) ?Action {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    const n = buf[0..name.len];
    for (name, n) |c, *d| d.* = if (c == '-') '_' else c;
    if (std.meta.stringToEnum(Action, n)) |a| return a;
    inline for (aliases) |pair| {
        if (std.mem.eql(u8, n, pair[0])) return pair[1];
    }
    return null;
}

/// A key as the table names it.
pub const Trigger = union(enum) {
    /// The character the key types, shift included: "G" is shift+g.
    char: u21,
    /// Ctrl with the key's unshifted character.
    ctrl: u21,
    named: Named,

    pub const Named = enum {
        escape,
        enter,
        tab,
        backspace,
        space,
        up,
        down,
        left,
        right,
        home,
        end,
        pageup,
        pagedown,
        delete,
        insert,
    };

    pub fn eql(a: Trigger, b: Trigger) bool {
        return std.meta.eql(a, b);
    }

    /// Parse a spec: "ctrl+" (or "shift+", which the character carries)
    /// then a name or one character. Null if it's none.
    pub fn parse(spec: []const u8) ?Trigger {
        var s = spec;
        var ctrl = false;
        while (s.len > 1) {
            const i = std.mem.indexOfScalar(u8, s, '+') orelse break;
            if (i == 0) break;
            const mod = s[0..i];
            if (std.ascii.eqlIgnoreCase(mod, "ctrl") or std.ascii.eqlIgnoreCase(mod, "control")) {
                ctrl = true;
            } else if (!std.ascii.eqlIgnoreCase(mod, "shift")) {
                return null;
            }
            s = s[i + 1 ..];
        }
        if (s.len == 0) return null;
        if (namedFromSpec(s)) |n| return if (ctrl) null else .{ .named = n };
        const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
        if (len != s.len) return null;
        const cp = std.unicode.utf8Decode(s) catch return null;
        return if (ctrl) .{ .ctrl = lower(cp) } else .{ .char = cp };
    }

    fn namedFromSpec(s: []const u8) ?Named {
        const names = .{
            .{ "escape", .escape },  .{ "esc", .escape },
            .{ "enter", .enter },    .{ "return", .enter },
            .{ "tab", .tab },        .{ "backspace", .backspace },
            .{ "bspace", .backspace }, .{ "space", .space },
            .{ "up", .up },          .{ "down", .down },
            .{ "left", .left },      .{ "right", .right },
            .{ "home", .home },      .{ "end", .end },
            .{ "pageup", .pageup },  .{ "ppage", .pageup },
            .{ "pagedown", .pagedown }, .{ "npage", .pagedown },
            .{ "delete", .delete },  .{ "insert", .insert },
        };
        inline for (names) |pair| {
            if (std.ascii.eqlIgnoreCase(s, pair[0])) return pair[1];
        }
        return null;
    }

    /// The trigger a key press is, if it's one the table can name.
    pub fn fromKey(e: KeyEvent) ?Trigger {
        if (e.mods.ctrl and !e.mods.alt and e.unshifted_codepoint != 0) {
            return .{ .ctrl = lower(e.unshifted_codepoint) };
        }
        if (namedFromKey(e.key)) |n| return .{ .named = n };
        const cp = codepointOf(e.utf8) orelse return null;
        return switch (cp) {
            0x1b => .{ .named = .escape },
            '\r', '\n' => .{ .named = .enter },
            '\t' => .{ .named = .tab },
            0x08, 0x7f => .{ .named = .backspace },
            ' ' => .{ .named = .space },
            else => if (cp >= 0x20) .{ .char = cp } else null,
        };
    }

    fn namedFromKey(key: Key) ?Named {
        return switch (key) {
            .escape => .escape,
            .enter, .numpad_enter => .enter,
            .tab => .tab,
            .backspace => .backspace,
            .space => .space,
            .arrow_up => .up,
            .arrow_down => .down,
            .arrow_left => .left,
            .arrow_right => .right,
            .home => .home,
            .end => .end,
            .page_up => .pageup,
            .page_down => .pagedown,
            .delete => .delete,
            .insert => .insert,
            else => null,
        };
    }
};

fn lower(cp: u21) u21 {
    return if (cp < 0x80) std.ascii.toLower(@intCast(cp)) else cp;
}

/// The one codepoint `utf8` is, or null.
fn codepointOf(utf8: []const u8) ?u21 {
    if (utf8.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(utf8[0]) catch return null;
    if (len != utf8.len) return null;
    return std.unicode.utf8Decode(utf8) catch null;
}

/// The keys in force: tmux's copy-mode-vi table, until `apply` lays
/// init.lua's over it. Its digits (counts here, a repeat prompt there),
/// `:` (goto-line), and the keys for commands slime lacks aren't in it.
pub const Table = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// `entries` replaces `defaults`.
    custom: bool = false,

    pub const Entry = struct { trigger: Trigger, action: Action };

    pub const defaults = [_]Entry{
        .{ .trigger = .{ .char = '#' }, .action = .search_word_backward },
        .{ .trigger = .{ .char = '*' }, .action = .search_word_forward },
        .{ .trigger = .{ .ctrl = 'c' }, .action = .cancel },
        .{ .trigger = .{ .ctrl = 'd' }, .action = .halfpage_down },
        .{ .trigger = .{ .ctrl = 'e' }, .action = .scroll_down },
        .{ .trigger = .{ .ctrl = 'b' }, .action = .page_up },
        .{ .trigger = .{ .ctrl = 'f' }, .action = .page_down },
        .{ .trigger = .{ .ctrl = 'h' }, .action = .cursor_left },
        .{ .trigger = .{ .ctrl = 'j' }, .action = .copy_selection_and_cancel },
        .{ .trigger = .{ .named = .enter }, .action = .copy_selection_and_cancel },
        .{ .trigger = .{ .ctrl = 'u' }, .action = .halfpage_up },
        .{ .trigger = .{ .ctrl = 'v' }, .action = .rectangle_toggle },
        .{ .trigger = .{ .ctrl = 'y' }, .action = .scroll_up },
        .{ .trigger = .{ .named = .escape }, .action = .clear_selection },
        .{ .trigger = .{ .ctrl = '[' }, .action = .clear_selection },
        .{ .trigger = .{ .named = .space }, .action = .begin_selection },
        .{ .trigger = .{ .char = '$' }, .action = .end_of_line },
        .{ .trigger = .{ .char = ',' }, .action = .jump_reverse },
        .{ .trigger = .{ .char = '/' }, .action = .search_forward },
        .{ .trigger = .{ .char = '0' }, .action = .start_of_line },
        .{ .trigger = .{ .char = ';' }, .action = .jump_again },
        .{ .trigger = .{ .char = '?' }, .action = .search_backward },
        .{ .trigger = .{ .char = 'B' }, .action = .previous_space },
        .{ .trigger = .{ .char = 'D' }, .action = .copy_end_of_line_and_cancel },
        .{ .trigger = .{ .char = 'E' }, .action = .next_space_end },
        .{ .trigger = .{ .char = 'F' }, .action = .jump_backward },
        .{ .trigger = .{ .char = 'G' }, .action = .history_bottom },
        .{ .trigger = .{ .char = 'H' }, .action = .top_line },
        .{ .trigger = .{ .char = 'J' }, .action = .scroll_down },
        .{ .trigger = .{ .char = 'K' }, .action = .scroll_up },
        .{ .trigger = .{ .char = 'L' }, .action = .bottom_line },
        .{ .trigger = .{ .char = 'M' }, .action = .middle_line },
        .{ .trigger = .{ .char = 'N' }, .action = .search_reverse },
        .{ .trigger = .{ .char = 'T' }, .action = .jump_to_backward },
        .{ .trigger = .{ .char = 'V' }, .action = .select_line },
        .{ .trigger = .{ .char = 'W' }, .action = .next_space },
        .{ .trigger = .{ .char = '^' }, .action = .back_to_indentation },
        .{ .trigger = .{ .char = 'b' }, .action = .previous_word },
        .{ .trigger = .{ .char = 'e' }, .action = .next_word_end },
        .{ .trigger = .{ .char = 'f' }, .action = .jump_forward },
        .{ .trigger = .{ .char = 'g' }, .action = .history_top },
        .{ .trigger = .{ .char = 'h' }, .action = .cursor_left },
        .{ .trigger = .{ .char = 'j' }, .action = .cursor_down },
        .{ .trigger = .{ .char = 'k' }, .action = .cursor_up },
        .{ .trigger = .{ .char = 'z' }, .action = .scroll_middle },
        .{ .trigger = .{ .char = 'l' }, .action = .cursor_right },
        .{ .trigger = .{ .char = 'n' }, .action = .search_again },
        .{ .trigger = .{ .char = 'o' }, .action = .other_end },
        .{ .trigger = .{ .char = 'q' }, .action = .cancel },
        .{ .trigger = .{ .char = 't' }, .action = .jump_to_forward },
        .{ .trigger = .{ .char = 'v' }, .action = .rectangle_toggle },
        .{ .trigger = .{ .char = 'w' }, .action = .next_word },
        .{ .trigger = .{ .char = '{' }, .action = .previous_paragraph },
        .{ .trigger = .{ .char = '}' }, .action = .next_paragraph },
        .{ .trigger = .{ .char = '%' }, .action = .next_matching_bracket },
        .{ .trigger = .{ .named = .home }, .action = .start_of_line },
        .{ .trigger = .{ .named = .end }, .action = .end_of_line },
        .{ .trigger = .{ .named = .backspace }, .action = .cursor_left },
        .{ .trigger = .{ .named = .pagedown }, .action = .page_down },
        .{ .trigger = .{ .named = .pageup }, .action = .page_up },
        .{ .trigger = .{ .named = .up }, .action = .cursor_up },
        .{ .trigger = .{ .named = .down }, .action = .cursor_down },
        .{ .trigger = .{ .named = .left }, .action = .cursor_left },
        .{ .trigger = .{ .named = .right }, .action = .cursor_right },
    };

    pub fn deinit(self: *Table) void {
        self.entries.deinit(alloc);
    }

    /// Start from the defaults and apply `text`'s lines over them, in
    /// order: "key<tab>action" binds, "key<tab>" unbinds. Returns the
    /// first line that doesn't parse, if any; the others still apply.
    pub fn apply(self: *Table, text: []const u8) std.mem.Allocator.Error!?[]const u8 {
        self.entries.clearRetainingCapacity();
        try self.entries.appendSlice(alloc, &defaults);
        self.custom = true;
        var bad: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const ok = self.applyLine(line) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Bad => false,
            };
            if (!ok and bad == null) bad = line;
        }
        return bad;
    }

    fn applyLine(self: *Table, line: []const u8) error{ Bad, OutOfMemory }!bool {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.Bad;
        const trigger = Trigger.parse(line[0..tab]) orelse return error.Bad;
        const name = line[tab + 1 ..];
        const action: ?Action = if (name.len == 0) null else actionNamed(name) orelse return error.Bad;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].trigger.eql(trigger)) {
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
        if (action) |a| try self.entries.append(alloc, .{ .trigger = trigger, .action = a });
        return true;
    }

    pub fn lookup(self: *const Table, trigger: Trigger) ?Action {
        const entries: []const Entry = if (self.custom) self.entries.items else &defaults;
        for (entries) |e| {
            if (e.trigger.eql(trigger)) return e.action;
        }
        return null;
    }
};

/// Which way a search goes: down is toward newer rows.
pub const Direction = enum(u8) { down = 0, up = 1 };

/// What a key did.
pub const Outcome = struct {
    /// The pane looks different: the cursor, selection, or viewport
    /// moved, or the mode ended.
    changed: bool = false,
    /// The selection's text was written for the clipboard.
    copied: bool = false,
    /// / or ?: the window should ask for a needle, to search this way.
    prompt: ?Direction = null,
};

/// tmux's `word-separators`: ASCII punctuation but the underscore.
const word_separators = [_]u21{ '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '`', '{', '|', '}', '~' };

/// A terminal's copy mode: off, or on over a snapshot.
pub const State = struct {
    /// The daemon config's keys: those of a view that brings none.
    table: Table = .{},
    mode: ?Mode = null,
    /// The last needle searched for: the next mode's n searches up for
    /// it, as tmux keeps it on the pane.
    needle: std.ArrayList(u8) = .empty,
    /// Counts entries: which snapshot a view's mouse gesture holds a
    /// place in (`epoch`).
    entries: u64 = 0,

    pub fn deinit(self: *State) void {
        if (self.mode) |*m| m.deinit();
        self.table.deinit();
        self.needle.deinit(alloc);
        self.* = undefined;
    }

    pub fn isOn(self: *const State) bool {
        return self.mode != null;
    }

    pub fn active(self: *State) ?*Mode {
        return if (self.mode) |*m| m else null;
    }

    /// The snapshot frames show while the mode is on.
    pub fn terminal(self: *State) ?*Terminal {
        const m = self.active() orelse return null;
        return m.snap;
    }

    /// Which terminal the view of the pane is: 0 for the pane's own, else
    /// the snapshot of this entry.
    pub fn epoch(self: *const State) u64 {
        return if (self.mode != null) self.entries else 0;
    }

    /// The action a key press would run, if it's bound and no jump or
    /// count is under way; for a caller that takes some keys first.
    /// `table` is the keys of the view the press came in on.
    pub fn actionFor(self: *State, table: *const Table, e: KeyEvent) ?Action {
        const m = self.active() orelse return null;
        if (e.action == .release or m.jump != null or m.count != 0) return null;
        const trigger = Trigger.fromKey(e) orelse return null;
        return table.lookup(trigger);
    }

    /// Start copy mode: snapshot `live`'s screen and its scrollback,
    /// keeping the view it had, with the cursor where the program's is (on
    /// the view's last row if that's scrolled out of it). A selection the
    /// mouse made comes along for the keys to extend, and leaves the pane.
    pub fn enter(self: *State, live: *Terminal) !void {
        if (self.mode != null) return;
        const snap = try snapshot(live);
        errdefer {
            snap.deinit(alloc);
            alloc.destroy(snap);
        }
        const screen = snap.screens.active;
        const live_screen = live.screens.active;
        if (screenPos(live_screen, live_screen.pages.getTopLeft(.viewport))) |top| {
            snap.scrollViewport(.{ .row = top.y });
        }
        var start = screen.cursor.page_pin.*;
        if (inView(screen, start) == null) {
            start = screen.pages.pin(.{ .viewport = .{ .y = screen.pages.rows - 1 } }) orelse start;
        }
        var mode: Mode = .{ .snap = snap, .cursor = try screen.pages.trackPin(start), .want_x = start.x };
        if (screen.selection) |sel| try mode.takeSelection(sel);
        if (self.needle.items.len > 0) mode.search.direction = .up;
        live_screen.clearSelection();
        self.entries += 1;
        self.mode = mode;
    }

    /// End copy mode: the snapshot goes, and the pane's view comes back
    /// to the bottom, as tmux's does.
    pub fn exit(self: *State, live: *Terminal) void {
        const m = self.active() orelse return;
        m.deinit();
        self.mode = null;
        live.scrollViewport(.bottom);
    }

    /// A key, while the mode is on. Its text, if the key copies, goes to
    /// `copied`. `live` is the pane's terminal, for a key that leaves;
    /// `table` the keys of the view it came in on.
    pub fn key(self: *State, table: *const Table, live: *Terminal, e: KeyEvent, copied: *std.Io.Writer) !Outcome {
        const m = self.active() orelse return .{};
        if (e.action == .release or e.key.modifier()) return .{};
        var out: Outcome = .{};
        const cp = codepointOf(e.utf8);

        // A jump's character.
        if (m.jump) |action| {
            m.jump = null;
            const n = @max(m.count, 1);
            m.count = 0;
            const target = cp orelse return .{};
            if (target < 0x20 or e.mods.ctrl) return .{};
            m.last_jump = .{ .action = action, .cp = target };
            m.jumpTo(action, target, n);
            m.moved(&out);
            return out;
        }

        // A count: digits before a key, 0 only after another.
        if (cp != null and !e.mods.ctrl and cp.? >= '0' and cp.? <= '9' and (cp.? != '0' or m.count > 0)) {
            m.count = @min(m.count * 10 + (cp.? - '0'), 9999);
            return .{};
        }

        const n: usize = @max(m.count, 1);
        m.count = 0;
        const trigger = Trigger.fromKey(e) orelse return .{};
        const action = table.lookup(trigger) orelse return .{};
        try self.perform(live, m, action, n, copied, &out);
        return out;
    }

    fn perform(self: *State, live: *Terminal, m: *Mode, action: Action, n: usize, copied: *std.Io.Writer, out: *Outcome) !void {
        const screen = m.screen();
        switch (action) {
            .cancel => {
                self.exit(live);
                out.changed = true;
                return;
            },
            .copy_selection, .copy_selection_and_cancel => {
                try copySelection(screen, copied, out);
                if (action == .copy_selection) {
                    m.clearAnchor();
                    screen.clearSelection();
                    out.changed = true;
                    return;
                }
                self.exit(live);
                out.changed = true;
                return;
            },
            .copy_end_of_line, .copy_end_of_line_and_cancel => {
                var nav: Nav = .init(m);
                var g = nav.reader();
                g.endOfLine(true, false);
                const end = Pos{ .x = @intCast(nav.r.limit(g.y)), .y = g.y };
                if (pinAt(screen, end)) |e| try screen.select(Selection.init(m.cursor.*, e, false));
                try copySelection(screen, copied, out);
                m.clearAnchor();
                screen.clearSelection();
                if (action == .copy_end_of_line_and_cancel) self.exit(live);
                out.changed = true;
                return;
            },
            .clear_selection => {
                m.clearAnchor();
                screen.clearSelection();
                out.changed = true;
                return;
            },
            .begin_selection => {
                try m.anchorAt(m.cursor.*);
                m.lines = false;
            },
            .select_line => {
                try m.anchorAt(m.cursor.*);
                m.lines = true;
                m.rectangle = false;
                if (n > 1) m.move(.cursor_down, n - 1);
            },
            .rectangle_toggle => {
                m.rectangle = !m.rectangle;
                m.lines = false;
            },
            .other_end => if (m.anchor) |a| {
                std.mem.swap(Pin, a, m.cursor);
                var nav: Nav = .init(m);
                nav.acquire(nav.p);
                m.want_x = nav.p.x;
                nav.commit();
            },
            .jump_forward, .jump_backward, .jump_to_forward, .jump_to_backward => {
                m.jump = action;
                m.count = @intCast(n);
                return;
            },
            .jump_again, .jump_reverse => {
                const j = m.last_jump orelse return;
                m.jumpTo(if (action == .jump_again) j.action else reverse(j.action), j.cp, n);
            },
            .search_forward, .search_backward => {
                out.prompt = if (action == .search_forward) .down else .up;
                return;
            },
            .search_again, .search_reverse => {
                const dir = m.search.direction orelse return;
                if (self.needle.items.len == 0) return;
                if (!m.search.found) try m.findMatches(self.needle.items);
                m.searchMove(if (action == .search_again) dir else opposite(dir), n);
            },
            .search_word_forward, .search_word_backward => {
                var word: std.ArrayList(u8) = .empty;
                defer word.deinit(alloc);
                try m.wordUnderCursor(&word);
                if (word.items.len == 0) return;
                try self.searchFor(m, word.items, if (action == .search_word_forward) .down else .up, n);
            },
            else => m.move(action, n),
        }
        m.moved(out);
    }

    /// Search for `needle` from the cursor, as the window's prompt asks,
    /// and remember it for n and N. An empty needle unmarks the matches.
    pub fn searchNeedle(self: *State, needle: []const u8, direction: Direction) !void {
        const m = self.active() orelse return;
        if (needle.len == 0) {
            m.search.shown = false;
            m.marks_dirty = true;
            return;
        }
        try self.searchFor(m, needle, direction, 1);
    }

    fn searchFor(self: *State, m: *Mode, needle: []const u8, direction: Direction, n: usize) !void {
        if (needle.ptr != self.needle.items.ptr) {
            self.needle.clearRetainingCapacity();
            try self.needle.appendSlice(alloc, needle);
        }
        m.search.direction = direction;
        try m.findMatches(self.needle.items);
        m.searchMove(direction, n);
        var out: Outcome = .{};
        m.moved(&out);
    }

    /// n or N from the window (its card's arrows).
    pub fn searchStep(self: *State, reverse_: bool) !void {
        const m = self.active() orelse return;
        const dir = m.search.direction orelse return;
        if (self.needle.items.len == 0) return;
        if (!m.search.found) try m.findMatches(self.needle.items);
        m.searchMove(if (reverse_) opposite(dir) else dir, 1);
        var out: Outcome = .{};
        m.moved(&out);
    }

    /// The matches marked, and the one under the cursor counted from
    /// the top (0 for none), for the frame; null while none are marked.
    pub fn searchInfo(self: *State) ?struct { matches: u32, current: u32 } {
        const m = self.active() orelse return null;
        if (!m.search.shown) return null;
        const pos = screenPos(m.screen(), m.cursor.*) orelse return null;
        const i = m.matchAt(pos);
        return .{
            .matches = std.math.cast(u32, m.search.matches.items.len) orelse std.math.maxInt(u32),
            .current = if (i) |idx| @intCast(@min(idx + 1, std.math.maxInt(u32))) else 0,
        };
    }

    /// Keep the snapshot the pane's size: reflow it as the pane's
    /// terminal was, and find the matches again in the new rows.
    pub fn fit(self: *State, live: *Terminal) void {
        const m = self.active() orelse return;
        if (m.snap.cols == live.cols and m.snap.rows == live.rows) return;
        m.snap.resize(alloc, .{ .cols = live.cols, .rows = live.rows }) catch return;
        if (m.search.found) m.findMatches(self.needle.items) catch {
            m.search.found = false;
            m.search.shown = false;
        };
        var nav: Nav = .init(m);
        nav.acquire(nav.p);
        nav.commit();
        m.updateSelection() catch {};
        m.marks_dirty = true;
    }

    /// Before a frame, after the render state's update from the snapshot:
    /// put the matches in view into the state's highlights, the one under
    /// the cursor as the current one.
    pub fn refresh(self: *State, state: *RenderState) void {
        const m = self.active() orelse return;
        if (!m.marks_dirty and state.dirty == .false) return;
        m.marks_dirty = false;
        search.clearHighlights(state);
        if (!m.search.shown) return;
        m.markMatches(state) catch {};
    }

    /// The viewport cell the cursor is in, for the frame's cursor; null
    /// while it's scrolled out of view.
    pub fn cursorCell(self: *State) ?vt.Coordinate {
        const m = self.active() orelse return null;
        return inView(m.screen(), m.cursor.*);
    }
};

fn opposite(d: Direction) Direction {
    return if (d == .down) .up else .down;
}

fn reverse(action: Action) Action {
    return switch (action) {
        .jump_forward => .jump_backward,
        .jump_backward => .jump_forward,
        .jump_to_forward => .jump_to_backward,
        .jump_to_backward => .jump_to_forward,
        else => action,
    };
}

/// A terminal holding a clone of `live`'s active screen with all its
/// scrollback, in its colors, as copy mode's snapshot.
fn snapshot(live: *Terminal) !*Terminal {
    const src = live.screens.active;
    var palette = try vt.color.DynamicPalette.init(alloc, live.colors.palette.original.*);
    palette.current = live.colors.palette.current;
    palette.mask = live.colors.palette.mask;
    const snap = try alloc.create(Terminal);
    errdefer alloc.destroy(snap);
    snap.* = Terminal.init(src.io, alloc, .{
        .cols = live.cols,
        .rows = live.rows,
        .max_scrollback_bytes = null,
        .colors = .{
            .background = live.colors.background,
            .foreground = live.colors.foreground,
            .cursor = live.colors.cursor,
            .palette = palette,
        },
    }) catch |err| {
        palette.deinit(alloc);
        return err;
    };
    errdefer snap.deinit(alloc);
    const clone = try src.clone(src.io, alloc, .{ .screen = .{} }, null);
    const screen = snap.screens.active;
    screen.deinit();
    screen.* = clone;
    return snap;
}

fn copySelection(screen: *Screen, copied: *std.Io.Writer, out: *Outcome) !void {
    const sel = screen.selection orelse return;
    const text = try screen.selectionString(alloc, .{ .sel = sel });
    defer alloc.free(text);
    try copied.writeAll(text);
    out.copied = true;
}

/// A cell of the snapshot, in screen coordinates (from the top of the
/// scrollback).
const Pos = struct { x: u16, y: u32 };

fn screenPos(screen: *const Screen, p: Pin) ?Pos {
    const pt = screen.pages.pointFromPin(.screen, p) orelse return null;
    return .{ .x = @intCast(pt.screen.x), .y = @intCast(pt.screen.y) };
}

fn pinAt(screen: *const Screen, p: Pos) ?Pin {
    const x = @min(p.x, screen.pages.cols - 1);
    return screen.pages.pin(.{ .screen = .{ .x = x, .y = p.y } });
}

/// The viewport cell a pin is in, or null when it's scrolled out of
/// view. pointFromPin gives a pin below the viewport a row past its
/// bottom rather than null.
pub fn inView(screen: *const Screen, p: Pin) ?vt.Coordinate {
    const pt = screen.pages.pointFromPin(.viewport, p) orelse return null;
    if (pt.viewport.y >= screen.pages.rows) return null;
    return .{ .x = pt.viewport.x, .y = pt.viewport.y };
}

pub const Mode = struct {
    /// The snapshot: copy mode's own terminal, freed with the mode.
    snap: *Terminal,
    /// Tracked in the snapshot's screen, so a reflow moves them along.
    cursor: *Pin,
    /// Where the selection started; null while nothing is selected by
    /// the keys.
    anchor: ?*Pin = null,
    /// The selection takes whole lines.
    lines: bool = false,
    /// The selection is a rectangle (tmux keeps the flag across
    /// selections).
    rectangle: bool = false,
    /// The column the cursor wants: motions along a line set it, and
    /// motions across rows keep to it where a row is long enough.
    want_x: u16 = 0,
    /// Digits typed so far, for the next key.
    count: u32 = 0,
    /// A jump waiting for the character to jump to.
    jump: ?Action = null,
    last_jump: ?struct { action: Action, cp: u21 } = null,
    search: Search = .{},
    /// The highlights need redoing: the matches, the cursor, or the
    /// view changed.
    marks_dirty: bool = true,

    const Search = struct {
        /// The way n goes; null before a needle.
        direction: ?Direction = null,
        /// The needle's matches over the whole snapshot, in order.
        matches: std.ArrayList(Match) = .empty,
        /// `matches` holds the needle's (n after entering finds them).
        found: bool = false,
        /// The matches are marked: a search ran and found some.
        shown: bool = false,
    };

    /// A match, from its first cell to its last, a wide character's
    /// spacer included.
    const Match = struct { start: Pos, end: Pos };

    fn deinit(self: *Mode) void {
        self.search.matches.deinit(alloc);
        // The pins go with the snapshot's pages.
        self.snap.deinit(alloc);
        alloc.destroy(self.snap);
        self.* = undefined;
    }

    pub fn screen(self: *const Mode) *Screen {
        return self.snap.screens.active;
    }

    /// Take up a selection the mouse made: the keys extend it from its
    /// end. With none, the cursor goes to `at`.
    pub fn syncSelection(self: *Mode, at: Pin) !void {
        if (self.screen().selection) |sel| {
            try self.takeSelection(sel);
        } else {
            self.clearAnchor();
            self.cursor.* = at;
            self.want_x = at.x;
        }
        self.marks_dirty = true;
    }

    fn takeSelection(self: *Mode, sel: Selection) !void {
        try self.anchorAt(sel.start());
        self.cursor.* = sel.end();
        self.want_x = self.cursor.x;
        self.rectangle = sel.rectangle;
        self.lines = false;
    }

    fn anchorAt(self: *Mode, at: Pin) !void {
        if (self.anchor) |a| {
            a.* = at;
        } else {
            self.anchor = try self.screen().pages.trackPin(at);
        }
    }

    fn clearAnchor(self: *Mode) void {
        if (self.anchor) |a| self.screen().pages.untrackPin(a);
        self.anchor = null;
    }

    /// After the cursor moved: extend the selection to it.
    fn moved(self: *Mode, out: *Outcome) void {
        self.updateSelection() catch {};
        self.marks_dirty = true;
        out.changed = true;
    }

    /// The viewport scrolled under the cursor (the wheel): keep the
    /// cursor on it, and the selection with the cursor.
    pub fn viewportMoved(self: *Mode) !void {
        const s = self.screen();
        if (inView(s, self.cursor.*) == null) {
            const top = s.pages.getTopLeft(.viewport);
            const y: u16 = if (self.cursor.before(top)) 0 else s.pages.rows - 1;
            if (s.pages.pin(.{ .viewport = .{ .x = self.cursor.x, .y = y } })) |p| self.cursor.* = p;
            var r: Reader = .init(s);
            if (screenPos(s, self.cursor.*)) |pos| self.cursor.x = @min(self.want_x, r.limit(pos.y));
        }
        try self.updateSelection();
        self.marks_dirty = true;
    }

    fn updateSelection(self: *Mode) !void {
        const a = self.anchor orelse return;
        const s = self.screen();
        if (self.lines) {
            var top = a.*;
            var bottom = self.cursor.*;
            if (bottom.before(top)) std.mem.swap(Pin, &top, &bottom);
            top.x = 0;
            bottom.x = @intCast(bottom.cells(.all).len - 1);
            try s.select(Selection.init(top, bottom, false));
        } else {
            try s.select(Selection.init(a.*, self.cursor.*, self.rectangle));
        }
    }

    fn move(self: *Mode, action: Action, n: usize) void {
        var nav: Nav = .init(self);
        for (0..n) |_| switch (action) {
            .cursor_left => {
                var g = nav.reader();
                g.left(true);
                nav.acquire(g.pos());
            },
            .cursor_right => {
                var g = nav.reader();
                g.right(true, self.anchor != null and self.rectangle);
                nav.acquire(g.pos());
            },
            .cursor_up => nav.vertical(.up),
            .cursor_down => nav.vertical(.down),
            .page_up => nav.page(.up, false),
            .page_down => nav.page(.down, false),
            .halfpage_up => nav.page(.up, true),
            .halfpage_down => nav.page(.down, true),
            .scroll_up => nav.scroll(.up),
            .scroll_down => nav.scroll(.down),
            .scroll_middle => nav.scrollMiddle(),
            .start_of_line => {
                var g = nav.reader();
                g.startOfLine(true);
                nav.acquire(g.pos());
            },
            .back_to_indentation => {
                var g = nav.reader();
                g.backToIndentation();
                nav.acquire(g.pos());
            },
            .end_of_line => {
                var g = nav.reader();
                const rect = self.anchor != null and self.rectangle;
                g.endOfLine(true, rect);
                var p = g.pos();
                if (!rect) p.x = nav.r.limit(p.y);
                nav.acquire(p);
            },
            .top_line, .middle_line, .bottom_line => {
                const row: u32 = switch (action) {
                    .top_line => 0,
                    .middle_line => (nav.rows - 1) / 2,
                    else => nav.rows - 1,
                };
                nav.p = .{ .x = 0, .y = nav.top + row };
            },
            .history_top => {
                nav.top = 0;
                nav.p = .{ .x = 0, .y = 0 };
            },
            .history_bottom => {
                nav.top = nav.hsize;
                const y = nav.hsize + nav.rows - 1;
                nav.p = .{ .x = nav.r.limit(y), .y = y };
            },
            .next_word, .next_space => {
                var g = nav.reader();
                g.nextWord(if (action == .next_word) &word_separators else &.{});
                nav.acquire(g.pos());
            },
            .next_word_end, .next_space_end => {
                var g = nav.reader();
                const set: []const u21 = if (action == .next_word_end) &word_separators else &.{};
                if (g.white() == 0) g.right(false, false);
                g.nextWordEnd(set);
                g.left(true);
                nav.acquire(g.pos());
            },
            .previous_word, .previous_space => {
                var g = nav.reader();
                g.previousWord(if (action == .previous_word) &word_separators else &.{}, true, false);
                nav.acquire(g.pos());
            },
            .next_paragraph => nav.nextParagraph(),
            .previous_paragraph => nav.previousParagraph(),
            .next_matching_bracket => nav.nextBracket(),
            .previous_matching_bracket => nav.previousBracket(),
            else => {},
        };
        switch (action) {
            .cursor_up, .cursor_down, .page_up, .page_down, .halfpage_up, .halfpage_down, .scroll_up, .scroll_down => {},
            else => self.want_x = nav.p.x,
        }
        nav.commit();
    }

    /// Jump to the `n`th `target` on the line: tmux's f, F, t, and T,
    /// which read on along a wrapped line; "to" stops a cell short, and
    /// skips a target next to the cursor, so ; goes on.
    fn jumpTo(self: *Mode, action: Action, target: u21, n: usize) void {
        var nav: Nav = .init(self);
        for (0..n) |_| {
            var g = nav.reader();
            switch (action) {
                .jump_forward, .jump_to_forward => {
                    g.x += if (action == .jump_forward) 1 else 2;
                    if (!g.jump(target)) break;
                    if (action == .jump_to_forward) g.left(true);
                },
                .jump_backward => {
                    g.left(false);
                    if (!g.jumpBack(target)) break;
                },
                .jump_to_backward => {
                    g.left(false);
                    g.left(false);
                    if (!g.jumpBack(target)) break;
                    g.right(true, false);
                },
                else => unreachable,
            }
            nav.acquire(g.pos());
        }
        self.want_x = nav.p.x;
        nav.commit();
    }

    /// The word under the cursor, by tmux's separators: empty on a blank
    /// or a separator.
    fn wordUnderCursor(self: *Mode, out: *std.ArrayList(u8)) !void {
        const s = self.screen();
        const pos = screenPos(s, self.cursor.*) orelse return;
        var r: Reader = .init(s);
        if (r.white(pos.x, pos.y) != 0 or r.separator(pos.x, pos.y, &word_separators)) return;
        var start = pos.x;
        while (start > 0 and r.white(start - 1, pos.y) == 0 and !r.separator(start - 1, pos.y, &word_separators)) start -= 1;
        const cells = r.cells(pos.y);
        var x = start;
        while (x < cells.len and r.white(x, pos.y) == 0 and !r.separator(x, pos.y, &word_separators)) : (x += 1) {
            const c = cells[x];
            if (c.wide == .spacer_tail) continue;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c.codepoint(), &buf) catch continue;
            try out.appendSlice(alloc, buf[0..len]);
        }
    }

    /// Find every match of `needle` in the snapshot, left to right and
    /// not overlapping, a wrapped line read as one. An all-lowercase
    /// needle ignores case, as tmux's does.
    fn findMatches(self: *Mode, needle: []const u8) !void {
        self.search.matches.clearRetainingCapacity();
        self.search.found = true;
        self.marks_dirty = true;
        var cps: std.ArrayList(u21) = .empty;
        defer cps.deinit(alloc);
        const fold = isLowercase(needle);
        var it = (std.unicode.Utf8View.init(needle) catch return).iterator();
        while (it.nextCodepoint()) |cp| try cps.append(alloc, if (fold) lower(cp) else cp);
        if (cps.items.len == 0) return;

        const LineCell = struct { cp: u21, x: u16, y: u32, wide: bool };
        var line: std.ArrayList(LineCell) = .empty;
        defer line.deinit(alloc);
        var r: Reader = .init(self.screen());
        var y: u32 = 0;
        while (y <= r.last_y) : (y += 1) {
            line.clearRetainingCapacity();
            while (true) {
                for (r.cells(y), 0..) |c, x| {
                    if (c.wide == .spacer_tail or c.wide == .spacer_head) continue;
                    const cp: u21 = if (c.hasText()) c.codepoint() else ' ';
                    try line.append(alloc, .{ .cp = if (fold) lower(cp) else cp, .x = @intCast(x), .y = y, .wide = c.wide == .wide });
                }
                if (y == r.last_y or !r.wrapped(y)) break;
                y += 1;
            }
            const n = cps.items.len;
            var i: usize = 0;
            outer: while (i + n <= line.items.len) {
                for (cps.items, line.items[i .. i + n]) |a, b| {
                    if (a != b.cp) {
                        i += 1;
                        continue :outer;
                    }
                }
                const first = line.items[i];
                const last = line.items[i + n - 1];
                try self.search.matches.append(alloc, .{
                    .start = .{ .x = first.x, .y = first.y },
                    .end = .{ .x = if (last.wide) last.x + 1 else last.x, .y = last.y },
                });
                i += n;
            }
        }
    }

    /// Go to the next match `n` times, down or up from the cursor and
    /// round at the ends; the cursor lands on its start, shown as tmux
    /// shows it. With none, the marks go and the cursor stays.
    fn searchMove(self: *Mode, dir: Direction, n: usize) void {
        const matches = self.search.matches.items;
        self.marks_dirty = true;
        if (matches.len == 0) {
            self.search.shown = false;
            return;
        }
        self.search.shown = true;
        var nav: Nav = .init(self);
        for (0..n) |_| {
            // The first match starting after the cursor, or the last
            // before it.
            const after = lowerBound(matches, nav.p, true);
            const i = switch (dir) {
                .down => if (after < matches.len) after else 0,
                .up => blk: {
                    const before = lowerBound(matches, nav.p, false);
                    break :blk if (before > 0) before - 1 else matches.len - 1;
                },
            };
            nav.scrollTo(matches[i].start);
        }
        self.want_x = nav.p.x;
        nav.commit();
    }

    /// The match the cursor is in, if any.
    fn matchAt(self: *const Mode, pos: Pos) ?usize {
        const matches = self.search.matches.items;
        const after = lowerBound(matches, pos, true);
        if (after == 0) return null;
        const m = matches[after - 1];
        if (lessEq(pos, m.end)) return after - 1;
        return null;
    }

    /// Highlight the matches in view, and the one under the cursor as the
    /// current one.
    fn markMatches(self: *Mode, state: *RenderState) !void {
        const s = self.screen();
        const top = (screenPos(s, s.pages.getTopLeft(.viewport)) orelse return).y;
        const bottom = top + s.pages.rows - 1;
        const cursor = screenPos(s, self.cursor.*);
        const current = if (cursor) |c| self.matchAt(c) else null;
        var hls: std.ArrayList(vt.highlight.Flattened) = .empty;
        defer {
            for (hls.items) |*h| h.deinit(alloc);
            hls.deinit(alloc);
        }
        const matches = self.search.matches.items;
        var i = lowerBound(matches, .{ .x = 0, .y = top -| 1 }, false);
        while (i < matches.len and matches[i].start.y <= bottom) : (i += 1) {
            const m = matches[i];
            if (m.end.y < top) continue;
            const start = pinAt(s, m.start) orelse continue;
            const end = pinAt(s, m.end) orelse continue;
            var hl = try search.flatten(start, end);
            if (current == i) {
                defer hl.deinit(alloc);
                try state.updateHighlightsFlattened(alloc, search.tag_current, &.{hl});
                continue;
            }
            hls.append(alloc, hl) catch |err| {
                hl.deinit(alloc);
                return err;
            };
        }
        try state.updateHighlightsFlattened(alloc, search.tag_match, hls.items);
    }
};

fn lessEq(a: Pos, b: Pos) bool {
    return a.y < b.y or (a.y == b.y and a.x <= b.x);
}

/// The index of the first match starting after `pos` (`strict`) or at
/// or after it.
fn lowerBound(matches: []const Mode.Match, pos: Pos, strict: bool) usize {
    var lo: usize = 0;
    var hi: usize = matches.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const s = matches[mid].start;
        const before = if (strict) lessEq(s, pos) else (s.y < pos.y or (s.y == pos.y and s.x < pos.x));
        if (before) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// tmux's test for a needle that ignores case: no ASCII capital in it.
fn isLowercase(needle: []const u8) bool {
    for (needle) |c| {
        if (c != std.ascii.toLower(c)) return false;
    }
    return true;
}

/// A key's motion over the snapshot: the cursor and the viewport's top
/// in screen coordinates, as tmux keeps them (its cx, cy, and oy), put
/// back in the snapshot by `commit`.
const Nav = struct {
    m: *Mode,
    r: Reader,
    p: Pos,
    top: u32,
    rows: u32,
    /// Rows of scrollback above the active area: the top's limit.
    hsize: u32,

    fn init(m: *Mode) Nav {
        const s = m.screen();
        const rows: u32 = s.pages.rows;
        const total: u32 = @intCast(s.pages.total_rows);
        return .{
            .m = m,
            .r = .init(s),
            .p = screenPos(s, m.cursor.*) orelse .{ .x = 0, .y = 0 },
            .top = if (screenPos(s, s.pages.getTopLeft(.viewport))) |t| t.y else 0,
            .rows = rows,
            .hsize = total -| rows,
        };
    }

    fn commit(self: *Nav) void {
        const s = self.m.screen();
        self.m.snap.scrollViewport(.{ .row = self.top });
        if (pinAt(s, self.p)) |p| self.m.cursor.* = p;
    }

    fn reader(self: *Nav) GridReader {
        return .{ .r = &self.r, .x = self.p.x, .y = self.p.y };
    }

    /// No further right than the row's last character, but in a
    /// rectangle, which goes past the text as vi's virtualedit=block.
    fn clampX(self: *Nav) void {
        if (!self.m.rectangle) self.p.x = @min(self.p.x, self.r.limit(self.p.y));
    }

    /// The cursor to `p`, scrolling the least that shows it (tmux's
    /// window_copy_acquire_cursor_up and _down).
    fn acquire(self: *Nav, p: Pos) void {
        if (p.y < self.top) {
            self.top = p.y;
        } else if (p.y >= self.top + self.rows) {
            self.top = p.y - self.rows + 1;
        }
        self.p = p;
        self.clampX();
    }

    /// The cursor to `p`, scrolling only if it's out of view, and then
    /// so it sits a quarter of the view up from the bottom, or as high
    /// as the top of the history allows (tmux's window_copy_scroll_to).
    fn scrollTo(self: *Nav, p: Pos) void {
        if (p.y < self.top or p.y >= self.top + self.rows) {
            const gap = self.rows / 4;
            self.top = if (p.y < self.rows)
                0
            else if (p.y > self.hsize + self.rows - gap)
                self.hsize
            else
                p.y + gap - self.rows;
        }
        self.p = p;
        self.clampX();
    }

    fn row(self: *const Nav) u32 {
        return self.p.y - self.top;
    }

    /// j and k: a row, the view scrolling at its edge, toward the column
    /// wanted.
    fn vertical(self: *Nav, dir: Direction) void {
        switch (dir) {
            .up => if (self.row() > 0) {
                self.p.y -= 1;
            } else if (self.top > 0) {
                self.top -= 1;
                self.p.y -= 1;
            },
            .down => if (self.row() < self.rows - 1) {
                self.p.y += 1;
            } else if (self.top < self.hsize) {
                self.top += 1;
                self.p.y += 1;
            },
        }
        self.wantColumn();
    }

    fn wantColumn(self: *Nav) void {
        if (!self.m.rectangle) self.p.x = self.m.want_x;
        self.clampX();
    }

    /// A page (two rows short of the view) or half the view, the cursor
    /// keeping its row on screen; past the end of the history, it moves
    /// instead (tmux's window_copy_pageup1 and _pagedown1).
    fn page(self: *Nav, dir: Direction, half: bool) void {
        const n: u32 = if (self.rows > 2) (if (half) self.rows / 2 else self.rows - 2) else 1;
        var cy = self.row();
        switch (dir) {
            .up => if (self.top < n) {
                self.top = 0;
                cy -|= n;
            } else {
                self.top -= n;
            },
            .down => if (self.hsize - self.top < n) {
                self.top = self.hsize;
                cy = @min(cy + n, self.rows - 1);
            } else {
                self.top += n;
            },
        }
        self.p.y = self.top + cy;
        self.wantColumn();
    }

    /// C-y and C-e: the view a row up or down with the cursor on its
    /// text, as tmux 3.8's vi keys keep it, unless that leaves the view.
    fn scroll(self: *Nav, dir: Direction) void {
        switch (dir) {
            .up => {
                if (self.top == 0) return;
                self.top -= 1;
                if (self.p.y >= self.top + self.rows) self.p.y = self.top + self.rows - 1;
            },
            .down => {
                if (self.top >= self.hsize) return;
                self.top += 1;
                if (self.p.y < self.top) self.p.y = self.top;
            },
        }
        self.wantColumn();
    }

    /// z: scroll the cursor's line to the middle, if the history lets the
    /// view go that far.
    fn scrollMiddle(self: *Nav) void {
        const mid = (self.rows - 1) / 2;
        const cy = self.row();
        if (cy > mid) {
            const d = cy - mid;
            if (self.hsize - self.top >= d) self.top += d;
        } else if (cy < mid) {
            const d = mid - cy;
            if (self.top >= d) self.top -= d;
        }
    }

    /// {: back over blank lines, then over the paragraph, to the blank
    /// line before it.
    fn previousParagraph(self: *Nav) void {
        var y = self.p.y;
        while (y > 0 and self.r.length(y) == 0) y -= 1;
        while (y > 0 and self.r.length(y) > 0) y -= 1;
        self.scrollTo(.{ .x = 0, .y = y });
    }

    /// }: on over blank lines, then over the paragraph, to the blank line
    /// after it, or the last row.
    fn nextParagraph(self: *Nav) void {
        const max = self.hsize + self.rows - 1;
        var y = self.p.y;
        while (y < max and self.r.length(y) == 0) y += 1;
        while (y < max and self.r.length(y) > 0) y += 1;
        self.scrollTo(.{ .x = self.r.length(y), .y = y });
    }

    const open = "{[(";
    const close = "}])";

    /// %: from an opening bracket to its match; from a closing one back
    /// to its match; elsewhere, to the next bracket along the line and
    /// then its match (tmux's next-matching-bracket with vi keys).
    fn nextBracket(self: *Nav) void {
        var px: u32 = self.p.x;
        var py = self.p.y;
        var xx: u32 = self.r.length(py);
        const yy = self.r.last_y;
        if (xx == 0) return;
        var found: u8 = 0;
        var end: u8 = 0;
        while (true) {
            if (self.r.ascii(px, py)) |c| {
                if (std.mem.indexOfScalar(u8, close, c) != null) {
                    const back = self.p;
                    self.scrollTo(.{ .x = @intCast(px), .y = py });
                    self.previousBracket();
                    if (self.r.ascii(self.p.x, self.p.y)) |now| {
                        if (std.mem.indexOfScalar(u8, close, now) != null) self.scrollTo(back);
                    }
                    return;
                }
                if (std.mem.indexOfScalar(u8, open, c)) |i| {
                    found = c;
                    end = close[i];
                    break;
                }
            }
            // On along the line, a wrapped one included.
            if (px > xx) {
                if (py == yy or !self.r.wrapped(py)) return;
                px = 0;
                py += 1;
                xx = self.r.length(py);
            } else px += 1;
        }
        var n: u32 = 1;
        while (n != 0) {
            if (px > xx) {
                if (py == yy) return;
                px = 0;
                py += 1;
                xx = self.r.length(py);
            } else px += 1;
            if (self.r.ascii(px, py)) |c| {
                if (c == found) n += 1 else if (c == end) n -= 1;
            }
        }
        self.scrollTo(.{ .x = @intCast(px), .y = py });
    }

    /// From a closing bracket back to its match; elsewhere, nothing.
    fn previousBracket(self: *Nav) void {
        var px: u32 = self.p.x;
        var py = self.p.y;
        if (self.r.length(py) == 0) return;
        const found = self.r.ascii(px, py) orelse return;
        const i = std.mem.indexOfScalar(u8, close, found) orelse return;
        const start = open[i];
        var n: u32 = 1;
        while (n != 0) {
            if (px == 0) {
                if (py == 0) return;
                var xx: u32 = 0;
                while (true) {
                    py -= 1;
                    xx = self.r.length(py);
                    if (xx != 0 or py == 0) break;
                }
                if (xx == 0) return;
                px = xx - 1;
            } else px -= 1;
            if (self.r.ascii(px, py)) |c| {
                if (c == found) n += 1 else if (c == start) n -= 1;
            }
        }
        self.scrollTo(.{ .x = @intCast(px), .y = py });
    }
};

/// The snapshot's rows by screen coordinate, the row last read kept so
/// a walk along rows doesn't search the pages for each.
const Reader = struct {
    pages: *PageList,
    cols: u16,
    last_y: u32,
    row_y: u32 = 0,
    row: ?Pin = null,

    fn init(s: *Screen) Reader {
        return .{
            .pages = &s.pages,
            .cols = s.pages.cols,
            .last_y = @intCast(s.pages.total_rows -| 1),
        };
    }

    fn rowPin(self: *Reader, y: u32) Pin {
        if (self.row) |p| {
            if (y == self.row_y) return p;
            const near = if (y == self.row_y + 1) p.down(1) else if (y + 1 == self.row_y) p.up(1) else null;
            if (near) |q| {
                self.row = q;
                self.row_y = y;
                return q;
            }
        }
        const p = self.pages.pin(.{ .screen = .{ .y = y } }).?;
        self.row = p;
        self.row_y = y;
        return p;
    }

    fn cells(self: *Reader, y: u32) []const Cell {
        return self.rowPin(y).cells(.all);
    }

    /// The row goes on into the next (a soft wrap).
    fn wrapped(self: *Reader, y: u32) bool {
        return self.rowPin(y).rowAndCell().row.wrap;
    }

    fn cell(self: *Reader, x: u32, y: u32) ?Cell {
        const cs = self.cells(y);
        return if (x < cs.len) cs[x] else null;
    }

    /// The row's text: up to its last cell that isn't blank (tmux's
    /// grid_line_length). A wide character's spacer counts as text.
    fn length(self: *Reader, y: u32) u16 {
        const cs = self.cells(y);
        var x = cs.len;
        while (x > 0) : (x -= 1) {
            const c = cs[x - 1];
            if (c.wide == .spacer_tail or (c.hasText() and c.codepoint() != ' ')) break;
        }
        return @intCast(x);
    }

    /// The row's last character, where vi's cursor stops (tmux's
    /// grid_line_limit); 0 for a blank row.
    fn limit(self: *Reader, y: u32) u16 {
        const cs = self.cells(y);
        var x = self.length(y);
        if (x == 0) return 0;
        x -= 1;
        while (x > 0 and cs[x].wide == .spacer_tail) x -= 1;
        return x;
    }

    /// The cell is a wide character's spacer (tmux's padding).
    fn padding(self: *Reader, x: u32, y: u32) bool {
        const c = self.cell(x, y) orelse return false;
        return c.wide == .spacer_tail;
    }

    /// The width of the blank at the cell, or 0 if it isn't one (tmux's
    /// grid_in_set for whitespace). Past the row's end is blank.
    fn white(self: *Reader, x: u32, y: u32) u16 {
        const c = self.cell(x, y) orelse return 1;
        if (c.wide == .spacer_tail) return 0;
        if (!c.hasText() or isWhitespace(c.codepoint())) return if (c.wide == .wide) 2 else 1;
        return 0;
    }

    fn separator(self: *Reader, x: u32, y: u32, set: []const u21) bool {
        const c = self.cell(x, y) orelse return false;
        if (c.wide == .spacer_tail or !c.hasText()) return false;
        return std.mem.indexOfScalar(u21, set, c.codepoint()) != null;
    }

    /// The cell's character if it's one ASCII byte, for brackets.
    fn ascii(self: *Reader, x: u32, y: u32) ?u8 {
        const c = self.cell(x, y) orelse return null;
        if (c.wide == .spacer_tail or !c.hasText()) return null;
        const cp = c.codepoint();
        return if (cp < 0x80) @intCast(cp) else null;
    }
};

/// Unicode's White_Space, as tmux's utf8_has_whitespace.
fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', 0x0b, 0x0c, '\r', 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// tmux's grid_reader: a cursor walking the snapshot's cells. Its x can
/// stand a cell past a row while a word motion crosses to the next.
const GridReader = struct {
    r: *Reader,
    x: u32,
    y: u32,

    fn pos(self: GridReader) Pos {
        return .{ .x = @intCast(@min(self.x, self.r.cols - 1)), .y = self.y };
    }

    fn white(self: *GridReader) u16 {
        return self.r.white(self.x, self.y);
    }

    fn separator(self: *GridReader, set: []const u21) bool {
        return self.r.separator(self.x, self.y, set);
    }

    /// A cell right, to the row's last character (all: the last cell),
    /// and on to the next row's start if `wrap`.
    fn right(self: *GridReader, wrap: bool, all: bool) void {
        const px: u32 = if (all) self.r.cols else self.r.limit(self.y);
        if (wrap and self.x >= px and self.y < self.r.last_y) {
            self.startOfLine(false);
            self.down();
        } else if (self.x < px) {
            self.x += 1;
            while (self.x < px and self.r.padding(self.x, self.y)) self.x += 1;
        }
    }

    /// A cell left, and back to the end of the row above if `wrap` or
    /// that row wraps into this one.
    fn left(self: *GridReader, wrap: bool) void {
        while (self.x > 0 and self.r.padding(self.x, self.y)) self.x -= 1;
        if (self.x == 0 and self.y > 0 and (wrap or self.r.wrapped(self.y - 1))) {
            self.up();
            self.endOfLine(false, false);
        } else if (self.x > 0) self.x -= 1;
    }

    fn down(self: *GridReader) void {
        if (self.y < self.r.last_y) self.y += 1;
        while (self.x > 0 and self.r.padding(self.x, self.y)) self.x -= 1;
    }

    fn up(self: *GridReader) void {
        if (self.y > 0) self.y -= 1;
        while (self.x > 0 and self.r.padding(self.x, self.y)) self.x -= 1;
    }

    fn startOfLine(self: *GridReader, wrap: bool) void {
        if (wrap) {
            while (self.y > 0 and self.r.wrapped(self.y - 1)) self.y -= 1;
        }
        self.x = 0;
    }

    fn endOfLine(self: *GridReader, wrap: bool, all: bool) void {
        if (wrap) {
            while (self.y < self.r.last_y and self.r.wrapped(self.y)) self.y += 1;
        }
        self.x = if (all) self.r.cols else self.r.length(self.y);
    }

    /// Keep x within the row, going on to the next as it passes the end
    /// (`xx`); false at the end of the snapshot.
    fn handleWrap(self: *GridReader, xx: *u32) bool {
        while (self.x > xx.*) {
            if (self.y == self.r.last_y) return false;
            self.startOfLine(false);
            self.down();
            xx.* = if (self.r.wrapped(self.y)) self.r.cols - 1 else self.r.length(self.y);
        }
        return true;
    }

    fn lineEnd(self: *GridReader) u32 {
        // A wrapped word isn't broken at the row's end.
        return if (self.r.wrapped(self.y)) self.r.cols - 1 else self.r.length(self.y);
    }

    /// w: past the rest of this word (a run of separators is one) and
    /// the blanks after it, across rows and the blank lines between.
    fn nextWord(self: *GridReader, set: []const u21) void {
        var xx = self.lineEnd();
        if (!self.handleWrap(&xx)) return;
        if (self.white() == 0) {
            if (self.separator(set)) {
                while (true) {
                    self.x += 1;
                    if (!(self.handleWrap(&xx) and self.separator(set) and self.white() == 0)) break;
                }
            } else {
                while (true) {
                    self.x += 1;
                    if (!(self.handleWrap(&xx) and !(self.separator(set) or self.white() != 0))) break;
                }
            }
        }
        while (self.handleWrap(&xx)) {
            const w = self.white();
            if (w == 0) break;
            self.x += w;
        }
    }

    /// e (before vi's step back): over blanks, then to the cell after the
    /// word's end.
    fn nextWordEnd(self: *GridReader, set: []const u21) void {
        var xx = self.lineEnd();
        while (self.handleWrap(&xx)) {
            if (self.white() != 0) {
                self.x += 1;
            } else if (self.separator(set)) {
                while (true) {
                    self.x += 1;
                    if (!(self.handleWrap(&xx) and self.separator(set) and self.white() == 0)) break;
                }
                return;
            } else {
                while (true) {
                    self.x += 1;
                    if (!(self.handleWrap(&xx) and !(self.white() != 0 or self.separator(set)))) break;
                }
                return;
            }
        }
    }

    /// b: back to the start of this word, or the one before.
    fn previousWord(self: *GridReader, set: []const u21, already: bool, stop_at_eol: bool) void {
        var word_is_letters: bool = undefined;
        if (already or self.white() != 0) {
            while (true) {
                if (self.x > 0) {
                    self.x -= 1;
                    if (self.white() == 0) {
                        word_is_letters = !self.separator(set);
                        break;
                    }
                } else {
                    if (self.y == 0) return;
                    self.up();
                    self.endOfLine(false, false);
                    if (stop_at_eol and self.x > 0) {
                        self.x -= 1;
                        const at_eol = self.white() != 0;
                        self.x += 1;
                        if (at_eol) {
                            word_is_letters = false;
                            break;
                        }
                    }
                }
            }
        } else word_is_letters = !self.separator(set);

        var old_x: u32 = undefined;
        var old_y: u32 = undefined;
        while (true) {
            old_x = self.x;
            old_y = self.y;
            if (self.x == 0) {
                if (self.y == 0 or !self.r.wrapped(self.y - 1)) break;
                self.up();
                self.endOfLine(false, true);
            }
            if (self.x > 0) self.x -= 1;
            if (!(self.white() == 0 and word_is_letters != self.separator(set))) break;
        }
        self.x = old_x;
        self.y = old_y;
    }

    fn equals(self: *GridReader, x: u32, y: u32, target: u21) bool {
        const c = self.r.cell(x, y) orelse return false;
        if (c.wide == .spacer_tail or !c.hasText()) return false;
        return c.codepoint() == target;
    }

    /// To the next `target` from here on, along a wrapped line.
    fn jump(self: *GridReader, target: u21) bool {
        var px = self.x;
        var py = self.y;
        while (py <= self.r.last_y) : (py += 1) {
            const xx = self.r.length(py);
            while (px < xx) : (px += 1) {
                if (self.equals(px, py, target)) {
                    self.x = px;
                    self.y = py;
                    return true;
                }
            }
            if (py == self.r.last_y or !self.r.wrapped(py)) return false;
            px = 0;
        }
        return false;
    }

    /// Back to the previous `target`, this cell included, along a wrapped
    /// line.
    fn jumpBack(self: *GridReader, target: u21) bool {
        var xx = self.x + 1;
        var py = self.y + 1;
        while (py > 0) : (py -= 1) {
            var px = xx;
            while (px > 0) : (px -= 1) {
                if (self.equals(px - 1, py - 1, target)) {
                    self.x = px - 1;
                    self.y = py - 1;
                    return true;
                }
            }
            if (py == 1 or !self.r.wrapped(py - 2)) return false;
            xx = self.r.length(py - 2);
        }
        return false;
    }

    /// ^: the line's first character that isn't blank.
    fn backToIndentation(self: *GridReader) void {
        const old_x = self.x;
        const old_y = self.y;
        self.startOfLine(true);
        var py = self.y;
        while (py <= self.r.last_y) : (py += 1) {
            const xx = self.r.length(py);
            var px: u32 = 0;
            while (px < xx) : (px += 1) {
                const c = self.r.cell(px, py) orelse break;
                if (c.wide != .spacer_tail and c.hasText() and c.codepoint() != ' ') {
                    self.x = px;
                    self.y = py;
                    return;
                }
            }
            if (!self.r.wrapped(py)) break;
        }
        self.x = old_x;
        self.y = old_y;
    }
};

test "triggers parse" {
    try std.testing.expectEqual(Trigger{ .char = 'G' }, Trigger.parse("G").?);
    try std.testing.expectEqual(Trigger{ .ctrl = 'v' }, Trigger.parse("ctrl+v").?);
    try std.testing.expectEqual(Trigger{ .ctrl = 'v' }, Trigger.parse("Ctrl+V").?);
    try std.testing.expectEqual(Trigger{ .named = .pageup }, Trigger.parse("PageUp").?);
    try std.testing.expectEqual(Trigger{ .char = '+' }, Trigger.parse("+").?);
    try std.testing.expectEqual(Trigger{ .char = '+' }, Trigger.parse("shift++").?);
    try std.testing.expect(Trigger.parse("alt+v") == null);
    try std.testing.expect(Trigger.parse("ctrl+escape") == null);
    try std.testing.expect(Trigger.parse("vv") == null);
    try std.testing.expect(Trigger.parse("") == null);
}

test "a table applies binds and unbinds over the defaults, by tmux's names too" {
    var table: Table = .{};
    defer table.deinit();
    try std.testing.expectEqual(Action.rectangle_toggle, table.lookup(.{ .char = 'v' }).?);
    try std.testing.expect(table.lookup(.{ .char = 'y' }) == null);
    const bad = try table.apply("x\tcancel\nv\tbegin-selection\ny\tcopy-pipe-and-cancel\nV\t\nbogus\tcancel\nq\tnot_an_action\n");
    try std.testing.expectEqualStrings("bogus\tcancel", bad.?);
    try std.testing.expectEqual(Action.cancel, table.lookup(.{ .char = 'x' }).?);
    try std.testing.expectEqual(Action.begin_selection, table.lookup(.{ .char = 'v' }).?);
    try std.testing.expectEqual(Action.copy_selection_and_cancel, table.lookup(.{ .char = 'y' }).?);
    try std.testing.expect(table.lookup(.{ .char = 'V' }) == null);
    try std.testing.expectEqual(Action.cancel, table.lookup(.{ .char = 'q' }).?);
    try std.testing.expectEqual(Action.rectangle_toggle, table.lookup(.{ .ctrl = 'v' }).?);
}

test "smart case" {
    try std.testing.expect(isLowercase("ghostty"));
    try std.testing.expect(isLowercase("foo.bar 12"));
    try std.testing.expect(!isLowercase("Ghostty"));
}
