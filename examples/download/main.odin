// Background tasks: tasks can only be started and cancelled from update; their results and progress
// come back to update as messages. Simulates a download with progress, cancellation and optional failure.
package download

import "core:strings"
import "core:time"

import ph "myod:icons/phosphor"
import ui "myod:ui"

// ---- State ----

Status :: enum {
	Idle,
	Running,
	Cancelling, // cancellation requested, waiting for the task to confirm
	Done,
	Failed,
	Cancelled,
}

State :: struct {
	status:           Status,
	progress:         f32,
	error:            string,
	simulate_failure: bool,
	job:              ui.Task_Id, // the running task; whether a task is running is itself part of the state
}

// ---- Messages ----

// From the UI
Start :: struct {}
Cancel :: struct {}
Set_Simulate_Failure :: distinct bool

// From the background task
Progress :: distinct f32
Done :: struct {}
Failed :: struct {
	reason: string,
}
Cancelled :: struct {}

Msg :: union {
	Start,
	Cancel,
	Set_Simulate_Failure,
	Progress,
	Done,
	Failed,
	Cancelled,
}

// ---- update: every transition of the state machine lives here ----

update :: proc(s: ^State, msg: Msg, fx: ^ui.Effects(Msg)) {
	switch m in msg {
	case Start:
		if s.status == .Running || s.status == .Cancelling do return // already running, ignore
		s.status = .Running
		s.progress = 0
		replace(&s.error, "")
		// Starting a task is an effect, so it happens in update. Arguments are copied to the task by value.
		s.job = ui.start_task(fx, download, Download_Args{simulate_failure = s.simulate_failure})

	case Cancel:
		if s.status != .Running do return
		ui.cancel_task(fx, s.job) // only a request; the task replies with Cancelled
		s.status = .Cancelling

	case Set_Simulate_Failure:
		s.simulate_failure = bool(m)

	case Progress:
		s.progress = f32(m)

	case Done:
		s.status = .Done
		s.job = {}

	case Failed:
		s.status = .Failed
		replace(&s.error, m.reason) // strings in messages only live until update returns; clone to keep
		s.job = {}

	case Cancelled:
		s.status = .Cancelled
		s.job = {}
	}
}

// ---- view ----

view :: proc(s: State, d: ui.Dispatch(Msg)) {
	busy := s.status == .Running || s.status == .Cancelling

	if ui.column({padding = 24, gap = 16}) {
		if ui.row({gap = 8, align_y = .Center}) {
			ui.text("下载", .Section)
			ui.spacer()
			status_tag(s.status)
		}

		ui.progress(s.progress)

		if s.status == .Failed {
			ui.text(s.error, .Metadata, color = .Error)
		}

		if ui.row({gap = 8, align_y = .Center}) {
			// disabled is presentation only; the real rule lives in update, which ignores stray messages.
			if ui.button("开始", icon = ph.DOWNLOAD_SIMPLE, variant = .Primary, disabled = busy).clicked {
				ui.dispatch(d, Start{})
			}
			if ui.button("取消", icon = ph.X, disabled = s.status != .Running).clicked {
				ui.dispatch(d, Cancel{})
			}
			ui.spacer()
			if ui.checkbox(s.simulate_failure, "模拟失败", disabled = busy).changed {
				ui.dispatch(d, Set_Simulate_Failure(!s.simulate_failure))
			}
		}
	}
}

// Status is shown as a tag: color is the signal, the text says what it means.
status_tag :: proc(status: Status) {
	switch status {
	case .Idle:       ui.tag("未开始", .Muted)
	case .Running:    ui.tag("下载中", .Info)
	case .Cancelling: ui.tag("正在取消", .Warning)
	case .Done:       ui.tag("完成", .Success)
	case .Failed:     ui.tag("失败", .Error)
	case .Cancelled:  ui.tag("已取消", .Muted)
	}
}

// ---- Background task: runs on a thread managed by the library ----
// It must not touch State; it can only emit messages, and returns one final message as its result.

Download_Args :: struct {
	simulate_failure: bool,
}

download :: proc(t: ^ui.Task_Context(Msg), args: Download_Args) -> Msg {
	for i in 1 ..= 100 {
		if ui.cancelled(t) do return Cancelled{}
		if args.simulate_failure && i == 70 do return Failed{reason = "连接被重置"}

		time.sleep(30 * time.Millisecond) // simulate downloading a chunk
		ui.emit(t, Progress(f32(i) / 100)) // sent to update; wakes the UI thread
	}
	return Done{}
}

main :: proc() {
	window := ui.open_window({title = "下载", size = {420, 220}})
	defer ui.close_window(&window)

	// store_destroy cancels and waits for every task first, then calls destroy to free the state.
	store: ui.Store(State, Msg)
	ui.store_init(&store, &window, State{}, update, destroy = state_destroy)
	defer ui.store_destroy(&store)

	for ui.next_frame(&window) {
		view(store.state, ui.dispatcher(&store))
	}
}

replace :: proc(dst: ^string, src: string) {
	old := dst^
	dst^ = strings.clone(src)
	delete(old)
}

state_destroy :: proc(s: ^State) {
	delete(s.error)
}
