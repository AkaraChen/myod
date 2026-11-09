// M3: a card feed on a CSS grid, `repeat(auto-fill, minmax(240px, 1fr))`, with flex layout and
// wrapping text inside each card. Each row is as tall as its tallest card (cards stretch to it), and
// the number of cards per row follows the window width.
//
// Flags:
//   --selftest      at several widths and every scale: cards per row, equal card widths, equal
//                   heights within a row set by the tallest card, text inside its card
//   --dump <prefix> write captures for tools/rgba2png.py
package example_feed

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"

import "myod:core"
import "myod:devtools/demo"
import ph "myod:icons/phosphor"
import "myod:render"
import "myod:text"
import "myod:theme"
import "myod:ui"

PAGE :: [2]f32{1200, 800}

PADDING :: 24
GAP :: 16
MIN_CARD :: 240

Post :: struct {
	title, body: string,
	tags:        []string,
	author:      string,
	icon:        ui.Icon,
}

POSTS := [?]Post {
	{"Taffy over a flat array", "Layout runs directly on the frame's node array; slots carry the cache across frames.", {"layout", "rust"}, "akrc", ph.TREE_STRUCTURE},
	{"2:1 grid", "半角 500，全角 1000：中英文在表格里严格对齐。", {"type"}, "dwg", ph.TEXT_AA},
	{"Ghost passes", "When layout disagrees with what view read, the pass reruns before anything is shown. At most three passes per frame; in practice almost always one.", {"frame", "core", "ghost"}, "akrc", ph.GHOST},
	{"Culling", "Containers outside the visible area are not opened at all.", {"perf"}, "akrc", ph.EYE_SLASH},
	{"Subtree reuse", "A Merkle hash per container: unchanged subtrees come straight from Taffy's cache, and Taffy never descends into them.", {"perf", "layout"}, "akrc", ph.RECYCLE},
	{"Hairlines", "Dividers keep their thickness in physical pixels wherever they land.", {"render"}, "akrc", ph.LINE_SEGMENT},
	{"字体回退", "DWG 之外的字符走系统回退：CoreText 自带，FreeType 用字素簇切分后逐个查找。", {"text", "fallback"}, "akrc", ph.TRANSLATE},
	{"Atlas paging", "Least recently used pages are evicted as a whole; a frame over budget grows the atlas instead.", {"atlas"}, "akrc", ph.SQUARES_FOUR},
	{"Phosphor", "1,248 icons in six weights; only the ones you use end up in the binary.", {"icons"}, "phosphor", ph.PALETTE},
	{"Sprites", "Box drawing, blocks, Braille and Powerline drawn per cell, joined without gaps.", {"text", "terminal"}, "akrc", ph.TERMINAL_WINDOW},
	{"Nix", "Every prebuilt library is rebuilt bit for bit by `just verify`.", {"build"}, "akrc", ph.PACKAGE},
	{"Short", "One line.", {}, "akrc", ph.DOT},
}

Example :: struct {
	core:  core.Context,
	cards: [len(POSTS)]struct {
		card, body, footer: ui.Id,
	},
	grid:  ui.Id,
}

view :: proc(data: rawptr) {
	ex := (^Example)(data)
	if ui.column({width = ui.grow(), padding = PADDING, gap = 16}) {
		ui.text("动态 Feed", .Page_Title)
		ui.text("repeat(auto-fill, minmax(240px, 1fr)) — resize the window to change the number of columns.", .Compact, color = .Muted)
		columns := []ui.Track{ui.repeat_fill(ui.minmax(ui.px(MIN_CARD), ui.fr(1)))}
		if ui.grid({columns = columns, gap = GAP, width = ui.grow()}) {
			ex.grid = ui.container_id()
			for post, i in POSTS {
				card(ex, post, i)
			}
		}
	}
}

card :: proc(ex: ^Example, post: Post, i: int) {
	if ui.column({id = i, width = ui.grow(), height = ui.grow(), padding = 16, gap = 8, border = .Default}) {
		ex.cards[i].card = ui.container_id()
		if ui.row({gap = 8, align_y = .Center, width = ui.grow()}) {
			ui.icon(post.icon, 20)
			ui.text(post.title, .Subsection, width = ui.grow())
		}
		ex.cards[i].body = ui.text(post.body, .Compact, color = .Muted).id
		if len(post.tags) > 0 {
			if ui.row({gap = 6, wrap = true}) {
				for tag in post.tags {
					if ui.row({padding = {6, 0, 6, 0}, border = .Strong}) {
						ui.text(tag, .Label, color = .Muted, wrap = false)
					}
				}
			}
		}
		ui.spacer()
		if ui.row({gap = 6, align_y = .Center, width = ui.grow()}) {
			ex.cards[i].footer = ui.container_id()
			ui.icon(ph.USER, 12, color = .Faint)
			ui.text(post.author, .Metadata, color = .Faint)
			ui.spacer()
			ui.text(fmt.tprintf("#%d", i + 1), .Metadata, color = .Faint)
		}
	}
}

draw_page :: proc(l: ^render.Command_List, ctx: ^text.Context, t: theme.Theme, scale: f32, view_size: [2]f32, data: rawptr) {
	ex := (^Example)(data)
	core.frame(&ex.core, view, ex, view_size, scale, t, l)
}

main :: proc() {
	app: demo.App
	ex := new(Example)
	demo.open(&app, "myod · 03_feed", PAGE, draw_page, ex)
	defer demo.close(&app)
	if !core.init(&ex.core, &app.text) {
		os.exit(1)
	}
	defer core.destroy(&ex.core)
	app.ui = &ex.core
	if slice.contains(os.args, "--selftest") {
		os.exit(0 if selftest(&app, ex) else 1)
	}
	if demo.dump_from_args(&app, PAGE) {
		return
	}
	demo.run(&app)
}

selftest :: proc(app: ^demo.App, ex: ^Example) -> bool {
	ok := true
	rect :: proc(ex: ^Example, id: ui.Id) -> core.Rect {
		r, _ := core.last_rect(&ex.core, id)
		return r
	}
	for width in ([?]f32{560, 820, 1200, 1700, 900}) {
		for scale in demo.SCALES {
			size := [2]f32{width, 2400} // tall enough that every card is visible
			_, captured := demo.capture(app, .Light, scale, size)
			if !captured {
				fmt.eprintfln("FAIL %.2fx %v: capture failed", scale, width)
				ok = false
				continue
			}
			at := fmt.tprintf("%.2fx width %v (passes %d, culled %d)", scale, width, ex.core.stats.passes, ex.core.stats.culled)
			tol := 1 / scale + 0.001
			inner := width - 2 * PADDING
			want_cols := max(1, int(math.floor((inner + GAP) / (MIN_CARD + GAP))))
			want_w := (inner - f32(want_cols - 1) * GAP) / f32(want_cols)

			// Group cards into rows by their top edge.
			cols := 0
			first_y := rect(ex, ex.cards[0].card).y
			for c in ex.cards {
				if rect(ex, c.card).y == first_y {
					cols += 1
				}
			}
			if cols != min(want_cols, len(POSTS)) {
				fmt.eprintfln("FAIL %s: %d cards in the first row, expected %d", at, cols, want_cols)
				ok = false
			}
			for c, i in ex.cards {
				r := rect(ex, c.card)
				if abs(r.w - want_w) > tol {
					fmt.eprintfln("FAIL %s: card %d is %v wide, expected %v", at, i, r.w, want_w)
					ok = false
				}
				b := rect(ex, c.body)
				if b.x < r.x || b.x + b.w > r.x + r.w + tol {
					fmt.eprintfln("FAIL %s: the text of card %d (%v) sticks out of the card (%v)", at, i, b, r)
					ok = false
				}
			}
			// Rows: equal heights, set by the tallest card (whose footer ends at its padding).
			for start := 0; start < len(POSTS); start += want_cols {
				row := ex.cards[start:min(start + want_cols, len(POSTS))]
				h := rect(ex, row[0].card).h
				tight := false
				for c, j in row {
					r := rect(ex, c.card)
					if abs(r.h - h) > tol {
						fmt.eprintfln("FAIL %s: card %d is %v tall, its row is %v", at, start + j, r.h, h)
						ok = false
					}
					f := rect(ex, c.footer)
					if abs(f.y + f.h + 16 + 1 - (r.y + r.h)) <= tol {
						tight = true
					}
				}
				if !tight {
					fmt.eprintfln("FAIL %s: no card in the row starting at card %d fills it exactly", at, start)
					ok = false
				}
			}
			free_all(context.temp_allocator)
		}
	}
	if ok {
		fmt.println("ok   feed: auto-fill columns, equal widths, rows as tall as their tallest card, text inside, at 5 widths × 4 scales")
	}
	fmt.println("selftest:", "PASS" if ok else "FAIL")
	return ok
}
