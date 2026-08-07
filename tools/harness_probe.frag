#version 300 es
precision highp float;

// hyprglaze harness instrument — not an effect. Renders *where* the daemon
// thinks things are, in surface coordinates, so a screenshot is a coordinate
// readout rather than a picture.
//
//   black             surface background
//   green outline     every iWindows[i]
//   red outline       the focused window (drawn last, wins)
//   blue crosshair    iMouse.xy
//   white 8x8 corner  surface origin (0,0), so every PNG carries its own frame
//
// Deliberately time-invariant and palette-independent: consecutive frames are
// byte-identical, so the harness can assert with `cmp -s` instead of a
// tolerance and a settling sleep.
//
// Rings are drawn OUTSIDE the window rect: the window is opaque and composited
// above the background layer, so anything painted inside its bounds is
// invisible to a screenshot. The 12px pad puts the ring on bare background
// immediately adjacent to the edge, where a pixel scan can find it.
//
// Pair with: --effect windowglow --shader tools/harness_probe.frag
// and [windowglow] music = false, grain = 0.0 — windowglow contributes no
// geometry of its own, so it just supplies uniforms this shader ignores.

uniform vec3 iResolution;
uniform vec4 iMouse;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform int iFocusedIndex;

out vec4 fragColor;

const float PAD = 12.0; // gap between the window edge and the ring
const float TH = 2.0;   // ring half-thickness

// True when p lies on a rectangular ring sitting `pad` px outside rect `r`.
bool ring(vec2 p, vec4 r, float pad, float t) {
    vec2 lo = r.xy - pad;
    vec2 hi = r.xy + r.zw + pad;
    bool outer = all(greaterThanEqual(p, lo - t)) && all(lessThanEqual(p, hi + t));
    bool inner = all(greaterThanEqual(p, lo + t)) && all(lessThanEqual(p, hi - t));
    return outer && !inner;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec3 col = vec3(0.0);

    // Every tracked window. Dynamic indexing of a uniform array is legal in
    // ES 3.00, but the count is also compared against the array bound so a
    // stale iWindowCount can never walk off the end.
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 w = iWindows[i];
        if (w.z < 1.0 || w.w < 1.0) continue;
        if (ring(fc, w, PAD, TH)) col = vec3(0.0, 1.0, 0.0);
    }

    // The focused one again, in red, so it wins wherever the rings overlap.
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        if (i != iFocusedIndex) continue;
        vec4 w = iWindows[i];
        if (w.z < 1.0 || w.w < 1.0) continue;
        if (ring(fc, w, PAD, TH)) col = vec3(1.0, 0.0, 0.0);
    }

    // Cursor crosshair.
    if (abs(fc.x - iMouse.x) < 1.5 && abs(fc.y - iMouse.y) < 12.0) col = vec3(0.0, 0.0, 1.0);
    if (abs(fc.y - iMouse.y) < 1.5 && abs(fc.x - iMouse.x) < 12.0) col = vec3(0.0, 0.0, 1.0);

    // Origin marker: proves which corner of the PNG is GL (0,0).
    if (fc.x < 8.0 && fc.y < 8.0) col = vec3(1.0);

    fragColor = vec4(col, 1.0);
}
