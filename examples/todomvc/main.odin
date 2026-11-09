// TodoMVC: lists, ID scopes, controlled text input, edit state, filtering, derived state.
package todomvc

import "core:fmt"
import "core:strings"

import ph "myod:icons/phosphor"
import ui "myod:ui"

// ---- State ----

Todo :: struct {
	id:    int,
	title: string,
	done:  bool,
}

Filter :: enum {
	All,
	Active,
	Completed,
}

FILTER_LABELS :: [Filter]string {
	.All       = "全部",
	.Active    = "未完成",
	.Completed = "已完成",
}

State :: struct {
	todos:      [dynamic]Todo,
	next_id:    int,
	filter:     Filter,
	draft:      string, // contents of the "new todo" input
	editing_id: int, // the todo being edited, 0 if none
	edit_text:  string, // contents of the edit input
}

// ---- Messages ----
// Single-value messages use distinct (constructed as Toggle(id)); messages without a value are empty structs.

Set_Draft :: distinct string
Add_Todo :: struct {}
Toggle :: distinct int
Toggle_All :: distinct bool
Remove :: distinct int
Start_Edit :: distinct int
Set_Edit_Text :: distinct string
Commit_Edit :: struct {}
Cancel_Edit :: struct {}
Set_Filter :: distinct Filter
Clear_Completed :: struct {}

Msg :: union {
	Set_Draft,
	Add_Todo,
	Toggle,
	Toggle_All,
	Remove,
	Start_Edit,
	Set_Edit_Text,
	Commit_Edit,
	Cancel_Edit,
	Set_Filter,
	Clear_Completed,
}

// ---- update ----
// Strings in messages only live until update returns; clone anything you keep (see replace).

update :: proc(s: ^State, msg: Msg, fx: ^ui.Effects(Msg)) {
	switch m in msg {
	case Set_Draft:
		replace(&s.draft, string(m))

	case Add_Todo:
		title := strings.trim_space(s.draft)
		if title == "" do return
		append(&s.todos, Todo{id = s.next_id, title = strings.clone(title)})
		s.next_id += 1
		replace(&s.draft, "")

	case Toggle:
		if t := find(s, int(m)); t != nil do t.done = !t.done

	case Toggle_All:
		for &t in s.todos do t.done = bool(m)

	case Remove:
		remove_todo(s, int(m))

	case Start_Edit:
		if t := find(s, int(m)); t != nil {
			s.editing_id = t.id
			replace(&s.edit_text, t.title)
		}

	case Set_Edit_Text:
		replace(&s.edit_text, string(m))

	case Commit_Edit:
		// State machine: a commit that arrives while nothing is being edited (e.g. a late blur) is ignored.
		if s.editing_id == 0 do return
		id := s.editing_id
		s.editing_id = 0
		title := strings.trim_space(s.edit_text)
		if title == "" {
			remove_todo(s, id) // TodoMVC spec: clearing the title deletes the todo
		} else if t := find(s, id); t != nil {
			replace(&t.title, title)
		}

	case Cancel_Edit:
		s.editing_id = 0

	case Set_Filter:
		s.filter = Filter(m)

	case Clear_Completed:
		#reverse for t, i in s.todos {
			if t.done {
				delete(t.title)
				ordered_remove(&s.todos, i)
			}
		}
	}
}

// ---- view ----

view :: proc(s: State, d: ui.Dispatch(Msg)) {
	// Derived state is computed every frame; with no cache, it can never go stale.
	active := 0
	for t in s.todos do if !t.done do active += 1
	completed := len(s.todos) - active

	// The outer column centers; the inner one caps the width.
	if ui.column({padding = 24, align_x = .Center}) {
		if ui.column({width = ui.grow(max = 560), height = ui.grow(), gap = 24}) {
			ui.text("待办", .Page_Title)

			// Controlled input: the value comes from state and edits come back as messages.
			// Widgets with a value also return the new value; the label sits above, never a placeholder.
			r, text := ui.text_input("新待办", s.draft, width = ui.grow())
			if r.changed do ui.dispatch(d, Set_Draft(text))
			if r.submitted do ui.dispatch(d, Add_Todo{})

			if len(s.todos) > 0 {
				if ui.checkbox(active == 0, "全部标记为完成").changed {
					ui.dispatch(d, Toggle_All(active != 0))
				}
			}

			todo_list(s, d)

			if len(s.todos) > 0 {
				footer(s, d, active, completed)
			}
		}
	}
}

todo_list :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.scroll({height = ui.grow()}) {
		for todo in s.todos {
			if !visible(todo, s.filter) do continue

			// id becomes this row's ID scope: even two todos with the same title
			// won't make their checkboxes and buttons collide.
			if ui.list_item({id = todo.id, gap = 8, align_y = .Center}) {
				if ui.checkbox(todo.done).changed do ui.dispatch(d, Toggle(todo.id))

				if s.editing_id == todo.id {
					// In-place editing hides the label, but the label text is still the accessible name.
					// autofocus is a presentation concern: the widget takes focus when it first appears.
					er, edit_text := ui.text_input("编辑待办", s.edit_text, width = ui.grow(), hide_label = true, autofocus = true)
					if er.changed do ui.dispatch(d, Set_Edit_Text(edit_text))
					if er.cancelled {
						ui.dispatch(d, Cancel_Edit{})
					} else if er.submitted || er.lost_focus {
						ui.dispatch(d, Commit_Edit{})
					}
				} else {
					// Completed todos only change color.
					color: ui.Color = .Faint if todo.done else .Fg
					if ui.text(todo.title, .Body, color = color, width = ui.grow()).double_clicked {
						ui.dispatch(d, Start_Edit(todo.id))
					}
					if ui.icon_button(ph.TRASH, "删除", variant = .Ghost).clicked {
						ui.dispatch(d, Remove(todo.id))
					}
				}
			}
		}
	}
}

footer :: proc(s: State, d: ui.Dispatch(Msg), active, completed: int) {
	if ui.row({gap = 8, align_y = .Center}) {
		ui.text(fmt.tprintf("%d 项未完成", active), .Metadata, color = .Faint)
		ui.spacer()

		// Tabs bind to an enum; labels come from an enumerated array; the new value is the second return value.
		if r, filter := ui.tabs(s.filter, FILTER_LABELS); r.changed do ui.dispatch(d, Set_Filter(filter))
		ui.spacer()

		if ui.button("清除已完成", variant = .Ghost, size = .Small, disabled = completed == 0).clicked {
			ui.dispatch(d, Clear_Completed{})
		}
	}
}

main :: proc() {
	window := ui.open_window({title = "TodoMVC", size = {560, 640}})
	defer ui.close_window(&window)

	// destroy runs when the store is destroyed and frees the memory held by the state.
	store: ui.Store(State, Msg)
	ui.store_init(&store, &window, State{next_id = 1}, update, destroy = state_destroy)
	defer ui.store_destroy(&store)

	for ui.next_frame(&window) {
		view(store.state, ui.dispatcher(&store))
	}
}

// ---- Helpers: plain business logic, unrelated to the UI library ----

visible :: proc(t: Todo, f: Filter) -> bool {
	switch f {
	case .All:       return true
	case .Active:    return !t.done
	case .Completed: return t.done
	}
	return true
}

find :: proc(s: ^State, id: int) -> ^Todo {
	for &t in s.todos do if t.id == id do return &t
	return nil
}

remove_todo :: proc(s: ^State, id: int) {
	for t, i in s.todos {
		if t.id == id {
			delete(t.title)
			ordered_remove(&s.todos, i)
			return
		}
	}
}

// Replaces dst with a copy of src and frees the old value. src may point into dst.
replace :: proc(dst: ^string, src: string) {
	old := dst^
	dst^ = strings.clone(src)
	delete(old)
}

state_destroy :: proc(s: ^State) {
	for t in s.todos do delete(t.title)
	delete(s.todos)
	delete(s.draft)
	delete(s.edit_text)
}
