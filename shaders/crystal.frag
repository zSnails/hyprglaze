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

// Music. All zero in silence (or with music = false) except the turn
// clock, which keeps creeping — the cluster is always slowly rolling, it
// just does it calmly.
uniform float iCrysTurn;     // rotation/light angle, energy-paced, beats jolt it
uniform float iCrysBands[6]; // smoothed AGC'd bands, low to high
uniform float iCrysBass;
uniform float iCrysBeat;     // kick envelope, ~200ms decay
uniform float iCrysDisp;     // dispersion strength
uniform float iCrysBright;

out vec4 fragColor;

const int SHARDS = 34;
// Only the nearest few shards along a ray can matter once the ones in
// front have absorbed most of the light, so the compositing buffer is
// capped well below the shard count. That keeps the painter's ordering
// cheap however dense the cluster gets.
const int MAXHIT = 8;

uint pcg(uint v) {
    v = v * 747796405u + 2891336453u;
    uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
    return (w >> 22u) ^ w;
}
float hf(uint v) { return float(pcg(v) & 0x00ffffffu) / 16777216.0; }

float sdRoundBox(vec2 p, vec2 c, vec2 hs, float r) {
    vec2 d = abs(p - c) - hs + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

mat3 rotYXZ(vec3 a) {
    float cx = cos(a.x), sx = sin(a.x);
    float cy = cos(a.y), sy = sin(a.y);
    float cz = cos(a.z), sz = sin(a.z);
    mat3 rx = mat3(1.0, 0.0, 0.0, 0.0, cx, -sx, 0.0, sx, cx);
    mat3 ry = mat3(cy, 0.0, sy, 0.0, 1.0, 0.0, -sy, 0.0, cy);
    mat3 rz = mat3(cz, -sz, 0.0, sz, cz, 0.0, 0.0, 0.0, 1.0);
    return ry * rx * rz;
}

// The habit of one shard: a hexagonal prism closed by a pyramid at each
// end — the way quartz actually grows. Cutting a box down with scattered
// planes only ever yields a rounded lump, because every extra cut shaves
// another corner toward a sphere. Building the prism and its terminations
// directly is what gives sharp parallel side faces meeting at a point,
// which is the silhouette that reads as "crystal" instantly.
//
// j 0-5   the six prism faces
// j 6-11  the upper termination, offset half a step so each pyramid face
//         lands on the edge between two prism faces
// j 12-17 the lower termination
// j 18-23 bevels on the prism edges, turning the hexagonal cross-section
//         into a twelve-sided one. Only some shards carry them.
vec3 planeDir(int j, uint seed) {
    float twist = hf(seed ^ 0x3C6EF372u) * 6.2831853;
    float taper = 0.72 + hf(seed ^ 0x1F83D9ABu) * 0.55;
    if (j < 6) {
        float a = float(j) * 1.0471976 + twist;
        return vec3(cos(a), 0.0, sin(a));
    }
    if (j < 12) {
        float a = (float(j - 6) + 0.5) * 1.0471976 + twist;
        return normalize(vec3(cos(a) * taper, 1.0, sin(a) * taper));
    }
    if (j < 18) {
        float a = (float(j - 12) + 0.5) * 1.0471976 + twist;
        return normalize(vec3(cos(a) * taper, -1.0, sin(a) * taper));
    }
    float a = (float(j - 18) + 0.5) * 1.0471976 + twist;
    return vec3(cos(a), 0.0, sin(a));
}

// How far each face sits from the centre. The prism faces set the
// thickness; the terminations sit further out, and how much further is
// what makes a shard stubby or needle sharp.
//
// The termination offsets alternate between neighbouring faces, which is
// how quartz actually terminates — alternating large and small rhombs
// around the point rather than a clean symmetric pyramid. It costs
// nothing and it is most of what makes a tip look grown rather than
// modelled.
float planeOff(int j, uint seed) {
    float rad = 0.34 + hf(seed ^ 0x85EBCA6Bu) * 0.22;
    float tip = rad * (1.35 + hf(seed ^ 0xC2B2AE35u) * 1.25);
    if (j < 6) return rad;
    if (j < 18) {
        bool odd = (j - (j / 2) * 2) == 1;
        float rz = odd ? (0.78 + hf(seed ^ 0x4A7F1B3Du) * 0.16) : 1.0;
        // The lower point is usually the shorter one.
        float endf = (j < 12) ? 1.0 : (0.82 + hf(seed ^ 0x6D3E9A11u) * 0.22);
        return tip * rz * endf;
    }
    // Beyond the corner: a plane this far out never cuts the solid, which
    // is how a shard opts out of being bevelled without changing the loop.
    return (hf(seed ^ 0x2F1E5C77u) > 0.45) ? rad * (1.03 + hf(seed ^ 0x9A1D3Bu) * 0.09) : 1e3;
}

// A sphere that certainly contains the shard, for rejecting rays before
// paying for the full face-by-face clip. Most shards miss most rays, so
// this is what makes a large cluster affordable.
float shardBound(uint seed, vec3 scale) {
    float rad = 0.34 + hf(seed ^ 0x85EBCA6Bu) * 0.22;
    float tip = rad * (1.35 + hf(seed ^ 0xC2B2AE35u) * 1.25);
    float taper = 0.72 + hf(seed ^ 0x1F83D9ABu) * 0.55;
    float apex = tip * sqrt(1.0 + taper * taper);
    return length(vec3(scale.x * rad, scale.y * apex, scale.z * rad)) * 1.05;
}

// Ray against a convex polyhedron, solved exactly rather than marched: a
// convex solid is the intersection of half-spaces, so clipping the ray
// against each plane in turn leaves the entry and exit points directly.
// No stepping means no surface noise, exact facet normals, and a cost
// that is simply the number of faces.
bool traceShard(vec3 ro, vec3 rd, int nplanes, uint seed, vec3 scale,
                out float t0, out float t1, out vec3 n0, out vec3 n1) {
    t0 = -1e9;
    t1 = 1e9;
    n0 = vec3(0.0, 0.0, -1.0);
    n1 = vec3(0.0, 0.0, 1.0);
    for (int j = 0; j < 24; j++) {
        if (j >= nplanes) break;
        vec3 nrm = planeDir(j, seed) / scale;
        float len = length(nrm);
        nrm /= len;
        float off = planeOff(j, seed) / len;
        float dn = dot(rd, nrm);
        float dp = off - dot(ro, nrm);
        if (abs(dn) < 1e-6) {
            // Ray parallel to this face: either wholly inside it or the
            // whole ray misses the solid.
            if (dp < 0.0) return false;
            continue;
        }
        float t = dp / dn;
        if (dn < 0.0) {
            if (t > t0) { t0 = t; n0 = nrm; }
        } else {
            if (t < t1) { t1 = t; n1 = nrm; }
        }
        if (t0 > t1) return false;
    }
    return t1 > max(t0, 0.0);
}

// What the crystal reflects and refracts. A gem is mostly an image of its
// surroundings bent through it, so this field is doing as much work as
// the geometry: a graded sky, the ground below, and one hard light whose
// reflection is what makes faces flash.
vec3 environ(vec3 d, vec3 L, vec3 deep, vec3 mid, vec3 pale, float beat) {
    // A graded surround with real range in it: every face is showing this
    // field from a different angle, so if it is flat the faces come out
    // flat too, however good the geometry is.
    float up = d.y * 0.5 + 0.5;
    vec3 col = mix(deep * 0.45, mid, up * up);
    col = mix(col, pale, smoothstep(0.45, 1.0, up) * 0.85);
    // Horizon band — a bright line the faces catch as they turn.
    col += mix(mid, pale, 0.6) * exp(-abs(d.y) * 7.0) * 0.35;
    // The key light, and a dimmer fill opposite it so faces turned away
    // don't fall to dead black.
    float k = max(dot(d, L), 0.0);
    col += pale * pow(k, 24.0) * (1.6 + beat * 1.2);
    col += mid * pow(k, 3.0) * 0.55;
    col += mix(mid, pale, 0.3) * pow(max(dot(d, -L), 0.0), 6.0) * 0.22;
    return col;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 res = iResolution.xy;
    vec2 uv = (fc - res * 0.5) / res.y;
    float t = iTime;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.098, 0.090, 0.141);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.88, 0.87, 0.91);
    vec3 accent = (iPaletteSize > 5) ? iPalette[5] : vec3(0.77, 0.65, 0.91);
    vec3 c_sec = (iPaletteSize > 6) ? iPalette[6] : vec3(0.61, 0.81, 0.85);

    // One hue family across a wide value range, built around the theme's
    // accent so the stone takes on whatever palette is loaded.
    vec3 deep = mix(bg, accent, 0.16);
    vec3 mid = mix(accent, c_sec, 0.20) * 0.72;
    vec3 pale = mix(accent, fg, 0.70);

    float turn = iCrysTurn;
    float disp = 0.030 * iCrysDisp * (1.0 + min(iCrysBass, 1.2) * 0.6);
    // Prism, both terminations, and the edge bevels.
    int nplanes = 24;
    vec3 L = normalize(vec3(cos(turn) * 0.75, 0.55, sin(turn) * 0.75));

    vec3 ro = vec3(0.0, 0.0, -3.9);
    vec3 rd = normalize(vec3(uv, 1.35));

    // --- windows as lights in the scene ---
    // The cluster is its own thing; the windows light it. Each one is
    // un-projected to a real position in front of the shards, so it lights
    // them from where it actually sits on screen — and because a facet is
    // a flat plane with one normal, a window swinging into alignment sets
    // whole faces alight at once. The focused window is the key light, so
    // moving focus sweeps brilliance across the cluster.
    vec3 key_dir = vec3(0.0);
    float key_amt = 0.0;
    vec3 fill_dir = vec3(0.0);
    float fill_amt = 0.0;
    float wlit = 0.0;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 w = iWindows[i];
        if (w.z < 1.0 || w.w < 1.0) continue;
        float fa = 0.0;
        if (i == iFocusedIndex) fa = max(fa, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex) fa = max(fa, 1.0 - smoothstep(0.0, 1.0, iTransition));

        // Sat in front of the cluster rather than in its plane, so the
        // light reaches the faces turned toward the viewer — the ones we
        // can actually see catch it.
        vec2 uvc = (w.xy + w.zw * 0.5 - res * 0.5) / res.y;
        vec3 wp = vec3(uvc * ((-1.9 - ro.z) / 1.35), -1.9);
        vec3 dir = normalize(wp);
        // Bigger windows are bigger lights.
        float inten = 0.25 + (w.z * w.w) / (res.x * res.y) * 1.1;
        key_dir += dir * inten * fa;
        key_amt += inten * fa;
        fill_dir += dir * inten;
        fill_amt += inten;

        float d = max(sdRoundBox(fc, w.xy + w.zw * 0.5, w.zw * 0.5, 16.0), 0.0);
        wlit += exp(-d / (170.0 + fa * 220.0)) * (0.14 + fa * 0.34);
    }
    bool has_key = key_amt > 1e-4 && dot(key_dir, key_dir) > 1e-6;
    key_dir = has_key ? normalize(key_dir) : L;
    bool has_fill = fill_amt > 1e-4 && dot(fill_dir, fill_dir) > 1e-6;
    fill_dir = has_fill ? normalize(fill_dir) : L;
    // The key light leads, but the drifting sweep still pulls it, so the
    // stone keeps turning in the light even while focus sits still.
    L = normalize(mix(L, key_dir, has_key ? 0.62 : 0.0));

    // Gather every shard the ray meets, then composite them back to front:
    // overlapping translucent solids are most of what gives a cluster its
    // depth, so they have to be layered in the right order rather than
    // just taking the nearest.
    float hit_t[MAXHIT];
    vec3 hit_c[MAXHIT];
    float hit_a[MAXHIT];
    int nhit = 0;

    for (int s = 0; s < SHARDS; s++) {
        uint seed = uint(s) * 7919u + 13u;
        float fs = float(s);
        // Shards drift and roll on their own axis and their own clock.
        vec3 ang = vec3(hf(seed) * 6.2831853 + t * (0.045 + hf(seed + 1u) * 0.05),
                        hf(seed + 2u) * 6.2831853 + t * (0.035 + hf(seed + 3u) * 0.05),
                        hf(seed + 4u) * 6.2831853 + t * 0.02);
        mat3 R = rotYXZ(ang);
        // Spread wide enough to carry the frame. Drawn from a plain hash
        // the centres clump and leave dead corners, so x is spaced evenly
        // across the field and only jittered within its share.
        float slot = (fs + 0.5) / float(SHARDS);
        vec3 ctr = vec3((slot - 0.5) * 7.2 + (hf(seed + 5u) - 0.5) * 1.4,
                        (hf(seed + 6u) - 0.5) * 3.4,
                        (hf(seed + 7u) - 0.5) * 3.4);
        ctr.y += sin(t * 0.12 + fs) * 0.10;
        // A wide spread of sizes: a cluster of near-identical shards reads
        // as a pattern, where big blades among small needles reads as
        // something grown.
        // Squared, so small shards outnumber large ones — a few big
        // blades reading against a crowd of needles, the way a real
        // cluster grades rather than coming in one size.
        float gh = hf(seed + 11u);
        float g = 0.13 + gh * gh * 0.72;
        vec3 scale = vec3(g * (0.72 + hf(seed + 8u) * 0.30),
                          g * (1.45 + hf(seed + 9u) * 1.30),
                          g * (0.72 + hf(seed + 10u) * 0.30));

        // Reject against the bounding sphere before paying for 24 planes.
        vec3 oc = ctr - ro;
        float tca = dot(oc, rd);
        float bound = shardBound(seed, scale);
        if (dot(oc, oc) - tca * tca > bound * bound) continue;
        if (tca < -bound) continue;

        vec3 rol = (ro - ctr) * R;
        vec3 rdl = rd * R;

        float t0, t1;
        vec3 n0l, n1l;
        if (!traceShard(rol, rdl, nplanes, seed, scale, t0, t1, n0l, n1l)) continue;
        if (t1 <= 0.0) continue;
        float tf = max(t0, 0.0);

        vec3 n = normalize(R * n0l);
        float thick = clamp(t1 - tf, 0.0, 3.0);

        // Reflection off the face, and the view bent through the solid.
        // The refracted ray is sampled once per channel at slightly
        // different bends, which is dispersion doing what it actually does
        // — splitting the transmitted image, not just the highlights.
        vec3 rfl = reflect(rd, n);
        vec3 col = environ(rfl, L, deep, mid, pale, iCrysBeat) * 0.55;

        vec3 tr = refract(rd, n, 0.72);
        if (dot(tr, tr) < 1e-6) tr = rfl;
        vec3 trans;
        trans.r = environ(normalize(tr + n * disp), L, deep, mid, pale, iCrysBeat).r;
        trans.g = environ(tr, L, deep, mid, pale, iCrysBeat).g;
        trans.b = environ(normalize(tr - n * disp), L, deep, mid, pale, iCrysBeat).b;
        // Thicker stone absorbs more and saturates what survives.
        trans *= exp(-thick * 0.42);
        col += trans * mix(mid, pale, 0.35) * 1.25;

        // Internal veins: healed fractures and phantom growth planes.
        // Found along the ray rather than sampled at one depth — a plane
        // inside a solid has to actually be intersected, or it slides
        // about on the surface as the shard turns instead of sitting still
        // inside it. Real quartz is full of these, and without something
        // in it a clear shard reads as an empty shell.
        vec3 oq = rol / scale;
        vec3 rq = rdl / scale;
        vec3 rqn = normalize(rq);
        vec3 vein = vec3(0.0);
        for (int vk = 0; vk < 3; vk++) {
            uint vs = seed + uint(vk) * 977u;
            vec3 vdir = normalize(vec3(hf(vs), hf(vs + 1u), hf(vs + 2u)) - 0.5);
            float voff = (hf(vs + 3u) - 0.5) * 0.5;
            float b = dot(rq, vdir);
            if (abs(b) < 1e-5) continue;
            float tv = (voff - dot(oq, vdir)) / b;
            // Only counts where it lies within the solid.
            if (tv <= tf || tv >= t1) continue;
            // Fades before it reaches the surface, the way a healed
            // fracture sits inside the stone rather than cutting it open.
            vec3 qh = oq + rq * tv;
            float r = length(qh - vdir * voff);
            float bloom = exp(-r * r * 1.9);
            // A fracture is a mirror only a few wavelengths thick, so it
            // catches most when the ray runs along it rather than through.
            float graze = pow(1.0 - abs(dot(rqn, vdir)), 3.0);
            // Thin-film tint — the reason real fractures flash colour.
            vein += mix(mix(mid, pale, 0.72), accent, 0.35 + 0.45 * sin(r * 8.0 + hf(vs + 5u) * 6.2831853))
                * bloom * (0.16 + graze * 1.45);
        }
        col += vein * 0.40;

        // Fresnel: faces turned edge-on to the eye go bright and mirror
        // like, faces square-on stay transmissive. This is what gives a
        // gem its rim brilliance and most of its sense of being solid.
        float fres = pow(1.0 - abs(dot(rd, n)), 4.0);
        col += pale * fres * 0.85;
        // The specular hit proper, the colour of the light rather than of
        // the stone.
        col += mix(fg, accent, 0.2) * pow(max(dot(rfl, L), 0.0), 90.0) * 2.0;

        // The windows, lighting the stone. A face square-on to the focused
        // window flares; the rest of the desktop's windows sum into a
        // softer fill from their side of the screen. Because a facet is
        // one flat plane, these land on whole faces at a time rather than
        // as a smear across the cluster.
        float kd = max(dot(n, key_dir), 0.0);
        col += mix(accent, fg, 0.45) * key_amt * (kd * kd * 0.55 + pow(kd, 40.0) * 1.5);
        float fd = max(dot(n, fill_dir), 0.0);
        col += mix(mid, pale, 0.45) * min(fill_amt, 2.2) * fd * fd * 0.22;

        float band = iCrysBands[int(min(hf(seed ^ 0x1B873593u) * 6.0, 5.0))];
        col *= 0.80 + min(band, 1.2) * 0.35;
        col += mix(mid, pale, 0.5) * wlit * 0.45;

        float alpha = clamp(0.50 + fres * 0.45 + thick * 0.12, 0.0, 0.94);
        if (nhit < MAXHIT) {
            hit_t[nhit] = tf;
            hit_c[nhit] = col;
            hit_a[nhit] = alpha;
            nhit++;
        } else {
            // Buffer full: keep this one only if it is nearer than the
            // furthest already held, since anything behind that is buried.
            int worst = 0;
            float wt = -1e9;
            for (int q = 0; q < MAXHIT; q++) {
                if (hit_t[q] > wt) { wt = hit_t[q]; worst = q; }
            }
            if (tf < wt) {
                for (int q = 0; q < MAXHIT; q++) {
                    if (q == worst) { hit_t[q] = tf; hit_c[q] = col; hit_a[q] = alpha; }
                }
            }
        }
    }

    // Painter's order: repeatedly draw whatever is furthest back.
    vec3 col = mix(bg, deep, 0.75) * (0.75 + wlit * 0.5);
    for (int pass = 0; pass < MAXHIT; pass++) {
        int far = -1;
        float ft = -1e9;
        for (int i = 0; i < MAXHIT; i++) {
            if (i >= nhit) break;
            if (hit_a[i] >= 0.0 && hit_t[i] > ft) { ft = hit_t[i]; far = i; }
        }
        if (far < 0) break;
        for (int i = 0; i < MAXHIT; i++) {
            if (i == far) { col = mix(col, hit_c[i], hit_a[i]); hit_a[i] = -1.0; }
        }
    }

    col += mix(accent, fg, 0.35) * exp(-distance(fc, iMouse.xy) / 200.0) * 0.10;

    vec2 q = (fc / res - 0.5) * 2.0;
    col *= 1.0 - dot(q, q) * 0.28;

    fragColor = vec4(bg + (col - bg) * iCrysBright, 1.0);
}
