// M2 (step a): DWG text through the CoreText backend, the glyph atlas and Cmd_Glyph_Run.
//
// Interactive keys:
//   1 / 2 / 3 / 4   simulate a 1x / 1.25x / 1.5x / 2x display scale (0 returns to the real scale)
//   d               toggle light / dark
//
// Flags:
//   --selftest      check that the 2:1 grid holds at every scale (half-width and full-width text
//                   measure to whole physical pixels, one full-width = two half-width), that fallback
//                   fonts supply characters DWG lacks, and that emoji land in the color atlas
package example_text

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:time"

import "myod:atlas"
import "myod:backend"
import "myod:platform"
import "myod:render"
import "myod:text"
import "myod:theme"

PAGE :: [2]f32{960, 760}
SCALES :: [4]f32{1, 1.25, 1.5, 2}

App :: struct {
	window:      ^platform.Window,
	gpu:         backend.Gpu,
	surface:     backend.Surface,
	renderer:    backend.Renderer,
	text:        text.Context,
	mode:        theme.Mode,
	mode_forced: bool,
	scale:       f32,
}

// DESIGN.md, "Typography": size / line height, weight.
Role :: struct {
	name:        string,
	size, line:  f32,
	weight:      text.Weight,
	sample:      string,
}

ROLES := [?]Role {
	{"display", 48, 56, .Bold, "myod 大弯勾"},
	{"page-title", 40, 48, .Bold, "即时模式 · Immediate mode"},
	{"title", 32, 40, .Bold, "中英混排 Mixed text"},
	{"section", 24, 32, .Bold, "严格 2:1 网格 · strict 2:1 grid"},
	{"subsection", 20, 26, .Bold, "字形图集 Glyph atlas"},
	{"lede", 18, 28, .Regular, "按状态机拆，不按界面拆。Split by state machine."},
	{"body", 16, 24, .Regular, "正文 body：The quick brown fox 跳过了懒狗 0123456789"},
	{"compact", 14, 20, .Regular, "compact 紧凑：输入框文字、列表行、次要文字"},
	{"label", 12, 20, .Bold, "LABEL 标签 · BUTTONS · TABS"},
	{"metadata", 12, 20, .Regular, "metadata 元数据 · 2026-11-09 21:00"},
}

main :: proc() {
	selftest := slice.contains(os.args, "--selftest")

	if !platform.init() {
		fmt.eprintln("failed to initialize the platform layer")
		os.exit(1)
	}
	defer platform.shutdown()

	app: App
	ok: bool
	app.window, ok = platform.open_window("myod · 02_text", i32(PAGE.x), i32(PAGE.y))
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

	if !text.init(&app.text) {
		fmt.eprintln("failed to load DWG from third_party/fonts (run from the repo root, or set MYOD_FONT_DIR)")
		os.exit(1)
	}
	defer text.destroy(&app.text)

	app.mode = .Dark if platform.is_dark_theme() else .Light

	if selftest {
		os.exit(0 if run_selftest(&app) else 1)
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
			}
		}
		redraw(&app)
		free_all(context.temp_allocator)
	}
}

redraw :: proc(data: rawptr) {
	app := (^App)(data)
	size := platform.pixel_size(app.window)
	real_scale := platform.display_scale(app.window)
	scale := app.scale if app.scale > 0 else real_scale
	t := theme.make_theme(app.mode)

	text.begin_frame(&app.text)
	list := render.make_command_list()
	draw_page(&list, &app.text, t, scale)

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
			"myod · 02_text · %v · scale %.2f%s · %d instances · %d draw calls · %.3f ms",
			app.mode,
			scale,
			" (simulated)" if app.scale > 0 else "",
			st.instances,
			st.draw_calls,
			time.duration_milliseconds(st.cpu_time),
		),
	)
}

draw_page :: proc(l: ^render.Command_List, ctx: ^text.Context, t: theme.Theme, scale: f32) {
	p := t.on_bg
	x: f32 = 40
	y: f32 = 32

	meta := text.Style{size = 12, line_height = 20, weight = .Regular, color = p.faint}
	for r in ROLES {
		text.draw(l, ctx, r.name, {x, y}, meta, scale)
		style := text.Style{size = r.size, line_height = r.line, weight = r.weight, color = p.fg}
		if r.name == "metadata" {
			style.color = p.faint
		}
		text.draw(l, ctx, r.sample, {x + 120, y}, style, scale)
		y += max(r.line, 20) + 8
	}

	y += 8
	render.line(l, {x, y, PAGE.x - 80, 1}, p.border)
	y += 16

	code := text.Style{size = 16, line_height = 24, weight = .Regular, color = p.fg}
	muted := code
	muted.color = p.muted

	// Cascadia Code's programming ligatures come from `calt`.
	text.draw(l, ctx, "ligatures", {x, y}, meta, scale)
	text.draw(l, ctx, "if (a != b && c >= d) => x === y -> z // 注释", {x + 120, y}, code, scale)
	y += 32

	// The 2:1 grid: eight half-width characters span exactly four full-width ones.
	text.draw(l, ctx, "2:1 grid", {x, y}, meta, scale)
	text.draw(l, ctx, "01234567|abcdefgh|", {x + 120, y}, code, scale)
	y += 24
	text.draw(l, ctx, "零一二三|四五六七|", {x + 120, y}, code, scale)
	y += 32

	// Characters outside DWG come from system fallback fonts; emoji from Apple Color Emoji.
	text.draw(l, ctx, "fallback", {x, y}, meta, scale)
	text.draw(l, ctx, "𠀀𪚥 (CJK Ext. B) · ελληνικά · עברית is out of scope · Ünïcödé", {x + 120, y}, muted, scale)
	y += 32
	text.draw(l, ctx, "emoji", {x, y}, meta, scale)
	text.draw(l, ctx, "🙂 👍 🎉 🇨🇳 👨‍👩‍👧 — color glyphs in the RGBA atlas", {x + 120, y}, code, scale)
}

// ---- Self-test ----

run_selftest :: proc(app: ^App) -> bool {
	fmt.println("text backend:", text.BACKEND_NAME)
	ok := true
	for scale in SCALES {
		for size in ([?]f32{12, 14, 16, 18, 20, 24, 32, 40, 48}) {
			style := text.Style{size = size, line_height = size * 1.5, weight = .Regular}
			half := text.shape(&app.text, "abcdefgh", style, scale).width
			full := text.shape(&app.text, "零一二三", style, scale).width
			phys := text.physical_size(size, scale)
			if half != full || half != math.round(half) || half != 4 * phys {
				fmt.eprintfln("FAIL %.2fx %vpx: 8 half-width = %v px, 4 full-width = %v px, expected both %v", scale, size, half, full, 4 * phys)
				ok = false
			}
		}
	}
	if ok {
		fmt.println("ok   2:1 grid: half-width and full-width text measure to whole, matching pixels at every scale and size")
	}

	if text.BACKEND_NAME != "CoreText" {
		// Fallback (Fontconfig) and color glyphs (FreeType + PNG) land in M2c for this backend.
		fmt.println("SKIP fallback and color emoji: not implemented in this backend yet")
		fmt.println("selftest:", "PASS" if ok else "FAIL")
		return ok
	}

	style := text.Style{size = 16, line_height = 24, weight = .Regular}
	primary := text.face_for(&app.text, style, 2)
	fallback := text.shape(&app.text, "𠀀", style, 2)
	if len(fallback.glyphs) == 0 || fallback.glyphs[0].face == primary {
		fmt.eprintln("FAIL fallback: 𠀀 was not supplied by a fallback font")
		ok = false
	} else {
		fmt.println("ok   fallback: 𠀀 comes from a fallback font")
	}

	list := render.make_command_list()
	text.draw(&list, &app.text, "🙂", {0, 0}, style, 2)
	run := list.commands[0].(render.Cmd_Glyph_Run)
	if len(run.quads) != 1 || run.quads[0].atlas != atlas.Kind.Color {
		fmt.eprintln("FAIL emoji: 🙂 did not land in the color atlas")
		ok = false
	} else {
		fmt.println("ok   emoji: 🙂 is a color glyph in the RGBA atlas")
	}

	fmt.println("selftest:", "PASS" if ok else "FAIL")
	return ok
}
