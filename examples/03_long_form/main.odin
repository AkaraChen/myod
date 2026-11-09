// M3 performance benchmark: a long, non-virtualized settings form, thousands of widgets, where one
// field's value changes every frame. Off-screen sections are culled (not even declared), unchanged
// on-screen subtrees come from the layout cache, so a frame costs about what is visible plus what
// changed. Scroll with the mouse wheel; MYOD_DEBUG_RENDER=1 shows the counters.
//
// Flags:
//   --bench         time frames (view + layout + draw commands, no GPU) in several situations
//   --selftest      a shorter run of the same, checking the counters, and that culling does not move
//                   anything: visible sections land where they would with culling off
//   --dump <prefix> write captures for tools/rgba2png.py
package example_long_form

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"

import "myod:core"
import "myod:devtools/demo"
import "myod:render"
import "myod:text"
import "myod:theme"
import "myod:ui"

PAGE :: [2]f32{960, 800}
SECTIONS :: 120
FIELDS :: 10

LABELS := [FIELDS]string{"Name 名称", "Host", "Port", "User 用户", "Timeout", "Retries", "Region 区域", "Log level", "Cache size", "Notes 备注"}
VALUES := [FIELDS]string{"production-eu", "db.internal.example.com", "5432", "akrc", "30s", "3", "eu-central-1", "info", "512 MiB", "迁移完成后删除旧的只读副本。"}

Example :: struct {
	core:     core.Context,
	app:      ^demo.App,
	tick:     int, // changes the edited field's value every frame
	edited:   int, // which field (section * FIELDS + field) shows the changing value
	sections: [SECTIONS]ui.Id,
	page_h:   f32,
}

view :: proc(data: rawptr) {
	ex := (^Example)(data)
	if ui.column({width = ui.grow(), padding = 32, gap = 32, align_x = .Center}) {
		if ui.column({width = ui.grow(max = 720), gap = 4}) {
			ui.text("设置 Settings", .Page_Title)
			ui.text(fmt.tprintf("%d sections × %d fields, not virtualized. Field %d changes every frame.", SECTIONS, FIELDS, ex.edited), .Compact, color = .Muted)
		}
		for s in 0 ..< SECTIONS {
			section(ex, s)
		}
	}
}

section :: proc(ex: ^Example, s: int) {
	if ui.column({id = s, width = ui.grow(max = 720), gap = 16}) {
		ex.sections[s] = ui.container_id()
		ui.text(fmt.tprintf("§%d 服务 Service %d", s + 1, s + 1), .Section)
		ui.text("Connection settings for one service. Changes apply on the next deploy; 修改将在下次部署时生效。", .Compact, color = .Muted)
		if ui.grid({columns = []ui.Track{ui.fr(1), ui.fr(1)}, gap = 16, width = ui.grow()}) {
			for f in 0 ..< FIELDS {
				field(ex, s, f)
			}
		}
		ui.divider()
	}
}

field :: proc(ex: ^Example, s, f: int) {
	if ui.column({id = f, gap = 4, width = ui.grow(), column_span = 2 if f == FIELDS - 1 else 1}) {
		ui.text(LABELS[f], .Label, color = .Muted)
		if ui.row({height = ui.fixed(28), width = ui.grow(), padding = {8, 0, 8, 0}, align_y = .Center, border = .Strong}) {
			value := VALUES[f]
			if s * FIELDS + f == ex.edited {
				value = fmt.tprintf("value %d", ex.tick)
			}
			ui.text(value, .Compact, wrap = false)
		}
		if f % 3 == 0 {
			ui.text("Metadata: shown below the field.", .Metadata, color = .Faint)
		}
	}
}

draw_page :: proc(l: ^render.Command_List, ctx: ^text.Context, t: theme.Theme, scale: f32, view_size: [2]f32, data: rawptr) {
	ex := (^Example)(data)
	ex.tick += 1
	core.frame(&ex.core, view, ex, view_size, scale, t, l, scroll = ex.app.scroll)
}

main :: proc() {
	app: demo.App
	ex := new(Example)
	ex.app = &app
	ex.edited = 1
	demo.open(&app, "myod · 03_long_form", PAGE, draw_page, ex)
	defer demo.close(&app)
	if !core.init(&ex.core, &app.text) {
		os.exit(1)
	}
	defer core.destroy(&ex.core)
	app.ui = &ex.core
	app.scrollable = true
	app.continuous = true
	switch {
	case slice.contains(os.args, "--bench"):
		bench(ex, 600)
	case slice.contains(os.args, "--selftest"):
		os.exit(0 if selftest(ex) else 1)
	case demo.dump_from_args(&app, PAGE):
	case:
		demo.run(&app)
	}
}

// ---- Benchmark ----

Result :: struct {
	name:                            string,
	frames:                          int,
	avg, p50, p99, worst:            time.Duration,
	declared, culled, reused:        int,
	computed, measured, max_passes:  int,
	view, layout, draw:              time.Duration,
}

// Runs `frames` frames, calling `step` before each, and summarizes them.
run :: proc(ex: ^Example, name: string, frames: int, step: proc(ex: ^Example, i: int), scale: f32 = 2) -> Result {
	t := theme.make_theme(.Light)
	times := make([]time.Duration, frames)
	defer delete(times)
	r := Result{name = name, frames = frames}
	for i in 0 ..< frames {
		step(ex, i)
		ex.tick += 1
		text.begin_frame(&ex.app.text)
		list := render.make_command_list()
		core.frame(&ex.core, view, ex, PAGE, scale, t, &list, scroll = ex.app.scroll)
		st := ex.core.stats
		times[i] = st.frame_time
		r.declared += st.declared
		r.culled += st.culled
		r.reused += st.reused
		r.computed += int(st.layout.computed)
		r.measured += int(st.layout.measured)
		r.max_passes = max(r.max_passes, st.passes)
		r.view += st.view_time
		r.layout += st.layout_time
		r.draw += st.draw_time
		free_all(context.temp_allocator)
	}
	slice.sort(times)
	total: time.Duration
	for d in times {
		total += d
	}
	n := time.Duration(frames)
	r.avg, r.p50, r.p99, r.worst = total / n, times[frames / 2], times[min(frames - 1, frames * 99 / 100)], times[frames - 1]
	r.declared /= frames
	r.culled /= frames
	r.reused /= frames
	r.computed /= frames
	r.measured /= frames
	r.view /= n
	r.layout /= n
	r.draw /= n
	return r
}

print_result :: proc(r: Result) {
	ms :: time.duration_milliseconds
	fmt.printfln("%-30s avg %6.3f  p50 %6.3f  p99 %6.3f  max %6.3f ms | view %.3f layout %.3f draw %.3f | widgets %4d culled %3d reused %4d computed %3d measured %3d passes ≤%d",
		r.name, ms(r.avg), ms(r.p50), ms(r.p99), ms(r.worst), ms(r.view), ms(r.layout), ms(r.draw), r.declared, r.culled, r.reused, r.computed, r.measured, r.max_passes)
}

total_widgets :: proc(ex: ^Example) -> int {
	saved := ex.core.no_culling
	ex.core.no_culling = true
	defer ex.core.no_culling = saved
	list := render.make_command_list()
	core.frame(&ex.core, view, ex, PAGE, 2, theme.make_theme(.Light), &list)
	ex.page_h = ex.core.trees[ex.core.cur].nodes[0].rect.h
	return ex.core.stats.declared
}

bench :: proc(ex: ^Example, frames: int) -> [4]Result {
	n := total_widgets(ex)
	fmt.printfln("page: %d widgets, %.0f px tall; window %v; %d frames per case", n, ex.page_h, PAGE, frames)
	results := [4]Result {
		run(ex, "edit visible field (top)", frames, proc(ex: ^Example, i: int) {ex.app.scroll = {}; ex.edited = 1}),
		run(ex, "edit off-screen field (top)", frames, proc(ex: ^Example, i: int) {ex.app.scroll = {}; ex.edited = 90 * FIELDS + 3}),
		run(ex, "edit visible field (middle)", frames, proc(ex: ^Example, i: int) {ex.app.scroll = {0, ex.page_h / 2}; ex.edited = 60 * FIELDS + 2}),
		run(ex, "scroll 40px per frame + edit", frames, proc(ex: ^Example, i: int) {ex.app.scroll = {0, f32((i * 40) % int(ex.page_h - PAGE.y))}; ex.edited = (i / 4) % (SECTIONS * FIELDS)}),
	}
	for r in results {
		print_result(r)
	}
	declaration_cost(ex)
	return results
}

// Declaring a widget should cost tens to around a hundred nanoseconds (ARCHITECTURE.md, "Cheap
// declaration"): 10,000 text widgets in one column, measured after the first frame.
declaration_cost :: proc(ex: ^Example) -> f64 {
	c: core.Context
	core.init(&c, &ex.app.text)
	defer core.destroy(&c)
	many :: proc(data: rawptr) {
		if ui.column({}) {
			for _ in 0 ..< 10_000 {
				ui.text("cell", .Compact, wrap = false)
			}
		}
	}
	t := theme.make_theme(.Light)
	view_time: time.Duration
	declared := 0
	FRAMES :: 30
	for i in 0 ..< FRAMES + 1 {
		list := render.make_command_list()
		core.frame(&c, many, nil, PAGE, 2, t, &list)
		if i > 0 {
			view_time += c.stats.view_time
			declared += c.stats.declared
		}
		free_all(context.temp_allocator)
	}
	ns := f64(time.duration_nanoseconds(view_time)) / f64(declared)
	fmt.printfln("declaration: %.0f ns per widget (10,000 text widgets, view only)", ns)
	return ns
}

// ---- Self-test ----

selftest :: proc(ex: ^Example) -> bool {
	ok := true
	results := bench(ex, 60)
	visible := 4 // sections that fit in the window, roughly
	for r in results[:3] {
		if r.culled < SECTIONS - visible - 2 {
			fmt.eprintfln("FAIL %s: only %d sections culled per frame", r.name, r.culled)
			ok = false
		}
		if r.computed > 40 {
			fmt.eprintfln("FAIL %s: %d nodes laid out per frame; unchanged subtrees should come from the cache", r.name, r.computed)
			ok = false
		}
		if r.max_passes > 1 {
			fmt.eprintfln("FAIL %s: %d passes in a frame without scrolling", r.name, r.max_passes)
			ok = false
		}
	}
	// The budget is 1 ms per frame in an optimized build (`just bench`: about 0.1 ms on an M3 MacBook
	// Air). The self-test runs a debug build, so it only guards against gross regressions.
	for r in results {
		if time.duration_milliseconds(r.avg) > 4 {
			fmt.eprintfln("FAIL %s: %.3f ms per frame on average, over the 4 ms debug-build guard", r.name, time.duration_milliseconds(r.avg))
			ok = false
		}
	}
	if results[1].computed > 5 {
		fmt.eprintfln("FAIL %s: editing an off-screen field laid out %d nodes", results[1].name, results[1].computed)
		ok = false
	}

	// Culling must not move anything: at several scroll positions, the visible sections are where
	// they are with culling off.
	t := theme.make_theme(.Light)
	for y in ([?]f32{0, 1234, ex.page_h / 3, ex.page_h - PAGE.y}) {
		ex.app.scroll = {0, y}
		got: [SECTIONS]core.Rect
		for pass in 0 ..< 2 {
			ex.core.no_culling = pass == 1
			list := render.make_command_list()
			core.frame(&ex.core, view, ex, PAGE, 2, t, &list, scroll = ex.app.scroll)
			for id, s in ex.sections {
				r, _ := core.last_rect(&ex.core, id)
				if pass == 0 {
					got[s] = r
				} else if core.intersects(r, {0, y, PAGE.x, PAGE.y}) && got[s] != r {
					fmt.eprintfln("FAIL scroll %v: section %d is at %v with culling, %v without", y, s, got[s], r)
					ok = false
				}
			}
			free_all(context.temp_allocator)
		}
		ex.core.no_culling = false
	}
	if ok {
		fmt.println("ok   long form: off-screen sections culled, unchanged subtrees from the layout cache, one pass per frame, culling moves nothing")
	}
	fmt.println("selftest:", "PASS" if ok else "FAIL")
	return ok
}
