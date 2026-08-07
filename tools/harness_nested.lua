-- hyprglaze multi-monitor harness — nested Hyprland config.
-- Generated per run. The user's real ~/.config/hypr/* is never read or written.

hl.config({
	general = {
		gaps_in = 0,
		gaps_out = 0,
		border_size = 0,
		resize_on_border = false,
		allow_tearing = false,
		layout = "dwindle",
	},

	-- Zero chrome: the rect Hyprland reports must be exactly the pixels on
	-- screen, or every measurement is off by a border.
	decoration = {
		rounding = 0,
		active_opacity = 1.0,
		inactive_opacity = 1.0,
		dim_inactive = false,
		shadow = { enabled = false },
		blur = { enabled = false },
	},

	-- KEEP ANIMATIONS ON. parseWorkspaceAnim maps a disabled or "fade"-styled
	-- workspaces leaf to Axis.none, and deriveRawState then drops every
	-- rel ~= 0 record — disabling animations would delete the feature under
	-- test rather than stabilise it. Every other leaf is crushed to 10ms below.
	animations = { enabled = true },

	misc = {
		-- Sentinel: any pixel still magenta is background Hyprland painted
		-- itself, i.e. hyprglaze is NOT on this output.
		background_color = "rgb(ff00ff)",
		force_default_wallpaper = 0,
		disable_hyprland_logo = true,
		disable_splash_rendering = true,
		disable_autoreload = true,
	},

	debug = {
		vfr = false, -- render continuously; grim never catches a stale frame
		damage_tracking = 0, -- full redraw; no partial-damage tearing in a shot
	},

	input = { kb_layout = "us", follow_mouse = 1, sensitivity = 0 },

	cursor = {
		no_hardware_cursors = true, -- nested + NVIDIA; also makes `grim -c` work
		no_warps = true,
		inactive_timeout = 0,
	},

	xwayland = { enabled = false },

	-- Plain sRGB so screenshot pixel values ARE the shader's output.
	render = { cm_enabled = false },

	ecosystem = { enforce_permissions = false, no_update_news = true, no_donation_nag = true },
})

hl.curve("linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })

-- Hyprland's speed unit is 100ms and LARGER IS SLOWER (hypr.zig: duration =
-- speed * 0.1). 0.1 => 10ms, effectively instant.
hl.animation({ leaf = "global", enabled = true, speed = 0.1, bezier = "linear" })
-- The one real animation: 500ms linear horizontal slide. hyprglaze reads
-- exactly this back out of j/animations and mirrors it.
hl.animation({ leaf = "workspaces", enabled = true, speed = 5, bezier = "linear", style = "slide" })

-- Boot-time layout. The harness re-applies positions at runtime once it has
-- read the real output sizes back, so these are defaults only.
hl.monitor({ output = "WAYLAND-1", mode = "800x600", position = "0x0", scale = 1 })
hl.monitor({ output = "WAYLAND-2", mode = "1600x1200", position = "800x0", scale = 1 })
-- Catch-all: a HEADLESS-* or third output must never land at "auto".
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

-- Persistent workspaces pinned per monitor: "focus the other monitor" is one
-- dispatch, and ids stay stable so the adjacent-workspace strip is deterministic.
hl.workspace_rule({ workspace = "1", monitor = "WAYLAND-1", default = true, persistent = true })
hl.workspace_rule({ workspace = "2", monitor = "WAYLAND-1", persistent = true })
hl.workspace_rule({ workspace = "3", monitor = "WAYLAND-1", persistent = true })
hl.workspace_rule({ workspace = "11", monitor = "WAYLAND-2", default = true, persistent = true })
hl.workspace_rule({ workspace = "12", monitor = "WAYLAND-2", persistent = true })
hl.workspace_rule({ workspace = "13", monitor = "WAYLAND-2", persistent = true })

-- Probe windows float; the harness places them by exact pixel dispatch and
-- reads the real rect back from `hyprctl clients`.
hl.window_rule({ name = "probe-float", match = { class = "^probe" }, float = true, no_anim = true })

hl.bind("SUPER + SHIFT + Q", hl.dsp.exit())
