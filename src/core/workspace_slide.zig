//! Workspace-switch slide transition: clock, direction, and easing.
//!
//! The daemon tracks a live strip of windows: the active workspace plus
//! its neighbors parked one screen off-screen (WindowGeometry.rel). On a
//! switch, every strip position jumps by one span as rel values rebase
//! around the new active workspace; this module supplies the camera
//! offset that cancels that jump and eases back to zero, mirroring
//! Hyprland's own workspace animation. main.zig applies the offset.
//!
//! Easing reproduces Hyprland's animation engine (hyprutils):
//! - Cubic beziers are evaluated CSS-style over `duration` seconds
//!   (Hyprland: speed × 100ms).
//! - Springs ignore duration entirely and run closed-form damped-spring
//!   physics on the wall clock, finishing when both the displacement and
//!   the velocity drop under Hyprland's epsilons (0.001 each).

const std = @import("std");

/// Slide axis, derived from the detected animation style:
/// "slide"/"slidefade" → horizontal, "slidevert"/"slidefadevert" →
/// vertical, "fade"/disabled → none (workspace changes snap).
pub const Axis = enum { horizontal, vertical, none };

/// Damped-spring parameters, matching hyprutils' SSpringCurve defaults.
/// (Hyprland's Lua config calls the damping coefficient "dampening".)
pub const Spring = struct {
    mass: f32 = 1.0,
    stiffness: f32 = 250.0,
    damping: f32 = 25.0,
};

pub const Ease = union(enum) {
    /// Control points X0,Y0,X1,Y1 of a cubic bezier from (0,0) to (1,1).
    cubic_bezier: [4]f32,
    spring: Spring,
};

pub const Change = enum { none, snap, slide };

pub const WorkspaceSlide = struct {
    axis: Axis = .horizontal,
    ease: Ease = .{ .spring = .{} },
    /// Seconds; used by bezier easing only (springs are wall-clock).
    duration: f32 = 0.4,

    /// 0 = unknown (startup, old-format watcher, special workspace).
    last_ws_id: i64 = 0,
    active: bool = false,
    /// +1: new workspace has a higher id and enters from the right
    /// (or from the bottom for vertical).
    dir: f32 = 0,
    start: f64 = 0,

    /// Record the startup workspace without triggering a transition.
    pub fn seed(self: *WorkspaceSlide, ws_id: i64) void {
        self.last_ws_id = ws_id;
        self.active = false;
    }

    /// Feed the workspace id carried by each geometry snapshot. Returns
    /// what the caller should do: nothing, snap the window set, or let
    /// `sample` drive the camera through a slide.
    pub fn noteWorkspace(self: *WorkspaceSlide, ws_id: i64, time: f64) Change {
        if (ws_id == self.last_ws_id) return .none;

        const prev = self.last_ws_id;
        self.last_ws_id = ws_id;

        // No slide without a direction (either id unknown/special) or
        // when sliding is disabled. Snap — never glide across a
        // workspace boundary.
        const bezier_degenerate = self.ease == .cubic_bezier and self.duration <= 0;
        if (ws_id <= 0 or prev <= 0 or self.axis == .none or bezier_degenerate) {
            self.active = false;
            return .snap;
        }

        // Mid-slide retargets restart the clock; strip positions rebase
        // around the new workspace and the camera re-cancels the jump,
        // so the switch stays visually continuous.
        self.dir = if (ws_id > prev) 1.0 else -1.0;
        self.start = time;
        self.active = true;
        return .slide;
    }

    /// Current camera offset in layout space (positive x = right,
    /// positive y = down; the caller flips sign for the GL y-up axis),
    /// or null when no slide is running. Applied uniformly to every
    /// strip window; starts at ±span (cancelling the rel rebase) and
    /// eases to zero. Deactivates itself once the easing settles. `span`
    /// is the screen extent along the slide axis.
    pub fn sample(self: *WorkspaceSlide, time: f64, span: f32) ?f32 {
        if (!self.active) return null;
        const t: f32 = @floatCast(@max(time - self.start, 0));

        const e: f32 = switch (self.ease) {
            .cubic_bezier => |pts| blk: {
                const u = t / self.duration;
                if (u >= 1.0) {
                    self.active = false;
                    return null;
                }
                break :blk bezierY(pts, u);
            },
            .spring => |sp| blk: {
                const r = springEval(sp, t);
                if (@abs(1.0 - r.value) <= spring_value_epsilon and
                    @abs(r.velocity) <= spring_velocity_epsilon)
                {
                    self.active = false;
                    return null;
                }
                break :blk r.value;
            },
        };

        // A spring's e may overshoot past 1, pushing the strip slightly
        // beyond its rest position and back — the springy feel.
        return self.dir * (1.0 - e) * span;
    }

    /// 0 → 1 settling indicator for effects; 1.0 whenever idle.
    pub fn progress(self: *const WorkspaceSlide, time: f64) f32 {
        if (!self.active) return 1.0;
        const t: f32 = @floatCast(@max(time - self.start, 0));
        return switch (self.ease) {
            .cubic_bezier => std.math.clamp(t / self.duration, 0.0, 1.0),
            .spring => |sp| std.math.clamp(1.0 - @abs(1.0 - springEval(sp, t).value), 0.0, 1.0),
        };
    }
};

// Hyprland's spring completion thresholds (hyprutils SSpringCurve).
const spring_value_epsilon: f32 = 0.001;
const spring_velocity_epsilon: f32 = 0.001;

/// Closed-form damped spring from value 0 (displacement −1) at rest
/// toward 1, evaluated at elapsed time `t`. Mirrors hyprutils
/// `advanceSpring`, which is the exact propagator — evaluating once from
/// the initial conditions equals stepping frame by frame.
fn springEval(sp: Spring, t: f32) struct { value: f32, velocity: f32 } {
    const m = @max(sp.mass, 0.0001);
    const k = @max(sp.stiffness, 0.0001);
    const damping = @max(sp.damping, 0.0);

    const d: f32 = -1.0; // initial displacement, velocity 0
    const w0 = @sqrt(k / m);
    const g = damping / (2.0 * m);

    if (g < w0) { // underdamped — oscillates, may overshoot
        const wd = @sqrt(w0 * w0 - g * g);
        const decay = @exp(-g * t);
        const s = @sin(wd * t);
        const co = @cos(wd * t);
        return .{
            .value = 1.0 + decay * (d * co + (g * d / wd) * s),
            .velocity = decay * (-(w0 * w0 * d / wd) * s),
        };
    }

    const crit_eps = @max(w0, 1.0) * 0.0001;
    if (@abs(g - w0) <= crit_eps) { // critically damped
        const decay = @exp(-g * t);
        const b = g * d;
        return .{
            .value = 1.0 + decay * (d + b * t),
            .velocity = decay * (-(g * b * t)),
        };
    }

    // Overdamped
    const root = @sqrt(g * g - w0 * w0);
    const r1 = -g + root;
    const r2 = -g - root;
    const a = (-r2 * d) / (r1 - r2);
    const b = d - a;
    const e1 = @exp(r1 * t);
    const e2 = @exp(r2 * t);
    return .{
        .value = 1.0 + a * e1 + b * e2,
        .velocity = a * r1 * e1 + b * r2 * e2,
    };
}

/// y for a given x on a cubic bezier (0,0)-(X0,Y0)-(X1,Y1)-(1,1),
/// CSS-timing-function style: Newton-solve the parameter for x, then
/// evaluate y. `pts` is [X0, Y0, X1, Y1].
fn bezierY(pts: [4]f32, x_in: f32) f32 {
    const x = std.math.clamp(x_in, 0.0, 1.0);
    var u: f32 = x;
    for (0..8) |_| {
        const err_x = bezierAxis(pts[0], pts[2], u) - x;
        if (@abs(err_x) < 1e-5) break;
        const slope = bezierAxisDeriv(pts[0], pts[2], u);
        if (@abs(slope) < 1e-6) break;
        u = std.math.clamp(u - err_x / slope, 0.0, 1.0);
    }
    return bezierAxis(pts[1], pts[3], u);
}

fn bezierAxis(p1: f32, p2: f32, u: f32) f32 {
    const inv = 1.0 - u;
    return 3.0 * inv * inv * u * p1 + 3.0 * inv * u * u * p2 + u * u * u;
}

fn bezierAxisDeriv(p1: f32, p2: f32, u: f32) f32 {
    const inv = 1.0 - u;
    return 3.0 * inv * inv * p1 + 6.0 * inv * u * (p2 - p1) + 3.0 * u * u * (1.0 - p2);
}

// --- Tests ---

const linear_ease = Ease{ .cubic_bezier = .{ 0.0, 0.0, 1.0, 1.0 } };

fn testSlide() WorkspaceSlide {
    return .{ .ease = linear_ease, .duration = 1.0 };
}

test "noteWorkspace same id is a no-op" {
    var ws = testSlide();
    ws.seed(3);
    try std.testing.expectEqual(Change.none, ws.noteWorkspace(3, 1.0));
    try std.testing.expect(!ws.active);
}

test "noteWorkspace direction follows id ordering" {
    var ws = testSlide();
    ws.seed(1);
    try std.testing.expectEqual(Change.slide, ws.noteWorkspace(2, 1.0));
    try std.testing.expectEqual(@as(f32, 1.0), ws.dir);
    // At the start the camera cancels the full rebase jump: strip
    // positions moved -span, the camera holds them at +span.
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0), ws.sample(1.0, 1000.0).?, 0.001);

    try std.testing.expectEqual(Change.slide, ws.noteWorkspace(1, 2.0));
    try std.testing.expectEqual(@as(f32, -1.0), ws.dir);
    try std.testing.expectApproxEqAbs(@as(f32, -1000.0), ws.sample(2.0, 1000.0).?, 0.001);
}

test "noteWorkspace unknown or special ids snap" {
    var ws = testSlide();
    ws.seed(2);
    // Into a special workspace (negative id) — snap, no glide.
    try std.testing.expectEqual(Change.snap, ws.noteWorkspace(-98, 1.0));
    try std.testing.expect(!ws.active);
    // Back out of it: previous id is now the special one — still snap.
    try std.testing.expectEqual(Change.snap, ws.noteWorkspace(2, 2.0));
    // From an unknown baseline (id 0) there is no direction — snap.
    var ws2 = testSlide();
    try std.testing.expectEqual(Change.snap, ws2.noteWorkspace(5, 1.0));
    // But the id was recorded, so the next switch slides.
    try std.testing.expectEqual(Change.slide, ws2.noteWorkspace(6, 2.0));
}

test "noteWorkspace disabled axis or degenerate duration snaps" {
    var ws = testSlide();
    ws.axis = .none;
    ws.seed(1);
    try std.testing.expectEqual(Change.snap, ws.noteWorkspace(2, 1.0));

    var ws2 = testSlide();
    ws2.duration = 0;
    ws2.seed(1);
    try std.testing.expectEqual(Change.snap, ws2.noteWorkspace(2, 1.0));
    try std.testing.expectEqual(@as(?f32, null), ws2.sample(1.0, 100.0));
}

test "sample eases across the span and deactivates at the end" {
    var ws = testSlide();
    ws.seed(1);
    _ = ws.noteWorkspace(2, 10.0);

    try std.testing.expectApproxEqAbs(@as(f32, 500.0), ws.sample(10.5, 1000.0).?, 1.0);

    try std.testing.expectEqual(@as(?f32, null), ws.sample(11.5, 1000.0));
    try std.testing.expect(!ws.active);
    // Idle progress reads settled.
    try std.testing.expectEqual(@as(f32, 1.0), ws.progress(12.0));
}

test "retarget mid-slide restarts the clock and recomputes direction" {
    var ws = testSlide();
    ws.seed(1);
    _ = ws.noteWorkspace(2, 10.0);
    _ = ws.sample(10.3, 1000.0);
    try std.testing.expectEqual(Change.slide, ws.noteWorkspace(1, 10.4));
    try std.testing.expectEqual(@as(f32, -1.0), ws.dir);
    try std.testing.expectEqual(@as(f64, 10.4), ws.start);
    try std.testing.expectApproxEqAbs(@as(f32, -1000.0), ws.sample(10.4, 1000.0).?, 0.001);
}

test "spring settles and deactivates" {
    var ws = WorkspaceSlide{ .ease = .{ .spring = .{} } };
    ws.seed(1);
    _ = ws.noteWorkspace(2, 0.0);
    // Just after the start: nearly full offset, definitely active.
    try std.testing.expect(ws.sample(0.01, 1000.0).? > 900.0);
    // The default spring (k=250, c=25, m=1) settles well within 2s.
    try std.testing.expectEqual(@as(?f32, null), ws.sample(2.0, 1000.0));
    try std.testing.expect(!ws.active);
}

test "underdamped spring overshoots its rest position" {
    // Low damping: γ=2.5, ω0=10 — clearly underdamped.
    const sp = Spring{ .mass = 1.0, .stiffness = 100.0, .damping = 5.0 };
    // Peak of the first oscillation is near t = π/ωd.
    const wd = @sqrt(100.0 - 2.5 * 2.5);
    const peak = springEval(sp, std.math.pi / wd);
    try std.testing.expect(peak.value > 1.05);
    // An overshooting ease pushes the camera past its rest position.
    var ws = WorkspaceSlide{ .ease = .{ .spring = sp } };
    ws.seed(1);
    _ = ws.noteWorkspace(2, 0.0);
    try std.testing.expect(ws.sample(std.math.pi / wd, 1000.0).? < 0.0);
}

test "spring branches are finite and settle toward 1" {
    const springs = [_]Spring{
        .{ .mass = 1, .stiffness = 250, .damping = 25 }, // underdamped (Hyprland default)
        .{ .mass = 1, .stiffness = 100, .damping = 20 }, // critically damped
        .{ .mass = 1, .stiffness = 100, .damping = 50 }, // overdamped
    };
    for (springs) |sp| {
        const early = springEval(sp, 0.0);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), early.value, 0.001);
        const late = springEval(sp, 10.0);
        try std.testing.expect(std.math.isFinite(late.value));
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), late.value, 0.01);
    }
}

test "bezierY hits endpoints and matches known curves" {
    const linear = [4]f32{ 0.0, 0.0, 1.0, 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bezierY(linear, 0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), bezierY(linear, 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bezierY(linear, 1.0), 0.001);

    // easeOutQuint-ish (0.23,1)-(0.32,1): front-loaded — y(0.5) well above 0.5.
    const ease_out = [4]f32{ 0.23, 1.0, 0.32, 1.0 };
    try std.testing.expect(bezierY(ease_out, 0.5) > 0.9);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bezierY(ease_out, 1.0), 0.001);
    // Out-of-range x clamps.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bezierY(ease_out, -1.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bezierY(ease_out, 2.0), 0.001);
}

test "progress reports settling and 1.0 when idle" {
    var ws = testSlide();
    ws.seed(1);
    try std.testing.expectEqual(@as(f32, 1.0), ws.progress(0.0));
    _ = ws.noteWorkspace(2, 10.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), ws.progress(10.5), 0.001);
}
