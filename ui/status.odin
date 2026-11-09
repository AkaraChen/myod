// Waiting indicators: the spinner and the pending state (DESIGN.md, "Spinner", "Pending state").
// Both only wake the frame loop while they are visible.
package ui

import "core:fmt"
import "core:time"

import "../core"
import "../layout"
import "../platform"

// The braille spinner sequence, as the four-by-four dot matrix of a braille cell: the four bits of
// the left column and the four of the right (dot 1, 2, 3, 7 and dot 4, 5, 6, 8).
@(private)
spinner_frames := [10]u8{0x0b, 0x19, 0x39, 0x38, 0x3c, 0x34, 0x26, 0x27, 0x07, 0x0f}

// 2×2px dots with 2px spacing: 6 × 14 overall, as in DESIGN.md.
@(private)
DOT :: 2.0
@(private)
DOT_PITCH :: 4.0

// A square braille spinner, about 10 frames a second, drawn from rectangles so the dots stay
// pixel-aligned at every scale (DESIGN.md, "Spinner"). It requests redraws only while visible.
spinner :: proc(color: Color = .Muted) -> Response {
	ctx := core.current()
	id := core.auto_id(ctx)
	outer := layout.Node {
		flex_direction  = .Column,
		align_items     = .Center,
		justify_content = .Center,
		size            = {{6, .Px}, {20, .Px}},
	}
	opened := core.open(ctx, id, outer, nil)
	if opened {
		frame := (platform.ticks_ms() / 100) % 10
		bits := spinner_frames[frame]
		cell := layout.Node{size = {{6, .Px}, {14, .Px}}}
		if core.open(ctx, core.auto_id(ctx), cell, nil) {
			for row in 0 ..< 4 {
				for col in 0 ..< 2 {
					lit := false
					switch {
					case col == 0 && row < 3:
						lit = bits & (u8(1) << uint(row)) != 0
					case col == 0 && row == 3:
						lit = bits & (u8(1) << 6) != 0
					case col == 1 && row < 3:
						lit = bits & (u8(1) << uint(3 + row)) != 0
					case col == 1 && row == 3:
						lit = bits & (u8(1) << 7) != 0
					}
					dot := layout.Node{position = 1, size = {{DOT, .Px}, {DOT, .Px}}}
					dot.inset[0] = {f32(col) * DOT_PITCH, .Px}
					dot.inset[2] = {f32(row) * DOT_PITCH, .Px}
					tok := core.Token.Border
					if lit {
						tok = token(color)
					}
					core.leaf(ctx, core.auto_id(ctx), dot, core.Paint_Box{fill = tok})
				}
			}
			core.close(ctx)
		}
		core.close(ctx)
	}
	// Only a visible spinner keeps waking the loop; one scrolled out of view costs nothing.
	if visible(ctx, id) {
		request_redraw(100 * time.Millisecond)
	}
	return response(ctx, id)
}

// The pending state for a background task: a spinner, what is being done, and (in metadata type)
// how long it has run and how long ago the task last reported activity. The second line refreshes
// once a second, not continuously (DESIGN.md, "Pending state").
pending_task :: proc(task: Task_Id, label: string, stage := "", count := "") -> Response {
	ctx := core.current()
	id := core.auto_id(ctx)
	outer := layout.Node{flex_direction = .Column, gap = {2, 2}}
	opened := core.open(ctx, id, outer, nil)
	if opened {
		if row({gap = 8, align_y = .Center, width = grow()}) {
			spinner(.Fg)
			text(label, .Label)
			if stage != "" {
				text(stage, .Metadata, .Faint)
			}
		}
		elapsed, idle, ok := task_times(task)
		line: string
		if ok {
			line = fmt.tprintf("%s · %s idle", short_duration(elapsed), short_duration(idle))
		}
		if count != "" {
			line = fmt.tprintf("%s · %s", line, count) if line != "" else count
		}
		if line != "" {
			text(line, .Metadata, .Faint)
		}
	}
	core.close(ctx)
	if visible(ctx, id) {
		request_redraw(time.Second)
	}
	return response(ctx, id)
}

@(private)
short_duration :: proc(d: time.Duration) -> string {
	ms := time.duration_milliseconds(d)
	if ms < 1000 {
		return "0s"
	}
	secs := i64(ms / 1000)
	if secs < 60 {
		return fmt.tprintf("%ds", secs)
	}
	return fmt.tprintf("%d:%02d", secs / 60, secs % 60)
}

@(private)
visible :: proc(ctx: ^core.Context, id: Id) -> bool {
	r, ok := core.last_rect(ctx, id)
	if !ok {
		return true // not laid out yet: keep drawing
	}
	vp := ctx.viewport
	return r.x < vp.x + vp.w && vp.x < r.x + r.w && r.y < vp.y + vp.h && vp.y < r.y + r.h
}
