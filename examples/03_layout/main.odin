// M3: an app shell — sidebar, main area and info panel separated by 1px dividers — declared with
// ui/ containers and laid out by Taffy. Resize the window: the main area takes the free width and
// its text rewraps; the side panels keep their widths.
//
// Flags:
//   --selftest      at several window sizes and every scale: panel and divider rects, dividers a
//                   hairline of the border color running the full height, both themes
//   --dump <prefix> write captures for tools/rgba2png.py
package example_layout

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

PAGE :: [2]f32{1200, 760}

SIDEBAR_W :: 240
INFO_W :: 280

Example :: struct {
	core: core.Context,
	ids: struct {
		shell, sidebar, main, info: ui.Id,
		dividers:                   [2]ui.Id,
	},
}

NAV := [?]struct {
	icon:  ui.Icon,
	label: string,
}{{ph.HOUSE, "概览 Overview"}, {ph.FOLDER, "项目 Projects"}, {ph.GIT_BRANCH, "分支 Branches"}, {ph.BELL, "通知 Notifications"}, {ph.GEAR, "设置 Settings"}}

PARAGRAPH :: "The shell is a row: a fixed 240px sidebar, a growing main area and a fixed 280px info panel, separated by dividers. Taffy lays it out; text is measured by myod's text system through a callback, so this paragraph wraps to whatever width the main area gets. 中文和英文混排时同样按 UAX #14 断行，窗口变窄时自动重新排版。"

view :: proc(data: rawptr) {
	ex := (^Example)(data)
	if ui.row({width = ui.grow(), height = ui.grow()}) {
		ex.ids.shell = ui.container_id()
		if ui.column({id = "sidebar", width = ui.fixed(SIDEBAR_W), padding = 16, gap = 4}) {
			ex.ids.sidebar = ui.container_id()
			ui.text("myod", .Section)
			ui.text("WORKSPACE", .Label, color = .Muted)
			for item, i in NAV {
				if ui.row({id = i, gap = 8, align_y = .Center, padding = {8, 4, 8, 4}, width = ui.grow(), fill = .Overlay if i == 0 else .None}) {
					ui.icon(item.icon, 16, .Fill if i == 0 else .Bold, color = .Fg if i == 0 else .Muted)
					ui.text(item.label, .Compact, color = .Fg if i == 0 else .Muted)
				}
			}
		}
		ui.divider()
		ex.ids.dividers[0] = last_child_id()
		if ui.column({id = "main", width = ui.grow(), padding = 24, gap = 16}) {
			ex.ids.main = ui.container_id()
			ui.text("布局 Layout", .Page_Title)
			ui.text(PARAGRAPH, .Body)
			if ui.row({gap = 8, wrap = true}) {
				for tag in ([?]string{"flex", "grid", "Taffy", "2:1 grid", "UAX #14", "subtree reuse", "culling"}) {
					if ui.row({padding = {6, 0, 6, 0}, border = .Strong}) {
						ui.text(tag, .Label, color = .Muted, wrap = false)
					}
				}
			}
			ui.divider()
			ui.text("Metadata 元数据 · hairlines are equally thick wherever they land, at every scale", .Metadata, color = .Faint)
		}
		ui.divider()
		ex.ids.dividers[1] = last_child_id()
		if ui.column({id = "info", width = ui.fixed(INFO_W), padding = 16, gap = 12}) {
			ex.ids.info = ui.container_id()
			ui.text("DETAILS", .Label, color = .Muted)
			for kv in ([?][2]string{{"Status", "Running"}, {"Branch", "main"}, {"Nodes", "Taffy 0.15"}}) {
				if ui.row({width = ui.grow()}) {
					ui.text(kv[0], .Compact, color = .Muted)
					ui.spacer()
					ui.text(kv[1], .Compact)
				}
			}
			ui.divider()
			ui.text("右侧面板固定 280px；中间区域占据剩余宽度。", .Compact, color = .Muted)
		}
	}
}

// The ID of the node just declared in the current container (for the self-test).
last_child_id :: proc() -> ui.Id {
	ctx := core.current()
	t := &ctx.trees[ctx.cur]
	parent := ctx.stack[len(ctx.stack) - 1]
	return t.nodes[t.nodes[parent].last_child].id
}

draw_page :: proc(l: ^render.Command_List, ctx: ^text.Context, t: theme.Theme, scale: f32, view_size: [2]f32, data: rawptr) {
	ex := (^Example)(data)
	core.frame(&ex.core, view, ex, view_size, scale, t, l)
}

main :: proc() {
	app: demo.App
	ex := new(Example)
	demo.open(&app, "myod · 03_layout", PAGE, draw_page, ex)
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
	near :: proc(a, b, scale: f32) -> bool {
		return abs(a - b) <= 0.5 / scale + 0.001
	}
	for size in ([?][2]f32{{1200, 760}, {900, 600}, {1440, 900}}) {
		for mode in theme.Mode {
			for scale in demo.SCALES {
				cap, captured := demo.capture(app, mode, scale, size)
				if !captured {
					fmt.eprintfln("FAIL %v %.2fx %v: capture failed", mode, scale, size)
					ok = false
					continue
				}
				rect :: proc(ex: ^Example, id: ui.Id) -> core.Rect {
					r, _ := core.last_rect(&ex.core, id)
					return r
				}
				sb, mn, nf := rect(ex, ex.ids.sidebar), rect(ex, ex.ids.main), rect(ex, ex.ids.info)
				d0, d1 := rect(ex, ex.ids.dividers[0]), rect(ex, ex.ids.dividers[1])
				at := fmt.tprintf("%v %.2fx %vx%v", mode, scale, size.x, size.y)
				expect := [?]struct {
					what:      string,
					got, want: f32,
				} {
					{"sidebar x", sb.x, 0},
					{"sidebar width", sb.w, SIDEBAR_W},
					{"divider 1 x", d0.x, SIDEBAR_W},
					{"main x", mn.x, SIDEBAR_W + 1},
					{"main width", mn.w, size.x - SIDEBAR_W - INFO_W - 2},
					{"divider 2 x", d1.x, size.x - INFO_W - 1},
					{"info x", nf.x, size.x - INFO_W},
					{"info width", nf.w, INFO_W},
					{"divider 1 height", d0.h, size.y},
					{"divider 2 height", d1.h, size.y},
				}
				for e in expect {
					if !near(e.got, e.want, scale) {
						fmt.eprintfln("FAIL %s: %s is %v, expected %v", at, e.what, e.got, e.want)
						ok = false
					}
				}
				// Each divider is a hairline of the border color, top to bottom: 1 logical pixel rounded
				// to whole physical pixels, the same at both dividers.
				border := theme.make_theme(mode).on_bg.border
				th := u32(max(1, math.round(scale)))
				for d in ([2]core.Rect{d0, d1}) {
					x := u32(math.round(d.x * scale))
					for y in ([3]u32{0, cap.height / 2, cap.height - 1}) {
						line := demo.pixel(cap, x - 1, y) != border && demo.pixel(cap, x + th, y) != border
						for i in 0 ..< th {
							line = line && demo.pixel(cap, x + i, y) == border
						}
						if !line {
							fmt.eprintfln("FAIL %s: divider at x = %d is not a %d px border-colored column at y = %d", at, x, th, y)
							ok = false
						}
					}
				}
				free_all(context.temp_allocator)
			}
		}
	}
	if ok {
		fmt.println("ok   layout: sidebar 240 · main grows · info 280, 1px dividers full height, at 3 window sizes × 4 scales × 2 themes")
	}
	fmt.println("selftest:", "PASS" if ok else "FAIL")
	return ok
}
