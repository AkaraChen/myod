// Shared scaffolding for the milestone examples: a window, the GPU, a text context, keys to switch
// scale and theme, the debug overlays, and offscreen capture for self-tests.
//
// Keys: 1 / 2 / 3 / 4 simulate a 1x / 1.25x / 1.5x / 2x display scale (0 returns to the real
// scale); d toggles light / dark.
package demo

import "core:fmt"
import "core:math"
import "core:os"
import "core:time"

import "../../backend"
import "../../platform"
import "../../render"
import "../../text"
import "../../theme"
import ".."

SCALES :: [4]f32{1, 1.25, 1.5, 2}

// Draws one frame of the page. `view` is the logical size of the area to draw into.
Draw_Proc :: #type proc(list: ^render.Command_List, ctx: ^text.Context, t: theme.Theme, scale: f32, view: [2]f32, data: rawptr)

App :: struct {
	title:       string,
	window:      ^platform.Window,
	gpu:         backend.Gpu,
	surface:     backend.Surface,
	renderer:    backend.Renderer,
	mode:        theme.Mode,
	mode_forced: bool,
	scale:       f32, // 0 = the real display scale
	draw:        Draw_Proc,
	data:        rawptr,
	text:        text.Context, // declared last: inside the struct, `text` names this field
}

// Opens the window and initializes the GPU and text. Exits the process with a message on failure.
open :: proc(app: ^App, title: string, size: [2]f32, draw: Draw_Proc, data: rawptr = nil) {
	app.title = title
	app.draw = draw
	app.data = data
	if !platform.init() {
		fmt.eprintln("failed to initialize the platform layer")
		os.exit(1)
	}
	ok: bool
	app.window, ok = platform.open_window(title, i32(size.x), i32(size.y))
	if !ok {
		fmt.eprintln("failed to create a window")
		os.exit(1)
	}
	app.gpu, app.surface, ok = backend.init(app.window)
	if !ok {
		os.exit(1)
	}
	app.renderer = backend.renderer_init(app.gpu, app.surface.config.format, app.surface.srgb)
	if !text.init(&app.text) {
		fmt.eprintln("failed to load DWG from third_party/fonts (run from the repo root, or set MYOD_FONT_DIR)")
		os.exit(1)
	}
	app.mode = .Dark if platform.is_dark_theme() else .Light
}

close :: proc(app: ^App) {
	text.destroy(&app.text)
	backend.renderer_destroy(&app.renderer)
	backend.shutdown(&app.gpu, &app.surface)
	platform.close_window(app.window)
	platform.shutdown()
}

// Runs the interactive event loop until the window closes.
run :: proc(app: ^App) {
	platform.set_redraw(app.window, redraw, app)
	redraw(app)
	for {
		e := platform.wait_event()
		#partial switch e.kind {
		case .Quit:
			return
		case .Theme_Changed:
			if !app.mode_forced {
				app.mode = .Dark if platform.is_dark_theme() else .Light
			}
		case .Key_Down:
			switch e.key {
			case '0':
				app.scale = 0
			case '1' ..= '4':
				scales := SCALES
				app.scale = scales[e.key - '1']
			case 'd':
				app.mode = .Light if app.mode == .Dark else .Dark
				app.mode_forced = true
			}
		}
		redraw(app)
		free_all(context.temp_allocator)
	}
}

@(private)
redraw :: proc(data: rawptr) {
	app := (^App)(data)
	if backend.device_lost(app.gpu) {
		backend.renderer_destroy(&app.renderer)
		if !backend.recover(&app.gpu, &app.surface, app.window) {
			os.exit(1)
		}
		app.renderer = backend.renderer_init(app.gpu, app.surface.config.format, app.surface.srgb)
	}
	size := platform.pixel_size(app.window)
	real_scale := platform.display_scale(app.window)
	scale := app.scale if app.scale > 0 else real_scale
	t := theme.make_theme(app.mode)
	view := [2]f32{f32(size.x) / scale, f32(size.y) / scale}

	text.begin_frame(&app.text)
	list := render.make_command_list()
	app.draw(&list, &app.text, t, scale, view, app.data)
	flags := devtools.flags()
	if flags.atlas {
		devtools.atlas_overlay(&list, &app.text, view, scale, t)
	}
	if flags.render {
		devtools.render_overlay(&list, &app.text, app.renderer.stats, view, scale, t)
	}

	frame, ok := backend.begin_frame(app.gpu, &app.surface, size)
	if !ok {
		return
	}
	backend.renderer_draw(app.gpu, &app.renderer, frame.encoder, frame.view, size, scale, list, t.on_bg.bg, &app.text.atlases)
	backend.end_frame(app.gpu, &app.surface, frame)

	st := app.renderer.stats
	platform.set_title(
		app.window,
		fmt.tprintf(
			"%s · %v · scale %.2f%s · %d instances · %d draw calls · %.3f ms",
			app.title,
			app.mode,
			scale,
			" (simulated)" if app.scale > 0 else "",
			st.instances,
			st.draw_calls,
			time.duration_milliseconds(st.cpu_time),
		),
	)
}

// Renders the page offscreen at `scale` for a logical `view` and reads it back (temp memory).
// The debug overlays are included when their environment variables are set.
capture :: proc(app: ^App, mode: theme.Mode, scale: f32, view: [2]f32) -> (backend.Capture, bool) {
	t := theme.make_theme(mode)
	size := [2]u32{u32(math.ceil(view.x * scale)), u32(math.ceil(view.y * scale))}
	text.begin_frame(&app.text)
	list := render.make_command_list()
	app.draw(&list, &app.text, t, scale, view, app.data)
	flags := devtools.flags()
	if flags.atlas {
		devtools.atlas_overlay(&list, &app.text, view, scale, t)
	}
	if flags.render {
		devtools.render_overlay(&list, &app.text, app.renderer.stats, view, scale, t)
	}
	return backend.capture(app.gpu, &app.renderer, size, scale, list, t.on_bg.bg, context.temp_allocator, &app.text.atlases)
}

// Writes a capture as raw RGBA (a width and height u32 header, then rows) for tools/rgba2png.py.
dump :: proc(cap: backend.Capture, path: string) -> bool {
	header := [2]u32{cap.width, cap.height}
	data := make([]u8, 8 + len(cap.pixels), context.temp_allocator)
	copy(data, ([^]u8)(&header)[:8])
	copy(data[8:], cap.pixels)
	return os.write_entire_file(path, data) == nil
}

// Handles `--dump <prefix>`: captures the page at 1x and 2x in both themes into <prefix>-<mode>-<scale>x.rgba.
// Returns false if the flag is absent.
dump_from_args :: proc(app: ^App, view: [2]f32) -> bool {
	for arg, i in os.args {
		if arg != "--dump" || i + 1 >= len(os.args) {
			continue
		}
		prefix := os.args[i + 1]
		for mode in theme.Mode {
			for scale in ([2]f32{1, 2}) {
				cap, ok := capture(app, mode, scale, view)
				if ok {
					path := fmt.tprintf("%s-%v-%dx.rgba", prefix, mode, int(scale))
					dump(cap, path)
					fmt.println("wrote", path)
				}
				free_all(context.temp_allocator)
			}
		}
		return true
	}
	return false
}

// The color of one captured pixel (opaque).
pixel :: proc(cap: backend.Capture, x, y: u32) -> theme.Color {
	i := (y * cap.width + x) * 4
	return {cap.pixels[i], cap.pixels[i + 1], cap.pixels[i + 2], 255}
}
