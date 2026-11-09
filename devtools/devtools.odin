// Debug overlays, switched on with environment variables (see ARCHITECTURE.md, "Rendering backend"):
//
//   MYOD_DEBUG_RENDER=1   render stats in the top-right corner: draw calls, instances, renderer CPU
//                         time, atlas pages and evictions; for frames built with core/, also
//                         widgets declared, containers culled, subtrees reused, layout work and the
//                         time per stage
//   MYOD_DEBUG_ATLAS=1    every atlas page, scaled down, along the bottom-left
//
// Apps append the overlays to their command list after the page, so they draw on top.
package devtools

import "core:fmt"
import "core:os"
import "core:time"

import "../atlas"
import "../backend"
import "../core"
import "../render"
import "../text"
import "../theme"

Flags :: struct {
	render: bool,
	atlas:  bool,
}

// Reads the MYOD_DEBUG_* environment variables.
flags :: proc() -> Flags {
	on :: proc(name: string) -> bool {
		v := os.get_env(name, context.temp_allocator)
		return v != "" && v != "0"
	}
	return {render = on("MYOD_DEBUG_RENDER"), atlas = on("MYOD_DEBUG_ATLAS")}
}

// Draws the render stats panel in the top-right corner of a `view` (logical size). `frame` adds the
// stats of a frame built with core/.
render_overlay :: proc(list: ^render.Command_List, ctx: ^text.Context, stats: backend.Render_Stats, view: [2]f32, scale: f32, t: theme.Theme, frame: ^core.Stats = nil) {
	s := t.on_solid
	style := text.Style{size = 12, line_height = 20, weight = .Regular, color = s.fg}
	mask := &ctx.atlases[.Mask]
	color := &ctx.atlases[.Color]
	lines := make([dynamic]string, context.temp_allocator)
	if frame != nil {
		f := frame^
		ms :: time.duration_milliseconds
		append(&lines, fmt.tprintf("widgets %d · culled containers %d · passes %d", f.declared, f.culled, f.passes))
		append(&lines, fmt.tprintf("reused %d/%d widgets (%d subtrees)", f.reused, f.declared, f.reused_roots))
		append(&lines, fmt.tprintf("layout: %d nodes computed · %d cache hits · %d measured", f.layout.computed, f.layout.cache_hits, f.layout.measured))
		append(&lines, fmt.tprintf("view %.3f · layout %.3f · draw %.3f · frame %.3f ms", ms(f.view_time), ms(f.layout_time), ms(f.draw_time), ms(f.frame_time)))
	}
	append(&lines, fmt.tprintf("draw calls %d · instances %d · commands %d", stats.draw_calls, stats.instances, stats.commands))
	append(&lines, fmt.tprintf("renderer CPU %.3f ms", time.duration_milliseconds(stats.cpu_time)))
	append(&lines, fmt.tprintf("atlas mask %d/%d pages · color %d/%d · evictions %d", len(mask.pages), mask.max_pages, len(color.pages), color.max_pages, mask.evictions + color.evictions))
	width: f32 = 0
	for l in lines {
		width = max(width, text.measure(ctx, l, style, scale).x)
	}
	pad: f32 = 8
	box := render.Rect{view.x - width - 2 * pad - 8, 8, width + 2 * pad, f32(len(lines)) * style.line_height + 2 * pad}
	render.bordered(list, box, s.border_strong, 1, s.bg_solid)
	for l, i in lines {
		text.draw(list, ctx, l, {box.x + pad, box.y + pad + f32(i) * style.line_height}, style, scale)
	}
}

// Draws every atlas page, scaled to `page_size` logical pixels, along the bottom-left of `view`.
atlas_overlay :: proc(list: ^render.Command_List, ctx: ^text.Context, view: [2]f32, scale: f32, t: theme.Theme, page_size: f32 = 192) {
	s := t.on_solid
	label := text.Style{size = 12, line_height = 20, weight = .Regular, color = s.muted}
	x: f32 = 8
	y := view.y - page_size - 8 - 20
	for kind in atlas.Kind {
		for _, page in ctx.atlases[kind].pages {
			render.bordered(list, {x - 1, y - 1, page_size + 2, page_size + 2}, s.border_strong, 1, s.bg_solid)
			render.fill(list, {x, y, page_size, page_size}, s.bg_solid)
			append(&list.commands, render.Cmd_Atlas_View{rect = {x, y, page_size, page_size}, atlas = kind, page = i32(page), color = s.fg})
			text.draw(list, ctx, fmt.tprintf("%v %d", kind, page), {x, y + page_size + 2}, label, scale)
			x += page_size + 12
		}
	}
}
