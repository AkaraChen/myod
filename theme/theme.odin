// Color tokens from DESIGN.md.
//
// Translucent tokens (border, overlay, faint, …) are defined as "fg at some alpha". They are almost
// always drawn over bg or bg-solid, so they are pre-resolved to opaque colors for each of those two
// surfaces when the theme is built. Opaque colors skip blending, so they match the design exactly on
// every platform and with every blending mode (see ARCHITECTURE.md, "Rendering backend").
package theme

// An sRGB color, 8 bits per channel, straight (non-premultiplied) alpha.
Color :: [4]u8

Mode :: enum {
	Light,
	Dark,
}

// Every token resolved to an opaque color over one particular surface.
Palette :: struct {
	bg:            Color,
	bg_solid:      Color,
	fg:            Color,
	muted:         Color,
	faint:         Color,
	border:        Color,
	border_strong: Color,
	overlay:       Color,
	overlay_hover: Color,
	error:         Color,
	warning:       Color,
	success:       Color,
	info:          Color,
}

Theme :: struct {
	mode:     Mode,
	on_bg:    Palette, // for content drawn on the window background
	on_solid: Palette, // for content drawn on popovers and menus (bg-solid)
	// Opacity of disabled widgets, applied as group alpha at draw time.
	disabled_alpha: f32,
}

// Source definitions: opaque colors are plain sRGB, translucent ones are fg + alpha.
@(private)
Source :: struct {
	bg, bg_solid, fg, muted:                                   [3]u8,
	faint, border, border_strong, overlay, overlay_hover:      f32,
	error, warning, success, info:                             [3]u8,
}

@(private)
LIGHT :: Source {
	bg            = {0xf8, 0xf8, 0xf8},
	bg_solid      = {0xff, 0xff, 0xff},
	fg            = {0x02, 0x02, 0x02},
	muted         = {0x5d, 0x5d, 0x5d},
	faint         = 0.55,
	border        = 0.12,
	border_strong = 0.30,
	overlay       = 0.05,
	overlay_hover = 0.09,
	error         = {0xd4, 0x09, 0x24},
	warning       = {0xbf, 0x67, 0x00},
	success       = {0x00, 0x7d, 0x1e},
	info          = {0x00, 0x69, 0xbd},
}

@(private)
DARK :: Source {
	bg            = {0x02, 0x02, 0x02},
	bg_solid      = {0x06, 0x06, 0x06},
	fg            = {0xf8, 0xf8, 0xf8},
	muted         = {0xb1, 0xb1, 0xb1},
	faint         = 0.52,
	border        = 0.10,
	border_strong = 0.28,
	overlay       = 0.05,
	overlay_hover = 0.09,
	error         = {0xf3, 0x62, 0x5d},
	warning       = {0xde, 0x93, 0x00},
	success       = {0x2e, 0xa9, 0x57},
	info          = {0x00, 0x99, 0xe6},
}

make_theme :: proc(mode: Mode) -> Theme {
	src := LIGHT if mode == .Light else DARK
	return Theme {
		mode = mode,
		on_bg = resolve(src, src.bg),
		on_solid = resolve(src, src.bg_solid),
		disabled_alpha = 0.36,
	}
}

@(private)
resolve :: proc(src: Source, surface: [3]u8) -> Palette {
	return Palette {
		bg            = opaque(src.bg),
		bg_solid      = opaque(src.bg_solid),
		fg            = opaque(src.fg),
		muted         = opaque(src.muted),
		faint         = over(src.fg, src.faint, surface),
		border        = over(src.fg, src.border, surface),
		border_strong = over(src.fg, src.border_strong, surface),
		overlay       = over(src.fg, src.overlay, surface),
		overlay_hover = over(src.fg, src.overlay_hover, surface),
		error         = opaque(src.error),
		warning       = opaque(src.warning),
		success       = opaque(src.success),
		info          = opaque(src.info),
	}
}

@(private)
opaque :: proc(c: [3]u8) -> Color {
	return {c.r, c.g, c.b, 255}
}

// Composites `fg` at `alpha` over an opaque `bg` in sRGB (gamma) space, the way browsers do.
over :: proc(fg: [3]u8, alpha: f32, bg: [3]u8) -> (out: Color) {
	for i in 0 ..< 3 {
		out[i] = u8(f32(fg[i]) * alpha + f32(bg[i]) * (1 - alpha) + 0.5)
	}
	out.a = 255
	return
}

// Returns `c` with its alpha multiplied by `alpha` (group opacity, e.g. disabled widgets).
with_alpha :: proc(c: Color, alpha: f32) -> Color {
	return {c.r, c.g, c.b, u8(f32(c.a) * alpha + 0.5)}
}
