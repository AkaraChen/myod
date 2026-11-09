package core

import "core:testing"

import "../layout"
import "../render"
import "../text"
import "../theme"

Fixture :: struct {
	txt: text.Context,
	ctx: Context,
}

setup :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	testing.expect(t, text.init(&f.txt), "DWG not found: run the tests from the repository root")
	testing.expect(t, init(&f.ctx, &f.txt))
	return f
}

teardown :: proc(f: ^Fixture) {
	destroy(&f.ctx)
	text.destroy(&f.txt)
	free(f)
}

run_frame :: proc(f: ^Fixture, view: View_Proc, data: rawptr = nil, size := [2]f32{800, 600}) {
	list := render.make_command_list()
	frame(&f.ctx, view, data, size, 1, theme.make_theme(.Light), &list)
	free_all(context.temp_allocator)
}

fixed :: proc(w, h: f32) -> layout.Node {
	return {size = {{w, .Px}, {h, .Px}}}
}

@(test)
ids_are_stable_scoped_and_labeled :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	Seen :: struct {
		a, b, save, save_toolbar, scoped: Id,
		display:                          string,
	}
	seen: [2]Seen
	view :: proc(data: rawptr) {
		s := (^[2]Seen)(data)
		ctx := current()
		i := 0 if s[0].a == 0 else 1
		s[i].a = key_id(ctx, "a")
		s[i].b = key_id(ctx, "b")
		s[i].save, _ = label_id(ctx, "Save")
		s[i].save_toolbar, s[i].display = label_id(ctx, "Save##toolbar")
		push_id(ctx, key_id_int(ctx, 7))
		s[i].scoped = key_id(ctx, "a")
		pop_id(ctx)
	}
	run_frame(f, view, &seen)
	run_frame(f, view, &seen)
	testing.expect(t, seen[0] == seen[1], "IDs change between frames")
	testing.expect(t, seen[0].a != seen[0].b)
	testing.expect(t, seen[0].save != seen[0].save_toolbar)
	testing.expect_value(t, seen[0].display, "Save")
	testing.expect(t, seen[0].scoped != seen[0].a, "push_id does not change the scope")
}

@(test)
duplicate_ids_are_reported_and_separated :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	view :: proc(_: rawptr) {
		ctx := current()
		id := key_id(ctx, "same")
		leaf(ctx, id, fixed(10, 10))
		leaf(ctx, id, fixed(10, 10))
	}
	run_frame(f, view)
	tree := &f.ctx.trees[f.ctx.cur]
	testing.expect_value(t, len(tree.nodes), 3)
	testing.expect(t, tree.nodes[1].id != tree.nodes[2].id, "duplicates were not given separate IDs")
	testing.expect(t, f.ctx.warned[tree.nodes[1].id], "no warning for the duplicate ID")
}

@(test)
state_survives_until_reclaimed :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	Data :: struct {
		declare: bool,
		value:   int,
	}
	d := Data{declare = true}
	view :: proc(data: rawptr) {
		d := (^Data)(data)
		ctx := current()
		if !d.declare {
			return
		}
		id := key_id(ctx, "widget")
		leaf(ctx, id, fixed(10, 10))
		s, created := state(ctx, id, int)
		if created {
			s^ = 42
		}
		d.value = s^
	}
	run_frame(f, view, &d)
	id := Id(0)
	for k in f.ctx.slot_of {
		if k != ROOT_ID {
			id = k
		}
	}
	d.declare = false
	for _ in 0 ..< RECLAIM_FRAMES / 2 {
		run_frame(f, view, &d)
	}
	d.declare = true
	d.value = 0
	run_frame(f, view, &d)
	testing.expect_value(t, d.value, 42)

	d.declare = false
	for _ in 0 ..< RECLAIM_FRAMES + 32 {
		run_frame(f, view, &d)
	}
	_, alive := f.ctx.slot_of[id]
	testing.expect(t, !alive, "the slot of a widget gone for longer than RECLAIM_FRAMES was not reclaimed")
	d.declare = true
	run_frame(f, view, &d)
	testing.expect_value(t, d.value, 42) // a fresh state, initialized again
}

@(test)
reading_a_size_that_changes_reruns_the_pass :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	Data :: struct {
		read:  [2]f32,
		width: f32,
	}
	d := Data{width = 300}
	view :: proc(data: rawptr) {
		d := (^Data)(data)
		ctx := current()
		id := key_id(ctx, "box")
		d.read = measured(ctx, id)
		open(ctx, id, fixed(d.width, 50))
		close(ctx)
	}
	run_frame(f, view, &d)
	testing.expect_value(t, f.ctx.stats.passes, 2) // nothing to read in the first pass
	testing.expect_value(t, d.read, [2]f32{300, 50})
	run_frame(f, view, &d)
	testing.expect_value(t, f.ctx.stats.passes, 1)
	d.width = 400
	run_frame(f, view, &d)
	testing.expect_value(t, f.ctx.stats.passes, 2)
	testing.expect_value(t, d.read, [2]f32{400, 50}) // view saw the final size before it was shown
}

@(test)
unchanged_subtrees_skip_layout :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	Data :: struct {
		changed: f32,
	}
	d := Data{changed = 10}
	view :: proc(data: rawptr) {
		d := (^Data)(data)
		ctx := current()
		for i in 0 ..< 20 {
			open(ctx, key_id_int(ctx, i), {flex_direction = .Row})
			for j in 0 ..< 5 {
				leaf(ctx, key_id_int(ctx, j), fixed(d.changed if i == 7 && j == 3 else 10, 10))
			}
			close(ctx)
		}
	}
	run_frame(f, view, &d)
	run_frame(f, view, &d)
	testing.expect_value(t, f.ctx.stats.layout.computed, 0)
	testing.expect_value(t, f.ctx.stats.reused, f.ctx.stats.declared)
	d.changed = 20
	run_frame(f, view, &d)
	testing.expect(t, f.ctx.stats.layout.computed <= 4, "a change in one leaf laid out more than its path to the root")
}

@(test)
culled_containers_keep_their_slots_alive :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	view :: proc(_: rawptr) {
		ctx := current()
		for i in 0 ..< 10 {
			if open(ctx, key_id_int(ctx, i), {flex_direction = .Column}) {
				leaf(ctx, key_id(ctx, "inner"), fixed(100, 200))
			}
			close(ctx)
		}
	}
	run_frame(f, view)
	inner_count := len(f.ctx.slot_of)
	for _ in 0 ..< RECLAIM_FRAMES + 32 {
		run_frame(f, view)
	}
	testing.expect(t, f.ctx.stats.culled >= 6, "off-screen containers were not culled")
	testing.expect_value(t, len(f.ctx.slot_of), inner_count)
	// Culled placeholders keep the page the same height.
	testing.expect_value(t, f.ctx.trees[f.ctx.cur].nodes[0].rect.h, 2000)
}
