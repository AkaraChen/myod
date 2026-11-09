// M1 acceptance: the static look of buttons, toggles, checkboxes, progress bars and friends,
// drawn with DESIGN.md tokens (no text yet: labels are placeholder bars in the text color).
//
// Interactive keys:
//   1 / 2 / 3 / 4   simulate a 1x / 1.25x / 1.5x / 2x display scale (0 returns to the real scale)
//   d               toggle light / dark (otherwise follows the system)
//   l               destroy the GPU device on purpose to exercise device-loss recovery
//
// Flags:
//   --selftest      render offscreen at every scale in both themes and check the pixels: probes must
//                   match the tokens exactly, and no pixel may have a color the page could not produce
//                   (an in-between color means a blurry edge)
//   --bench         redraw 10,000 rectangles continuously and report frame times
package example_rects

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:time"

import "myod:backend"
import "myod:platform"
import "myod:render"
import "myod:theme"

PAGE :: [2]f32{960, 560}
SCALES :: [4]f32{1, 1.25, 1.5, 2}

App :: struct {
	window:      ^platform.Window,
	gpu:         backend.Gpu,
	surface:     backend.Surface,
	renderer:    backend.Renderer,
	mode:        theme.Mode,
	mode_forced: bool,
	scale:       f32, // 0 = the real display scale
}

main :: proc() {
	selftest := slice.contains(os.args, "--selftest")
	bench := slice.contains(os.args, "--bench")

	if !platform.init() {
		fmt.eprintln("failed to initialize the platform layer")
		os.exit(1)
	}
	defer platform.shutdown()

	app: App
	ok: bool
	app.window, ok = platform.open_window("myod · 01_rects", i32(PAGE.x), i32(PAGE.y))
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

	app.renderer = backend.renderer_init(app.gpu, app.surface.config.format, app.surface.srgb)
	defer backend.renderer_destroy(&app.renderer)

	app.mode = .Dark if platform.is_dark_theme() else .Light

	if selftest {
		os.exit(0 if run_selftest(&app) else 1)
	}
	if bench {
		run_bench(&app)
		return
	}

	platform.set_redraw(app.window, redraw, &app)
	redraw(&app)

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
			case 'l':
				fmt.eprintln("01_rects: destroying the GPU device on purpose")
				backend.debug_lose_device(app.gpu)
			}
		}
		redraw(&app)
		free_all(context.temp_allocator)
	}
}

redraw :: proc(data: rawptr) {
	app := (^App)(data)
	if backend.device_lost(app.gpu) {
		backend.renderer_destroy(&app.renderer)
		if !backend.recover(&app.gpu, &app.surface, app.window) {
			fmt.eprintln("01_rects: could not recover from device loss")
			os.exit(1)
		}
		app.renderer = backend.renderer_init(app.gpu, app.surface.config.format, app.surface.srgb)
		fmt.eprintln("01_rects: recovered from device loss")
	}

	size := platform.pixel_size(app.window)
	real_scale := platform.display_scale(app.window)
	scale := app.scale if app.scale > 0 else real_scale
	t := theme.make_theme(app.mode)

	list := render.make_command_list()
	draw_page(&list, t)

	frame, ok := backend.begin_frame(app.gpu, &app.surface, size)
	if !ok {
		return
	}
	backend.renderer_draw(app.gpu, &app.renderer, frame.encoder, frame.view, size, scale, list, t.on_bg.bg)
	backend.end_frame(app.gpu, &app.surface, frame)

	st := app.renderer.stats
	platform.set_title(
		app.window,
		fmt.tprintf(
			"myod · 01_rects · %v · scale %.2f%s · %d instances · %d draw calls · %.3f ms",
			app.mode,
			scale,
			" (simulated)" if app.scale > 0 else "",
			st.instances,
			st.draw_calls,
			time.duration_milliseconds(st.cpu_time),
		),
	)
}

// ---- The page ----

draw_page :: proc(l: ^render.Command_List, t: theme.Theme) {
	p := t.on_bg
	s := t.on_solid

	// Buttons: four variants × four states.
	for v in Button_Variant {
		for st in Button_State {
			x := 40 + f32(int(st)) * 108
			y := 40 + f32(int(v)) * 40
			button(l, p, {x, y, 96, 28}, v, st, t.disabled_alpha)
		}
	}

	// A focused button: 2px fg ring, 1px outside the button.
	b := render.Rect{40, 220, 96, 28}
	button(l, p, b, .Outline, .Idle, t.disabled_alpha)
	render.bordered(l, {b.x - 3, b.y - 3, b.w + 6, b.h + 6}, p.fg, 2)

	// Toggles, checkboxes, radios.
	toggle(l, p, 172, 224, false)
	toggle(l, p, 220, 224, true)
	checkbox(l, p, 276, 226, false)
	checkbox(l, p, 304, 226, true)
	radio(l, p, 332, 226, false)
	radio(l, p, 360, 226, true)

	// Progress bars and a slider.
	for v, i in ([3]f32{0.34, 0.78, 1}) {
		progress(l, p, 40, 272 + f32(i) * 20, 200, v)
	}
	slider(l, p, 260, 276, 160, 0.4)

	// Tags in each signal color.
	for c, i in ([5]theme.Color{p.error, p.warning, p.success, p.info, p.muted}) {
		tag(l, {40 + f32(i) * 76, 340, 64, 20}, c)
	}

	// List rows.
	for i in 0 ..< 4 {
		list_row(l, p, {40, 392 + f32(i) * 28, 380, 28}, p.error if i == 3 else p.fg)
	}

	// Divider between the two columns, and a hovered divider (same width, fg color).
	render.line(l, {470, 40, 1, 480}, p.border)
	render.line(l, {500, 520, 400, 1}, p.fg)

	// Menu on a bg-solid surface: 2px border, 1px separators, the current item marked by a 2px bar.
	menu(l, s, {500, 40, 180, 132})

	// Tooltip: inverted colors.
	render.fill(l, {700, 40, 120, 20}, p.fg)
	text_bar(l, {700, 40, 120, 20}, 72, p.bg)

	// A clipped scroll area with an overlay scrollbar.
	scroll_area(l, p, {500, 200, 240, 120})
}

Button_Variant :: enum {
	Outline,
	Primary,
	Ghost,
	Danger,
}

Button_State :: enum {
	Idle,
	Hover,
	Pressed,
	Disabled,
}

// Colors per DESIGN.md, "Component specs" → buttons. A zero color means "not drawn".
button :: proc(l: ^render.Command_List, p: theme.Palette, r: render.Rect, v: Button_Variant, s: Button_State, disabled_alpha: f32) {
	fill, border, text: theme.Color
	state := Button_State.Idle if s == .Disabled else s
	switch v {
	case .Outline:
		switch state {
		case .Idle, .Disabled: border, text = p.border_strong, p.fg
		case .Hover:           border, fill, text = p.fg, p.overlay, p.fg
		case .Pressed:         border, fill, text = p.fg, p.fg, p.bg
		}
	case .Primary:
		switch state {
		case .Idle, .Disabled: border, fill, text = p.fg, p.fg, p.bg
		case .Hover:           border, text = p.fg, p.fg
		case .Pressed:         border, fill, text = p.fg, p.overlay_hover, p.fg
		}
	case .Ghost:
		switch state {
		case .Idle, .Disabled: text = p.muted
		case .Hover:           border, fill, text = p.border, p.overlay, p.fg
		case .Pressed:         fill, text = p.overlay_hover, p.fg
		}
	case .Danger:
		switch state {
		case .Idle, .Disabled:  border, text = p.error, p.error
		case .Hover, .Pressed:  border, fill, text = p.error, p.error, p.bg
		}
	}
	if s == .Disabled {
		fill = theme.with_alpha(fill, disabled_alpha)
		border = theme.with_alpha(border, disabled_alpha)
		text = theme.with_alpha(text, disabled_alpha)
	}
	render.bordered(l, r, border, 1, fill)
	text_bar(l, r, 40, text)
}

// A placeholder for a text label: a 6px bar centered in the given rect.
text_bar :: proc(l: ^render.Command_List, r: render.Rect, width: f32, color: theme.Color) {
	if color.a == 0 {
		return
	}
	render.fill(l, {r.x + math.floor((r.w - width) / 2), r.y + math.floor((r.h - 6) / 2), width, 6}, color)
}

toggle :: proc(l: ^render.Command_List, p: theme.Palette, x, y: f32, on: bool) {
	if on {
		render.bordered(l, {x, y, 36, 20}, p.success, 1, p.success)
		render.fill(l, {x + 19, y + 3, 14, 14}, p.bg_solid)
	} else {
		render.bordered(l, {x, y, 36, 20}, p.border_strong, 1)
		render.fill(l, {x + 3, y + 3, 14, 14}, p.muted)
	}
}

checkbox :: proc(l: ^render.Command_List, p: theme.Palette, x, y: f32, checked: bool) {
	if checked {
		render.fill(l, {x, y, 16, 16}, p.fg)
		render.fill(l, {x + 5, y + 5, 6, 6}, p.bg) // stands in for the `check` icon until M2
	} else {
		render.bordered(l, {x, y, 16, 16}, p.border_strong, 1)
	}
}

radio :: proc(l: ^render.Command_List, p: theme.Palette, x, y: f32, selected: bool) {
	render.bordered(l, {x, y, 16, 16}, p.border_strong, 1)
	if selected {
		render.fill(l, {x + 4, y + 4, 8, 8}, p.fg)
	}
}

progress :: proc(l: ^render.Command_List, p: theme.Palette, x, y, w, value: f32) {
	render.bordered(l, {x, y, w, 8}, p.border_strong, 1)
	render.fill(l, {x + 1, y + 1, math.round((w - 2) * value), 6}, p.fg)
}

slider :: proc(l: ^render.Command_List, p: theme.Palette, x, y, w, value: f32) {
	render.bordered(l, {x, y, w, 6}, p.border_strong, 1)
	render.fill(l, {x + math.round((w - 8) * value), y - 4, 8, 14}, p.fg)
}

tag :: proc(l: ^render.Command_List, r: render.Rect, color: theme.Color) {
	render.bordered(l, r, color, 1)
	text_bar(l, r, 36, color)
}

list_row :: proc(l: ^render.Command_List, p: theme.Palette, r: render.Rect, value_color: theme.Color) {
	render.line(l, {r.x, r.y + r.h - 1, r.w, 1}, p.border)
	render.fill(l, {r.x + 8, r.y + 11, 96, 6}, p.muted)
	render.fill(l, {r.x + r.w - 8 - 48, r.y + 11, 48, 6}, value_color)
}

menu :: proc(l: ^render.Command_List, s: theme.Palette, r: render.Rect) {
	render.bordered(l, r, s.border_strong, 2, s.bg_solid)
	item_colors := [4]theme.Color{s.fg, s.fg, s.muted, s.error}
	for c, i in item_colors {
		item := render.Rect{r.x + 2, r.y + 2 + f32(i) * 32, r.w - 4, 32}
		if i < 3 {
			render.line(l, {item.x, item.y + 31, item.w, 1}, s.border)
		}
		if i == 0 {
			render.line(l, {item.x, item.y, 2, 31}, s.fg)
		}
		render.fill(l, {item.x + 12, item.y + 13, 72, 6}, c)
	}
}

scroll_area :: proc(l: ^render.Command_List, p: theme.Palette, r: render.Rect) {
	render.bordered(l, r, p.border_strong, 1)
	inner := render.Rect{r.x + 1, r.y + 1, r.w - 2, r.h - 2}
	render.clip_push(l, inner)
	for i in 0 ..< 10 {
		list_row(l, p, {inner.x, inner.y - 14 + f32(i) * 28, inner.w, 28}, p.fg)
	}
	render.clip_pop(l)
	render.fill(l, {inner.x + inner.w - 6, inner.y + 8, 6, 40}, p.border_strong) // overlay scrollbar thumb
}

// ---- Self-test ----

run_selftest :: proc(app: ^App) -> bool {
	all_ok := true
	for mode in theme.Mode {
		t := theme.make_theme(mode)
		for scale in SCALES {
			allowed := allowed_colors(t, app.renderer.srgb) // temp memory is freed after every scale
			size := [2]u32{u32(math.ceil(PAGE.x * scale)), u32(math.ceil(PAGE.y * scale))}
			list := render.make_command_list()
			draw_page(&list, t)
			cap, ok := backend.capture(app.gpu, &app.renderer, size, scale, list, t.on_bg.bg, context.temp_allocator)
			if !ok {
				fmt.eprintfln("FAIL %v %.2fx: capture failed", mode, scale)
				all_ok = false
				continue
			}

			// 1. Probes: known pixels must match the tokens exactly.
			Probe :: struct {
				name:   string,
				at:     [2]f32, // logical position (a point well inside a solid area)
				expect: theme.Color,
			}
			probes := [?]Probe {
				{"page background", {20, 20}, t.on_bg.bg},
				{"primary button fill", {40 + 4, 80 + 4}, t.on_bg.fg},
				{"outline button border (top-left pixel)", {40, 40}, t.on_bg.border_strong},
				{"pressed outline fill", {256 + 4, 40 + 4}, t.on_bg.fg},
				{"hover outline overlay", {148 + 4, 40 + 4}, t.on_bg.overlay},
				{"toggle on fill", {220 + 2, 224 + 10}, t.on_bg.success},
				{"menu fill", {500 + 160, 40 + 10}, t.on_solid.bg_solid},
				{"menu border", {500, 40 + 50}, t.on_solid.border_strong},
				{"error tag border", {40, 340 + 10}, t.on_bg.error},
			}
			for pr in probes {
				px := u32(math.round(pr.at.x * scale))
				py := u32(math.round(pr.at.y * scale))
				got := pixel(cap, px, py)
				if got != pr.expect {
					fmt.eprintfln("FAIL %v %.2fx: %s at (%d, %d) is %v, expected %v", mode, scale, pr.name, px, py, got, pr.expect)
					all_ok = false
				}
			}

			// 2. Crisp edges: every pixel must be a color the page can produce. Check each distinct
			//    color once, counting how many pixels have it.
			counts := make(map[theme.Color]int, 256, context.temp_allocator)
			for i := 0; i < len(cap.pixels); i += 4 {
				counts[theme.Color{cap.pixels[i], cap.pixels[i + 1], cap.pixels[i + 2], 255}] += 1
			}
			unexpected := 0
			sample: theme.Color
			for c, n in counts {
				if !contains_close(allowed[:], c) {
					if unexpected == 0 {
						sample = c
					}
					unexpected += n
				}
			}
			// 3. Uniform hairlines: every list-row separator must have the same physical thickness.
			want := u32(max(1, math.round(scale)))
			for i in 0 ..< 4 {
				x := u32(math.round(240 * scale))
				y0 := u32(math.round((392 + f32(i) * 28 + 20) * scale))
				thickness := u32(0)
				for y in y0 ..< y0 + u32(math.round(16 * scale)) {
					if pixel(cap, x, y) == t.on_bg.border {
						thickness += 1
					}
				}
				if thickness != want {
					fmt.eprintfln("FAIL %v %.2fx: separator of row %d is %d px thick, expected %d", mode, scale, i, thickness, want)
					all_ok = false
				}
			}

			if unexpected > 0 {
				fmt.eprintfln("FAIL %v %.2fx: %d pixels have colors the page cannot produce (e.g. %v)", mode, scale, unexpected, sample)
				all_ok = false
			} else {
				fmt.printfln("ok   %v %.2fx: %d×%d, all probes exact, no in-between colors", mode, scale, size.x, size.y)
			}
			free_all(context.temp_allocator)
		}
	}
	// 4. Device loss: destroy the device on purpose, recover, and render again.
	// The loss is reported by the first frame that touches the lost device, as in a real app.
	backend.debug_lose_device(app.gpu)
	redraw(app)
	if !backend.device_lost(app.gpu) {
		fmt.eprintln("FAIL device loss: destroying the device was not reported as a loss")
		all_ok = false
	} else {
		backend.renderer_destroy(&app.renderer)
		if !backend.recover(&app.gpu, &app.surface, app.window) {
			fmt.eprintln("FAIL device loss: recovery failed")
			all_ok = false
		} else {
			app.renderer = backend.renderer_init(app.gpu, app.surface.config.format, app.surface.srgb)
			t := theme.make_theme(.Light)
			list := render.make_command_list()
			draw_page(&list, t)
			cap, ok := backend.capture(app.gpu, &app.renderer, {960, 560}, 1, list, t.on_bg.bg, context.temp_allocator)
			if !ok || pixel(cap, 44, 84) != t.on_bg.fg || backend.device_lost(app.gpu) {
				fmt.eprintln("FAIL device loss: rendering after recovery is wrong")
				all_ok = false
			} else {
				fmt.println("ok   device loss: detected, recovered, rendering correct afterwards")
			}
		}
	}

	fmt.println("selftest:", "PASS" if all_ok else "FAIL")
	return all_ok
}

// Every opaque token, plus every token composited at the disabled alpha over another token or over
// such a composite (disabled labels sit on disabled fills). Blending happens in the same space as on
// the GPU: gamma space for non-sRGB targets, linear space for sRGB targets.
allowed_colors :: proc(t: theme.Theme, linear: bool) -> [dynamic]theme.Color {
	base := make([dynamic]theme.Color, context.temp_allocator)
	for pal in ([2]theme.Palette{t.on_bg, t.on_solid}) {
		for c in ([13]theme.Color{
			pal.bg, pal.bg_solid, pal.fg, pal.muted, pal.faint, pal.border, pal.border_strong,
			pal.overlay, pal.overlay_hover, pal.error, pal.warning, pal.success, pal.info,
		}) {
			append(&base, c)
		}
	}
	out := make([dynamic]theme.Color, context.temp_allocator)
	append(&out, ..base[:])
	level1 := make([dynamic]theme.Color, context.temp_allocator)
	for a in base {
		for b in base {
			append(&level1, blend(a, t.disabled_alpha, b, linear))
		}
	}
	append(&out, ..level1[:])
	for a in base {
		for b in level1 {
			append(&out, blend(a, t.disabled_alpha, b, linear))
		}
	}
	return out
}

blend :: proc(fg: theme.Color, alpha: f32, bg: theme.Color, linear: bool) -> (out: theme.Color) {
	for i in 0 ..< 3 {
		f, b := f32(fg[i]) / 255, f32(bg[i]) / 255
		if linear {
			v := to_linear(f) * alpha + to_linear(b) * (1 - alpha)
			out[i] = u8(math.round(to_srgb(v) * 255))
		} else {
			out[i] = u8(math.round((f * alpha + b * (1 - alpha)) * 255))
		}
	}
	out.a = 255
	return
}

to_linear :: proc(v: f32) -> f32 {
	return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
}

to_srgb :: proc(v: f32) -> f32 {
	return v * 12.92 if v <= 0.0031308 else 1.055 * math.pow(v, 1 / 2.4) - 0.055
}

// GPU blending rounds slightly differently from the CPU, so composites may be off by 1 per channel.
contains_close :: proc(set: []theme.Color, c: theme.Color) -> bool {
	for s in set {
		if abs(int(s.r) - int(c.r)) <= 1 && abs(int(s.g) - int(c.g)) <= 1 && abs(int(s.b) - int(c.b)) <= 1 {
			return true
		}
	}
	return false
}

pixel :: proc(cap: backend.Capture, x, y: u32) -> theme.Color {
	i := (y * cap.width + x) * 4
	return {cap.pixels[i], cap.pixels[i + 1], cap.pixels[i + 2], 255}
}

// ---- Benchmark ----

run_bench :: proc(app: ^App) {
	FRAMES :: 600
	COUNT :: 10_000
	t := theme.make_theme(app.mode)
	r := rand.create(1)
	context.random_generator = rand.default_random_generator(&r)

	Box :: struct {
		rect:  render.Rect,
		color: theme.Color,
	}
	boxes := make([]Box, COUNT)
	defer delete(boxes)
	palette := [5]theme.Color{t.on_bg.fg, t.on_bg.muted, t.on_bg.border_strong, t.on_bg.info, t.on_bg.success}
	for &b in boxes {
		b.rect = {rand.float32() * (PAGE.x - 24), rand.float32() * (PAGE.y - 24), 4 + rand.float32() * 20, 4 + rand.float32() * 20}
		b.color = rand.choice(palette[:])
	}

	cpu_total: time.Duration
	start := time.tick_now()
	frames := 0
	for frames < FRAMES {
		for {
			e := platform.poll_event()
			if e.kind == .None {
				break
			}
			if e.kind == .Quit {
				return
			}
		}
		size := platform.pixel_size(app.window)
		scale := platform.display_scale(app.window)
		list := render.make_command_list()
		for b in boxes {
			render.fill(&list, b.rect, b.color)
		}
		frame, ok := backend.begin_frame(app.gpu, &app.surface, size)
		if ok {
			backend.renderer_draw(app.gpu, &app.renderer, frame.encoder, frame.view, size, scale, list, t.on_bg.bg)
			backend.end_frame(app.gpu, &app.surface, frame)
			cpu_total += app.renderer.stats.cpu_time
			frames += 1
		}
		free_all(context.temp_allocator)
	}
	elapsed := time.tick_since(start)
	interval := time.duration_milliseconds(elapsed) / FRAMES
	fmt.printfln(
		"bench: %d rectangles, %d frames, %.2f ms per frame (%.1f fps), renderer CPU time %.3f ms per frame",
		COUNT,
		FRAMES,
		interval,
		1000 / interval,
		time.duration_milliseconds(cpu_total) / FRAMES,
	)
}
