//! Direct3D 11 renderer: device, flip-model swap chain, and the terminal
//! grid pipeline (see shaders.hlsl) for a single window, which shows one
//! or more terminals (a tab's panes), each in its own viewport. The window's
//! chrome is drawn over the grid with Direct2D, on the same device.
//!
//! Frames are presented without vsync and gated twice (see `frameGate`):
//! by a timer, so we draw at most once per refresh period (`-Dmax-fps`,
//! 300 by default; 0 paces to the display), and by the swap chain's
//! frame latency waitable object with a maximum latency of 1, so nothing
//! queues up behind the display. Input latency stays about one refresh,
//! and an idle terminal draws the next change immediately. The timer
//! matters where DWM doesn't pace presents at all, e.g. over Remote
//! Desktop, where even vsync'd presents run at thousands of fps.
//!
//! The swap chain is the content of a DirectComposition visual, the root
//! of the window's tree, so that content we don't draw (a browser pane's)
//! can be composed with it: each such pane gets a container visual over
//! the chain (`setPaneVisual`), and while there are any, a second,
//! transparent chain over them takes what must be over panes (dialogs,
//! the menu, the tooltip, a dragged pane). Floating tabs go between: a
//! third chain over the shown tab's browsers takes the floats (their
//! boxes, terminals, and strips), and a float's own browsers go over
//! that, under the overlay (`PaneVisual.layer`). Without browsers the
//! window draws into the one chain alone. Text on the transparent chains
//! is grayscale-antialiased: ClearType needs opaque pixels under it.
//!
//! A device can be lost (a driver update or reset, a GPU going away):
//! `isLost` says so after a failed `draw` or `resize`, and `recover`
//! makes everything on the device again on a new one. The composition
//! tree isn't the device's, so it stays, and browser panes' visuals with
//! it; what others made on the device (kitty textures, decoded images)
//! is told apart by `device_generation`.
const D3D11 = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const d3d11 = win32.d3d11;
const d3dcompiler = win32.d3dcompiler;
const dxgi = win32.dxgi;
const d2d1 = win32.d2d1;
const dcomp = win32.dcomp;
const wic = win32.wic;
const font = @import("../font/font.zig");
const cells = @import("cells.zig");
const image = @import("image.zig");
pub const Painter = @import("Painter.zig");

const log = std.log.scoped(.d3d11);

const buffer_count = 2;
const buffer_format: dxgi.FORMAT = .B8G8R8A8_UNORM;
const shader_source = @embedFile("shaders.hlsl");

/// 60 Hz, for when DWM can't tell us the refresh rate.
const default_refresh_period = 10_000_000 / 60;

alloc: std.mem.Allocator,
// Everything up to `brush` is made on the device (`createDeviceObjects`),
// undefined while `released`.
device: *d3d11.IDevice = undefined,
context: *d3d11.IDeviceContext = undefined,
/// Made with the device: one made before the adapters changed still
/// lists the old ones.
factory: *dxgi.IFactory2 = undefined,
/// The ground: everything but what `overlay` takes.
swap_chain: *dxgi.ISwapChain1 = undefined,
/// Must be passed again to ResizeBuffers.
swap_chain_flags: u32 = 0,
present_flags: u32 = 0,
/// Signaled when the swap chain can accept another frame. Each wait
/// takes one frame's worth; see `waitForFrame`.
frame_waitable: win32.HANDLE = undefined,
/// Set when a wait on `frame_waitable` succeeded and no frame has been
/// presented since.
frame_acquired: bool = false,
/// Set by `waitForFrame` until the frame is presented, so it starts each
/// frame (and advances the pace timer) once however often it's called.
frame_started: bool = false,
/// Manual-reset timer, signaled once a refresh period has passed since
/// the last frame started.
pace_timer: win32.HANDLE,
/// The display refresh period in 100 ns units (SetWaitableTimer's).
refresh_period: i64 = default_refresh_period,
/// When the last frame was allowed to start, as a FILETIME. Frames are
/// scheduled from this rather than from when the loop got around to them,
/// so wake-up latency doesn't add to every period.
frame_due: i64 = 0,
rtv: ?*d3d11.IRenderTargetView = null,
width: u32,
height: u32,

pipeline: Pipeline = undefined,
uniforms: *d3d11.IBuffer = undefined,
bg_cells: DynamicBuffer = .{ .stride = @sizeOf(u32) },
instances: DynamicBuffer = .{ .stride = @sizeOf(cells.Instance) },

/// The GPU copies of each grid's atlases, by `Fonts.id`, while a frame
/// draws a pane at it.
gpu_fonts: std.AutoArrayHashMapUnmanaged(u32, GpuFonts) = .empty,

/// The placement being drawn (see `drawImages`).
image_placement: *d3d11.IBuffer = undefined,
/// The pane box being drawn (see `drawBox`).
box: *d3d11.IBuffer = undefined,

d2d_factory: *d2d1.IFactory1 = undefined,
d2d_device: *d2d1.IDevice = undefined,
d2d_context: *d2d1.IDeviceContext = undefined,
/// The back buffer as a Direct2D target. Released with `rtv`.
d2d_target: ?*d2d1.IBitmap1 = null,
brush: *d2d1.ISolidColorBrush = undefined,
/// The device is software (WARP): no hardware one could be made.
warp: bool = false,
/// The objects made on the device are released (`releaseDevice`), and
/// `recover` hasn't made them again.
released: bool = true,
/// The device was found lost (`isLost`) and `recover` hasn't yet
/// succeeded: `draw` does nothing, and `resize` only notes the size.
lost: bool = false,
/// Bumped by every `recover`. What's made on the device outside the
/// renderer (kitty textures, decoded images) records the generation it
/// was made at, and is dropped at another.
device_generation: u32 = 0,
/// Debug builds: `isLost` says so once, as if the device were gone
/// (`loseDevice`), and the next overlay resize fails
/// (`failOverlayResize`).
debug_lose: bool = false,
debug_fail_overlay_resize: bool = false,
/// The app icon, for the title bar. Null where Direct2D can't draw SVG.
icon: ?Painter.Icon = null,
/// The chrome's icons. Null where Direct2D can't draw SVG.
lucide: ?Painter.LucideIcons = null,
/// The chrome's text antialiasing, as Direct2D takes it.
text_antialias: u32,
/// Not the device's: it outlives `recover`.
comp: Composition,
/// Browser panes' container visuals, over the ground (see `setPaneVisual`).
pane_visuals: std.ArrayList(PaneVisualEntry) = .empty,
/// The chain over `pane_visuals`, while there are any.
overlay: ?LayerChain = null,
/// The floats' chain, over the ground's pane visuals and under the
/// floats' own: made by the first `draw` with floats while there's an
/// overlay, and gone with it.
float_chain: ?LayerChain = null,
/// A copy of part of the last frame, for the UI to draw scaled (a pane
/// being dragged). Kept between frames at its last size.
capture: ?Capture = null,
/// Decodes `decodeImage`'s pictures; made with the first.
wic_factory: ?*wic.IImagingFactory = null,

/// GPU copies of one terminal's kitty images (see `image.Images`), by
/// kitty image ID. Each terminal needs its own: image IDs are per
/// terminal, and pixels are freed once uploaded, so these are the only
/// copies; after `recover`, slime sends them again.
pub const ImageTextures = struct {
    map: std.AutoArrayHashMapUnmanaged(u32, ImageTexture) = .empty,
    /// The `device_generation` the textures were made at.
    generation: u32 = 0,

    pub fn deinit(self: *ImageTextures, alloc: std.mem.Allocator) void {
        for (self.map.values()) |t| t.deinit();
        self.map.deinit(alloc);
    }

    /// Release the textures if they're another generation's, the old
    /// device's, and take `generation`.
    fn adopt(self: *ImageTextures, generation: u32) void {
        if (self.generation == generation) return;
        for (self.map.values()) |t| t.deinit();
        self.map.clearRetainingCapacity();
        self.generation = generation;
    }
};

const Capture = struct {
    texture: *d3d11.ITexture2D,
    bitmap: *d2d1.IBitmap1,
    width: u32,
    height: u32,

    fn deinit(self: Capture) void {
        com.release(self.bitmap);
        com.release(self.texture);
    }
};

const ImageTexture = struct {
    texture: *d3d11.ITexture2D,
    srv: *d3d11.IShaderResourceView,

    fn deinit(self: ImageTexture) void {
        com.release(self.srv);
        com.release(self.texture);
    }
};

/// One grid's atlases and metrics, which the panes drawn at its size
/// share.
pub const Fonts = struct {
    /// The grid's (`font.Grid.id`).
    id: u32,
    atlas: *const font.Atlas,
    color_atlas: *const font.Atlas,
    lcd_atlas: *const font.Atlas,
    metrics: font.Grid.Metrics,

    pub fn of(grid: *const font.Grid) Fonts {
        return .{
            .id = grid.id,
            .atlas = &grid.atlas,
            .color_atlas = &grid.color_atlas,
            .lcd_atlas = &grid.lcd_atlas,
            .metrics = grid.metrics,
        };
    }
};

const GpuFonts = struct {
    atlas: AtlasTexture = .{},
    color_atlas: AtlasTexture = .{},
    lcd_atlas: AtlasTexture = .{},
    /// A pane of this frame is drawn at it.
    seen: bool = false,

    fn deinit(self: *GpuFonts) void {
        self.lcd_atlas.deinit();
        self.color_atlas.deinit();
        self.atlas.deinit();
    }
};

/// What to draw: terminals, each at its font grid's size.
pub const Frame = struct {
    panes: []const Pane,
    /// Where each float's panes start in `panes`, bottom to top: the
    /// panes before the first are the tab's under them. Each float's are
    /// drawn over the UI's ground, between its box and its strips
    /// (`ui.paintFloat`). Empty for none.
    floats: []const usize = &.{},
    /// Behind the panes, where none is.
    background: [4]f32,
    /// How each pane's box looks.
    box: BoxStyle,
};

/// A pane's box: a rounded rectangle in its terminal's background, with
/// a border inside its edge and shadows under it. Colors are straight
/// RGBA; sizes are pixels.
pub const BoxStyle = struct {
    radius: f32,
    border_width: f32,
    border: [4]f32,
    shadows: []const Shadow,

    pub const Shadow = struct {
        color: [4]f32,
        /// The blur's standard deviation.
        sigma: f32,
        /// How far down it falls.
        offset: f32,
    };
};

/// What to draw of a terminal, and where.
pub const Pane = struct {
    fonts: *const Fonts,
    cells: *const cells.Cells,
    images: *image.Images,
    textures: *ImageTextures,
    /// All of the pane, which its box fills.
    frame: Painter.Rect,
    /// The terminal's part of the window, which clips it.
    viewport: Painter.Rect,
    /// The grid's top-left in the viewport.
    grid_offset: [2]f32,
};

pub const Error = com.Error;

/// `antialias` is for the chrome's text; the grid's comes rasterized.
pub fn init(alloc: std.mem.Allocator, hwnd: win32.HWND, width: u32, height: u32, antialias: font.Antialias) Error!D3D11 {
    const pace_timer = win32.CreateWaitableTimerExW(
        null,
        null,
        win32.CREATE_WAITABLE_TIMER_MANUAL_RESET | win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
        win32.TIMER_ALL_ACCESS,
    ) orelse return error.HResult;
    errdefer _ = win32.CloseHandle(pace_timer);

    const comp: Composition = try .init(hwnd);
    errdefer comp.deinit();

    var self: D3D11 = .{
        .alloc = alloc,
        .pace_timer = pace_timer,
        .width = width,
        .height = height,
        .text_antialias = textAntialiasMode(antialias),
        .comp = comp,
    };
    self.updateRefreshRate();
    try self.createDeviceObjects(hwnd, true);
    // Signal right away: the first frame needn't wait.
    self.setPaceTimer(-1);
    return self;
}

pub fn deinit(self: *D3D11) void {
    if (!self.released) self.releaseDevice();
    for (self.pane_visuals.items) |e| e.deinit();
    self.pane_visuals.deinit(self.alloc);
    if (self.float_chain) |*fc| fc.deinit();
    if (self.overlay) |*o| o.deinit();
    self.comp.deinit();
    com.releaseOpt(&self.wic_factory);
    self.gpu_fonts.deinit(self.alloc);
    _ = win32.CloseHandle(self.pace_timer);
    self.* = undefined;
}

/// Whether the device is gone: once a `draw` or `resize` failed, it
/// may be. Says so until `recover` succeeds.
pub fn isLost(self: *D3D11) bool {
    if (self.lost) return true;
    if (self.released) return true;
    const hr = if (builtin.mode == .debug and self.debug_lose) dxgi.ERROR_DEVICE_REMOVED else self.device.getDeviceRemovedReason();
    self.debug_lose = false;
    if (hr >= 0) return false;
    log.err("device lost: HRESULT=0x{X:0>8}", .{@as(u32, @bitCast(hr))});
    self.lost = true;
    return true;
}

/// Make everything on the device again on a new one, and bump
/// `device_generation`: the composition tree and the panes' visuals
/// stay, and the new chains become the root's and the overlay's
/// content. Software (WARP) only if `allow_warp`. On error the old
/// objects are already gone and it's still lost: call again later.
/// Works on a device that isn't lost too, to move off WARP.
pub fn recover(self: *D3D11, hwnd: win32.HWND, allow_warp: bool) Error!void {
    self.lost = true;
    if (!self.released) self.releaseDevice();
    try self.createDeviceObjects(hwnd, allow_warp);
    self.lost = false;
    self.device_generation +%= 1;
    // A wait the loop made on the old chain's waitable isn't this one's.
    self.frame_acquired = false;
    self.setPaceTimer(-1);
}

/// Debug builds: have the next `isLost` say the device is gone.
pub fn loseDevice(self: *D3D11) void {
    if (builtin.mode == .debug) self.debug_lose = true;
}

/// Debug builds: have the next overlay resize fail, its targets gone.
pub fn failOverlayResize(self: *D3D11) void {
    if (builtin.mode == .debug) self.debug_fail_overlay_resize = true;
}

/// What `createDeviceObjects` makes before handing it to the renderer.
const Gpu = struct {
    factory: *dxgi.IFactory2,
    device: *d3d11.IDevice,
    context: *d3d11.IDeviceContext,
    warp: bool,
    swap_chain: *dxgi.ISwapChain1,
    swap_chain_flags: u32,
    tearing: bool,
    frame_waitable: win32.HANDLE,
    pipeline: Pipeline,
    uniforms: *d3d11.IBuffer,
    image_placement: *d3d11.IBuffer,
    box: *d3d11.IBuffer,
    d2d: D2d,

    fn init(hwnd: win32.HWND, width: u32, height: u32, text_antialias: u32, allow_warp: bool) Error!Gpu {
        // A new factory each time: one made before the adapters changed
        // still lists the old ones, and the device would be made on one.
        var factory: ?*dxgi.IFactory2 = null;
        try com.check(
            dxgi.CreateDXGIFactory2(0, &dxgi.IFactory2.iid, @ptrCast(&factory)),
            "CreateDXGIFactory2",
        );
        errdefer com.releaseOpt(&factory);

        var device: ?*d3d11.IDevice = null;
        var context: ?*d3d11.IDeviceContext = null;
        const driver = try createDevice(&device, &context, allow_warp);
        errdefer com.releaseOpt(&device);
        errdefer com.releaseOpt(&context);

        // Tearing lets a frame reach the screen without waiting for vblank
        // when DWM hands the window an independent flip (e.g. maximized on
        // a display with VRR or MPO support); otherwise DWM still composes
        // at vblank and the flag just keeps Present from blocking.
        const tearing = tearingSupported(factory.?);
        const swap_chain_flags = dxgi.SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT |
            if (tearing) dxgi.SWAP_CHAIN_FLAG_ALLOW_TEARING else 0;

        const swap_chain = try createChain(factory.?, device.?, width, height, dxgi.ALPHA_MODE_IGNORE, swap_chain_flags);
        errdefer com.release(swap_chain);

        const swap_chain2 = com.query(swap_chain, dxgi.ISwapChain2) orelse {
            log.err("swap chain has no IDXGISwapChain2", .{});
            return error.HResult;
        };
        defer com.release(swap_chain2);
        try com.check(swap_chain2.setMaximumFrameLatency(1), "IDXGISwapChain2::SetMaximumFrameLatency");
        const frame_waitable = swap_chain2.getFrameLatencyWaitableObject() orelse {
            log.err("swap chain has no frame latency waitable object", .{});
            return error.HResult;
        };
        errdefer _ = win32.CloseHandle(frame_waitable);

        // Fullscreen is ours to implement; don't let DXGI hijack Alt+Enter.
        _ = factory.?.makeWindowAssociation(hwnd, dxgi.MWA_NO_ALT_ENTER);

        var pipeline: Pipeline = try .init(device.?);
        errdefer pipeline.deinit();

        var uniforms: ?*d3d11.IBuffer = null;
        try com.check(device.?.createBuffer(&.{
            .ByteWidth = @sizeOf(cells.Uniforms),
            .Usage = d3d11.USAGE_DYNAMIC,
            .BindFlags = d3d11.BIND_CONSTANT_BUFFER,
            .CPUAccessFlags = d3d11.CPU_ACCESS_WRITE,
        }, &uniforms), "ID3D11Device::CreateBuffer(uniforms)");
        errdefer com.releaseOpt(&uniforms);

        var image_placement: ?*d3d11.IBuffer = null;
        try com.check(device.?.createBuffer(&.{
            .ByteWidth = @sizeOf(image.Placement),
            .Usage = d3d11.USAGE_DYNAMIC,
            .BindFlags = d3d11.BIND_CONSTANT_BUFFER,
            .CPUAccessFlags = d3d11.CPU_ACCESS_WRITE,
        }, &image_placement), "ID3D11Device::CreateBuffer(image placement)");
        errdefer com.releaseOpt(&image_placement);

        var box: ?*d3d11.IBuffer = null;
        try com.check(device.?.createBuffer(&.{
            .ByteWidth = @sizeOf(Box),
            .Usage = d3d11.USAGE_DYNAMIC,
            .BindFlags = d3d11.BIND_CONSTANT_BUFFER,
            .CPUAccessFlags = d3d11.CPU_ACCESS_WRITE,
        }, &box), "ID3D11Device::CreateBuffer(box)");
        errdefer com.releaseOpt(&box);

        const d2d = try createD2d(device.?, text_antialias);

        return .{
            .factory = factory.?,
            .device = device.?,
            .context = context.?,
            .warp = driver == .WARP,
            .swap_chain = swap_chain,
            .swap_chain_flags = swap_chain_flags,
            .tearing = tearing,
            .frame_waitable = frame_waitable,
            .pipeline = pipeline,
            .uniforms = uniforms.?,
            .image_placement = image_placement.?,
            .box = box.?,
            .d2d = d2d,
        };
    }
};

/// Make everything that's the device's (see `Gpu`) on a new device, the
/// back buffers' targets, the chrome's icons, and the overlay's chain if
/// there's an overlay, and make the chains the visuals' content. All or
/// nothing.
fn createDeviceObjects(self: *D3D11, hwnd: win32.HWND, allow_warp: bool) Error!void {
    std.debug.assert(self.released);
    const gpu: Gpu = try .init(hwnd, self.width, self.height, self.text_antialias, allow_warp);
    self.factory = gpu.factory;
    self.device = gpu.device;
    self.context = gpu.context;
    self.warp = gpu.warp;
    self.swap_chain = gpu.swap_chain;
    self.swap_chain_flags = gpu.swap_chain_flags;
    self.present_flags = if (gpu.tearing) dxgi.PRESENT_ALLOW_TEARING else 0;
    self.frame_waitable = gpu.frame_waitable;
    self.pipeline = gpu.pipeline;
    self.uniforms = gpu.uniforms;
    self.image_placement = gpu.image_placement;
    self.box = gpu.box;
    self.d2d_factory = gpu.d2d.factory;
    self.d2d_device = gpu.d2d.device;
    self.d2d_context = gpu.d2d.context;
    self.brush = gpu.d2d.brush;
    self.icon = Painter.Icon.init(gpu.d2d.context, @embedFile("slime-small.svg"), 1024);
    self.lucide = Painter.initLucide(gpu.d2d.context);
    self.released = false;
    errdefer self.releaseDevice();

    try self.createRenderTarget();
    if (self.overlay) |*o| try self.createLayerChain(o, "overlay");
    if (self.float_chain) |*fc| try self.createLayerChain(fc, "float");
    try com.check(self.comp.root.setContent(self.swap_chain), "IDCompositionVisual::SetContent");
    try self.commit();
    log.info("composition swap chain: waitable, max latency 1, tearing={}, refresh {d:.1} Hz", .{
        gpu.tearing,
        10_000_000.0 / @as(f64, @floatFromInt(self.refresh_period)),
    });
}

/// Let go of everything made on the device, leaving the composition
/// tree (the visuals without content) and what isn't the device's.
fn releaseDevice(self: *D3D11) void {
    std.debug.assert(!self.released);
    // The visuals hold the chains, and with them the old device.
    _ = self.comp.root.setContent(null);
    if (self.overlay) |*o| o.releaseChain();
    if (self.float_chain) |*fc| fc.releaseChain();
    _ = self.comp.device.commit();
    self.context.clearState();
    self.d2d_context.setTarget(null);
    com.releaseOpt(&self.d2d_target);
    com.releaseOpt(&self.rtv);
    if (self.icon) |icon| icon.deinit();
    self.icon = null;
    if (self.lucide) |*icons| Painter.deinitLucide(icons);
    self.lucide = null;
    if (self.capture) |c| c.deinit();
    self.capture = null;
    (D2d{ .factory = self.d2d_factory, .device = self.d2d_device, .context = self.d2d_context, .brush = self.brush }).deinit();
    com.release(self.image_placement);
    com.release(self.box);
    self.dropAtlases();
    self.instances.deinit();
    self.bg_cells.deinit();
    com.release(self.uniforms);
    self.pipeline.deinit();
    _ = win32.CloseHandle(self.frame_waitable);
    com.release(self.swap_chain);
    com.release(self.factory);
    com.release(self.context);
    com.release(self.device);
    self.frame_acquired = false;
    self.frame_started = false;
    self.released = true;
}

fn tearingSupported(factory: *dxgi.IFactory2) bool {
    const factory5 = com.query(factory, dxgi.IFactory5) orelse return false;
    defer com.release(factory5);
    var allowed: win32.BOOL = win32.FALSE;
    const hr = factory5.checkFeatureSupport(dxgi.FEATURE_PRESENT_ALLOW_TEARING, &allowed, @sizeOf(win32.BOOL));
    return hr >= 0 and allowed != win32.FALSE;
}

/// Re-read DWM's composition refresh rate, unless `-Dmax-fps` (300 by
/// default) fixes the rate. Call when the window may have moved to
/// another display or display settings changed.
pub fn updateRefreshRate(self: *D3D11) void {
    if (build_options.max_fps > 0) {
        self.refresh_period = 10_000_000 / build_options.max_fps;
        return;
    }
    var timing: win32.DWM_TIMING_INFO = .{};
    var qpc_freq: i64 = 0;
    if (win32.DwmGetCompositionTimingInfo(null, &timing) < 0 or
        timing.qpcRefreshPeriod == 0 or
        win32.QueryPerformanceFrequency(&qpc_freq) == 0)
    {
        self.refresh_period = default_refresh_period;
        return;
    }
    const period: i64 = @intCast(timing.qpcRefreshPeriod);
    self.refresh_period = @max(1, @divTrunc(period * 10_000_000, qpc_freq));
}

/// The handle the message loop should wait on before the next frame: the
/// pace timer until a refresh period has passed since the last frame,
/// then `frame_waitable`. When `frame_waitable` fires, call
/// `frameAcquired`; when the timer fires, just ask again.
pub fn frameGate(self: *const D3D11) win32.HANDLE {
    if (win32.WaitForSingleObject(self.pace_timer, 0) != win32.WAIT_OBJECT_0) return self.pace_timer;
    return self.frame_waitable;
}

/// Record that the caller already waited on `frame_waitable` (e.g. in
/// the message loop), so the next `draw` doesn't wait again.
pub fn frameAcquired(self: *D3D11) void {
    self.frame_acquired = true;
}

fn armPaceTimer(self: *D3D11) void {
    var now: i64 = undefined;
    win32.GetSystemTimePreciseAsFileTime(&now);
    // Waking a little late is normal and the next frame makes up for it.
    // More than a period behind (idle, or frames slower than the cap):
    // start the timeline over instead of catching up in a burst.
    self.frame_due += self.refresh_period;
    if (self.frame_due < now - self.refresh_period) self.frame_due = now;
    // Positive due times are absolute.
    self.setPaceTimer(self.frame_due + self.refresh_period);
}

/// Negative due times are relative, positive ones an absolute FILETIME,
/// both in 100 ns units.
fn setPaceTimer(self: *D3D11, due: i64) void {
    _ = win32.SetWaitableTimer(self.pace_timer, &due, 0, null, null, win32.FALSE);
}

/// Block until the swap chain can accept a frame, unless the message loop
/// already waited. Every Present must be preceded by exactly one
/// successful wait, or frames start queueing again. Call before taking
/// the terminal snapshot so the frame shows the newest state.
pub fn waitForFrame(self: *D3D11) void {
    if (self.lost or self.frame_started) return;
    self.frame_started = true;
    // The next frame may start a refresh period after this one starts,
    // not after it's presented, or rendering time stretches the period.
    self.armPaceTimer();
    if (self.frame_acquired) return;
    // The timeout only guards against a stuck compositor.
    self.frame_acquired = win32.WaitForSingleObject(self.frame_waitable, 1000) == win32.WAIT_OBJECT_0;
}

/// Resize the swap chain buffers to the new client area size. While
/// the device is lost, only the size is noted, for `recover`.
pub fn resize(self: *D3D11, width: u32, height: u32) Error!void {
    if (width == 0 or height == 0) return;
    if (width == self.width and height == self.height) return;
    if (self.lost) {
        self.width = width;
        self.height = height;
        return;
    }

    // All references to the back buffers must be released before
    // ResizeBuffers, including the ones bound to the pipeline.
    self.context.clearState();
    com.releaseOpt(&self.rtv);
    self.d2d_context.setTarget(null);
    com.releaseOpt(&self.d2d_target);

    try com.check(
        self.swap_chain.resizeBuffers(0, width, height, .UNKNOWN, self.swap_chain_flags),
        "IDXGISwapChain::ResizeBuffers",
    );
    self.width = width;
    self.height = height;
    try self.createRenderTarget();
    if (self.overlay) |*o| try self.resizeLayer(o);
    if (self.float_chain) |*fc| try self.resizeLayer(fc);
}

/// Draw the terminals, then `ui` over them, and present. `ui` has a
/// `paint(*Painter, Ui.Layer)` method, and `capture() ?Painter.Rect` and
/// `paintOver(*Painter, ?Painter.Image)`: when `capture` names a part of
/// the frame, that part is copied once `paint` is done, and `paintOver`
/// draws over the frame with the copy. While there's an overlay chain,
/// `paint`'s `.ground` goes into the swap chain and its `.over` and
/// `paintOver` into the overlay, which is drawn while `hasOver()` says
/// it has something; otherwise `paint` draws `.all`. The floats
/// (`Frame.floats`: `ui`'s `paintFloat` and `paintAbove`) go into the
/// float chain while there's an overlay, else into the swap chain after
/// the ground. Commits the composition tree if it changed. Waits for
/// the swap chain first unless `waitForFrame` or `frameAcquired` already
/// did. Does nothing while the device is lost.
pub fn draw(self: *D3D11, alloc: std.mem.Allocator, f: Frame, ui: anytype) error{ DeviceLost, HResult }!void {
    if (self.lost) return;
    const rtv = self.rtv orelse return;
    const ctx = self.context;
    self.waitForFrame();

    // Each grid's atlases once, however many panes are at its size; a
    // grid no pane is drawn at any more loses its copies after.
    for (self.gpu_fonts.values()) |*g| g.seen = false;
    for (f.panes) |pane| {
        const gop = self.gpu_fonts.getOrPut(self.alloc, pane.fonts.id) catch return error.HResult;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const g = gop.value_ptr;
        if (g.seen) continue;
        g.seen = true;
        try g.atlas.upload(self.device, ctx, pane.fonts.atlas);
        try g.color_atlas.upload(self.device, ctx, pane.fonts.color_atlas);
        try g.lcd_atlas.upload(self.device, ctx, pane.fonts.lcd_atlas);
    }
    defer self.dropUnseenFonts();

    // Direct2D shares the context and leaves its own state bound.
    ctx.clearState();
    ctx.omSetRenderTargets(&.{rtv});
    ctx.clearRenderTargetView(rtv, &f.background);
    try self.drawPanes(alloc, f, f.panes[0..if (f.floats.len > 0) f.floats[0] else f.panes.len]);
    // With browsers (an overlay), the floats get a chain of their own
    // over the ground's; the first frame with floats makes it. Failing
    // that, they're drawn in the ground, under the browsers.
    if (f.floats.len > 0 and self.overlay != null and self.float_chain == null) {
        self.createFloatChain() catch |err| log.warn("making the float chain failed: {}", .{err});
    }
    const layered = f.floats.len > 0 and self.float_chain != null and self.float_chain.?.rtv != null;
    if (f.floats.len > 0 and !layered) {
        // The ground under the floats, then the floats, then the ground
        // over them.
        try self.paintUi(ui, .ground);
        try self.drawFloats(alloc, f, ui, rtv);
    }
    if (self.overlay) |*o| {
        if (f.floats.len == 0 or layered) try self.paintUi(ui, .ground);
        const capture = ui.capture();
        const img = if (capture) |region| self.captureRegion(region) catch |err| img: {
            log.warn("capturing the frame failed: {}", .{err});
            break :img null;
        } else null;
        try self.presentGround();
        if (self.float_chain) |*fc| try self.drawFloatChain(fc, alloc, f, ui, layered);
        try self.drawOverlay(o, ui, capture != null, img);
    } else {
        if (f.floats.len > 0) try self.paintUi(ui, .over) else try self.paintUi(ui, .all);
        if (ui.capture()) |region| {
            const img = self.captureRegion(region) catch |err| img: {
                log.warn("capturing the frame failed: {}", .{err});
                break :img null;
            };
            try self.paintOver(ui, img);
        }
        try self.presentGround();
    }
    if (self.comp.dirty) try self.commit();
}

/// Each float's box, terminals, and strips, bottom to top, then the UI
/// over them, into `rtv` (the Direct2D target set).
fn drawFloats(self: *D3D11, alloc: std.mem.Allocator, f: Frame, ui: anytype, rtv: *d3d11.IRenderTargetView) error{ DeviceLost, HResult }!void {
    const ctx = self.context;
    for (f.floats, 0..) |start, k| {
        const end = if (k + 1 < f.floats.len) f.floats[k + 1] else f.panes.len;
        try self.paintFloat(ui, k, .box);
        ctx.clearState();
        ctx.omSetRenderTargets(&.{rtv});
        try self.drawPanes(alloc, f, f.panes[start..end]);
        try self.paintFloat(ui, k, .panes);
    }
    try self.paintAbove(ui);
}

/// The float chain's frame: the floats over transparency, if `layered`;
/// else presented clear, once, and then left alone.
fn drawFloatChain(self: *D3D11, fc: *LayerChain, alloc: std.mem.Allocator, f: Frame, ui: anytype, layered: bool) error{ DeviceLost, HResult }!void {
    if (!layered) {
        if (fc.shown) try self.clearLayer(fc);
        return;
    }
    // A failed resize left the chain without targets until the next.
    const rtv = fc.rtv orelse return;
    fc.shown = true;
    const ctx = self.context;
    ctx.clearState();
    ctx.omSetRenderTargets(&.{rtv});
    ctx.clearRenderTargetView(rtv, &.{ 0, 0, 0, 0 });
    const d2d = self.d2d_context;
    d2d.setTarget(fc.d2d_target);
    defer d2d.setTarget(self.d2d_target);
    if (self.text_antialias == d2d1.TEXT_ANTIALIAS_MODE_CLEARTYPE) d2d.setTextAntialiasMode(d2d1.TEXT_ANTIALIAS_MODE_GRAYSCALE);
    defer d2d.setTextAntialiasMode(self.text_antialias);
    try self.drawFloats(alloc, f, ui, rtv);
    try checkPresent(fc.swap_chain.?.present(0, 0));
}

/// Draw `panes`' shadows, then their boxes and terminals, over what the
/// target has.
fn drawPanes(self: *D3D11, alloc: std.mem.Allocator, f: Frame, panes: []const Pane) error{ DeviceLost, HResult }!void {
    const ctx = self.context;
    // Every shadow before any pane, so none falls on a neighbor.
    for (panes) |pane| for (f.box.shadows) |shadow| {
        const b = pane.frame;
        const reach = 3 * shadow.sigma;
        const box_rect: Painter.Rect = .{ .x = b.x, .y = b.y + shadow.offset, .w = b.w, .h = b.h };
        try self.drawBox(self.pipeline.shadow_ps, .{
            .target_size = .{ @floatFromInt(self.width), @floatFromInt(self.height) },
            .radius = f.box.radius,
            .border_width = 0,
            .bounds = rectArray(box_rect.inset(-reach, -reach)),
            .box = rectArray(box_rect),
            .fill = .{ 0, 0, 0, 0 },
            .border = .{ 0, 0, 0, 0 },
            .shadow = premultiply(shadow.color),
            .shadow_sigma = shadow.sigma,
        });
    };
    // Each pane's data replaces the last's in the same buffers, which
    // discarding maps rename, so draws already queued keep theirs.
    for (panes) |pane| {
        const v = pane.viewport;
        if (pane.frame.w < 1 or pane.frame.h < 1) continue;
        try self.drawBox(self.pipeline.box_ps, .{
            .target_size = .{ @floatFromInt(self.width), @floatFromInt(self.height) },
            .radius = f.box.radius,
            .border_width = f.box.border_width,
            .bounds = rectArray(pane.frame),
            .box = rectArray(pane.frame),
            .fill = pane.cells.uniforms(pane.fonts.metrics, .{ 0, 0, 1, 1 }, .{ 0, 0 }).default_bg,
            .border = premultiply(f.box.border),
            .shadow = .{ 0, 0, 0, 0 },
            .shadow_sigma = 0,
        });
        if (v.w < 1 or v.h < 1) continue;
        try self.bg_cells.upload(self.device, ctx, std.mem.sliceAsBytes(pane.cells.bg.items));
        try self.instances.upload(self.device, ctx, std.mem.sliceAsBytes(pane.cells.instances.items));
        try self.uploadImages(alloc, pane.images, pane.textures);

        const uniforms = pane.cells.uniforms(pane.fonts.metrics, .{ v.x, v.y, v.w, v.h }, pane.grid_offset);
        var mapped: d3d11.MAPPED_SUBRESOURCE = undefined;
        try com.check(ctx.map(self.uniforms.resource(), d3d11.MAP_WRITE_DISCARD, &mapped), "Map(uniforms)");
        @as(*cells.Uniforms, @ptrCast(@alignCast(mapped.pData.?))).* = uniforms;
        ctx.unmap(self.uniforms.resource());
        try self.drawGrid(pane);
    }
}

fn presentGround(self: *D3D11) error{ DeviceLost, HResult }!void {
    self.frame_acquired = false;
    self.frame_started = false;
    try checkPresent(self.swap_chain.present(0, self.present_flags));
}

fn checkPresent(hr: win32.HRESULT) error{ DeviceLost, HResult }!void {
    // The caller's `isLost` and `recover` deal with it.
    if (hr == dxgi.ERROR_DEVICE_REMOVED or hr == dxgi.ERROR_DEVICE_RESET) return error.DeviceLost;
    try com.check(hr, "IDXGISwapChain::Present");
}

/// The overlay's frame: `ui`'s `.over` and, if `capture`, `paintOver`
/// with `img`, over transparency. An overlay with nothing to show is
/// presented cleared, and then left alone.
fn drawOverlay(self: *D3D11, o: *LayerChain, ui: anytype, capture: bool, img: ?Painter.Image) error{ DeviceLost, HResult }!void {
    const over = ui.hasOver();
    if (!over) {
        if (o.shown) try self.clearLayer(o);
        return;
    }
    // A failed resize left the overlay without targets until the next.
    const rtv = o.rtv orelse return;
    o.shown = true;
    self.context.clearRenderTargetView(rtv, &.{ 0, 0, 0, 0 });
    const d2d = self.d2d_context;
    d2d.setTarget(o.d2d_target);
    defer d2d.setTarget(self.d2d_target);
    // ClearType needs opaque pixels under the text to blend with.
    if (self.text_antialias == d2d1.TEXT_ANTIALIAS_MODE_CLEARTYPE) d2d.setTextAntialiasMode(d2d1.TEXT_ANTIALIAS_MODE_GRAYSCALE);
    defer d2d.setTextAntialiasMode(self.text_antialias);
    d2d.beginDraw();
    var p = self.painter();
    ui.paint(&p, .over);
    if (capture) ui.paintOver(&p, img);
    try com.check(d2d.endDraw(), "ID2D1DeviceContext::EndDraw(overlay)");
    try checkPresent(o.swap_chain.?.present(0, 0));
}

/// Shader constants for a pane's box. Must match `Box` in shaders.hlsl.
const Box = extern struct {
    target_size: [2]f32,
    radius: f32,
    border_width: f32,
    bounds: [4]f32,
    box: [4]f32,
    fill: [4]f32,
    border: [4]f32,
    shadow: [4]f32,
    shadow_sigma: f32,
    _pad: [3]f32 = .{ 0, 0, 0 },

    comptime {
        std.debug.assert(@sizeOf(Box) % 16 == 0);
    }
};

fn rectArray(r: Painter.Rect) [4]f32 {
    return .{ r.x, r.y, r.w, r.h };
}

fn premultiply(c: [4]f32) [4]f32 {
    return .{ c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3] };
}

/// One quad of a pane's box or shadow, over the whole render target.
fn drawBox(self: *D3D11, ps: *d3d11.IPixelShader, b: Box) Error!void {
    const ctx = self.context;
    var mapped: d3d11.MAPPED_SUBRESOURCE = undefined;
    try com.check(ctx.map(self.box.resource(), d3d11.MAP_WRITE_DISCARD, &mapped), "Map(box)");
    @as(*Box, @ptrCast(@alignCast(mapped.pData.?))).* = b;
    ctx.unmap(self.box.resource());
    ctx.rsSetViewports(&.{.{ .TopLeftX = 0, .TopLeftY = 0, .Width = @floatFromInt(self.width), .Height = @floatFromInt(self.height) }});
    ctx.iaSetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    ctx.vsSetShader(self.pipeline.box_vs);
    ctx.vsSetConstantBuffers(2, &.{self.box});
    ctx.psSetShader(ps);
    ctx.psSetConstantBuffers(2, &.{self.box});
    ctx.omSetBlendState(self.pipeline.blend);
    ctx.draw(4, 0);
}

/// The grid's passes, with kitty images before, between, and after them,
/// clipped to the viewport, over the pane's box.
fn drawGrid(self: *D3D11, f: Pane) Error!void {
    const ctx = self.context;
    const frame = f.cells;
    const images = f.images;
    const v = f.viewport;
    ctx.rsSetViewports(&.{.{ .TopLeftX = v.x, .TopLeftY = v.y, .Width = v.w, .Height = v.h }});
    try self.drawImages(images, f.textures, .below_bg);

    if (frame.bg.items.len > 0) {
        ctx.iaSetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx.vsSetShader(self.pipeline.bg_vs);
        ctx.psSetShader(self.pipeline.bg_ps);
        ctx.psSetConstantBuffers(0, &.{self.uniforms});
        ctx.psSetShaderResources(0, &.{self.bg_cells.srv});
        ctx.omSetBlendState(self.pipeline.blend);
        ctx.draw(3, 0);
    }
    try self.drawImages(images, f.textures, .below_text);

    if (frame.instances.items.len > 0) {
        ctx.iaSetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        ctx.vsSetShader(self.pipeline.text_vs);
        ctx.vsSetConstantBuffers(0, &.{self.uniforms});
        ctx.vsSetShaderResources(1, &.{self.instances.srv});
        ctx.psSetShader(self.pipeline.text_ps);
        const g = self.gpu_fonts.getPtr(f.fonts.id).?;
        ctx.psSetShaderResources(2, &.{ g.atlas.srv, g.color_atlas.srv, g.lcd_atlas.srv });
        ctx.omSetBlendState(self.pipeline.text_blend);
        ctx.drawInstanced(4, @intCast(frame.instances.items.len), 0, 0);
    }
    try self.drawImages(images, f.textures, .above_text);
}

fn painter(self: *const D3D11) Painter {
    return .{
        .ctx = self.d2d_context,
        .factory = self.d2d_factory,
        .brush = self.brush,
        .icon = self.icon,
        .lucide = if (self.lucide) |*icons| icons else null,
        .generation = self.device_generation,
    };
}

fn paintOver(self: *D3D11, ui: anytype, img: ?Painter.Image) Error!void {
    const d2d = self.d2d_context;
    d2d.beginDraw();
    var p = self.painter();
    ui.paintOver(&p, img);
    try com.check(d2d.endDraw(), "ID2D1DeviceContext::EndDraw");
}

/// Copy `region` of the frame drawn so far, as an image for Direct2D.
/// Direct2D's EndDraw has flushed its drawing to the context, so the
/// copy, queued after it, sees it.
fn captureRegion(self: *D3D11, region: Painter.Rect) Error!?Painter.Image {
    const x0: u32 = @intFromFloat(std.math.clamp(@round(region.x), 0, @as(f32, @floatFromInt(self.width))));
    const y0: u32 = @intFromFloat(std.math.clamp(@round(region.y), 0, @as(f32, @floatFromInt(self.height))));
    const x1: u32 = @intFromFloat(std.math.clamp(@round(region.right()), 0, @as(f32, @floatFromInt(self.width))));
    const y1: u32 = @intFromFloat(std.math.clamp(@round(region.bottom()), 0, @as(f32, @floatFromInt(self.height))));
    if (x1 <= x0 or y1 <= y0) return null;
    const w = x1 - x0;
    const h = y1 - y0;
    if (self.capture) |c| if (c.width != w or c.height != h) {
        c.deinit();
        self.capture = null;
    };
    if (self.capture == null) self.capture = try self.createCapture(w, h);
    const c = self.capture.?;

    var back_buffer: ?*d3d11.ITexture2D = null;
    try com.check(
        self.swap_chain.getBuffer(0, &d3d11.ITexture2D.iid, @ptrCast(&back_buffer)),
        "IDXGISwapChain::GetBuffer",
    );
    defer com.releaseOpt(&back_buffer);
    self.context.copySubresourceRegion(c.texture.resource(), 0, 0, back_buffer.?.resource(), &.{ .left = x0, .top = y0, .right = x1, .bottom = y1 });
    return .{ .bitmap = c.bitmap, .w = @floatFromInt(w), .h = @floatFromInt(h), .generation = self.device_generation };
}

/// Decode the PNG (or JPEG) in `stream`, read from its start, into an
/// image to draw with `Painter.image`. The caller owns it: release its
/// bitmap, before the renderer goes. It's this device's: after
/// `recover`, it draws nothing, and should be decoded again.
pub fn decodeImage(self: *D3D11, stream: *win32.IStream) Error!Painter.Image {
    if (self.released) return error.HResult;
    if (self.wic_factory == null) {
        var out: ?*anyopaque = null;
        try com.check(win32.CoCreateInstance(&wic.CLSID_ImagingFactory, null, win32.CLSCTX_INPROC_SERVER, &wic.IImagingFactory.iid, &out), "CoCreateInstance(WICImagingFactory)");
        self.wic_factory = @ptrCast(@alignCast(out.?));
    }
    const factory = self.wic_factory.?;
    try com.check(stream.rewind(), "IStream::Seek");
    var decoder: ?*wic.IBitmapDecoder = null;
    try com.check(factory.createDecoderFromStream(stream, &decoder), "IWICImagingFactory::CreateDecoderFromStream");
    defer com.releaseOpt(&decoder);
    var frame: ?*wic.IBitmapSource = null;
    try com.check(decoder.?.getFrame(0, &frame), "IWICBitmapDecoder::GetFrame");
    defer com.releaseOpt(&frame);
    var converter: ?*wic.IFormatConverter = null;
    try com.check(factory.createFormatConverter(&converter), "IWICImagingFactory::CreateFormatConverter");
    defer com.releaseOpt(&converter);
    try com.check(converter.?.initialize(frame.?, &wic.GUID_PixelFormat32bppPBGRA), "IWICFormatConverter::Initialize");
    var w: u32 = 0;
    var h: u32 = 0;
    try com.check(frame.?.getSize(&w, &h), "IWICBitmapSource::GetSize");
    if (w == 0 or h == 0) return error.HResult;
    var bitmap: ?*d2d1.IBitmap1 = null;
    try com.check(self.d2d_context.createBitmapFromWicBitmap(converter.?, &.{
        .pixelFormat = .{ .format = buffer_format, .alphaMode = d2d1.ALPHA_MODE_PREMULTIPLIED },
        .bitmapOptions = 0,
    }, &bitmap), "ID2D1DeviceContext::CreateBitmapFromWicBitmap");
    return .{ .bitmap = bitmap.?, .w = @floatFromInt(w), .h = @floatFromInt(h), .generation = self.device_generation };
}

fn createCapture(self: *D3D11, w: u32, h: u32) Error!Capture {
    var texture: ?*d3d11.ITexture2D = null;
    try com.check(self.device.createTexture2D(&.{
        .Width = w,
        .Height = h,
        .Format = buffer_format,
        .Usage = d3d11.USAGE_DEFAULT,
        .BindFlags = d3d11.BIND_SHADER_RESOURCE,
    }, &texture), "ID3D11Device::CreateTexture2D(capture)");
    errdefer com.releaseOpt(&texture);
    const surface = com.query(texture.?, dxgi.ISurface) orelse {
        log.err("capture texture has no IDXGISurface", .{});
        return error.HResult;
    };
    defer com.release(surface);
    var bitmap: ?*d2d1.IBitmap1 = null;
    try com.check(self.d2d_context.createBitmapFromDxgiSurface(surface, &.{
        .pixelFormat = .{ .format = buffer_format, .alphaMode = d2d1.ALPHA_MODE_IGNORE },
        .bitmapOptions = 0,
    }, &bitmap), "ID2D1DeviceContext::CreateBitmapFromDxgiSurface(capture)");
    return .{ .texture = texture.?, .bitmap = bitmap.?, .width = w, .height = h };
}

/// Float `k`'s box, or its panes' strips (`Ui.paintFloat`).
fn paintFloat(self: *D3D11, ui: anytype, k: usize, part: anytype) Error!void {
    const d2d = self.d2d_context;
    d2d.beginDraw();
    var p = self.painter();
    ui.paintFloat(&p, k, part);
    try com.check(d2d.endDraw(), "ID2D1DeviceContext::EndDraw(float)");
}

/// The UI's ground over the floats (`Ui.paintAbove`).
fn paintAbove(self: *D3D11, ui: anytype) Error!void {
    const d2d = self.d2d_context;
    d2d.beginDraw();
    var p = self.painter();
    ui.paintAbove(&p);
    try com.check(d2d.endDraw(), "ID2D1DeviceContext::EndDraw(above)");
}

fn paintUi(self: *D3D11, ui: anytype, layer: anytype) Error!void {
    const d2d = self.d2d_context;
    d2d.beginDraw();
    var p = self.painter();
    ui.paint(&p, layer);
    try com.check(d2d.endDraw(), "ID2D1DeviceContext::EndDraw");
}

/// Draw one layer of kitty images, each placement a quad with its image
/// bound (see shaders.hlsl).
fn drawImages(self: *D3D11, images: *const image.Images, textures: *const ImageTextures, layer: image.Layer) Error!void {
    const start, const end = images.layer(layer);
    if (start == end) return;
    const ctx = self.context;
    ctx.iaSetPrimitiveTopology(d3d11.PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    ctx.vsSetShader(self.pipeline.image_vs);
    ctx.vsSetConstantBuffers(0, &.{ self.uniforms, self.image_placement });
    ctx.psSetShader(self.pipeline.image_ps);
    ctx.psSetSamplers(0, &.{self.pipeline.image_sampler});
    ctx.omSetBlendState(self.pipeline.blend);
    for (images.placements.items[start..end], images.placement_ids.items[start..end]) |p, id| {
        const tex = textures.map.get(id) orelse continue;
        var mapped: d3d11.MAPPED_SUBRESOURCE = undefined;
        try com.check(ctx.map(self.image_placement.resource(), d3d11.MAP_WRITE_DISCARD, &mapped), "Map(image placement)");
        @as(*image.Placement, @ptrCast(@alignCast(mapped.pData.?))).* = p;
        ctx.unmap(self.image_placement.resource());
        ctx.psSetShaderResources(5, &.{tex.srv});
        ctx.draw(4, 0);
    }
}

/// The GPU copy of a font atlas.
const AtlasTexture = struct {
    texture: ?*d3d11.ITexture2D = null,
    srv: ?*d3d11.IShaderResourceView = null,
    size: u32 = 0,
    generation: u64 = 0,

    fn deinit(self: *AtlasTexture) void {
        com.releaseOpt(&self.srv);
        com.releaseOpt(&self.texture);
    }

    /// Mirror `atlas`, reallocating if it grew.
    fn upload(self: *AtlasTexture, device: *d3d11.IDevice, ctx: *d3d11.IDeviceContext, atlas: *const font.Atlas) Error!void {
        if (self.size != atlas.size) {
            self.deinit();
            self.size = 0;

            try com.check(device.createTexture2D(&.{
                .Width = atlas.size,
                .Height = atlas.size,
                .Format = switch (atlas.format) {
                    .gray => .R8_UNORM,
                    .rgba, .lcd => .R8G8B8A8_UNORM,
                },
                .Usage = d3d11.USAGE_DEFAULT,
                .BindFlags = d3d11.BIND_SHADER_RESOURCE,
            }, &self.texture), "ID3D11Device::CreateTexture2D(atlas)");
            try com.check(
                device.createShaderResourceView(self.texture.?.resource(), &self.srv),
                "ID3D11Device::CreateShaderResourceView(atlas)",
            );
            self.size = atlas.size;
            self.generation = atlas.generation -% 1;
            log.debug("{t} atlas texture {d}x{d}", .{ atlas.format, atlas.size, atlas.size });
        }

        if (self.generation != atlas.generation) {
            ctx.updateSubresource(self.texture.?.resource(), atlas.data.ptr, atlas.size * atlas.format.depth());
            self.generation = atlas.generation;
        }
    }
};

/// Mirror the snapshot's images on the GPU: upload new or changed images,
/// freeing their pixels, and release textures of images no longer in it.
fn uploadImages(self: *D3D11, alloc: std.mem.Allocator, images: *image.Images, textures: *ImageTextures) Error!void {
    // Made on a device that's gone: slime sends the pixels again.
    textures.adopt(self.device_generation);
    var i: usize = 0;
    while (i < textures.map.count()) {
        if (images.images.contains(textures.map.keys()[i])) {
            i += 1;
            continue;
        }
        textures.map.values()[i].deinit();
        textures.map.swapRemoveAt(i);
    }

    var it = images.images.iterator();
    while (it.next()) |kv| {
        const img = kv.value_ptr;
        const rgba = img.rgba orelse continue;
        const gop = textures.map.getOrPut(alloc, kv.key_ptr.*) catch return error.HResult;
        if (gop.found_existing) gop.value_ptr.deinit();
        errdefer textures.map.swapRemoveAt(gop.index);

        var texture: ?*d3d11.ITexture2D = null;
        try com.check(self.device.createTexture2D(&.{
            .Width = img.width,
            .Height = img.height,
            .Format = .R8G8B8A8_UNORM,
            .Usage = d3d11.USAGE_DEFAULT,
            .BindFlags = d3d11.BIND_SHADER_RESOURCE,
        }, &texture), "ID3D11Device::CreateTexture2D(image)");
        errdefer com.releaseOpt(&texture);
        var srv: ?*d3d11.IShaderResourceView = null;
        try com.check(
            self.device.createShaderResourceView(texture.?.resource(), &srv),
            "ID3D11Device::CreateShaderResourceView(image)",
        );
        self.context.updateSubresource(texture.?.resource(), rgba.ptr, img.width * 4);
        gop.value_ptr.* = .{ .texture = texture.?, .srv = srv.? };
        image.Images.freePixels(alloc, img);
        log.debug("image texture id={d} {d}x{d}", .{ kv.key_ptr.*, img.width, img.height });
    }
}

fn createRenderTarget(self: *D3D11) Error!void {
    try self.createTargets(self.swap_chain, d2d1.ALPHA_MODE_IGNORE, &self.rtv, &self.d2d_target);
    self.d2d_context.setTarget(self.d2d_target);
}

/// Direct3D and Direct2D targets over `chain`'s back buffer.
fn createTargets(
    self: *D3D11,
    chain: *dxgi.ISwapChain1,
    alpha_mode: u32,
    rtv: *?*d3d11.IRenderTargetView,
    d2d_target: *?*d2d1.IBitmap1,
) Error!void {
    // With the flip model, buffer 0 is always the one being drawn, so
    // both targets follow the swap chain as it flips.
    var back_buffer: ?*d3d11.ITexture2D = null;
    try com.check(
        chain.getBuffer(0, &d3d11.ITexture2D.iid, @ptrCast(&back_buffer)),
        "IDXGISwapChain::GetBuffer",
    );
    defer com.releaseOpt(&back_buffer);

    try com.check(
        self.device.createRenderTargetView(back_buffer.?.resource(), rtv),
        "ID3D11Device::CreateRenderTargetView",
    );
    errdefer com.releaseOpt(rtv);

    const surface = com.query(back_buffer.?, dxgi.ISurface) orelse {
        log.err("back buffer has no IDXGISurface", .{});
        return error.HResult;
    };
    defer com.release(surface);
    try com.check(self.d2d_context.createBitmapFromDxgiSurface(surface, &.{
        .pixelFormat = .{ .format = buffer_format, .alphaMode = alpha_mode },
        .bitmapOptions = d2d1.BITMAP_OPTIONS_TARGET | d2d1.BITMAP_OPTIONS_CANNOT_DRAW,
    }, d2d_target), "ID2D1DeviceContext::CreateBitmapFromDxgiSurface");
}

/// A flip-model chain for a visual's content. A composition chain can't
/// take the window's size the way one on the HWND did, and refuses an
/// empty one: a client area a title bar high gets a 1 px chain, resized
/// with the window.
fn createChain(factory: *dxgi.IFactory2, device: *d3d11.IDevice, width: u32, height: u32, alpha_mode: u32, flags: u32) Error!*dxgi.ISwapChain1 {
    var chain: ?*dxgi.ISwapChain1 = null;
    try com.check(factory.createSwapChainForComposition(device, &.{
        .Width = @max(1, width),
        .Height = @max(1, height),
        .Format = buffer_format,
        .BufferUsage = dxgi.USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = buffer_count,
        // The only scaling composition takes; the buffers always match
        // the window, so nothing is scaled.
        .Scaling = dxgi.SCALING_STRETCH,
        .SwapEffect = dxgi.SWAP_EFFECT_FLIP_DISCARD,
        .AlphaMode = alpha_mode,
        .Flags = flags,
    }, &chain), "IDXGIFactory2::CreateSwapChainForComposition");
    return chain.?;
}

/// The window's DirectComposition tree: a root visual whose content is
/// the swap chain, and whose children, over it, are the panes' container
/// visuals and then the overlay's. Made without a rendering device, so
/// a lost one leaves it standing.
const Composition = struct {
    device: *dcomp.IDesktopDevice,
    target: *dcomp.ITarget,
    root: *dcomp.IVisual,
    /// Set when the tree changed since the last commit. Presents need
    /// none.
    dirty: bool = false,

    /// The root's content, the swap chain, is the caller's to set.
    fn init(hwnd: win32.HWND) Error!Composition {
        var device: ?*dcomp.IDesktopDevice = null;
        try com.check(
            dcomp.DCompositionCreateDevice3(null, &dcomp.IDesktopDevice.iid, @ptrCast(&device)),
            "DCompositionCreateDevice3",
        );
        errdefer com.releaseOpt(&device);
        var target: ?*dcomp.ITarget = null;
        try com.check(device.?.createTargetForHwnd(hwnd, true, &target), "IDCompositionDesktopDevice::CreateTargetForHwnd");
        errdefer com.releaseOpt(&target);
        var root: ?*dcomp.IVisual = null;
        try com.check(device.?.createVisual(&root), "IDCompositionDevice2::CreateVisual");
        errdefer com.releaseOpt(&root);
        try com.check(target.?.setRoot(root.?), "IDCompositionTarget::SetRoot");
        return .{ .device = device.?, .target = target.?, .root = root.? };
    }

    fn deinit(self: Composition) void {
        com.release(self.root);
        com.release(self.target);
        com.release(self.device);
    }
};

/// Apply what changed in the composition tree since the last commit. `draw`
/// does it after presenting; call it when the tree changes with no frame
/// to draw.
pub fn commit(self: *D3D11) Error!void {
    try com.check(self.comp.device.commit(), "IDCompositionDevice2::Commit");
    self.comp.dirty = false;
}

/// Where and how a browser pane's visual shows.
pub const PaneVisual = struct {
    /// The pane's content, under its title strip, in the client area's
    /// pixels.
    rect: Painter.Rect,
    /// The radius of the box's bottom corners; the top ones meet the
    /// strip.
    radius: f32,
    /// Below 1, the ground under it shows through: an unfocused pane.
    opacity: f32 = 1,
    /// Under the floats (the shown tab's) or over them (a float's own).
    layer: Layer = .ground,
};

/// Where a pane's visual goes among the chains: over the ground and
/// under the float chain, or over the float chain and under the overlay.
pub const Layer = enum { ground, float };

const PaneVisualEntry = struct {
    key: u64,
    visual: *dcomp.IVisual3,
    clip: *dcomp.IRectangleClip,
    props: PaneVisual,

    fn deinit(self: PaneVisualEntry) void {
        com.release(self.clip);
        com.release(self.visual);
    }

    fn apply(self: *PaneVisualEntry, p: PaneVisual) Error!void {
        const v = self.visual.visual();
        const c = self.clip;
        try com.check(v.setOffsetX(p.rect.x), "IDCompositionVisual::SetOffsetX");
        try com.check(v.setOffsetY(p.rect.y), "IDCompositionVisual::SetOffsetY");
        // The clip is in the visual's space, which the offset moved.
        try com.check(c.setLeft(0), "IDCompositionRectangleClip::SetLeft");
        try com.check(c.setTop(0), "IDCompositionRectangleClip::SetTop");
        try com.check(c.setRight(p.rect.w), "IDCompositionRectangleClip::SetRight");
        try com.check(c.setBottom(p.rect.h), "IDCompositionRectangleClip::SetBottom");
        try com.check(c.setBottomLeftRadiusX(p.radius), "IDCompositionRectangleClip::SetBottomLeftRadiusX");
        try com.check(c.setBottomLeftRadiusY(p.radius), "IDCompositionRectangleClip::SetBottomLeftRadiusY");
        try com.check(c.setBottomRightRadiusX(p.radius), "IDCompositionRectangleClip::SetBottomRightRadiusX");
        try com.check(c.setBottomRightRadiusY(p.radius), "IDCompositionRectangleClip::SetBottomRightRadiusY");
        try com.check(self.visual.setOpacity(p.opacity), "IDCompositionVisual3::SetOpacity");
        self.props = p;
    }
};

/// Show a container visual for the pane `key` (its ID) as `props` says,
/// over the swap chain and under the overlay (in its layer, about the
/// float chain). The first one made brings the overlay chain, so the UI
/// over panes is drawn over it from the next frame. The caller hangs the
/// pane's own visual under the one returned, which stays the same until
/// `removePaneVisual`. Call again whenever the layout or focus changes;
/// the tree is committed with the next `draw` or `commit`. A pane a tab
/// switch or a zoom hides is removed, not hidden, so a window showing
/// none has no overlay and its UI gets ClearType back.
pub fn setPaneVisual(self: *D3D11, key: u64, props: PaneVisual) Error!*dcomp.IVisual {
    for (self.pane_visuals.items) |*e| if (e.key == key) {
        if (!std.meta.eql(e.props, props)) {
            const moved = e.props.layer != props.layer;
            try e.apply(props);
            if (moved) {
                _ = self.comp.root.removeVisual(e.visual.visual());
                try self.insertPaneVisual(e.visual.visual(), props.layer);
            }
            self.comp.dirty = true;
        }
        return e.visual.visual();
    };

    var visual: ?*dcomp.IVisual = null;
    try com.check(self.comp.device.createVisual(&visual), "IDCompositionDevice2::CreateVisual");
    defer com.releaseOpt(&visual);
    const visual3 = com.query(visual.?, dcomp.IVisual3) orelse {
        log.err("visual has no IDCompositionVisual3", .{});
        return error.HResult;
    };
    var clip: ?*dcomp.IRectangleClip = null;
    com.check(self.comp.device.createRectangleClip(&clip), "IDCompositionDevice2::CreateRectangleClip") catch |err| {
        com.release(visual3);
        return err;
    };
    var entry: PaneVisualEntry = .{ .key = key, .visual = visual3, .clip = clip.?, .props = props };
    errdefer entry.deinit();
    try com.check(visual.?.setClip(clip.?), "IDCompositionVisual::SetClip");
    try entry.apply(props);
    self.pane_visuals.ensureUnusedCapacity(self.alloc, 1) catch return error.HResult;

    try self.insertPaneVisual(visual.?, props.layer);
    self.pane_visuals.appendAssumeCapacity(entry);
    self.comp.dirty = true;
    return visual3.visual();
}

/// Put a pane's visual in the tree in `layer`: under the float chain
/// (or the overlay, with none) for the ground, under the overlay for a
/// float. The first makes the overlay, over it.
fn insertPaneVisual(self: *D3D11, visual: *dcomp.IVisual, layer: Layer) Error!void {
    const root = self.comp.root;
    const o = self.overlay orelse {
        try com.check(root.addVisual(visual, true, null), "IDCompositionVisual::AddVisual");
        self.createOverlay(visual) catch |err| {
            _ = root.removeVisual(visual);
            return err;
        };
        return;
    };
    const under = switch (layer) {
        .ground => if (self.float_chain) |fc| fc.visual else o.visual,
        .float => o.visual,
    };
    try com.check(root.addVisual(visual, false, under), "IDCompositionVisual::AddVisual");
}

/// Remove the pane `key`'s visual, and the overlay and float chain with
/// the last one. Whatever the caller hung under it goes with it.
pub fn removePaneVisual(self: *D3D11, key: u64) void {
    for (self.pane_visuals.items, 0..) |e, i| if (e.key == key) {
        _ = self.comp.root.removeVisual(e.visual.visual());
        e.deinit();
        _ = self.pane_visuals.swapRemove(i);
        self.comp.dirty = true;
        break;
    };
    if (self.pane_visuals.items.len == 0) {
        if (self.float_chain) |*fc| {
            _ = self.comp.root.removeVisual(fc.visual);
            fc.deinit();
            self.float_chain = null;
            log.info("float chain destroyed", .{});
        }
        if (self.overlay) |*o| {
            _ = self.comp.root.removeVisual(o.visual);
            o.deinit();
            self.overlay = null;
            self.comp.dirty = true;
            log.info("overlay chain destroyed", .{});
        }
    }
}

/// A transparent chain over the panes' visuals, the window's size: the
/// overlay, or the floats'. The visual outlives a lost device; the chain
/// and its targets don't.
const LayerChain = struct {
    visual: *dcomp.IVisual,
    /// Null while the device is lost.
    swap_chain: ?*dxgi.ISwapChain1 = null,
    rtv: ?*d3d11.IRenderTargetView = null,
    d2d_target: ?*d2d1.IBitmap1 = null,
    /// What was last presented isn't clear.
    shown: bool = false,

    fn releaseTargets(self: *LayerChain) void {
        com.releaseOpt(&self.rtv);
        com.releaseOpt(&self.d2d_target);
    }

    /// Let the chain go, leaving the visual empty.
    fn releaseChain(self: *LayerChain) void {
        self.releaseTargets();
        if (self.swap_chain == null) return;
        _ = self.visual.setContent(null);
        com.releaseOpt(&self.swap_chain);
        self.shown = false;
    }

    fn deinit(self: *LayerChain) void {
        self.releaseChain();
        com.release(self.visual);
    }
};

/// Make the overlay, its chain presented clear, and put it over `above`.
/// While the device is lost, the visual alone: `recover` makes the
/// chain.
fn createOverlay(self: *D3D11, above: *dcomp.IVisual) Error!void {
    var visual: ?*dcomp.IVisual = null;
    try com.check(self.comp.device.createVisual(&visual), "IDCompositionDevice2::CreateVisual");
    var o: LayerChain = .{ .visual = visual.? };
    errdefer o.deinit();
    if (!self.released) try self.createLayerChain(&o, "overlay");
    try com.check(self.comp.root.addVisual(o.visual, true, above), "IDCompositionVisual::AddVisual");
    self.overlay = o;
}

/// Make the float chain, presented clear, right under the overlay, and
/// move the floats' pane visuals over it. While the device is lost, the
/// visual alone: `recover` makes the chain.
fn createFloatChain(self: *D3D11) Error!void {
    const o = self.overlay orelse return error.HResult;
    var visual: ?*dcomp.IVisual = null;
    try com.check(self.comp.device.createVisual(&visual), "IDCompositionDevice2::CreateVisual");
    var fc: LayerChain = .{ .visual = visual.? };
    errdefer fc.deinit();
    if (!self.released) try self.createLayerChain(&fc, "float");
    const root = self.comp.root;
    try com.check(root.addVisual(fc.visual, false, o.visual), "IDCompositionVisual::AddVisual");
    for (self.pane_visuals.items) |e| {
        if (e.props.layer != .float) continue;
        _ = root.removeVisual(e.visual.visual());
        try com.check(root.addVisual(e.visual.visual(), false, o.visual), "IDCompositionVisual::AddVisual");
    }
    self.float_chain = fc;
    self.comp.dirty = true;
}

/// Make `c`'s chain, presented clear, its visual's content.
fn createLayerChain(self: *D3D11, c: *LayerChain, name: []const u8) Error!void {
    const chain = try createChain(self.factory, self.device, self.width, self.height, dxgi.ALPHA_MODE_PREMULTIPLIED, 0);
    c.swap_chain = chain;
    errdefer c.releaseChain();
    try self.createTargets(chain, d2d1.ALPHA_MODE_PREMULTIPLIED, &c.rtv, &c.d2d_target);
    try self.clearLayer(c);
    try com.check(c.visual.setContent(chain), "IDCompositionVisual::SetContent");
    self.comp.dirty = true;
    log.info("{s} chain created {d}x{d}", .{ name, self.width, self.height });
}

/// Present a layer's chain clear. Twice: DWM can hold a flip chain's
/// last present back until another comes (it did with no display
/// attached), and a layer presents nothing more until it has something
/// to show, so a single clear left a closed dialog on screen.
fn clearLayer(self: *D3D11, c: *LayerChain) Error!void {
    const rtv = c.rtv orelse return;
    for (0..2) |_| {
        self.context.clearRenderTargetView(rtv, &.{ 0, 0, 0, 0 });
        try com.check(c.swap_chain.?.present(0, 0), "IDXGISwapChain::Present(layer)");
    }
    c.shown = false;
}

fn resizeLayer(self: *D3D11, c: *LayerChain) Error!void {
    const chain = c.swap_chain orelse return;
    c.releaseTargets();
    if (builtin.mode == .debug and self.debug_fail_overlay_resize) {
        self.debug_fail_overlay_resize = false;
        log.err("IDXGISwapChain::ResizeBuffers(layer) failed on purpose", .{});
        return error.HResult;
    }
    try com.check(
        chain.resizeBuffers(0, self.width, self.height, .UNKNOWN, 0),
        "IDXGISwapChain::ResizeBuffers(layer)",
    );
    try self.createTargets(chain, d2d1.ALPHA_MODE_PREMULTIPLIED, &c.rtv, &c.d2d_target);
    // The resized buffers hold nothing presentable.
    try self.clearLayer(c);
}

const D2d = struct {
    factory: *d2d1.IFactory1,
    device: *d2d1.IDevice,
    context: *d2d1.IDeviceContext,
    brush: *d2d1.ISolidColorBrush,

    fn deinit(self: D2d) void {
        com.release(self.brush);
        com.release(self.context);
        com.release(self.device);
        com.release(self.factory);
    }
};

/// A Direct2D device context on our D3D device, which was created with
/// BGRA support for this. Its DPI stays at 96, so it draws in pixels.
fn textAntialiasMode(antialias: font.Antialias) u32 {
    return switch (antialias) {
        .grayscale => d2d1.TEXT_ANTIALIAS_MODE_GRAYSCALE,
        .cleartype => d2d1.TEXT_ANTIALIAS_MODE_CLEARTYPE,
        .aliased => d2d1.TEXT_ANTIALIAS_MODE_ALIASED,
    };
}

/// The font grids were made anew (a config reload): their atlases are
/// uploaded afresh, whatever generation they're at.
pub fn dropAtlases(self: *D3D11) void {
    for (self.gpu_fonts.values()) |*g| g.deinit();
    self.gpu_fonts.clearRetainingCapacity();
}

/// Release the atlases of grids the frame drew no pane at.
fn dropUnseenFonts(self: *D3D11) void {
    var i: usize = 0;
    while (i < self.gpu_fonts.count()) {
        const g = &self.gpu_fonts.values()[i];
        if (g.seen) {
            i += 1;
            continue;
        }
        g.deinit();
        self.gpu_fonts.swapRemoveAt(i);
    }
}

/// Change the chrome's text antialiasing: `font-antialias` was reloaded.
pub fn setTextAntialias(self: *D3D11, antialias: font.Antialias) void {
    self.text_antialias = textAntialiasMode(antialias);
    if (!self.released) self.d2d_context.setTextAntialiasMode(self.text_antialias);
}

fn createD2d(device: *d3d11.IDevice, text_antialias: u32) Error!D2d {
    var factory: ?*d2d1.IFactory1 = null;
    try com.check(
        d2d1.D2D1CreateFactory(d2d1.FACTORY_TYPE_SINGLE_THREADED, &d2d1.IFactory1.iid, null, @ptrCast(&factory)),
        "D2D1CreateFactory",
    );
    errdefer com.releaseOpt(&factory);

    const dxgi_device = com.query(device, dxgi.IDevice) orelse {
        log.err("device has no IDXGIDevice", .{});
        return error.HResult;
    };
    defer com.release(dxgi_device);
    var d2d_device: ?*d2d1.IDevice = null;
    try com.check(factory.?.createDevice(dxgi_device, &d2d_device), "ID2D1Factory1::CreateDevice");
    errdefer com.releaseOpt(&d2d_device);

    var context: ?*d2d1.IDeviceContext = null;
    try com.check(d2d_device.?.createDeviceContext(0, &context), "ID2D1Device::CreateDeviceContext");
    errdefer com.releaseOpt(&context);
    context.?.setTextAntialiasMode(text_antialias);

    var brush: ?*d2d1.ISolidColorBrush = null;
    try com.check(context.?.createSolidColorBrush(&.{ 0, 0, 0, 1 }, &brush), "ID2D1DeviceContext::CreateSolidColorBrush");

    return .{ .factory = factory.?, .device = d2d_device.?, .context = context.?, .brush = brush.? };
}

/// A device on the default adapter, else, if `allow_warp`, a software
/// one. Returns which.
fn createDevice(device: *?*d3d11.IDevice, context: *?*d3d11.IDeviceContext, allow_warp: bool) Error!d3d11.DRIVER_TYPE {
    // Structured buffers in vertex/pixel shaders need feature level 11.
    const levels = [_]d3d11.FEATURE_LEVEL{ .@"11_1", .@"11_0" };
    const base_flags = d3d11.CREATE_DEVICE_BGRA_SUPPORT;

    // The debug layer needs the "Graphics Tools" optional Windows feature,
    // so fall back to a regular device if it's missing.
    const attempts = [_]struct { driver: d3d11.DRIVER_TYPE, flags: u32 }{
        .{ .driver = .HARDWARE, .flags = base_flags | d3d11.CREATE_DEVICE_DEBUG },
        .{ .driver = .HARDWARE, .flags = base_flags },
        .{ .driver = .WARP, .flags = base_flags },
    };

    for (attempts) |a| {
        if (builtin.mode != .debug and a.flags & d3d11.CREATE_DEVICE_DEBUG != 0) continue;
        if (!allow_warp and a.driver == .WARP) continue;

        var level: d3d11.FEATURE_LEVEL = undefined;
        const hr = d3d11.D3D11CreateDevice(
            null,
            a.driver,
            null,
            a.flags,
            &levels,
            levels.len,
            d3d11.SDK_VERSION,
            device,
            &level,
            context,
        );
        if (hr >= 0) {
            log.info("device created driver={t} feature_level=0x{x} debug={}", .{
                a.driver,
                @intFromEnum(level),
                a.flags & d3d11.CREATE_DEVICE_DEBUG != 0,
            });
            return a.driver;
        }
        log.warn("D3D11CreateDevice driver={t} flags=0x{x} failed: HRESULT=0x{X:0>8}", .{
            a.driver,
            a.flags,
            @as(u32, @bitCast(hr)),
        });
    }

    return error.HResult;
}

/// Shaders and fixed-function state.
const Pipeline = struct {
    bg_vs: *d3d11.IVertexShader,
    bg_ps: *d3d11.IPixelShader,
    box_vs: *d3d11.IVertexShader,
    box_ps: *d3d11.IPixelShader,
    shadow_ps: *d3d11.IPixelShader,
    text_vs: *d3d11.IVertexShader,
    text_ps: *d3d11.IPixelShader,
    image_vs: *d3d11.IVertexShader,
    image_ps: *d3d11.IPixelShader,
    image_sampler: *d3d11.ISamplerState,
    blend: *d3d11.IBlendState,
    text_blend: *d3d11.IBlendState,

    fn init(device: *d3d11.IDevice) Error!Pipeline {
        var bg_vs: ?*d3d11.IVertexShader = null;
        var bg_ps: ?*d3d11.IPixelShader = null;
        var box_vs: ?*d3d11.IVertexShader = null;
        var box_ps: ?*d3d11.IPixelShader = null;
        var shadow_ps: ?*d3d11.IPixelShader = null;
        var text_vs: ?*d3d11.IVertexShader = null;
        var text_ps: ?*d3d11.IPixelShader = null;
        var image_vs: ?*d3d11.IVertexShader = null;
        var image_ps: ?*d3d11.IPixelShader = null;
        var image_sampler: ?*d3d11.ISamplerState = null;
        var blend: ?*d3d11.IBlendState = null;
        var text_blend: ?*d3d11.IBlendState = null;
        errdefer {
            com.releaseOpt(&bg_vs);
            com.releaseOpt(&bg_ps);
            com.releaseOpt(&box_vs);
            com.releaseOpt(&box_ps);
            com.releaseOpt(&shadow_ps);
            com.releaseOpt(&text_vs);
            com.releaseOpt(&text_ps);
            com.releaseOpt(&image_vs);
            com.releaseOpt(&image_ps);
            com.releaseOpt(&image_sampler);
            com.releaseOpt(&blend);
            com.releaseOpt(&text_blend);
        }

        try createShader(device, "bg_vs", &bg_vs);
        try createShader(device, "bg_ps", &bg_ps);
        try createShader(device, "box_vs", &box_vs);
        try createShader(device, "box_ps", &box_ps);
        try createShader(device, "shadow_ps", &shadow_ps);
        try createShader(device, "text_vs", &text_vs);
        try createShader(device, "text_ps", &text_ps);
        try createShader(device, "image_vs", &image_vs);
        try createShader(device, "image_ps", &image_ps);
        try com.check(device.createSamplerState(&.{
            .Filter = d3d11.FILTER_MIN_MAG_LINEAR_MIP_POINT,
        }, &image_sampler), "ID3D11Device::CreateSamplerState");

        // Premultiplied alpha: out = src + dst * (1 - src.a).
        var desc: d3d11.BLEND_DESC = .{};
        desc.RenderTarget[0] = .{
            .BlendEnable = win32.TRUE,
            .SrcBlend = d3d11.BLEND_ONE,
            .DestBlend = d3d11.BLEND_INV_SRC_ALPHA,
            .SrcBlendAlpha = d3d11.BLEND_ONE,
            .DestBlendAlpha = d3d11.BLEND_INV_SRC_ALPHA,
        };
        try com.check(device.createBlendState(&desc, &blend), "ID3D11Device::CreateBlendState");

        // Text blends each channel by its own alpha, the second output
        // of text_ps, so ClearType's subpixels mix separately:
        // out = src0 + dst * (1 - src1). With equal channels it's the
        // premultiplied blend above.
        desc.RenderTarget[0].DestBlend = d3d11.BLEND_INV_SRC1_COLOR;
        desc.RenderTarget[0].DestBlendAlpha = d3d11.BLEND_INV_SRC1_ALPHA;
        try com.check(device.createBlendState(&desc, &text_blend), "ID3D11Device::CreateBlendState(text)");

        return .{
            .bg_vs = bg_vs.?,
            .bg_ps = bg_ps.?,
            .box_vs = box_vs.?,
            .box_ps = box_ps.?,
            .shadow_ps = shadow_ps.?,
            .text_vs = text_vs.?,
            .text_ps = text_ps.?,
            .image_vs = image_vs.?,
            .image_ps = image_ps.?,
            .image_sampler = image_sampler.?,
            .blend = blend.?,
            .text_blend = text_blend.?,
        };
    }

    fn deinit(self: *Pipeline) void {
        com.release(self.bg_vs);
        com.release(self.bg_ps);
        com.release(self.box_vs);
        com.release(self.box_ps);
        com.release(self.shadow_ps);
        com.release(self.text_vs);
        com.release(self.text_ps);
        com.release(self.image_vs);
        com.release(self.image_ps);
        com.release(self.image_sampler);
        com.release(self.blend);
        com.release(self.text_blend);
        self.* = undefined;
    }

    /// Compile `entry` from shaders.hlsl. The shader type comes from the
    /// output pointer: vertex shaders use vs_5_0, pixel shaders ps_5_0.
    fn createShader(device: *d3d11.IDevice, comptime entry: [:0]const u8, out: anytype) Error!void {
        const is_vs = @TypeOf(out) == *?*d3d11.IVertexShader;
        const flags = d3dcompiler.COMPILE_ENABLE_STRICTNESS | if (builtin.mode == .debug)
            d3dcompiler.COMPILE_DEBUG | d3dcompiler.COMPILE_SKIP_OPTIMIZATION
        else
            d3dcompiler.COMPILE_OPTIMIZATION_LEVEL3;

        var code: ?*d3dcompiler.IBlob = null;
        var errors: ?*d3dcompiler.IBlob = null;
        defer com.releaseOpt(&code);
        defer com.releaseOpt(&errors);
        const hr = d3dcompiler.D3DCompile(
            shader_source.ptr,
            shader_source.len,
            "shaders.hlsl",
            null,
            null,
            entry,
            if (is_vs) "vs_5_0" else "ps_5_0",
            flags,
            0,
            &code,
            &errors,
        );
        if (errors) |e| log.err("{s}: {s}", .{ entry, e.slice() });
        try com.check(hr, "D3DCompile(" ++ entry ++ ")");

        const bytecode = code.?.slice();
        if (is_vs) {
            try com.check(device.createVertexShader(bytecode, out), "CreateVertexShader(" ++ entry ++ ")");
        } else {
            try com.check(device.createPixelShader(bytecode, out), "CreatePixelShader(" ++ entry ++ ")");
        }
    }
};

/// A CPU-writable structured buffer bound as a shader resource. It grows
/// to the next power of two when the data outgrows it.
const DynamicBuffer = struct {
    stride: u32,
    buffer: ?*d3d11.IBuffer = null,
    srv: ?*d3d11.IShaderResourceView = null,
    capacity: u32 = 0,

    fn deinit(self: *DynamicBuffer) void {
        com.releaseOpt(&self.srv);
        com.releaseOpt(&self.buffer);
        self.capacity = 0;
    }

    fn upload(self: *DynamicBuffer, device: *d3d11.IDevice, ctx: *d3d11.IDeviceContext, bytes: []const u8) Error!void {
        const count: u32 = @intCast(bytes.len / self.stride);
        if (count == 0) return;

        if (count > self.capacity) {
            self.deinit();
            const capacity = @max(64, std.math.ceilPowerOfTwoAssert(u32, count));
            try com.check(device.createBuffer(&.{
                .ByteWidth = capacity * self.stride,
                .Usage = d3d11.USAGE_DYNAMIC,
                .BindFlags = d3d11.BIND_SHADER_RESOURCE,
                .CPUAccessFlags = d3d11.CPU_ACCESS_WRITE,
                .MiscFlags = d3d11.RESOURCE_MISC_BUFFER_STRUCTURED,
                .StructureByteStride = self.stride,
            }, &self.buffer), "ID3D11Device::CreateBuffer(structured)");
            try com.check(
                device.createShaderResourceView(self.buffer.?.resource(), &self.srv),
                "ID3D11Device::CreateShaderResourceView(structured)",
            );
            self.capacity = capacity;
        }

        var mapped: d3d11.MAPPED_SUBRESOURCE = undefined;
        try com.check(ctx.map(self.buffer.?.resource(), d3d11.MAP_WRITE_DISCARD, &mapped), "Map(structured)");
        @memcpy(@as([*]u8, @ptrCast(mapped.pData.?))[0..bytes.len], bytes);
        ctx.unmap(self.buffer.?.resource());
    }
};

test "ImageTextures.adopt releases another generation's textures" {
    const alloc = std.testing.allocator;
    // A COM object whose every slot counts a release.
    const Fake = struct {
        vtable: com.VTable = &slots,
        var released: u32 = 0;
        fn release(_: *anyopaque) callconv(.winapi) u32 {
            released += 1;
            return 0;
        }
        const slots = [_]*const anyopaque{ @ptrCast(&release), @ptrCast(&release), @ptrCast(&release) };
    };
    var obj: Fake = .{};
    var t: ImageTextures = .{};
    defer t.deinit(alloc);
    try t.map.put(alloc, 7, .{ .texture = @ptrCast(&obj), .srv = @ptrCast(&obj) });

    t.adopt(0);
    try std.testing.expectEqual(1, t.map.count());
    try std.testing.expectEqual(0, Fake.released);

    t.adopt(1);
    try std.testing.expectEqual(0, t.map.count());
    try std.testing.expectEqual(2, Fake.released);
    try std.testing.expectEqual(1, t.generation);
}
