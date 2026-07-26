const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const spectral = @import("spectral.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// A short combed pile the desktop sits on. The strands are shader-side —
// a follicle grid marched shell by shell from the tips down to the skin —
// and everything that touches the coat comes from state the daemon
// already tracks: the cursor combs a parting through it, windows crush it
// flat where they sit and shove it aside at their edges, and the focused
// window keeps its own edge standing.
//
// This context owns the drift clock. It creeps on its own so the coat
// always has a slow current running through it, and quickens with energy.
// Accumulated here rather than derived from iTime so a tempo change never
// snaps the grain.
pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    an: spectral.Bands = .{},
    onset: spectral.Onset = .{},

    flow: f32 = 0,

    /// Follicle spacing and pile height, both in pixels. Spacing is the
    /// knob that matters: fine strands shimmer as they move and turn to
    /// noise behind text, so the default is deliberately coarse.
    cell: f32,
    length: f32,
    brightness: f32,

    cached_program: c.GLuint = 0,
    loc_flow: c.GLint = -1,
    loc_bands: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_beat: c.GLint = -1,
    loc_cell: c.GLint = -1,
    loc_len: c.GLint = -1,
    loc_bright: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        var audio: ?*audio_mod.AudioCapture = null;
        if (params.getBool("music", true)) audio = try audio_mod.spawn(allocator, params);
        return .{
            .allocator = allocator,
            .audio = audio,
            .cell = std.math.clamp(params.getFloat("spacing", 23.0), 4.0, 60.0),
            .length = std.math.clamp(params.getFloat("length", 30.0), 2.0, 120.0),
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
        self.flow += dt * (0.25 + self.an.energy_ema * 0.65);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_flow = c.glGetUniformLocation(prog.program, "iFurFlow");
            self.loc_bands = c.glGetUniformLocation(prog.program, "iFurBands[0]");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iFurBass");
            self.loc_beat = c.glGetUniformLocation(prog.program, "iFurBeat");
            self.loc_cell = c.glGetUniformLocation(prog.program, "iFurCell");
            self.loc_len = c.glGetUniformLocation(prog.program, "iFurLength");
            self.loc_bright = c.glGetUniformLocation(prog.program, "iFurBright");
        }
        if (self.loc_flow >= 0) c.glUniform1f(self.loc_flow, self.flow);
        if (self.loc_bands >= 0) c.glUniform1fv(self.loc_bands, 6, &self.an.smooth[0]);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, (self.an.smooth[0] + self.an.smooth[1]) * 0.5);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.onset.beat);
        if (self.loc_cell >= 0) c.glUniform1f(self.loc_cell, self.cell);
        if (self.loc_len >= 0) c.glUniform1f(self.loc_len, self.length);
        if (self.loc_bright >= 0) c.glUniform1f(self.loc_bright, self.brightness);
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| audio_mod.shutdown(audio, self.allocator);
    }
};
