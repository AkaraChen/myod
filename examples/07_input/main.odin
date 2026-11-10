// The M7 acceptance example: every state of the text field, and body text you can select.
//
// Try: type Chinese with the system Pinyin input method (the candidate window follows the caret),
// select with the mouse or Shift + arrows, copy with Command / Control + C, paste with V, undo with
// Z. Drag across the paragraphs below: the selection is inverted and copies in document order.
package input

import "core:fmt"
import "core:strings"

import ui "myod:ui"

// ---- State ----

State :: struct {
	name:  string,
	email: string,
	notes: string,
	tag:   string,
	edits: int,
	taps:  int,
}

Set_Name :: struct{ v: string }
Set_Email :: struct{ v: string }
Set_Notes :: struct{ v: string }
Set_Tag :: struct{ v: string }
Entered :: struct{}
Tapped :: struct{}
Clear :: struct{}
Fill :: struct{}

Msg :: union {
	Set_Name,
	Set_Email,
	Set_Notes,
	Set_Tag,
	Entered,
	Tapped,
	Clear,
	Fill,
}

// ---- update ----

update :: proc(s: ^State, msg: Msg, fx: ^ui.Effects(Msg)) {
	switch m in msg {
	case Set_Name:
		replace(&s.name, m.v)
	case Set_Email:
		replace(&s.email, m.v)
	case Set_Notes:
		replace(&s.notes, m.v)
	case Set_Tag:
		replace(&s.tag, m.v)
	case Entered:
		s.edits += 1
	case Tapped:
		s.taps += 1
	case Clear:
		replace(&s.name, "")
		replace(&s.email, "")
		replace(&s.notes, "")
		replace(&s.tag, "")
	case Fill:
		replace(&s.name, "林晓")
		replace(&s.email, "xiao@example.com")
		replace(&s.notes, "第一行：备注可以换行。\n第二行：Enter 插入换行，而不是提交。")
		replace(&s.tag, "design")
	}
}

// The value returned by a field is only valid until `update` returns: State keeps a copy.
@(private)
replace :: proc(dst: ^string, v: string) {
	if dst^ == v {
		return
	}
	delete(dst^)
	dst^ = strings.clone(v)
}

state_destroy :: proc(s: ^State) {
	delete(s.name)
	delete(s.email)
	delete(s.notes)
	delete(s.tag)
}

// ---- view ----

view :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.scroll_events(d, {}, {id = "page", width = ui.grow(), height = ui.grow()}) {
		if ui.column({padding = 40, gap = 32, width = ui.grow(), align_x = .Center}) {
			if ui.column({width = ui.grow(max = 680), gap = 8}) {
				ui.text("文本输入 / TEXT INPUT", .Page_Title)
				ui.text(
					"受控输入：值来自 State，每次编辑都会返回新文本；光标、选区与输入法预编辑由库按控件 ID 保存。",
					.Lede,
					.Muted,
				)
			}
			form(s, d)
			body_text(s, d)
		}
	}
}

form :: proc(s: State, d: ui.Dispatch(Msg)) {
	invalid := s.email != "" && !strings.contains(s.email, "@")
	if ui.column({width = ui.grow(max = 680), gap = 20}) {
		ui.section_heading("表单 / FORM", "01", "label · error · disabled")
		if ui.row({gap = 16, width = ui.grow(), align_y = .End}) {
			if r, v := ui.text_input("姓名", s.name, width = ui.grow()); r.changed {
				ui.dispatch(d, Set_Name{v})
			} else if r.submitted {
				ui.dispatch(d, Entered{})
			}
			if r, v := ui.text_input("标签", s.tag, width = ui.grow(), key = "tag"); r.changed {
				ui.dispatch(d, Set_Tag{v})
			}
		}
		r, v := ui.text_input(
			"邮箱",
			s.email,
			width = ui.grow(),
			error = "请输入有效的邮箱地址（需要包含 @）" if invalid else "",
		)
		if r.changed {
			ui.dispatch(d, Set_Email{v})
		}
		if r.submitted {
			ui.dispatch(d, Entered{})
		}
		ui.text_input("工号", "MYOD-0042", width = ui.grow(), disabled = true)
		r2, notes := ui.text_area("备注", s.notes, rows = 4, width = ui.grow())
		if r2.changed {
			ui.dispatch(d, Set_Notes{notes})
		}
		if ui.row({gap = 8, align_y = .Center}) {
			if ui.button("填入示例").clicked do ui.dispatch(d, Fill{})
			if ui.button("清空", variant = .Outline).clicked do ui.dispatch(d, Clear{})
			ui.spacer()
			ui.text(fmt.tprintf("已提交 %d 次", s.edits), .Metadata, .Faint)
		}
		ui.text(
			"姓名与邮箱按 Enter 提交；备注里 Enter 插入换行。清空会从外部改写值，光标随即收敛到新文本里。",
			.Metadata,
			.Faint,
		)
	}
}

body_text :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column({width = ui.grow(max = 680), gap = 8}) {
		ui.section_heading("正文 / BODY TEXT", "02", "可拖选")
		ui.text(
			"所有正文默认可以被选中。在段落之间拖动，选区会按声明顺序（也就是文档顺序）跨控件延续，Command / Control + C 会按行复制。",
			.Body,
		)
		ui.text(
			"文字选中的效果是反色：底色用前景色，文字用背景色。双击选择一个词（UAX #29 边界；中文按单字），三击选择整段。",
			.Body,
			.Muted,
		)
		ui.text(
			"按钮、菜单项、标签里的文字不参与拖选：在那里按下是操作控件。需要点击的正文用 interactive 声明，同样不被选中。",
			.Body,
			.Faint,
		)
		if r := ui.text("这段文字是 interactive 的：双击这里不会选中它。", .Compact, .Info, interactive = true); r.double_clicked {
			ui.dispatch(d, Tapped{})
		}
		if s.taps > 0 {
			ui.text(fmt.tprintf("交互文本被双击 %d 次。", s.taps), .Metadata, .Faint)
		}
	}
}

// ---- main ----

main :: proc() {
	window := ui.open_window({title = "文本输入", size = {900, 800}})
	defer ui.close_window(&window)

	store: ui.Store(State, Msg)
	// Every string the state owns is allocated, so `replace` may delete it (a literal must not be
	// freed).
	state := State {
		name  = strings.clone("林晓"),
		notes = strings.clone("在这里输入多行备注。"),
		tag   = strings.clone("design"),
	}
	ui.store_init(&store, &window, state, update, destroy = state_destroy)
	defer ui.store_destroy(&store)

	for ui.next_frame(&window) {
		view(store.state, ui.dispatcher(&store))
	}
}
