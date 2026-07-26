const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const spectral = @import("spectral.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// A cleaved gem the desktop lives inside. The facets are shader-side —
// drifting fracture planes, so faces are irregular convex polygons with
// straight cleavage edges — and each face holds one constant normal, so a
// sweeping light flashes whole faces at once the way a real cut stone
// sparkles when you turn it. Windows are light sources buried in the
// stone; the glow transmitting out through the facets is what makes them
// present, and it splits prismatically on the way.
//
// This context owns the one thing the shader can't keep: the turn clock.
// It creeps on its own, quickens with energy, and lurches on kicks — so a
// beat sends a wave of faces catching the light in sequence. Accumulated
// here rather than derived from iTime so a tempo change never snaps the
// stone's angle.
pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    an: spectral.Bands = .{},
    onset: spectral.Onset = .{},

    /// Light-sweep angle, and the decaying angular kick a beat adds to it.
    turn: f32 = 0,
    turn_vel: f32 = 0,
    beat_prev: f32 = 0,

    dispersion: f32,
    brightness: f32,

    cached_program: c.GLuint = 0,
    loc_turn: c.GLint = -1,
    loc_bands: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_beat: c.GLint = -1,
    loc_disp: c.GLint = -1,
    loc_bright: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        var audio: ?*audio_mod.AudioCapture = null;
        if (params.getBool("music", true)) audio = try audio_mod.spawn(allocator, params);
        return .{
            .allocator = allocator,
            .audio = audio,
            .dispersion = std.math.clamp(params.getFloat("dispersion", 1.0), 0.0, 4.0),
            .brightness = std.math.clamp(params.getFloat("brightness", 1.0), 0.0, 3.0),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        if (self.audio) |audio| {
            const wave = audio.getWaveform();
            const mags = spectral.magnitudes(&wave);
            self.an.update(&mags, dt);
            self.onset.update(&mags, dt, self.an.bands[0]);
        }

        const beat_hit = self.onset.beat > self.beat_prev;
        self.beat_prev = self.onset.beat;
        if (beat_hit) self.turn_vel += 2.4 * std.math.clamp(self.onset.beat, 0.0, 1.5);
        self.turn_vel *= @exp(-3.0 * dt);
        self.turn += dt * (0.20 + self.an.energy_ema * 0.75 + self.turn_vel);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_turn = c.glGetUniformLocation(prog.program, "iCrysTurn");
            self.loc_bands = c.glGetUniformLocation(prog.program, "iCrysBands[0]");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iCrysBass");
            self.loc_beat = c.glGetUniformLocation(prog.program, "iCrysBeat");
            self.loc_disp = c.glGetUniformLocation(prog.program, "iCrysDisp");
            self.loc_bright = c.glGetUniformLocation(prog.program, "iCrysBright");
        }
        if (self.loc_turn >= 0) c.glUniform1f(self.loc_turn, self.turn);
        if (self.loc_bands >= 0) c.glUniform1fv(self.loc_bands, 6, &self.an.smooth[0]);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, (self.an.smooth[0] + self.an.smooth[1]) * 0.5);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.onset.beat);
        if (self.loc_disp >= 0) c.glUniform1f(self.loc_disp, self.dispersion);
        if (self.loc_bright >= 0) c.glUniform1f(self.loc_bright, self.brightness);
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| audio_mod.shutdown(audio, self.allocator);
    }
};
