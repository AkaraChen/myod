// M2: Phosphor icons — every weight at the common sizes, two-color duotone, and icons inline with text.
//
// Flags:
//   --selftest      at every scale, every icon in the matrix draws inside its box, duotone shows both
//                   colors, and inline icons sit inside their line box, in both themes
//   --dump <prefix> write captures for tools/rgba2png.py
package example_icons

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"

import "myod:backend"
import "myod:devtools/demo"
import "myod:icons"
import ph "myod:icons/phosphor"
import "myod:render"
import "myod:text"
import "myod:theme"

PAGE :: [2]f32{1120, 600}

SIZES :: [4]f32{12, 16, 20, 24}
ICONS := [?]icons.Icon{ph.GEAR, ph.HOUSE, ph.MAGNIFYING_GLASS, ph.HEART, ph.TRASH, ph.CHECK, ph.CARET_DOWN, ph.DOWNLOAD_SIMPLE}
DUOTONE := [?]icons.Icon{ph.GEAR, ph.FOLDER, ph.BELL, ph.USER, ph.STAR, ph.WARNING, ph.INFO, ph.HEART}

MARGIN :: 40
LABEL_W :: 90
GAP :: 8
GROUP_GAP :: 28
MATRIX_TOP :: 112
ROW_H :: 36
DUOTONE_SIZE :: 32
DUOTONE_TOP :: MATRIX_TOP + 6 * ROW_H + 40
INLINE_TOP :: DUOTONE_TOP + DUOTONE_SIZE + 64

// Top-left of one icon in the weight × size matrix, in logical pixels.
matrix_pos :: proc(weight: icons.Weight, size_index, icon_index: int) -> [2]f32 {
	sizes := SIZES
	x: f32 = MARGIN + LABEL_W
	for s in 0 ..< size_index {
		x += f32(len(ICONS)) * (sizes[s] + GAP) + GROUP_GAP
	}
	x += f32(icon_index) * (sizes[size_index] + GAP)
	y := f32(MATRIX_TOP + int(weight) * ROW_H) + (ROW_H - sizes[size_index]) / 2
	return {x, y}
}

duotone_pos :: proc(i: int) -> [2]f32 {
	return {MARGIN + LABEL_W + f32(i) * (DUOTONE_SIZE + 16), DUOTONE_TOP}
}

inline_style :: proc(p: theme.Palette) -> text.Style {
	return {size = 16, line_height = 24, weight = .Regular, color = p.fg}
}

INLINE_LINES := [?][]text.Item {
	{text.Inline_Icon{ph.FOLDER, .Bold}, "myod/text", text.Inline_Icon{ph.CARET_DOWN, .Bold}, "·", text.Inline_Icon{ph.GIT_BRANCH, .Bold}, "main"},
	{text.Inline_Icon{ph.DOWNLOAD_SIMPLE, .Bold}, "下载完成", text.Inline_Icon{ph.CHECK, .Fill}, "共 3 个文件"},
	{"Settings", text.Inline_Icon{ph.GEAR, .Fill}},
}

draw_page :: proc(l: ^render.Command_List, ctx: ^text.Context, t: theme.Theme, scale: f32, view: [2]f32, data: rawptr) {
	p := t.on_bg
	title := text.Style{size = 24, line_height = 32, weight = .Bold, color = p.fg}
	label := text.Style{size = 12, line_height = 16, weight = .Regular, color = p.muted}
	text.draw(l, ctx, "Phosphor icons", {MARGIN, 32}, title, scale)

	sizes := SIZES
	for s in 0 ..< len(sizes) {
		pos := matrix_pos(.Thin, s, 0)
		text.draw(l, ctx, fmt.tprintf("%vpx", sizes[s]), {pos.x, MATRIX_TOP - 24}, label, scale)
	}
	for weight in icons.Weight {
		row_y := f32(MATRIX_TOP + int(weight) * ROW_H)
		text.draw(l, ctx, fmt.tprint(weight), {MARGIN, row_y + (ROW_H - label.line_height) / 2}, label, scale)
		for s in 0 ..< len(sizes) {
			for icon, i in ICONS {
				text.draw_icon(l, ctx, icon, weight, matrix_pos(weight, s, i), sizes[s], p.fg, scale)
			}
		}
	}

	text.draw(l, ctx, "Duotone", {MARGIN, DUOTONE_TOP + (DUOTONE_SIZE - label.line_height) / 2}, label, scale)
	for icon, i in DUOTONE {
		text.draw_icon(l, ctx, icon, .Duotone, duotone_pos(i), DUOTONE_SIZE, p.fg, scale, secondary = p.info)
	}

	text.draw(l, ctx, "Inline", {MARGIN, INLINE_TOP + 4}, label, scale)
	style := inline_style(p)
	for line, i in INLINE_LINES {
		y := f32(INLINE_TOP + i * 32)
		render.bordered(l, {MARGIN + LABEL_W, y, text.measure_items(ctx, line, style, scale).x, style.line_height}, p.border, 1) // the line box
		text.draw_items(l, ctx, line, {MARGIN + LABEL_W, y}, style, scale)
	}
}

main :: proc() {
	app: demo.App
	demo.open(&app, "myod · 02_icons", PAGE, draw_page)
	defer demo.close(&app)
	if slice.contains(os.args, "--selftest") {
		os.exit(0 if selftest(&app) else 1)
	}
	if demo.dump_from_args(&app, PAGE) {
		return
	}
	demo.run(&app)
}

// Counts pixels in the physical box of a logical rect that are not `bg`, and that equal `want`.
@(private)
scan :: proc(cap: backend.Capture, rect: [4]f32, scale: f32, bg, want: theme.Color) -> (ink, exact: int) {
	x0 := u32(math.round(rect.x * scale))
	y0 := u32(math.round(rect.y * scale))
	x1 := min(cap.width, u32(math.round((rect.x + rect.z) * scale)))
	y1 := min(cap.height, u32(math.round((rect.y + rect.w) * scale)))
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			c := demo.pixel(cap, x, y)
			if c != bg {
				ink += 1
			}
			if c == want {
				exact += 1
			}
		}
	}
	return
}

selftest :: proc(app: ^demo.App) -> bool {
	ok := true
	sizes := SIZES
	for mode in theme.Mode {
		p := theme.make_theme(mode).on_bg
		for scale in demo.SCALES {
			cap, captured := demo.capture(app, mode, scale, PAGE)
			if !captured {
				fmt.eprintfln("FAIL %v %.2fx: capture failed", mode, scale)
				ok = false
				continue
			}
			// Every icon of the matrix draws inside its own box, and nothing spills into the gap
			// to its right.
			for weight in icons.Weight {
				for s in 0 ..< len(sizes) {
					for icon, i in ICONS {
						pos := matrix_pos(weight, s, i)
						ink, _ := scan(cap, {pos.x, pos.y, sizes[s], sizes[s]}, scale, p.bg, p.fg)
						if ink == 0 {
							fmt.eprintfln("FAIL %v %.2fx: %s %v %vpx drew nothing", mode, scale, icon.name, weight, sizes[s])
							ok = false
						}
						spill, _ := scan(cap, {pos.x + sizes[s] + 1, pos.y, GAP - 2, sizes[s]}, scale, p.bg, p.fg)
						if spill > 0 {
							fmt.eprintfln("FAIL %v %.2fx: %s %v %vpx spills out of its box", mode, scale, icon.name, weight, sizes[s])
							ok = false
						}
					}
				}
			}
			// Duotone: both layers, each in its own color.
			for icon, i in DUOTONE {
				pos := duotone_pos(i)
				box := [4]f32{pos.x, pos.y, DUOTONE_SIZE, DUOTONE_SIZE}
				_, front := scan(cap, box, scale, p.bg, p.fg)
				_, back := scan(cap, box, scale, p.bg, p.info)
				if front == 0 || back == 0 {
					fmt.eprintfln("FAIL %v %.2fx: duotone %s has %d foreground and %d secondary pixels", mode, scale, icon.name, front, back)
					ok = false
				}
			}
			// Inline icons stay inside the line box (rows above and below the box are clean).
			style := inline_style(p)
			for line, i in INLINE_LINES {
				y := f32(INLINE_TOP + i * 32)
				w := text.measure_items(&app.text, line, style, scale).x
				ink, _ := scan(cap, {MARGIN + LABEL_W, y + 1, w, style.line_height - 2}, scale, p.bg, p.fg)
				above, _ := scan(cap, {MARGIN + LABEL_W, y - 4, w, 3}, scale, p.bg, p.fg)
				below, _ := scan(cap, {MARGIN + LABEL_W, y + style.line_height + 1, w, 3}, scale, p.bg, p.fg)
				if ink == 0 || above > 0 || below > 0 {
					fmt.eprintfln("FAIL %v %.2fx: inline line %d: %d ink, %d above, %d below the line box", mode, scale, i, ink, above, below)
					ok = false
				}
			}
			free_all(context.temp_allocator)
		}
	}
	if ok {
		fmt.println("ok   icons: 6 weights × 4 sizes stay in their boxes, duotone has both colors, inline icons fit the line, at every scale, both themes")
	}
	fmt.println("selftest:", "PASS" if ok else "FAIL")
	return ok
}
