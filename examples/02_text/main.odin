// M2: DWG text through either text backend, the glyph atlas and Cmd_Glyph_Run; wrapping,
// uppercasing and letter spacing.
//
// Interactive keys:
//   1 / 2 / 3 / 4   simulate a 1x / 1.25x / 1.5x / 2x display scale (0 returns to the real scale)
//   d               toggle light / dark
//
// Flags:
//   --selftest      check that the 2:1 grid holds at every scale (half-width and full-width text
//                   measure to whole physical pixels, one full-width = two half-width); wrapping of
//                   English and Chinese text; uppercasing and letter spacing; and (CoreText) that
//                   fallback fonts supply characters DWG lacks and emoji land in the color atlas
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

PAGE :: [2]f32{1040, 1180}

// A variable font that ships with macOS, used to demonstrate variation axes.
SYSTEM_VARIABLE_FONT :: "/System/Library/Fonts/SFNS.ttf"
SCALES :: [4]f32{1, 1.25, 1.5, 2}

App :: struct {
	window:      ^platform.Window,
	gpu:         backend.Gpu,
	surface:     backend.Surface,
	renderer:    backend.Renderer,
	variable:    text.Font_Ref, // 0 if the system variable font is unavailable
	text:        text.Context, // declared last: inside the struct, `text` now names this field
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
	uppercase:   bool,
	tracking:    f32,
}

ROLES := [?]Role {
	{"display", 48, 56, .Bold, "myod 大弯勾", false, 0},
	{"page-title", 40, 48, .Bold, "即时模式 · Immediate mode", false, 0},
	{"title", 32, 40, .Bold, "中英混排 Mixed text", false, 0},
	{"section", 24, 32, .Bold, "严格 2:1 网格 · strict 2:1 grid", false, 0},
	{"subsection", 20, 26, .Bold, "字形图集 Glyph atlas", false, 0},
	{"lede", 18, 28, .Regular, "按状态机拆，不按界面拆。Split by state machine.", false, 0},
	{"body", 16, 24, .Regular, "正文 body：The quick brown fox 跳过了懒狗 0123456789", false, 0},
	{"compact", 14, 20, .Regular, "compact 紧凑：输入框文字、列表行、次要文字", false, 0},
	{"label", 12, 20, .Bold, "label 标签 · buttons · tabs", true, 0.12},
	{"metadata", 12, 20, .Regular, "metadata 元数据 · 2026-11-09 21:00", false, 0},
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
	app.variable, _ = text.load_font(&app.text, SYSTEM_VARIABLE_FONT)

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
	draw_page(&list, &app.text, t, scale, f32(size.x) / scale, app.variable)

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

PARAGRAPH :: "Wrapping follows UAX #14: English breaks between words, while 中文可以在任意两个汉字之间断行，标点遵守避头尾规则。Resize the window and this paragraph reflows — 拖动窗口边缘，这一段会实时重新排版。"

draw_page :: proc(l: ^render.Command_List, ctx: ^text.Context, t: theme.Theme, scale: f32, width: f32, variable: text.Font_Ref) {
	p := t.on_bg
	x: f32 = 40
	y: f32 = 32

	meta := text.Style{size = 12, line_height = 20, weight = .Regular, color = p.faint}
	for r in ROLES {
		text.draw(l, ctx, r.name, {x, y}, meta, scale)
		style := text.Style{size = r.size, line_height = r.line, weight = r.weight, color = p.fg, uppercase = r.uppercase, letter_spacing = r.tracking}
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
	y += 40

	// A paragraph that wraps with the window width.
	text.draw(l, ctx, "wrapping", {x, y}, meta, scale)
	body := text.Style{size = 16, line_height = 24, weight = .Regular, color = p.fg}
	max_w := max(width - x - 120 - 40, 80)
	text.draw_wrapped(l, ctx, PARAGRAPH, {x + 120, y}, body, max_w, scale)
	size := text.measure_wrapped(ctx, PARAGRAPH, body, max_w, scale)
	render.line(l, {x + 120 + max_w, y, 1, size.y}, p.border) // the wrap width
	y += size.y + 24

	// OpenType features on DWG (Cascadia Code supplies calt, ss19, frac, …).
	sample := "0O != => -> 1/2 3/4"
	for f in ([?]string{"", "-calt", "ss19", "frac"}) {
		text.draw(l, ctx, f if f != "" else "default", {x, y}, meta, scale)
		st := code
		st.features = f
		text.draw(l, ctx, sample, {x + 120, y}, st, scale)
		y += 28
	}

	// Variation axes on a system variable font.
	if variable != 0 {
		y += 8
		for w in ([?]int{100, 300, 500, 700, 900}) {
			text.draw(l, ctx, fmt.tprintf("wght=%d", w), {x, y}, meta, scale)
			st := text.Style{size = 20, line_height = 28, color = p.fg, font = variable, variations = fmt.tprintf("wght=%d", w)}
			text.draw(l, ctx, "Variable weight · Hamburgefonstiv", {x + 120, y}, st, scale)
			y += 28
		}
		for w in ([?]int{60, 100, 140}) {
			text.draw(l, ctx, fmt.tprintf("wdth=%d", w), {x, y}, meta, scale)
			st := text.Style{size = 20, line_height = 28, color = p.fg, font = variable, variations = fmt.tprintf("wdth=%d wght=600", w)}
			text.draw(l, ctx, "Variable width · Hamburgefonstiv", {x + 120, y}, st, scale)
			y += 28
		}
	}
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

	ok = check_wrapping_and_spacing(app) && ok
	ok = check_features_and_variations(app) && ok

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

check_wrapping_and_spacing :: proc(app: ^App) -> bool {
	ok := true
	ctx := &app.text
	for scale in SCALES {
		body := text.Style{size = 16, line_height = 24, weight = .Regular}
		phys := text.physical_size(16, scale)

		// English: every line fits, and the lines rejoin into the original text.
		english := "The quick brown fox jumps over the lazy dog again and again until the line has to wrap."
		max_w := f32(200)
		lines := text.wrap(ctx, english, body, max_w, scale)
		rejoined := ""
		for l in lines {
			if l.width > max_w * scale {
				fmt.eprintfln("FAIL %.2fx wrap: line %q is %v px, wider than %v", scale, english[l.start:l.end], l.width, max_w * scale)
				ok = false
			}
			rejoined = fmt.tprintf("%s%s%s", rejoined, " " if rejoined != "" else "", english[l.start:l.end])
		}
		if rejoined != english || len(lines) < 3 {
			fmt.eprintfln("FAIL %.2fx wrap: %d lines rejoin to %q", scale, len(lines), rejoined)
			ok = false
		}

		// Chinese: any two characters may break, so 20 characters in 7.5 cells give lines of 7, 7, 6.
		chinese := "零一二三四五六七八九零一二三四五六七八九"
		cjk_lines := text.wrap(ctx, chinese, body, 7.5 * phys / scale, scale)
		counts := make([dynamic]int, context.temp_allocator)
		for l in cjk_lines {
			append(&counts, (l.end - l.start) / 3)
		}
		if !slice.equal(counts[:], []int{7, 7, 6}) {
			fmt.eprintfln("FAIL %.2fx wrap: Chinese lines have %v characters, expected [7, 7, 6]", scale, counts[:])
			ok = false
		}

		// Uppercasing changes the glyphs, not the clusters; letter spacing skips Chinese.
		label := text.Style{size = 12, line_height = 20, weight = .Bold}
		upper := label
		upper.uppercase = true
		if text.measure(ctx, "label", upper, scale) != text.measure(ctx, "LABEL", label, scale) {
			fmt.eprintfln("FAIL %.2fx uppercase: \"label\" uppercased measures differently from \"LABEL\"", scale)
			ok = false
		}
		tracked := label
		tracked.letter_spacing = 0.12
		step := math.round(0.12 * text.physical_size(12, scale))
		plain_w := text.shape(ctx, "ABCD", label, scale).width
		tracked_w := text.shape(ctx, "ABCD", tracked, scale).width
		if tracked_w != plain_w + 3 * step {
			fmt.eprintfln("FAIL %.2fx letter spacing: ABCD is %v px, expected %v", scale, tracked_w, plain_w + 3 * step)
			ok = false
		}
		if text.shape(ctx, "中文", tracked, scale).width != text.shape(ctx, "中文", label, scale).width {
			fmt.eprintfln("FAIL %.2fx letter spacing: Chinese characters got letter spacing", scale)
			ok = false
		}
	}
	if ok {
		fmt.println("ok   wrapping (English and Chinese), uppercasing and letter spacing at every scale")
	}
	return ok
}

check_features_and_variations :: proc(app: ^App) -> bool {
	ok := true
	ctx := &app.text
	base := text.Style{size = 16, line_height = 24, weight = .Regular}

	glyph_ids :: proc(ctx: ^text.Context, s: string, st: text.Style) -> []u32 {
		ids := make([dynamic]u32, context.temp_allocator)
		for g in text.shape(ctx, s, st, 2).glyphs {
			append(&ids, g.glyph)
		}
		return ids[:]
	}
	Case :: struct {
		features, sample, what: string,
	}
	for c in ([?]Case{{"-calt", "!= =>", "turning off calt changes the ligatures"}, {"ss19", "0", "ss19 changes the zero"}, {"frac", "1/2", "frac changes the fraction"}}) {
		st := base
		st.features = c.features
		if slice.equal(glyph_ids(ctx, c.sample, base), glyph_ids(ctx, c.sample, st)) {
			fmt.eprintfln("FAIL features: %s (%q shapes the same with %q)", c.what, c.sample, c.features)
			ok = false
		}
	}
	if ok {
		fmt.println("ok   features: -calt, ss19 and frac change the glyphs")
	}

	if app.variable == 0 {
		fmt.println("SKIP variations: the system variable font is not available")
		return ok
	}
	light := text.Style{size = 20, line_height = 28, font = app.variable, variations = "wght=100"}
	heavy := light
	heavy.variations = "wght=900"
	lw := text.shape(ctx, "Hamburgefonstiv", light, 2).width
	hw := text.shape(ctx, "Hamburgefonstiv", heavy, 2).width
	if !(hw > lw) {
		fmt.eprintfln("FAIL variations: wght=900 is %v px wide, wght=100 is %v px; the heavier weight should be wider", hw, lw)
		ok = false
	} else {
		fmt.printfln("ok   variations: wght=100 → %v px, wght=900 → %v px", lw, hw)
	}
	return ok
}
