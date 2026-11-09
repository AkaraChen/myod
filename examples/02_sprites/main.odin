// M2: sprite glyphs — box drawing, blocks, Braille and Powerline drawn at the exact cell size.
//
// Flags:
//   --selftest      at every scale, a grid of ┼ must have unbroken horizontal lines across cells and
//                   unbroken vertical lines across line boxes, in both themes
package example_sprites

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"

import "myod:devtools/demo"
import "myod:render"
import "myod:text"
import "myod:theme"

PAGE :: [2]f32{1000, 760}

LINES := [?]string {
	"┌──────┬───────┐  ╔══════╦═══════╗  ┏━━━━━━┳━━━━━━━┓  ╭──────╮",
	"│ name │ value │  ║ name ║ value ║  ┃ name ┃ value ┃  │ 圆角 │",
	"├──────┼───────┤  ╠══════╬═══════╣  ┣━━━━━━╋━━━━━━━┫  ╰──────╯",
	"│ 宽度 │ 2:1   │  ║ 宽度 ║ 2:1   ║  ┃ 宽度 ┃ 2:1   ┃",
	"└──────┴───────┘  ╚══════╩═══════╝  ┗━━━━━━┻━━━━━━━┛",
	"",
	"╒═╤═╕ ╓─╥─╖ ┍━┯━┑ ┎─┰─┒ ╭─┬─╮   ┄┄┄┄ ┅┅┅┅ ┈┈┈┈ ┉┉┉┉ ╌╌╌╌ ╍╍╍╍",
	"╞═╪═╡ ╟─╫─╢ ┝━┿━┥ ┠─╂─┨ ├─┼─┤   ┆┇┊┋╎╏ ╱╲╳╱╲╳",
	"╘═╧═╛ ╙─╨─╜ ┕━┷━┙ ┖─┸─┚ ╰─┴─╯   ╴╵╶╷ ╸╹╺╻ ╼╽╾╿",
	"",
	"▁▂▃▄▅▆▇█ ▏▎▍▌▋▊▉█ ░▒▓█ ▖▗▘▙▚▛▜▝▞▟ ▀▄▌▐▔▕",
	"⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ ⣿⣾⣽⣻⢿⡿⣟⣯⣷ ⣀⣠⣤⣴⣶⣾⣿ ⢀⣀⣠⣤⣦⣶⣾⣿",
	"\ue0b0 \ue0b1 \ue0b2 \ue0b3 \ue0b4 \ue0b5 \ue0b6 \ue0b7", // Powerline separators
}

draw_page :: proc(l: ^render.Command_List, ctx: ^text.Context, t: theme.Theme, scale: f32, view: [2]f32, data: rawptr) {
	p := t.on_bg
	x: f32 = 40
	y: f32 = 32
	title := text.Style{size = 24, line_height = 32, weight = .Bold, color = p.fg}
	text.draw(l, ctx, "Sprite glyphs", {x, y}, title, scale)
	y += 48

	code := text.Style{size = 16, line_height = 20, weight = .Regular, color = p.fg}
	for line in LINES {
		text.draw(l, ctx, line, {x, y}, code, scale)
		y += code.line_height
	}
	y += 20

	// A Powerline-style status bar: segment backgrounds, with each separator drawn in the color of
	// the segment to its left.
	Segment :: struct {
		label:  string,
		bg, fg: theme.Color,
	}
	segments := [?]Segment{{" NORMAL ", p.fg, p.bg}, {" \ue0a0 main ", p.muted, p.bg}, {" myod/text ", p.border_strong, p.fg}}
	bar := code
	sx := x
	for s, i in segments {
		bar.color = s.fg
		w := text.measure(ctx, s.label, bar, scale).x
		render.fill(l, {sx, y, w, bar.line_height}, s.bg)
		text.draw(l, ctx, s.label, {sx, y}, bar, scale)
		sx += w
		sep := bar
		sep.color = s.bg
		next_bg := segments[i + 1].bg if i + 1 < len(segments) else p.bg
		sw := text.measure(ctx, "\ue0b0", sep, scale).x
		render.fill(l, {sx, y, sw, bar.line_height}, next_bg)
		text.draw(l, ctx, "\ue0b0", {sx, y}, sep, scale)
		sx += sw
	}
	y += 40

	// The self-test grid.
	for i in 0 ..< GRID_ROWS {
		text.draw(l, ctx, GRID_LINE, {x, y + f32(i) * code.line_height}, code, scale)
	}
}

GRID_LINE :: "┼┼┼┼┼┼┼┼┼┼┼┼"
GRID_CELLS :: 12
GRID_ROWS :: 4

main :: proc() {
	app: demo.App
	demo.open(&app, "myod · 02_sprites", PAGE, draw_page)
	defer demo.close(&app)
	if slice.contains(os.args, "--selftest") {
		os.exit(0 if selftest(&app) else 1)
	}
	if demo.dump_from_args(&app, PAGE) {
		return
	}
	demo.run(&app)
}

selftest :: proc(app: ^demo.App) -> bool {
	ok := true
	code := text.Style{size = 16, line_height = 20, weight = .Regular}
	for mode in theme.Mode {
		fg := theme.make_theme(mode).on_bg.fg
		for scale in demo.SCALES {
			cap, captured := demo.capture(app, mode, scale, PAGE)
			if !captured {
				fmt.eprintfln("FAIL %v %.2fx: capture failed", mode, scale)
				ok = false
				continue
			}
			// Where the grid is: the same layout as draw_page.
			grid_y: f32 = 32 + 48 + f32(len(LINES)) * code.line_height + 20 + 40
			x0 := u32(math.round(40 * scale))
			cell := u32(math.round(text.shape(&app.text, "┼", code, scale).width))
			x1 := x0 + cell * u32(GRID_CELLS)
			top := u32(math.round(grid_y * scale))
			bottom := u32(math.round((grid_y + GRID_ROWS * code.line_height) * scale))
			t := u32(max(1, math.round(text.physical_size(16, scale) / 16)))

			// Vertical strokes run through every line box without a gap.
			for c in 0 ..< u32(GRID_CELLS) {
				x := x0 + c * cell + (cell - t) / 2
				for y in top ..< bottom {
					if demo.pixel(cap, x, y) != fg {
						fmt.eprintfln("FAIL %v %.2fx: vertical line of column %d is broken at y = %d", mode, scale, c, y)
						ok = false
						break
					}
				}
			}
			// Horizontal strokes run across every cell without a gap.
			for row in 0 ..< u32(GRID_ROWS) {
				line_top := u32(math.round((grid_y + f32(row) * code.line_height) * scale))
				line_bottom := u32(math.round((grid_y + f32(row + 1) * code.line_height) * scale))
				y := line_top + (line_bottom - line_top - t) / 2
				for x in x0 ..< x1 {
					if demo.pixel(cap, x, y) != fg {
						fmt.eprintfln("FAIL %v %.2fx: horizontal line of row %d is broken at x = %d", mode, scale, row, x)
						ok = false
						break
					}
				}
			}
			free_all(context.temp_allocator)
		}
	}
	if ok {
		fmt.println("ok   sprites: ┼ grid lines are unbroken across cells and line boxes at every scale, both themes")
	}
	fmt.println("selftest:", "PASS" if ok else "FAIL")
	return ok
}
