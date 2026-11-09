// The M6 acceptance example: every component of DESIGN.md, in every state, laid out on one page —
// the "full state matrix". Light and dark themes switch with one button, and everything on the page
// is drawn from the theme tokens, so both are always visible.
package widgets

import "core:fmt"
import "core:math"
import "core:time"

import ph "myod:icons/phosphor"
import ui "myod:ui"

// ---- State ----

Tab :: enum {
	Overview,
	Activity,
	Settings,
}

TAB_LABELS :: [Tab]string {
	.Overview = "概览",
	.Activity = "动态",
	.Settings = "设置",
}

State :: struct {
	light: bool,

	checked:     bool,
	check_alt:   bool,
	toggle_on:   bool,
	toggle_auto: bool,
	radio:       int,

	volume:   f32,
	progress: f32,
	tab:      Tab,

	menu_open:    bool,
	popover_open: bool,
	dialog_open:  bool,
	pop_check:    bool,
	last_action:  string,

	split: f32,

	job: ui.Task_Id,

	toast:     bool,
	toast_seq: int,

	end_hits: int,

	sprite:    ui.Image,
	sprite_px: []u8,
}

// ---- Messages ----

Show_Toast :: struct {
	label: string,
}
Hide_Toast :: struct {
	seq: int,
}

Start_Job :: struct{}
Cancel_Job :: struct{}
Job_Done :: struct{}

Msg :: union {
	Toggle_Theme,

	Set_Checked,
	Set_Check_Alt,
	Set_Toggle,
	Set_Toggle_Auto,
	Set_Radio,

	Set_Volume,
	Set_Progress,
	Set_Tab,

	Set_Menu,
	Set_Popover,
	Set_Dialog,
	Set_Pop_Check,
	Set_Action,

	Resize,

	Start_Job,
	Cancel_Job,
	Job_Done,

	Show_Toast,
	Hide_Toast,

	Reached_End,
}

Toggle_Theme :: struct{}
Set_Checked :: struct{ v: bool }
Set_Check_Alt :: struct{ v: bool }
Set_Toggle :: struct{ v: bool }
Set_Toggle_Auto :: struct{ v: bool }
Set_Radio :: struct{ v: int }
Set_Volume :: struct{ v: f32 }
Set_Progress :: struct{ v: f32 }
Set_Tab :: struct{ v: Tab }
Set_Menu :: struct{ v: bool }
Set_Popover :: struct{ v: bool }
Set_Dialog :: struct{ v: bool }
Set_Pop_Check :: struct{ v: bool }
Set_Action :: struct{ label: string }
Resize :: struct{ width: f32 }
Reached_End :: struct{}

// ---- update ----

update :: proc(s: ^State, msg: Msg, fx: ^ui.Effects(Msg)) {
	switch m in msg {
	case Toggle_Theme:
		s.light = !s.light

	case Set_Checked:
		s.checked = m.v
	case Set_Check_Alt:
		s.check_alt = m.v
	case Set_Toggle:
		s.toggle_on = m.v
	case Set_Toggle_Auto:
		s.toggle_auto = m.v
	case Set_Radio:
		s.radio = m.v

	case Set_Volume:
		s.volume = m.v
	case Set_Progress:
		s.progress = clamp(m.v, 0, 1)
	case Set_Tab:
		s.tab = m.v

	case Set_Menu:
		s.menu_open = m.v
	case Set_Popover:
		s.popover_open = m.v
	case Set_Dialog:
		s.dialog_open = m.v
	case Set_Pop_Check:
		s.pop_check = m.v
	case Set_Action:
		s.last_action = m.label
		s.menu_open = false
		s.popover_open = false

	case Resize:
		s.split = clamp(m.width, 120, 420)

	case Start_Job:
		if s.job != {} do return
		s.job = ui.start_task(fx, work, Work_Args{})

	case Cancel_Job:
		if s.job == {} do return
		ui.cancel_task(fx, s.job)
		s.job = {}

	case Job_Done:
		s.job = {}

	case Show_Toast:
		s.toast = true
		s.toast_seq += 1
		// The toast is presentation state owned by the app: the timer sends the message that hides it.
		ui.after(fx, 4 * time.Second, Hide_Toast{seq = s.toast_seq})

	case Hide_Toast:
		if m.seq == s.toast_seq {
			s.toast = false
		}

	case Reached_End:
		s.end_hits += 1
	}
}

Work_Args :: struct{}

// A background task with no progress messages: it just keeps the pending state alive for a while.
work :: proc(t: ^ui.Task_Context(Msg), _: Work_Args) -> Msg {
	for _ in 0 ..< 18 {
		if ui.cancelled(t) do break
		time.sleep(100 * time.Millisecond)
	}
	return Job_Done{}
}

// ---- view ----

view :: proc(s: State, d: ui.Dispatch(Msg)) {
	// The theme is window state, and the app owns it here. Applied before anything is declared.
	ui.set_theme(.Light if s.light else .Dark)

	// The page scroll also reports when it reaches the bottom; `update` counts the messages.
	if ui.scroll_events(d, Reached_End{}, {id = "page", width = ui.grow(), height = ui.grow()}) {
		if ui.column({padding = 28, gap = 32, width = ui.grow(), align_x = .Start}) {
			header(s, d)
			typography()
			buttons_and_choices(s, d)
			ranges(s, d)
			navigation(s, d)
			layout_demo(s, d)
			status_demo(s, d)
			images(s)
			list_demo(s)
			// Layers are declared at the end of the page too: they escape layout, and declaring them
			// next to their triggers keeps the anchor rect of this pass in hand.
			layers(s, d)
		}
	}
}

header :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.row({gap = 12, align_y = .Center, width = ui.grow()}) {
		ui.text("控件总览", .Page_Title)
		ui.spacer()
		mode := "深色"
		if s.light do mode = "浅色"
		ui.text(mode, .Metadata, .Faint)
		if b := ui.button("切换主题", icon = ph.PALETTE, variant = .Ghost, size = .Small); b.clicked {
			ui.dispatch(d, Toggle_Theme{})
		} else {
			ui.tooltip(b, "浅色 / 深色")
		}
	}
	ui.text("DESIGN.md 中每个组件的全部状态，同一页面上一次看全。拖动分栏、滚动列表、打开菜单试试。", .Lede, .Muted)
}

typography :: proc() {
	ui.section_heading("排版 / TYPOGRAPHY", "01", "12 级字号")
	if ui.column({gap = 10, width = ui.grow()}) {
		type_row("Display", "标题字 48/56", .Display)
		type_row("Page title", "页面标题 40/48", .Page_Title)
		type_row("Title", "标题 32/40", .Title)
		type_row("Section", "小节 24/32", .Section)
		type_row("Subsection", "小标题 20/26", .Subsection)
		type_row("Lede", "导语 18/28", .Lede)
		type_row("Body", "正文 16/24 — 一段安静的正文，用来检查行高与颜色。", .Body)
		type_row("Compact", "紧凑 14/20", .Compact)
		type_row("Label", "标签 12/20 字距 0.12", .Label)
		type_row("Metadata", "元数据 12/20", .Metadata)
	}
}

type_row :: proc(name, sample: string, style: ui.Text_Style) {
	if ui.row({gap = 16, align_y = .Center, width = ui.grow()}) {
		if ui.column({width = ui.fixed(120)}) {
			ui.text(name, .Metadata, .Faint)
		}
		ui.text(sample, style, .Fg)
	}
}

buttons_and_choices :: proc(s: State, d: ui.Dispatch(Msg)) {
	ui.section_heading("按钮 / BUTTONS", "02", "4 变体 · 2 尺寸 · 图标")
	if ui.column({gap = 12, width = ui.grow()}) {
		button_row("Outline", .Outline)
		button_row("Primary", .Primary)
		button_row("Ghost", .Ghost)
		button_row("Danger", .Danger)
		if ui.row({gap = 8, align_y = .Center}) {
			ui.text("图标按钮", .Metadata, .Faint)
			ui.icon_button(ph.PLUS, "新增", variant = .Outline)
			ui.icon_button(ph.TRASH, "删除", variant = .Ghost)
			ui.icon_button(ph.GEAR, "设置", variant = .Primary)
			ui.icon_button(ph.X, "关闭禁用", variant = .Outline, disabled = true)
		}
	}

	ui.section_heading("选择 / CHOICE", "03", "toggle · checkbox · radio")
	if ui.column({gap = 12, width = ui.grow()}) {
		if ui.row({gap = 24, align_y = .Center, wrap = true}) {
			if ui.checkbox(s.checked, "启用实验功能").changed do ui.dispatch(d, Set_Checked{v = !s.checked})
			if ui.checkbox(s.check_alt, "记住窗口大小").changed do ui.dispatch(d, Set_Check_Alt{v = !s.check_alt})
			ui.checkbox(true, "已勾选（禁用）", disabled = true)
			ui.checkbox(false, "未勾选（禁用）", disabled = true)
		}
		if ui.row({gap = 24, align_y = .Center, wrap = true}) {
			if ui.toggle(s.toggle_on, "自动保存").changed do ui.dispatch(d, Set_Toggle{v = !s.toggle_on})
			if ui.toggle(s.toggle_auto, "同步到云端").changed do ui.dispatch(d, Set_Toggle_Auto{v = !s.toggle_auto})
			ui.toggle(true, "打开（禁用）", disabled = true)
			ui.toggle(false, "关闭（禁用）", disabled = true)
		}
		if ui.row({gap = 24, align_y = .Center, wrap = true}) {
			names := [3]string{"小", "中", "大"}
			for name, i in names {
				if ui.radio(s.radio == i, name).changed do ui.dispatch(d, Set_Radio{v = i})
			}
			ui.radio(false, "禁用", disabled = true)
		}
	}
}

button_row :: proc(name: string, variant: ui.Button_Variant) {
	if ui.row({gap = 8, align_y = .Center, wrap = true}) {
		ui.text(name, .Metadata, .Faint, width = ui.fixed(72))
		ui.button(fmt.tprintf("%s·默认", name), variant = variant)
		ui.button(fmt.tprintf("%s·小", name), icon = ph.CHECK, variant = variant, size = .Small)
		ui.button(fmt.tprintf("%s·禁用", name), variant = variant, disabled = true)
	}
}

ranges :: proc(s: State, d: ui.Dispatch(Msg)) {
	ui.section_heading("数值 / RANGE", "04", "slider · progress · tag")
	if ui.column({gap = 14, width = ui.grow()}) {
		if ui.row({gap = 12, align_y = .Center, width = ui.grow()}) {
			ui.text("音量", .Metadata, .Faint, width = ui.fixed(72))
			if r, v := ui.slider(s.volume, ui.fixed(280)); r.changed {
				ui.dispatch(d, Set_Volume{v = v})
			}
			ui.text(fmt.tprintf("%d%%", int(s.volume * 100 + 0.5)), .Compact, .Muted)
		}
		if ui.row({gap = 12, align_y = .Center, width = ui.grow()}) {
			ui.text("禁用", .Metadata, .Faint, width = ui.fixed(72))
			ui.slider(0.4, ui.fixed(280), disabled = true)
			ui.text("40%", .Compact, .Faint)
		}
		if ui.row({gap = 12, align_y = .Center, width = ui.grow()}) {
			ui.text("进度", .Metadata, .Faint, width = ui.fixed(72))
			ui.progress(s.progress, ui.fixed(280))
			if ui.button("+10%", variant = .Ghost, size = .Small).clicked {
				ui.dispatch(d, Set_Progress{v = s.progress + 0.1})
			}
			if ui.button("归零", variant = .Ghost, size = .Small).clicked {
				ui.dispatch(d, Set_Progress{v = 0})
			}
		}
		if ui.row({gap = 8, align_y = .Center, wrap = true}) {
			ui.text("标签", .Metadata, .Faint, width = ui.fixed(72))
			ui.tag("中性", .Muted)
			ui.tag("信息", .Info)
			ui.tag("成功", .Success)
			ui.tag("警告", .Warning)
			ui.tag("错误", .Error)
		}
	}
}

navigation :: proc(s: State, d: ui.Dispatch(Msg)) {
	ui.section_heading("导航 / NAVIGATION", "05", "tabs · list row")
	if ui.column({gap = 12, width = ui.grow()}) {
		if r, tab := ui.tabs(s.tab, TAB_LABELS); r.changed {
			ui.dispatch(d, Set_Tab{v = tab})
		}
		switch s.tab {
		case .Overview:
			ui.text("概览页：当前选中第一个标签。", .Body, .Muted)
		case .Activity:
			ui.text("动态页：当前选中第二个标签。", .Body, .Muted)
		case .Settings:
			ui.text("设置页：当前选中第三个标签。", .Body, .Muted)
		}
		if ui.column({width = ui.fixed(360)}) {
			ui.list_row("版本", "0.6.0")
			ui.list_row("通道", "Beta", .Info)
			ui.list_row("上次更新", "刚刚", .Success)
		}
	}
}

layout_demo :: proc(s: State, d: ui.Dispatch(Msg)) {
	ui.section_heading("布局 / LAYOUT", "06", "splitter · scroll · sticky")
	if ui.row({height = ui.fixed(220), width = ui.grow(), border = .Default, fill = .Bg}) {
		if ui.column({width = ui.fixed(s.split), padding = 14, gap = 8}) {
			ui.text("左栏", .Label)
			ui.text(fmt.tprintf("%d px", int(s.split)), .Compact, .Muted)
			ui.text("拖动右侧的分隔条调整宽度。", .Compact, .Faint)
		}
		if r := ui.splitter(); r.dragging && r.drag != 0 {
			ui.dispatch(d, Resize{width = s.split + r.drag})
		}
		if ui.column({width = ui.grow(), height = ui.grow(), padding = 14, gap = 8}) {
			if ui.scroll({id = "demo_log", width = ui.grow(), height = ui.grow(), padding = {0, 28, 0, 0}}) {
				for i in 0 ..< 40 {
					kind := "读取"
					if i % 3 == 0 do kind = "写入"
					ui.list_row(fmt.tprintf("日志行 %02d", i + 1), kind)
				}
				if ui.sticky({height = ui.fixed(28), padding = {10, 0, 10, 0}, fill = .Bg_Solid, border = .Strong}) {
					ui.text("固定表头 / STICKY", .Label)
					ui.spacer()
					ui.text(fmt.tprintf("底部触发 %d 次", s.end_hits), .Metadata, .Faint)
				}
			}
		}
	}
	ui.text("滚动到底部会触发 on_end（示例只计数）。", .Metadata, .Faint)
}

status_demo :: proc(s: State, d: ui.Dispatch(Msg)) {
	ui.section_heading("状态 / STATUS", "07", "spinner · pending · disabled")
	if ui.row({gap = 24, align_y = .Center, wrap = true}) {
		if ui.row({gap = 8, align_y = .Center}) {
			ui.spinner(.Fg)
			ui.text("加载中", .Compact, .Muted)
		}
		ui.spinner(.Info)
		ui.spinner(.Success)
		ui.spinner(.Warning)
		ui.spinner(.Error)
	}
	if ui.column({gap = 10, width = ui.grow()}) {
		if s.job == {} {
			if ui.button("开始后台任务", icon = ph.DOWNLOAD_SIMPLE, variant = .Primary).clicked {
				ui.dispatch(d, Start_Job{})
			}
		} else {
			ui.pending_task(s.job, "正在生成预览", "编译中", "约 2 秒")
			if ui.button("取消任务", icon = ph.X, variant = .Ghost, size = .Small).clicked {
				ui.dispatch(d, Cancel_Job{})
			}
		}
		ui.text("按钮和输入控件的禁用态统一为 36% 不透明度。", .Metadata, .Faint)
	}
}

images :: proc(s: State) {
	ui.section_heading("图像 / IMAGES", "08", "Cmd_Image · contain / cover / stretch")
	if ui.row({gap = 16, align_y = .Start, wrap = true}) {
		if ui.column({gap = 6}) {
			if ui.row({width = ui.fixed(200), height = ui.fixed(120), border = .Default, fill = .Bg}) {
				ui.image(s.sprite, ui.grow(), ui.grow(), .Contain)
			}
			ui.text("Contain", .Metadata, .Faint)
		}
		if ui.column({gap = 6}) {
			if ui.row({width = ui.fixed(200), height = ui.fixed(120), border = .Default, fill = .Bg}) {
				ui.image(s.sprite, ui.grow(), ui.grow(), .Cover)
			}
			ui.text("Cover", .Metadata, .Faint)
		}
		if ui.column({gap = 6}) {
			if ui.row({width = ui.fixed(120), height = ui.fixed(120), border = .Default, fill = .Bg}) {
				ui.image(s.sprite, ui.grow(), ui.grow(), .Stretch)
			}
			ui.text("Stretch", .Metadata, .Faint)
		}
		if ui.column({gap = 6}) {
			ui.image(s.sprite, ui.fixed(160), ui.fixed(100), .Contain)
			ui.text("固定尺寸", .Metadata, .Faint)
		}
	}
}

list_demo :: proc(s: State) {
	ui.section_heading("列表 / LIST ROWS", "09", "key/value · 28px")
	if ui.column({width = ui.fixed(420)}) {
		ui.list_row("名称", "myod")
		ui.list_row("许可证", "MIT", .Info)
		ui.list_row("平台", "macOS", .Success)
		ui.list_row("状态", "开发中", .Warning)
	}
}

layers :: proc(s: State, d: ui.Dispatch(Msg)) {
	ui.section_heading("浮层 / LAYERS", "10", "menu · popover · dialog · tooltip · toast")

	menu_btn: ui.Response
	pop_btn: ui.Response
	if ui.row({gap = 8, align_y = .Center, wrap = true}) {
		menu_btn = ui.button("打开菜单", icon = ph.CARET_DOWN, variant = .Outline)
		if menu_btn.clicked do ui.dispatch(d, Set_Menu{v = !s.menu_open})
		ui.tooltip(menu_btn, "菜单、子菜单与快捷键")

		pop_btn = ui.button("打开浮层", icon = ph.SQUARES_FOUR, variant = .Outline)
		if pop_btn.clicked do ui.dispatch(d, Set_Popover{v = !s.popover_open})

		if ui.button("打开对话框", icon = ph.WARNING, variant = .Danger).clicked {
			ui.dispatch(d, Set_Dialog{v = true})
		}
		if ui.button("显示 Toast", icon = ph.BELL, variant = .Ghost).clicked {
			ui.dispatch(d, Show_Toast{label = "已更新"})
		}
	}
	if s.last_action != "" {
		ui.text(fmt.tprintf("最近一次操作：%s", s.last_action), .Metadata, .Muted)
	}

	// ---- The layers themselves, declared after the content that anchors them ----

	if ui.menu(d, Set_Menu{v = false}, s.menu_open, menu_btn, "actions") {
		if ui.menu_item("编辑", ph.TEXT_AA, "⌘E").clicked do ui.dispatch(d, Set_Action{label = "编辑"})
		if ui.menu_item("复制", ph.SQUARES_FOUR, "⌘C").clicked do ui.dispatch(d, Set_Action{label = "复制"})
		if ui.menu_item("粘贴", ph.PACKAGE, "⌘V", disabled = true).clicked {}
		if ui.menu_item("导出…", ph.DOWNLOAD_SIMPLE, submenu = true).clicked {
			ui.dispatch(d, Set_Action{label = "导出"})
		}
		if ui.menu_item("删除", ph.TRASH, "⌫", danger = true).clicked {
			ui.dispatch(d, Set_Action{label = "删除"})
		}
	}

	if ui.popover(d, Set_Popover{v = false}, s.popover_open, pop_btn, "filters", min_width = 280) {
		ui.text("筛选", .Label)
		ui.text("弹出层锚定在触发按钮上，空间不足时自动翻转。", .Compact, .Muted)
		if ui.checkbox(s.pop_check, "只看未读").changed do ui.dispatch(d, Set_Pop_Check{v = !s.pop_check})
		if ui.row({gap = 8, align_y = .Center, width = ui.grow()}) {
			ui.spacer()
			if ui.button("关闭", size = .Small, variant = .Ghost).clicked {
				ui.dispatch(d, Set_Popover{v = false})
			}
			if ui.button("应用", size = .Small, variant = .Primary).clicked {
				ui.dispatch(d, Set_Action{label = "应用筛选"})
			}
		}
	}

	if ui.dialog(d, Set_Dialog{v = false}, s.dialog_open, "删除全部数据？", 420) {
		ui.text("这个操作无法撤销。所有本地数据都会被移除。", .Body, .Muted)
		if ui.row({gap = 8, align_y = .Center, width = ui.grow()}) {
			ui.spacer()
			if ui.button("取消", variant = .Ghost).clicked do ui.dispatch(d, Set_Dialog{v = false})
			if ui.button("删除", icon = ph.TRASH, variant = .Danger).clicked {
				ui.dispatch(d, Set_Dialog{v = false})
				ui.dispatch(d, Set_Action{label = "已删除"})
				ui.dispatch(d, Show_Toast{label = "已删除全部数据"})
			}
		}
	}

	ui.toast(s.toast, "已更新", "设置已保存 · 4 秒后消失")
}

// ---- main ----

main :: proc() {
	window := ui.open_window({title = "控件总览", size = {980, 800}})
	defer ui.close_window(&window)

	store: ui.Store(State, Msg)
	state := State {
		checked   = true,
		toggle_on = true,
		radio     = 1,
		volume    = 0.6,
		progress  = 0.35,
		split     = 260,
	}
	state.sprite, state.sprite_px = make_sprite()
	ui.store_init(&store, &window, state, update, destroy = state_destroy)
	defer ui.store_destroy(&store)

	for ui.next_frame(&window) {
		view(store.state, ui.dispatcher(&store))
	}
}

state_destroy :: proc(s: ^State) {
	delete(s.sprite_px)
}

// A 160×100 RGBA8 gradient with a checkerboard: no asset files, and a version the backend can key
// its texture on (`ui.image` copies nothing; the app owns the pixels).
make_sprite :: proc() -> (img: ui.Image, px: []u8) {
	w, h := 160, 100
	px = make([]u8, w * h * 4)
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := (y * w + x) * 4
			u := f32(x) / f32(w - 1)
			v := f32(y) / f32(h - 1)
			checker := ((x / 16) + (y / 16)) % 2 == 0
			base := f32(0.25 if checker else 0.55)
			px[i + 0] = u8(255 * clamp(base + 0.35 * u, 0, 1))
			px[i + 1] = u8(255 * clamp(0.2 + 0.6 * (1 - v) * u, 0, 1))
			px[i + 2] = u8(255 * clamp(0.9 - 0.5 * u + 0.2 * math.sin(v * math.PI), 0, 1))
			px[i + 3] = 255
		}
	}
	return ui.Image{pixels = px, w = w, h = h, version = 1}, px
}
