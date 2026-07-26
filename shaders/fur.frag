#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Music. Zero in silence (or with music = false) except the drift clock,
// which keeps turning so the coat always has a slow current in it.
uniform float iFurFlow;     // comb-drift clock, energy-paced
uniform float iFurBands[6]; // smoothed AGC'd bands, low to high
uniform float iFurBass;
uniform float iFurBeat;     // kick envelope, ~200ms decay
uniform float iFurCell;     // follicle spacing in px
uniform float iFurLength;   // pile height in px
uniform float iFurBright;

out vec4 fragColor;

const int SHELLS = 22;

uint pcg(uint v) {
    v = v * 747796405u + 2891336453u;
    uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
    return (w >> 22u) ^ w;
}
float hf(uint v) { return float(pcg(v) & 0x00ffffffu) / 16777216.0; }
uint cellKey(vec2 c) { return uint(int(c.x) + 4096) * 8191u + uint(int(c.y) + 4096); }

float sdRoundBox(vec2 p, vec2 c, vec2 hs, float r) {
    vec2 d = abs(p - c) - hs + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

// Which way the pile lies at a point on the skin, and how flat it has
// been pressed. The lie is what the whole effect turns on: a coat all
// combed one way is a doormat, and it is the swirls, partings and
// pressed patches that make it read as fur that something has touched.
//
// `flat` is separate from direction because pressing and combing are
// different things — a window sits on the pile and squashes it, where the
// cursor pushes it aside without shortening it.
void combAt(vec2 p, vec2 res, float t, float bass,
            out vec2 lie, out float flat_amt, out float ruffle) {
    // Standing cowlicks: two slow incommensurate swirls, so the coat has
    // a natural grain with partings in it before anything disturbs it.
    vec2 u = p / 420.0;
    lie = vec2(sin(u.y * 1.10 + t * 0.31) + 0.55 * sin(u.y * 2.30 - t * 0.21),
               cos(u.x * 0.95 - t * 0.27) + 0.55 * cos(u.x * 2.10 + t * 0.19)) * 0.55;
    // A shiver runs through the whole coat on the low end.
    lie += vec2(sin(p.y * 0.011 + t * 3.1), cos(p.x * 0.010 - t * 2.7)) * bass * 0.30;

    flat_amt = 0.0;
    ruffle = 0.0;

    // The cursor combs a parting: the pile is pushed away radially, hard
    // up close and easing off with distance.
    vec2 dc = p - iMouse.xy;
    float dcl = length(dc);
    lie += (dc / max(dcl, 1.0)) * exp(-dcl / 130.0) * 2.6;

    // Windows sit on the coat. The pile is crushed under them and pushed
    // outward at the edges, the way a hand pressed into pile leaves a
    // flattened patch with a raised lip. Because the daemon hands us
    // smoothed rects, a window dragged across the screen mows a flattened
    // path that springs back behind it on its own.
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 w = iWindows[i];
        if (w.z < 1.0 || w.w < 1.0) continue;
        vec2 c = w.xy + w.zw * 0.5;
        float d = sdRoundBox(p, c, w.zw * 0.5, 18.0);
        // Crushed flat under the footprint, and the whole transition from
        // crushed to standing is kept *inside* the frame. Letting it run
        // past the edge leaves a band of half-flattened pile hugging every
        // window, and since both the height and the lie change across that
        // band it reads as a drawn outline around each one — which is
        // exactly what nothing else in this effect does.
        flat_amt = max(flat_amt, 1.0 - smoothstep(-72.0, -8.0, d));
        // Outside, the displaced pile heaps into a low ridge. Eased in
        // from the frame rather than peaking on it, and decaying on its
        // own instead of being cut off at a fixed radius: a hard stop at
        // either end draws a second rim.
        vec2 away = p - c;
        float ridge = smoothstep(0.0, 34.0, d) * exp(-max(d, 0.0) / 105.0);
        lie += (away / max(length(away), 1.0)) * ridge * 1.15;
        float fa = 0.0;
        if (i == iFocusedIndex) fa = smoothstep(0.0, 1.0, iTransition);
        if (i == iPrevIndex) fa = max(fa, 1.0 - smoothstep(0.0, 1.0, iTransition));
        // The focused window's edge keeps its pile standing and stirred.
        // Spread wide so it reads as a glow in the coat rather than as
        // another ring following the frame.
        ruffle = max(ruffle, fa * exp(-max(d, 0.0) / 150.0) * 0.8);
    }
    flat_amt = clamp(flat_amt, 0.0, 1.0);
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 res = iResolution.xy;
    float t = iFurFlow;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.098, 0.090, 0.141);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.88, 0.87, 0.91);
    vec3 accent = (iPaletteSize > 5) ? iPalette[5] : vec3(0.77, 0.65, 0.91);
    vec3 c_sec = (iPaletteSize > 6) ? iPalette[6] : vec3(0.61, 0.81, 0.85);

    // Two-tone coat: a dark undercoat at the skin lifting to lit tips.
    // Nearly all of the depth in fur comes from this gradient plus the
    // occlusion down between the strands.
    // The gaps matter as much as the strands. Against near-black, every
    // hair reads as a separate lit object and the pile turns to bristle;
    // lifting the skin and undercoat lets the strands run together into
    // one mass, which is what fur actually looks like.
    vec3 skin = mix(bg, accent, 0.30) * 0.92;
    vec3 under = mix(bg, accent, 0.52);
    vec3 tipc = mix(accent, fg, 0.20);

    float cell = max(iFurCell, 4.0);
    float pile = max(iFurLength, 2.0);
    float bass = min(iFurBass, 1.4);

    vec2 lie;
    float flat_amt;
    float ruffle;
    combAt(fc, res, t, bass, lie, flat_amt, ruffle);
    // A crushed patch keeps almost none of its height, and a ruffled edge
    // stands taller than the rest of the coat.
    float pile_h = pile * (1.0 - flat_amt * 0.82) * (1.0 + ruffle * 0.35);
    // Pressed pile also lies over rather than standing up.
    vec2 lean = lie * (1.0 + flat_amt * 2.2);

    // Parallax: the view leans further from straight-on toward the edges
    // of the screen, so the pile there is seen from the side and the
    // strands lean away. Without it the coat reads as a flat pattern
    // rather than as something with height.
    vec2 par = (fc - res * 0.5) / res.y * 0.55;

    // Light, raised and to one side: low enough that the pile casts along
    // itself, high enough that the whole coat is lit rather than only the
    // patches that happen to lean into it.
    vec3 L3 = normalize(vec3(0.38, 0.52, 0.92));
    vec3 V3 = normalize(vec3(-par, 1.0));

    vec3 col = skin;
    bool hit = false;

    // March from the tips down to the skin. The first strand met is the
    // topmost one along this ray, which is all an opaque strand needs.
    for (int i = 0; i < SHELLS; i++) {
        float h = 1.0 - float(i) / float(SHELLS - 1);
        // Both the lean and the parallax are known functions of height, so
        // the sample point is moved instead of the strands. That keeps
        // every follicle inside its own grid cell: one hash per step, and
        // no strand ever straddles a cell boundary to be clipped square.
        // The lean has to carry the ray across several follicles over the
        // pile's height. Keep it short and the ray meets the top of one
        // strand and stops, so the coat comes out as a field of separate
        // round tips; carry it further and each strand is seen along its
        // length, crossing its neighbours, which is what turns dots into
        // overlapping hair.
        vec2 s = fc + (lean * 62.0 + par * pile_h * 1.6) * h;

        // Warp the sample before the grid lookup. Follicles have to stay
        // inside their own cell for the one-hash-per-step trick to hold,
        // and a regular grid of them reads as a manufactured brush — rows
        // and columns are plainly visible. Bending the space first leaves
        // the follicles where they are but destroys the lattice they sit
        // on, which costs two sines and buys back the disorder that makes
        // it a coat instead of a doormat.
        vec2 wq = s / 190.0;
        s += vec2(sin(wq.y * 2.7 + wq.x * 1.3), cos(wq.x * 2.9 - wq.y * 1.1)) * cell * 0.85;

        vec2 g = s / cell;
        vec2 ci = floor(g);
        vec2 f = g - ci;
        uint k = cellKey(ci);

        // Not every follicle grows to the same height; the spread is what
        // stops the coat looking mown.
        float len = (0.55 + hf(k) * 0.45) * pile_h;
        float hz = h * pile;
        if (hz > len) continue;

        vec2 jit = vec2(hf(k ^ 0x9E3779B9u), hf(k ^ 0x85EBCA6Bu)) - 0.5;
        float d = length(f - 0.5 - jit * 0.48);
        float up = hz / max(len, 1e-3);
        // Held near full thickness most of the way and drawn to a point
        // only at the very end. A straight linear taper leaves the upper
        // pile so thin that most rays fall between the strands to the
        // skin, and the coat comes out as sparse bristle over black
        // rather than as anything you would want to touch.
        float r = 0.37 * pow(max(1.0 - up, 0.0), 0.5);
        if (d > r) continue;

        // Kajiya-Kay: a strand is a cylinder, so it has no single normal —
        // its highlight runs as a band around the fibre, set by the angle
        // between the light and the strand's tangent. This is what makes
        // fur read as fibre instead of as stippled paint.
        vec3 T = normalize(vec3(lean * 0.55, 1.0));
        float tl = dot(T, L3);
        float tv = dot(T, V3);
        float sl = sqrt(max(1.0 - tl * tl, 0.0));
        float sv = sqrt(max(1.0 - tv * tv, 0.0));
        float spec = pow(max(tl * tv + sl * sv, 0.0), 28.0);

        // Down between the strands it is dark: the deeper the hit, the
        // more coat is standing over it. The floor matters — with none,
        // everything but the tips falls to black and the pile loses its
        // body.
        float ao = up * up * 0.68 + 0.32;
        // Rim: the outermost hairs are lit through from behind.
        float rim = smoothstep(0.72, 1.0, up) * (0.30 + ruffle * 0.5);

        vec3 fib = mix(under, tipc, up);
        // Each strand keeps its own tone so the coat has grain up close.
        fib *= 0.78 + hf(k ^ 0x2545F491u) * 0.40;
        col = fib * (sl * 0.45 + 0.62) * ao
            + mix(tipc, fg, 0.30) * spec * (0.14 + up * 0.34)
            + mix(accent, c_sec, 0.4) * rim * 0.55
            + mix(tipc, fg, 0.3) * iFurBeat * up * 0.08;
        hit = true;
        break;
    }

    if (!hit) {
        // Straight down to the skin between the strands.
        col = skin * (0.75 + flat_amt * 0.25);
    }

    // The cursor leaves the parting lit, so the comb is legible.
    col += mix(accent, fg, 0.3) * exp(-distance(fc, iMouse.xy) / 150.0) * 0.06;

    vec2 q = (fc / res - 0.5) * 2.0;
    col *= 1.0 - dot(q, q) * 0.16;

    fragColor = vec4(bg + (col - bg) * iFurBright, 1.0);
}
