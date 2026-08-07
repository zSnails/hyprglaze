//! Layout space to surface space.
//!
//! Hyprland reports window rects and the cursor in *global logical layout*
//! coordinates: the origin is the whole desktop's top-left, y grows downward,
//! and a monitor at layout x=3072 has windows whose x starts at 3072. The
//! layer surface is monitor-local and, being GL, has y growing upward from the
//! bottom.
//!
//! Both conversions live here rather than inline at the three call sites in
//! main.zig, because sign errors in this arithmetic are invisible until
//! someone runs a stacked monitor layout, and main.zig is not unit-testable
//! (it needs a live compositor and a GL context).
//!
//! `scale` maps logical pixels onto buffer pixels. Hyprland's coordinates and
//! the layer surface's configured size are both logical, so scale is 1.0
//! unless the surface renders at a higher buffer resolution than its logical
//! size — see the fractional-scale handling in wayland.zig.

const std = @import("std");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// Rebase a window rect onto the surface: subtract the monitor origin, flip
/// onto GL's y-up axis, and scale into buffer pixels. `surf_h` is the surface
/// height in the same (buffer) pixels the result is expressed in.
///
/// The arithmetic is done in f32 rather than i32 so that a pathological origin
/// or a monitor placed far into negative layout space cannot trip an integer
/// overflow panic in ReleaseSafe.
pub fn toGl(x: i32, y: i32, w: i32, h: i32, ox: i32, oy: i32, surf_h: f32, scale: f32) Rect {
    const lx = @as(f32, @floatFromInt(x)) - @as(f32, @floatFromInt(ox));
    const ly = @as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(oy));
    const lw = @as(f32, @floatFromInt(w));
    const lh = @as(f32, @floatFromInt(h));
    return .{
        .x = lx * scale,
        // Flip about the surface: the rect's *bottom* edge in layout space
        // becomes its origin in GL space.
        .y = surf_h - (ly + lh) * scale,
        .w = lw * scale,
        .h = lh * scale,
    };
}

/// The same transform for a bare point (the cursor). Equivalent to `toGl`'s
/// corner for a zero-height rect.
pub fn toGlPoint(x: i32, y: i32, ox: i32, oy: i32, surf_h: f32, scale: f32) [2]f32 {
    const lx = @as(f32, @floatFromInt(x)) - @as(f32, @floatFromInt(ox));
    const ly = @as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(oy));
    return .{ lx * scale, surf_h - ly * scale };
}

// --- tests ---

test "origin (0,0) at scale 1 reproduces the pre-multi-monitor behaviour" {
    // Pins the single-monitor case: this is exactly what deriveRawState
    // computed before window coordinates were ever rebased.
    const r = toGl(100, 50, 800, 600, 0, 0, 1080, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100), r.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1080 - 650), r.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 800), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 600), r.h, 0.001);
}

test "a monitor to the right rebases x onto its own surface" {
    // 3840x2160 @ scale 1.25 occupies 3072 of layout space, so the monitor to
    // its right starts at x=3072. A window 100px into that monitor must land
    // at surface x=100, not 3172.
    const r = toGl(3072 + 100, 50, 800, 600, 3072, 0, 1728, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100), r.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1728 - 650), r.y, 0.001);
}

test "a monitor below rebases y before the flip" {
    // The y case only shows up on a stacked layout, which is why it gets its
    // own test rather than riding along with the x one.
    const r = toGl(0, 1080 + 200, 400, 300, 0, 1080, 1080, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1080 - 500), r.y, 0.001);
}

test "a monitor to the left has a negative origin" {
    const r = toGl(-1920 + 60, 10, 200, 100, -1920, 0, 1080, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 60), r.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1080 - 110), r.y, 0.001);
}

test "scale maps logical coordinates onto a larger buffer" {
    // Logical 3072x1728 surface rendered into a 3840x2160 buffer: a window at
    // logical (100, 50) sized 800x600 covers buffer (125, ...) sized 1000x750.
    const r = toGl(100, 50, 800, 600, 0, 0, 2160, 1.25);
    try std.testing.expectApproxEqAbs(@as(f32, 125), r.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2160 - 812.5), r.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1000), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 750), r.h, 0.001);
}

test "a non-zero origin and a non-unity scale compose in the right order" {
    // The other tests all hold either scale == 1 or origin == 0, and under
    // both of those the wrong implementation `x * scale - ox` agrees with the
    // correct `(x - ox) * scale`. This is the only case that separates them:
    // a 3840x2160 monitor at scale 1.25 is 3072 logical wide, so its
    // right-hand neighbour starts at layout x=3072, and a window 100 logical
    // px into that monitor belongs at buffer x=125 — not 890.
    const r = toGl(3072 + 100, 50, 800, 600, 3072, 0, 2160, 1.25);
    try std.testing.expectApproxEqAbs(@as(f32, 125), r.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1000), r.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2160 - 812.5), r.y, 0.001);

    const p = toGlPoint(3072 + 100, 50, 3072, 0, 2160, 1.25);
    try std.testing.expectApproxEqAbs(@as(f32, 125), p[0], 0.001);
}

test "toGlPoint agrees with toGl for a zero-height rect" {
    const p = toGlPoint(3072 + 400, 300, 3072, 0, 1728, 1.0);
    const r = toGl(3072 + 400, 300, 0, 0, 3072, 0, 1728, 1.0);
    try std.testing.expectApproxEqAbs(r.x, p[0], 0.001);
    try std.testing.expectApproxEqAbs(r.y, p[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 400), p[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1728 - 300), p[1], 0.001);
}
