//! squish's own exports, compiled into libghostty-vt (`-Dvt-extra`) next
//! to its C API. The library's Zig API is `@import("root")`; terminals
//! come in as the C API's handles. vt.go and view.go declare these.
//!
//! A View is one pane as a client sees and drives it: the render state
//! frames are cut from, and the input state events act on (the
//! selection gesture, the wheel's remainder, the pane's geometry). Its
//! event handling is what squish's Session did against its own terminal.
//! Calls on a View and its terminal must not overlap.

const std = @import("std");
const vt = @import("root");
const frame = @import("frame.zig");
const event = @import("event.zig");
const search = @import("search.zig");
const copymode = @import("copymode.zig");

const Terminal = vt.c_api.terminal.Terminal;
const Frames = frame.Codec(vt);
const Events = event.Codec(vt);
const alloc = std.heap.smp_allocator;

const MouseEncodeOptions = vt.input.MouseEncodeOptions;

/// The Zig terminal behind a C API handle.
fn zigTerminal(t: Terminal) ?*vt.Terminal {
    return (t orelse return null).terminal;
}

/// The frame codec's layout id (frame.zig), which squish checks against
/// its own.
export fn squish_vt_frame_layout() u64 {
    return Frames.layout_id;
}

/// The text of the rows a frame carries, a line each, into a buffer the
/// caller frees with free() (null when there's none): for tests and
/// debugging. A partial frame decodes against a blank screen of its
/// size. Returns false for a bad frame.
export fn squish_vt_frame_text(ptr: [*]const u8, len: usize, out_ptr: *?[*]u8, out_len: *usize) bool {
    const bytes = ptr[0..len];
    if (bytes.len < 5) return false;
    var screen: Frames.Screen = .{};
    defer screen.deinit(alloc);
    screen.resize(alloc, std.mem.readInt(u16, bytes[1..3], .little), std.mem.readInt(u16, bytes[3..5], .little)) catch return false;
    screen.apply(alloc, bytes) catch return false;
    return screenText(&screen, true, out_ptr, out_len);
}

/// A screen a client mirrors from a pane's frames, as squish's Session
/// does: for tests and debugging in Go.
export fn squish_vt_screen_new() ?*Frames.Screen {
    const s = alloc.create(Frames.Screen) catch return null;
    s.* = .{};
    return s;
}

export fn squish_vt_screen_free(s: *Frames.Screen) void {
    s.deinit(alloc);
    alloc.destroy(s);
}

/// Apply a frame. Returns false for a bad one, or a partial one that
/// doesn't fit the screen.
export fn squish_vt_screen_apply(s: *Frames.Screen, ptr: [*]const u8, len: usize) bool {
    s.apply(alloc, ptr[0..len]) catch return false;
    return true;
}

/// The screen's text, a line a row, as squish_vt_frame_text gives it.
export fn squish_vt_screen_text(s: *const Frames.Screen, out_ptr: *?[*]u8, out_len: *usize) bool {
    return screenText(s, false, out_ptr, out_len);
}

fn screenText(s: *const Frames.Screen, changed_only: bool, out_ptr: *?[*]u8, out_len: *usize) bool {
    var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    s.text(&out.writer, changed_only) catch return false;
    // An empty slice's pointer isn't an allocation free() can take.
    out_ptr.* = null;
    out_len.* = 0;
    if (out.written().len == 0) {
        out.deinit();
        return true;
    }
    const text = out.toOwnedSlice() catch return false;
    out_ptr.* = text.ptr;
    out_len.* = text.len;
    return true;
}

/// What a terminal's views share: the render state frames are cut from,
/// brought up to date once per frame by whichever view cuts it, and a
/// generation per viewport row saying when the row last changed. A view
/// remembers the generation its last frame covered and sends the rows
/// changed since, so any number of views can each see every change,
/// though libghostty-vt's render state consumes the terminal's dirty
/// flags as it updates and could serve only one.
const Source = struct {
    state: vt.RenderState = .empty,
    /// Per viewport row: the generation it last changed in.
    gens: std.ArrayList(u64) = .empty,
    /// Counts updates. A view's `generation` is the one its last frame
    /// covered; rows with a later generation changed since.
    generation: u64 = 0,
    /// The generation of the last update that changed everything (a
    /// resize, a screen switch): a view behind it sends a full frame.
    full_generation: u64 = 0,
    /// Search (search.zig): the terminal's, so every view shows it.
    search: search.State = .{},
    /// Copy mode (copymode.zig): the terminal's, so every view shows it.
    /// While it's on, frames show its snapshot in place of the terminal.
    copy: copymode.State = .{},
    /// Which terminal the state was built from: copy mode's epoch.
    shown_epoch: u64 = 0,

    /// Bring the state up to date with the terminal (copy mode's
    /// snapshot while it's on), marking the rows that changed with a new
    /// generation.
    fn update(self: *Source, live: *vt.Terminal) !void {
        // A state built from one terminal is no use for another: copy
        // mode came or went.
        const epoch = self.copy.epoch();
        if (epoch != self.shown_epoch) {
            self.state.deinit(alloc);
            self.state = .empty;
            self.shown_epoch = epoch;
        }
        self.copy.fit(live);
        try self.state.update(alloc, self.copy.terminal() orelse live);
        // Its highlights go in before the dirty rows are read.
        if (self.copy.isOn()) self.copy.refresh(&self.state) else self.search.refresh(live, &self.state);
        self.generation += 1;
        const rows = @min(self.state.row_data.len, self.state.rows);
        var full = self.state.dirty == .full;
        if (self.gens.items.len != rows) {
            try self.gens.resize(alloc, rows);
            full = true;
        }
        if (full) {
            self.full_generation = self.generation;
            @memset(self.gens.items, self.generation);
        } else {
            for (self.state.row_data.items(.dirty)[0..rows], self.gens.items) |dirty, *g| {
                if (dirty) g.* = self.generation;
            }
        }
        self.state.clean();
    }
};

export fn squish_vt_source_new() ?*Source {
    const s = alloc.create(Source) catch return null;
    s.* = .{};
    return s;
}

/// Free a source. Its views must be gone. `t` is its terminal, which
/// must still be open: a search holds places in it.
export fn squish_vt_source_free(s: ?*Source, t: Terminal) void {
    const self = s orelse return;
    self.search.deinit(zigTerminal(t));
    self.copy.deinit();
    self.state.deinit(alloc);
    self.gens.deinit(alloc);
    alloc.destroy(self);
}

/// Set copy mode's keys: the defaults with `text`'s lines over them, a
/// "key<tab>action" each (copymode.Table.apply). The first line that
/// doesn't parse comes back in `bad` (a slice of `text`; null for
/// none). Returns false if out of memory.
export fn squish_vt_source_copy_keys(s: ?*Source, ptr: [*]const u8, len: usize, bad_ptr: *?[*]const u8, bad_len: *usize) bool {
    const self = s orelse return false;
    bad_ptr.* = null;
    bad_len.* = 0;
    const bad = self.copy.table.apply(ptr[0..len]) catch return false;
    if (bad) |line| {
        bad_ptr.* = line.ptr;
        bad_len.* = line.len;
    }
    return true;
}

/// Whether the terminal is in copy mode.
export fn squish_vt_source_copy_mode(s: ?*Source) bool {
    const self = s orelse return false;
    return self.copy.isOn();
}

/// The number libghostty-vt's key enum gives the key called `name`
/// (ghostty's names: escape, arrow_up, page_down), or 0 for none: for
/// tests, which encode key events.
export fn squish_vt_key_code(ptr: [*]const u8, len: usize) u16 {
    const key = std.meta.stringToEnum(vt.input.Key, ptr[0..len]) orelse return 0;
    return @intCast(@intFromEnum(key));
}

const View = struct {
    // Frames.
    /// The terminal's render state, shared with its other views.
    source: *Source,
    /// The source generation the last frame covered; 0 before any.
    generation: u64 = 0,
    /// Whether the last frame showed the cursor, for `hold`.
    cursor_shown: bool = true,
    /// Scratch: which rows the frame being cut carries.
    changed: std.ArrayList(bool) = .empty,
    frame: std.Io.Writer.Allocating,
    palette: ?vt.color.Palette = null,
    /// The kitty images the client has, and the last frame's placements.
    images: Frames.ImageSender = .{},
    /// The last image's pixels handed out, until the next.
    image_rgba: ?[]u8 = null,

    // Events: what the last one produced.
    out: std.Io.Writer.Allocating,
    copied: std.Io.Writer.Allocating,
    scratch: Events.Scratch = .{},

    // Input state.
    geometry: event.Geometry = .{
        .cell_width = 1,
        .cell_height = 1,
        .padding = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .width = 0,
        .height = 0,
    },
    double_click_ms: u32 = 500,
    word_boundary: std.ArrayList(u21) = .empty,
    gesture: vt.SelectionGesture = .init,
    /// Which terminal the gesture holds a place in: copy mode's epoch.
    gesture_epoch: u64 = 0,
    /// A left button drag is selecting text rather than being reported.
    selecting: bool = false,
    /// Where the selection drag last was, for autoscroll ticks, and
    /// whether it asked for a rectangle.
    drag: struct { x: f32 = 0, y: f32 = 0, rectangle: bool = false } = .{},
    /// The cell the last mouse event was reported in, so motion within
    /// one cell is reported once.
    mouse_cell: ?vt.Coordinate = null,
    /// Wheel rotation not yet turned into scrolling, vertical then
    /// horizontal, in 1/WHEEL_DELTA notches times the lines per notch.
    wheel_remainder: [2]i32 = .{ 0, 0 },
    /// Copy mode's keys as this view's client gave them
    /// (squish_vt_view_copy_keys), over the defaults; null takes the
    /// source's, the daemon config's.
    copy_keys: ?copymode.Table = null,

    fn copyTable(self: *const View) *const copymode.Table {
        return if (self.copy_keys) |*t| t else &self.source.copy.table;
    }
};

/// What an event (or autoscroll tick) did. The bytes are the View's,
/// valid until the next call on it.
const Result = extern struct {
    /// Bytes for the child.
    pty_ptr: ?[*]const u8 = null,
    pty_len: usize = 0,
    /// A copy's text, when `copied`.
    copied_ptr: ?[*]const u8 = null,
    copied_len: usize = 0,
    copy_tag: u32 = 0,
    copied: bool = false,
    /// The pane looks different without new output: the selection or
    /// the viewport moved.
    changed: bool = false,
    /// A selection drag sits past an edge: tick squish_vt_view_autoscroll
    /// every autoscroll_ms while this stays set.
    autoscroll: bool = false,
    /// Copy mode asks the client for a search needle (its / or ?): 1 to
    /// search down, 2 up; 0 for nothing.
    search_prompt: u8 = 0,
};

/// The terminal the view shows: copy mode's snapshot while it's on, else
/// `live`. The mouse gesture holds a place in one; one left in a
/// snapshot that's gone is dropped (its pin went with it), and one in
/// `live` let go once the view shows a snapshot.
fn shown(self: *View, live: *vt.Terminal) *vt.Terminal {
    const cm = &self.source.copy;
    const epoch = cm.epoch();
    if (self.gesture_epoch != epoch) {
        if (self.gesture_epoch == 0) self.gesture.reset(live) else self.gesture = .init;
        self.selecting = false;
        self.gesture_epoch = epoch;
    }
    return cm.terminal() orelse live;
}

/// Whether a search is still working through the history: another frame
/// should follow for its count.
export fn squish_vt_source_search_pending(s: ?*Source) bool {
    const self = s orelse return false;
    return self.search.pending();
}

/// A view on the terminal whose source is `source`, which outlives it.
export fn squish_vt_view_new(source: ?*Source) ?*View {
    const src = source orelse return null;
    const v = alloc.create(View) catch return null;
    v.* = .{ .source = src, .frame = .init(alloc), .out = .init(alloc), .copied = .init(alloc) };
    v.word_boundary.appendSlice(alloc, &default_word_boundary) catch {};
    return v;
}

/// Selection's word boundaries until the client sends its own: Ghostty's
/// `selection-word-chars` default.
const default_word_boundary = [_]u21{ ' ', '\t', '\'', '"', '│', '`', '|', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' };

export fn squish_vt_view_free(v: ?*View, t: Terminal) void {
    const self = v orelse return;
    if (zigTerminal(t)) |term| {
        // The gesture's pin is in the terminal it's in, if that's still
        // there.
        if (self.gesture_epoch == 0) {
            self.gesture.deinit(term);
        } else if (self.gesture_epoch == self.source.copy.epoch()) {
            self.gesture.deinit(self.source.copy.terminal().?);
        }
    }
    self.frame.deinit();
    self.out.deinit();
    self.copied.deinit();
    self.word_boundary.deinit(alloc);
    self.changed.deinit(alloc);
    self.images.deinit(alloc);
    if (self.copy_keys) |*keys| keys.deinit();
    if (self.image_rgba) |rgba| alloc.free(rgba);
    alloc.destroy(self);
}

/// Set the view's own copy mode keys, which it takes over the source's,
/// as squish_vt_source_copy_keys does them; a null `ptr` drops them for
/// the source's again. Returns false if out of memory.
export fn squish_vt_view_copy_keys(v: ?*View, ptr: ?[*]const u8, len: usize, bad_ptr: *?[*]const u8, bad_len: *usize) bool {
    const self = v orelse return false;
    bad_ptr.* = null;
    bad_len.* = 0;
    const text = (ptr orelse {
        if (self.copy_keys) |*t| t.deinit();
        self.copy_keys = null;
        return true;
    })[0..len];
    var table: copymode.Table = .{};
    const bad = table.apply(text) catch {
        table.deinit();
        return false;
    };
    if (self.copy_keys) |*t| t.deinit();
    self.copy_keys = table;
    if (bad) |line| {
        bad_ptr.* = line.ptr;
        bad_len.* = line.len;
    }
    return true;
}

/// Forget the input state the last client left, for a new one: a
/// selection drag in progress (the selection it made stays), the wheel's
/// remainder, and the cell motion was last reported in.
export fn squish_vt_view_reset(v: ?*View, t: Terminal) void {
    const self = v orelse return;
    const term = zigTerminal(t) orelse return;
    self.gesture.reset(shown(self, term));
    self.selecting = false;
    self.drag = .{};
    self.mouse_cell = null;
    self.wheel_remainder = .{ 0, 0 };
}

/// Give a terminal squish's defaults: mode 2027 clusters multi-codepoint
/// graphemes (emoji sequences, combining marks) into one cell, as the
/// Ghostty app does, and a null cursor blink blinks, including after a
/// DECSCUSR 0, RIS, or DECSTR. `fresh` sets the modes too, for a new
/// terminal; a restored one keeps what its program set.
///
/// The pointer is an arrow until the program asks for another shape
/// with OSC 22: an I-beam (Ghostty's default) looks wrong over TUIs. An
/// empty OSC 22 still resets it to the I-beam. A restored terminal can't
/// tell the default I-beam from one the program asked for, and takes the
/// arrow.
export fn squish_vt_terminal_defaults(t: Terminal, fresh: bool) void {
    const term = zigTerminal(t) orelse return;
    term.modes.default.grapheme_cluster = true;
    if (fresh) term.modes.set(.grapheme_cluster, true);
    term.setDefaultCursorBlink(null);
    if (fresh or term.mouse_shape == .text) term.mouse_shape = .default;
}

/// Why the next frame should wait: 0 for no reason, 1 while the program
/// is partway through an update (synchronized output, mode 2026), 2 when
/// it hid the cursor the last frame showed. ConPTY passes console writes
/// on as they're made, so PSReadLine's `?25l`, line redraw, and `?25h`
/// often arrive apart; a frame between them flashes the cursor off on
/// every key.
export fn squish_vt_view_hold(v: ?*View, t: Terminal) u8 {
    const self = v orelse return 0;
    const term = zigTerminal(t) orelse return 0;
    // Copy mode's snapshot waits on nothing the program does.
    if (self.source.copy.isOn()) return 0;
    if (term.modes.get(.synchronized_output)) return 1;
    if (!term.modes.get(.cursor_visible) and self.cursor_shown) return 2;
    return 0;
}

/// End synchronized output that held frames too long, as Ghostty does,
/// so a program that never ends its update can't freeze the screen.
export fn squish_vt_end_sync(t: Terminal) void {
    const term = zigTerminal(t) orelse return;
    term.modes.set(.synchronized_output, false);
}

/// Encode a frame of what changed in `t` since the last one, or of
/// everything if `full`, which also means a client that has none of
/// the images. The bytes are the View's own, valid until the next frame
/// (squish_vt_view_image doesn't touch them). Returns false if out of
/// memory.
export fn squish_vt_view_frame(
    v: ?*View,
    t: Terminal,
    full: bool,
    out_ptr: *[*]const u8,
    out_len: *usize,
) bool {
    const self = v orelse return false;
    const term = zigTerminal(t) orelse return false;
    const src = self.source;
    src.update(term) catch return false;
    // Everything, if the client asks or everything changed since its
    // last frame; else the rows changed since.
    const whole = full or self.generation < src.full_generation;
    self.changed.resize(alloc, src.gens.items.len) catch return false;
    for (src.gens.items, self.changed.items) |g, *c| c.* = g > self.generation;
    if (full) self.images.reset();
    self.images.gather(alloc, src.copy.terminal() orelse term, &src.state) catch return false;
    const palette = src.state.colors.palette;
    const palette_changed = if (self.palette) |p| !std.mem.eql(vt.color.RGB, &p, &palette) else true;
    // In copy mode the frame's cursor is copy mode's: a steady block
    // where the keys have it, in place of the program's. Its matches are
    // the search the frame counts, and the mouse is its own.
    const copying = src.copy.isOn();
    const copy_cursor: ?vt.RenderState.Cursor = if (copying) copyCursor(src) else null;
    const Found = struct { matches: u32, current: u32, partial: bool };
    const found: ?Found = if (copying)
        (if (src.copy.searchInfo()) |s| .{ .matches = s.matches, .current = s.current, .partial = false } else null)
    else if (src.search.isOn())
        .{ .matches = src.search.total, .current = src.search.current, .partial = src.search.partial }
    else
        null;
    self.frame.clearRetainingCapacity();
    Frames.encode(&self.frame.writer, &src.state, .{
        .full = whole,
        .changed = self.changed.items,
        .palette = palette_changed,
        .motion = !copying and term.flags.mouse_event == .any,
        .mouse_shape = std.math.cast(u8, @intFromEnum(term.mouse_shape)) orelse 0,
        .images = &self.images,
        .search = if (found) |f| .{ .matches = f.matches, .current = f.current, .partial = f.partial } else null,
        .cursor = if (copy_cursor) |*c| c else null,
        .copy_mode = copying,
    }) catch return false;
    self.generation = src.generation;
    self.cursor_shown = (copy_cursor orelse src.state.cursor).visible;
    self.palette = palette;
    const bytes = self.frame.written();
    out_ptr.* = bytes.ptr;
    out_len.* = bytes.len;
    return true;
}

/// Copy mode's cursor as the frame carries it: a visible, steady block on
/// its cell, with the cell's content and style from the render state (the
/// client colors the text under a block cursor by them); out of the
/// viewport, hidden.
fn copyCursor(src: *Source) vt.RenderState.Cursor {
    var cur = src.state.cursor;
    cur.visible = true;
    cur.blinking = false;
    cur.password_input = false;
    cur.visual_style = .block;
    cur.viewport = null;
    cur.cell = .{};
    cur.style = .{};
    const at = src.copy.cursorCell() orelse return cur;
    const rows = src.state.row_data.slice();
    const y: usize = at.y;
    if (y < rows.len and y < src.state.rows and at.x < src.state.cols) {
        const cells = rows.items(.cells)[y].slice();
        if (at.x < cells.len) {
            cur.cell = cells.items(.raw)[at.x];
            // The state's style is undefined for a cell with none.
            if (cur.cell.style_id != 0) cur.style = cells.items(.style)[at.x];
        }
    }
    cur.viewport = .{ .x = at.x, .y = @intCast(at.y), .wide_tail = cur.cell.wide == .spacer_tail };
    return cur;
}

/// An image the client needs before the last frame (view.go's Image).
const Image = extern struct {
    id: u32 = 0,
    generation: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Straight RGBA, rows top-down, `width * height * 4` bytes.
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

/// The `i`th image the last frame places that the client lacks, to send
/// before it. Returns 0 past the last, 1 with the image (its pixels are
/// the View's, valid until the next image or the View's end), 2 if it's
/// gone from the terminal or won't fit in memory, to skip.
export fn squish_vt_view_image(v: ?*View, t: Terminal, i: usize, out: *Image) u8 {
    const self = v orelse return 0;
    const term = zigTerminal(t) orelse return 0;
    out.* = .{};
    if (i >= self.images.pending.items.len) return 0;
    if (self.image_rgba) |rgba| alloc.free(rgba);
    self.image_rgba = null;
    const px = (self.images.pixels(alloc, self.source.copy.terminal() orelse term, i) catch null) orelse return 2;
    self.image_rgba = px.rgba;
    out.* = .{
        .id = px.id,
        .generation = px.generation,
        .width = px.width,
        .height = px.height,
        .ptr = px.rgba.ptr,
        .len = px.rgba.len,
    };
    return 1;
}

/// Handle an event (event.zig) from the client. `win32_input` is whether
/// the program asked for win32-input-mode (DEC 9001), which
/// libghostty-vt leaves to us. Returns false for a bad event or no
/// memory.
export fn squish_vt_view_event(
    v: ?*View,
    t: Terminal,
    win32_input: bool,
    ptr: [*]const u8,
    len: usize,
    result: *Result,
) bool {
    const self = v orelse return false;
    const term = zigTerminal(t) orelse return false;
    result.* = .{};
    self.out.clearRetainingCapacity();
    self.copied.clearRetainingCapacity();
    const ev = Events.decode(ptr[0..len], &self.scratch) catch return false;
    handle(self, term, win32_input, ev, result) catch return false;
    finish(self, result);
    return true;
}

/// Scroll the viewport one row toward a selection drag past an edge,
/// and extend the selection there.
export fn squish_vt_view_autoscroll(v: ?*View, t: Terminal, result: *Result) bool {
    const self = v orelse return false;
    const term = shown(self, zigTerminal(t) orelse return false);
    result.* = .{};
    self.out.clearRetainingCapacity();
    self.copied.clearRetainingCapacity();
    const sel = self.gesture.autoscrollTick(term, .{
        .viewport = cellAt(self, term, self.drag.x, self.drag.y),
        .xpos = self.drag.x,
        .ypos = self.drag.y,
        .rectangle = self.drag.rectangle,
        .word_boundary_codepoints = self.word_boundary.items,
        .geometry = dragGeometry(self, term),
    });
    // A reset gesture (the screen switched) leaves the selection alone.
    if (self.gesture.left_click_count != 0) {
        term.screens.active.select(sel) catch return false;
        if (self.source.copy.active()) |mode| {
            const pin = term.screens.active.pages.pin(.{ .viewport = cellAt(self, term, self.drag.x, self.drag.y) });
            if (pin) |p| mode.syncSelection(p) catch return false;
        }
        result.changed = true;
    }
    finish(self, result);
    return true;
}

fn finish(self: *View, result: *Result) void {
    const out = self.out.written();
    if (out.len > 0) {
        result.pty_ptr = out.ptr;
        result.pty_len = out.len;
    }
    if (result.copied) {
        const text = self.copied.written();
        result.copied_ptr = text.ptr;
        result.copied_len = text.len;
    }
    result.autoscroll = self.selecting and self.gesture.left_drag_autoscroll != .none;
}

const Error = std.Io.Writer.Error || std.mem.Allocator.Error || error{ SelectionFailed, EncodeFailed };

fn handle(self: *View, live: *vt.Terminal, win32_input: bool, ev: Events.Event, result: *Result) Error!void {
    const w = &self.out.writer;
    const cm = &self.source.copy;
    // What the mouse and a copy act on: copy mode's snapshot while it's
    // on. Keys and the program's settings are the pane's own terminal's.
    const t = shown(self, live);
    switch (ev) {
        .key => |k| {
            const e = k.event;
            // Copy mode takes every key, bound or not.
            if (cm.isOn()) return copyModeKey(self, live, e, result);
            if (win32_input) {
                for (k.win32) |rec| try rec.encode(w);
                if (e.action != .release and !e.key.modifier()) typed(live, result);
                return;
            }
            const opts: vt.input.KeyEncodeOptions = .fromTerminal(live);
            if (!try legacyCtrl(w, e, opts)) {
                vt.input.encodeKey(w, e, opts) catch return error.EncodeFailed;
            }
            if (self.out.written().len > 0 and e.action != .release and !e.key.modifier()) typed(live, result);
        },
        .text => |text| {
            // Text typed in copy mode is keys, a character each, as in
            // tmux: an IME's commit, or a WM_CHAR posted by a test.
            if (cm.isOn()) {
                var it = std.unicode.Utf8View.initUnchecked(text).iterator();
                while (it.nextCodepointSlice()) |cp| {
                    try copyModeKey(self, live, .{ .utf8 = cp }, result);
                    if (!cm.isOn() or result.search_prompt != 0) break;
                }
                return;
            }
            if (win32_input) {
                // A press and release of no key per UTF-16 unit, carrying
                // the text, as WM_CHAR delivered it.
                var it = std.unicode.Utf8View.initUnchecked(text).iterator();
                while (it.nextCodepoint()) |cp| {
                    var units: [2]u16 = undefined;
                    const len = utf16Units(cp, &units);
                    for (units[0..len]) |unit| for ([_]bool{ true, false }) |down| {
                        try (event.Win32Key{ .char = unit, .down = down }).encode(w);
                    };
                }
            } else {
                try w.writeAll(text);
            }
            typed(live, result);
        },
        .paste => |text| {
            if (cm.isOn()) return;
            const opts: vt.input.PasteOptions = .fromTerminal(live);
            // The encoder replaces control bytes in place.
            const copy = try alloc.dupe(u8, text);
            defer alloc.free(copy);
            for (vt.input.encodePaste(copy, opts)) |part| try w.writeAll(part);
            typed(live, result);
        },
        .focus => |gained| {
            if (!live.modes.get(.focus_event)) return;
            vt.input.encodeFocus(w, if (gained) .gained else .lost) catch return error.EncodeFailed;
        },
        .mouse => |m| try mouse(self, t, m, result),
        .wheel => |m| try wheel(self, t, m, result),
        .copy => |tag| {
            result.copy_tag = tag;
            result.copied = true;
            const screen = t.screens.active;
            const sel = screen.selection orelse return;
            const text = screen.selectionString(alloc, .{ .sel = sel }) catch return error.SelectionFailed;
            defer alloc.free(text);
            try self.copied.writer.writeAll(text);
        },
        .geometry => |g| self.geometry = g,
        .settings => |s| {
            self.double_click_ms = s.double_click_ms;
            self.word_boundary.clearRetainingCapacity();
            try self.word_boundary.appendSlice(alloc, s.word_boundary);
            // Keeping what the program changed (OSC 4/10/11/12).
            const colors = &live.colors;
            colors.background.default = s.colors.background;
            colors.foreground.default = s.colors.foreground;
            colors.cursor.default = s.colors.cursor;
            try colors.palette.changeDefault(live.gpa(), s.colors.palette);
            result.changed = true;
        },
        .cancel => if (self.selecting) endSelection(self, t, null),
        // In copy mode, the needle its / or ? asked for, and its n and N;
        // else the pane's own search.
        .search => |s| {
            if (cm.isOn()) {
                cm.searchNeedle(s.needle, @enumFromInt(@intFromEnum(s.direction))) catch return error.SelectionFailed;
            } else {
                const direction: search.Direction = @enumFromInt(@intFromEnum(s.direction));
                self.source.search.start(live, s.needle, direction) catch return error.SelectionFailed;
            }
            result.changed = true;
        },
        .search_step => |step| {
            if (cm.isOn()) {
                cm.searchStep(step == .previous) catch return error.SelectionFailed;
            } else {
                self.source.search.step(live, @enumFromInt(@intFromEnum(step))) catch return error.SelectionFailed;
            }
            result.changed = true;
        },
        .copy_mode => |how| {
            const on = cm.isOn();
            switch (how) {
                .enter => if (!on) try enterCopyMode(self, live),
                .exit => cm.exit(live),
                .toggle => if (on) cm.exit(live) else try enterCopyMode(self, live),
            }
            result.changed = true;
        },
        // The daemon's to handle, before the view (events.go).
        .refresh => {},
    }
}

/// Copy mode in place of the pane's search, which it has its own of.
fn enterCopyMode(self: *View, live: *vt.Terminal) Error!void {
    self.source.search.end(live);
    self.source.copy.enter(live) catch return error.SelectionFailed;
}

/// A key press in copy mode (copymode.zig): what it did goes in `result`,
/// a copy as one nobody asked for (tag 0), which the client takes as
/// such, and / or ? as a request for a needle.
fn copyModeKey(self: *View, live: *vt.Terminal, e: vt.input.KeyEvent, result: *Result) Error!void {
    const out = self.source.copy.key(self.copyTable(), live, e, &self.copied.writer) catch return error.SelectionFailed;
    if (out.changed) result.changed = true;
    if (out.copied) {
        result.copied = true;
        result.copy_tag = 0;
    }
    if (out.prompt) |d| result.search_prompt = if (d == .down) 1 else 2;
}

/// UTF-16 units of a codepoint.
fn utf16Units(cp: u21, out: *[2]u16) usize {
    if (cp < 0x10000) {
        out[0] = @intCast(cp);
        return 1;
    }
    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

/// Write ctrl and a character as xterm and the Windows console send them
/// when no keyboard protocol is on: its C0 byte, shift or not (ctrl+[ is
/// ESC, ctrl+shift+a is 0x01, ctrl+@ is NUL), or the character itself
/// for one with none (ctrl+; is ;). Following fixterms, the legacy
/// encoder sends CSI u for many of these, which shells and programs
/// that never asked for it take as text. Alt adds the ESC prefix.
/// Returns false for the encoder to take the key.
fn legacyCtrl(w: *std.Io.Writer, e: vt.input.KeyEvent, opts: vt.input.KeyEncodeOptions) std.Io.Writer.Error!bool {
    if (e.action == .release or e.composing or e.utf8.len == 0) return false;
    if (opts.modify_other_keys_state_2 or @as(u5, @bitCast(opts.kitty_flags)) != 0) return false;
    const mods = e.effectiveMods().binding();
    if (!mods.ctrl or mods.super) return false;
    // Text past ASCII takes its key's place on a US layout, as the
    // encoder does: ctrl+с on a Russian layout is ctrl+c.
    const char: u8 = if (e.utf8.len == 1) e.utf8[0] else std.math.cast(u8, e.key.codepoint() orelse 0) orelse 0;
    if (char < 0x20 or char >= 0x7F) return false;
    const c0 = ctrlByte(char);
    if (mods.alt and (c0 != null or opts.alt_esc_prefix)) try w.writeByte(0x1B);
    if (c0) |c| try w.writeByte(c) else try w.writeAll(e.utf8);
    return true;
}

/// The C0 byte ctrl makes of an ASCII character, after xterm and
/// Ghostty's table.
fn ctrlByte(c: u8) ?u8 {
    return switch (c) {
        // A-Z and [ \ ] ^ _, and @ as NUL.
        '@'...'_' => c - '@',
        'a'...'z' => c - 'a' + 1,
        ' ', '2' => 0,
        '3' => 0x1B,
        '4' => 0x1C,
        '5' => 0x1D,
        '6', '~' => 0x1E,
        '7', '/' => 0x1F,
        '8', '?' => 0x7F,
        else => null,
    };
}

/// Drop the selection and bring the viewport back from scrollback, as
/// typing does.
fn typed(t: *vt.Terminal, result: *Result) void {
    const screen = t.screens.active;
    if (screen.selection != null) {
        screen.clearSelection();
        result.changed = true;
    }
    if (screen.pages.viewport == .active) return;
    t.scrollViewport(.bottom);
    result.changed = true;
}

/// Report a mouse button press or release, or motion, if the program
/// asked for mouse events; else select with the left button. Shift
/// selects even when it asked, and so does copy mode, which the program
/// hears nothing from.
fn mouse(self: *View, t: *vt.Terminal, m: Events.Mouse, result: *Result) Error!void {
    const copying = self.source.copy.isOn();
    if (!self.selecting and m.button == .left and m.action == .press) {
        if (t.flags.mouse_event != .none and !m.mods.shift and !copying) {
            self.gesture.reset(t);
        } else {
            self.selecting = true;
        }
    }
    if (self.selecting) return selectionInput(self, t, m, result);
    if (copying) return;

    var opts: MouseEncodeOptions = .fromTerminal(t, surfaceSize(self, t));
    opts.any_button_pressed = m.held;
    opts.last_cell = &self.mouse_cell;
    vt.input.encodeMouse(&self.out.writer, .{
        .action = m.action,
        .button = m.button,
        .mods = m.mods,
        .pos = .{ .x = m.x, .y = m.y },
    }, opts) catch return error.EncodeFailed;
}

/// Start, extend, or finish a selection with the left button: a click
/// clears it, a drag selects cells (a rectangle with ctrl+alt), and
/// double and triple clicks select words and lines.
fn selectionInput(self: *View, t: *vt.Terminal, m: Events.Mouse, result: *Result) Error!void {
    const pin = t.screens.active.pages.pin(.{ .viewport = cellAt(self, t, m.x, m.y) }) orelse return;
    const sel: ?vt.Selection = sel: {
        if (m.action == .press and m.button == .left) {
            break :sel self.gesture.press(t, .{
                .time = .{ .nanoseconds = @as(i96, m.time) * std.time.ns_per_ms },
                .pin = pin,
                .xpos = m.x,
                .ypos = m.y,
                .max_distance = @floatFromInt(self.geometry.cell_width),
                .repeat_interval = @as(u64, self.double_click_ms) * std.time.ns_per_ms,
                .word_boundary_codepoints = self.word_boundary.items,
            }) catch return error.SelectionFailed;
        }
        if (m.action == .motion and m.held) {
            self.drag = .{ .x = m.x, .y = m.y, .rectangle = m.mods.ctrl and m.mods.alt };
            break :sel self.gesture.drag(t, .{
                .pin = pin,
                .xpos = m.x,
                .ypos = m.y,
                .rectangle = self.drag.rectangle,
                .word_boundary_codepoints = self.word_boundary.items,
                .geometry = dragGeometry(self, t),
            });
        }
        if (m.action == .release and m.button == .left) {
            endSelection(self, t, pin);
        }
        return;
    };
    t.screens.active.select(sel) catch return error.SelectionFailed;
    // Copy mode's cursor follows the mouse: a drag's end, or a click.
    if (self.source.copy.active()) |mode| mode.syncSelection(pin) catch return error.SelectionFailed;
    result.changed = true;
}

/// Finish a selection drag, at `pin` if the button was released over a
/// cell.
fn endSelection(self: *View, t: *vt.Terminal, pin: ?vt.Pin) void {
    self.gesture.release(t, .{ .pin = pin });
    self.selecting = false;
}

/// Scroll with the wheel: report wheel buttons if the program asked for
/// mouse events, else send arrow keys on the alternate screen with
/// alternate scroll (mode 1007) set, else move the viewport through
/// scrollback.
fn wheel(self: *View, t: *vt.Terminal, m: Events.Wheel, result: *Result) Error!void {
    // Copy mode scrolls the viewport, whatever the program asked for.
    const copying = self.source.copy.isOn();
    const reporting = t.flags.mouse_event != .none and !copying;
    const alternate_scroll = !reporting and !copying and
        t.screens.active_key == .alternate and
        t.modes.get(.mouse_alternate_scroll);
    if (m.horizontal and !reporting) return;

    // Reports are one per notch; programs pick how far that scrolls.
    const lines: u32 = if (reporting) 1 else if (m.lines_per_notch == event.lines_page) t.rows else @min(m.lines_per_notch, t.rows);
    const remainder = &self.wheel_remainder[@intFromBool(m.horizontal)];
    remainder.* += @as(i32, m.rotation) * @as(i32, @intCast(lines));
    const wheel_delta = 120;
    const steps = @divTrunc(remainder.*, wheel_delta);
    remainder.* -= steps * wheel_delta;
    if (steps == 0) return;
    // Positive rotation is away from the user, or to the right.
    const up = steps > 0;
    const count = @abs(steps);

    if (reporting) {
        var opts: MouseEncodeOptions = .fromTerminal(t, surfaceSize(self, t));
        opts.last_cell = &self.mouse_cell;
        const ev: vt.input.MouseEncodeEvent = .{
            .button = if (m.horizontal)
                (if (up) .seven else .six)
            else
                (if (up) .four else .five),
            .mods = m.mods,
            .pos = .{ .x = m.x, .y = m.y },
        };
        for (0..count) |_| vt.input.encodeMouse(&self.out.writer, ev, opts) catch return error.EncodeFailed;
    } else if (alternate_scroll) {
        const seq: []const u8 = if (t.modes.get(.cursor_keys))
            (if (up) "\x1bOA" else "\x1bOB")
        else
            (if (up) "\x1b[A" else "\x1b[B");
        for (0..count) |_| try self.out.writer.writeAll(seq);
    } else {
        const delta: isize = @intCast(count);
        t.scrollViewport(.{ .delta = if (up) -delta else delta });
        if (self.source.copy.active()) |mode| mode.viewportMoved() catch return error.SelectionFailed;
        result.changed = true;
    }
}

fn dragGeometry(self: *const View, t: *const vt.Terminal) vt.SelectionGesture.Drag.Geometry {
    return .{
        .columns = t.cols,
        .cell_width = self.geometry.cell_width,
        .padding_left = self.geometry.padding.left,
        .screen_height = self.geometry.height,
    };
}

/// The viewport cell under a position, clamped to the grid.
fn cellAt(self: *const View, t: *const vt.Terminal, px: f32, py: f32) vt.Coordinate {
    const g = self.geometry;
    const x: i64 = @intFromFloat(@floor((px - @as(f32, @floatFromInt(g.padding.left))) / @as(f32, @floatFromInt(@max(g.cell_width, 1)))));
    const y: i64 = @intFromFloat(@floor((py - @as(f32, @floatFromInt(g.padding.top))) / @as(f32, @floatFromInt(@max(g.cell_height, 1)))));
    return .{
        .x = @intCast(std.math.clamp(x, 0, @as(i64, t.cols) - 1)),
        .y = @intCast(std.math.clamp(y, 0, @as(i64, t.rows) - 1)),
    };
}

/// The pane as the mouse encoder sees it, to map positions to cells.
fn surfaceSize(self: *const View, t: *const vt.Terminal) @FieldType(MouseEncodeOptions, "size") {
    const g = self.geometry;
    return .{
        .screen = .{ .width = g.width, .height = g.height },
        .cell = .{ .width = g.cell_width, .height = g.cell_height },
        .padding = .{
            .top = g.padding.top,
            .left = g.padding.left,
            .right = g.width -| g.padding.left -| @as(u32, t.cols) * g.cell_width,
            .bottom = g.height -| g.padding.top -| @as(u32, t.rows) * g.cell_height,
        },
    };
}
