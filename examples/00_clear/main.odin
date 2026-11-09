// M0 acceptance: open a window and draw the test pattern.
//
// Drag a window edge continuously: the border, center crosshair and grid lines must stay crisp at
// 1 logical pixel and follow the new size live — no stretching, no flicker, no stale size.
// Switching the system between light and dark mode switches the colors.
package example_clear

import "core:fmt"
import "core:os"

import "myod:backend"
import "myod:platform"

App :: struct {
	window:  ^platform.Window,
	gpu:     backend.Gpu,
	surface: backend.Surface,
	pattern: backend.Test_Pattern,
	dark:    bool,
}

main :: proc() {
	if !platform.init() {
		fmt.eprintln("failed to initialize the platform layer")
		os.exit(1)
	}
	defer platform.shutdown()

	app: App
	ok: bool
	app.window, ok = platform.open_window("myod · 00_clear", 960, 600)
	if !ok {
		fmt.eprintln("failed to create a window")
		os.exit(1)
	}
	defer platform.close_window(app.window)

	app.gpu, app.surface, ok = backend.init(app.window)
	if !ok {
		os.exit(1)
	}
	defer backend.shutdown(&app.gpu, &app.surface)

	app.pattern = backend.test_pattern_init(app.gpu, app.surface)
	defer backend.test_pattern_destroy(&app.pattern)

	app.dark = platform.is_dark_theme()

	// The platform layer calls redraw directly whenever needed, including while a window edge is dragged.
	platform.set_redraw(app.window, redraw, &app)
	redraw(&app)

	for {
		#partial switch platform.wait_event().kind {
		case .Quit:
			return
		case .Theme_Changed:
			app.dark = platform.is_dark_theme()
			redraw(&app)
		}
		free_all(context.temp_allocator)
	}
}

redraw :: proc(data: rawptr) {
	app := (^App)(data)
	size := platform.pixel_size(app.window)
	scale := platform.display_scale(app.window)

	frame, ok := backend.begin_frame(app.gpu, &app.surface, size)
	if !ok {
		return
	}
	backend.test_pattern_draw(app.gpu, app.surface, frame, app.pattern, scale, colors(app.dark))
	backend.end_frame(app.gpu, &app.surface, frame)

	platform.set_title(app.window, fmt.tprintf("myod · 00_clear · %d×%d px · %.2fx", size.x, size.y, scale))
}

// Color tokens from DESIGN.md. The grid uses the translucent border token, pre-resolved to an opaque
// color over the background as ARCHITECTURE.md prescribes.
colors :: proc(dark: bool) -> backend.Test_Pattern_Colors {
	if dark {
		bg := [3]u8{0x02, 0x02, 0x02}
		fg := [3]u8{0xf8, 0xf8, 0xf8}
		return {bg = bg, fg = fg, grid = over(fg, 0.10, bg)}
	}
	bg := [3]u8{0xf8, 0xf8, 0xf8}
	fg := [3]u8{0x02, 0x02, 0x02}
	return {bg = bg, fg = fg, grid = over(fg, 0.12, bg)}
}

over :: proc(fg: [3]u8, alpha: f32, bg: [3]u8) -> (out: [3]u8) {
	for i in 0 ..< 3 {
		out[i] = u8(f32(fg[i]) * alpha + f32(bg[i]) * (1 - alpha) + 0.5)
	}
	return
}
