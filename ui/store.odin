// The Store: state, messages, update, side effects and background tasks
// (ARCHITECTURE.md, "API design → 1, 5, 7").
//
//	State, Msg, update, view
//	store_init(&store, &window, State{}, update)
//	for ui.next_frame(&window) { view(store.state, ui.dispatcher(&store)) }
//
// Messages sent from `view` are held in the pass's buffer and only enter the queue when the pass is
// accepted (a ghost pass drops them, API design → 2). `update` is the only place that changes state,
// and effects are the only way to start side work: tasks, timers, focus.
package ui

import "core:sync"
import "core:thread"
import "core:time"

import "../core"
import "../platform"

Task_Id :: distinct u64

Timer :: struct($M: typeid) {
	deadline: u64, // ms since the platform layer started
	msg:      M,
}

// The M-typed half of the store, reachable from Dispatch and Effects without knowing State.
Mailbox :: struct($M: typeid) {
	window:    ^Window,
	sent:      [dynamic]M, // sent during the pass being declared
	queue:     [dynamic]M, // ready for update
	timers:    [dynamic]Timer(M),
	focus:     [256]u8,
	focus_key: string,
	scroll:    [256]u8,
	scroll_key: string,
	scroll_index: int,
	scroll_visible: bool, // the request names a widget to reveal, not a list index
	scroll_has: bool,
	next_task: Task_Id,
}

Dispatch :: struct($M: typeid) {
	mail: ^Mailbox(M),
}

// Sends a message from `view`. The message is only delivered if the pass it was sent from is
// accepted.
dispatch :: proc(d: Dispatch($M), msg: M) {
	append(&d.mail.sent, msg)
}

Task_Context :: struct($M: typeid) {
	id:        Task_Id,
	queue:     ^Task_Queue(M),
	cancelled: ^bool,
	window:    platform.Window_Id,
	start:     time.Tick, // when the task started, for the pending state
	last:      time.Tick, // the task's most recent emit
}

@(private)
Task_Queue :: struct($M: typeid) {
	msgs: [dynamic]M,
	mu:   sync.Mutex,
}

// A message queue for low-level use (ARCHITECTURE.md, "API design → 7"). Safe to send from any
// thread; sending wakes the window.
Inbox :: struct($T: typeid) {
	q: Task_Queue(T),
}

inbox_send :: proc(inbox: ^Inbox($T), msg: T) {
	sync.mutex_lock(&inbox.q.mu)
	append(&inbox.q.msgs, msg)
	sync.mutex_unlock(&inbox.q.mu)
}

// ---- Task liveness, for the pending state ----
//
// The pending state shows how long a task has run and how long ago it last emitted, without the app
// having to carry timestamps through its state. The registry is written by the task thread (on
// start and on every emit) and read by `view`.

@(private)
Task_Meta :: struct {
	start, last: time.Tick,
}

@(private)
task_meta_mu: sync.Mutex
@(private)
task_meta: map[Task_Id]Task_Meta

@(private)
record_task_start :: proc(id: Task_Id) {
	sync.mutex_lock(&task_meta_mu)
	now := time.tick_now()
	task_meta[id] = {start = now, last = now}
	sync.mutex_unlock(&task_meta_mu)
}

@(private)
record_task_activity :: proc(id: Task_Id) {
	sync.mutex_lock(&task_meta_mu)
	if m, ok := task_meta[id]; ok {
		m.last = time.tick_now()
		task_meta[id] = m
	}
	sync.mutex_unlock(&task_meta_mu)
}

@(private)
record_task_end :: proc(id: Task_Id) {
	sync.mutex_lock(&task_meta_mu)
	delete_key(&task_meta, id)
	sync.mutex_unlock(&task_meta_mu)
}

// How long a task has been running and how long ago it last emitted something.
task_times :: proc(id: Task_Id) -> (elapsed, idle: time.Duration, ok: bool) {
	sync.mutex_lock(&task_meta_mu)
	m, found := task_meta[id]
	sync.mutex_unlock(&task_meta_mu)
	if !found {
		return 0, 0, false
	}
	now := time.tick_now()
	return time.tick_diff(m.start, now), time.tick_diff(m.last, now), true
}

// ---- Effects ----

Store_Api :: struct($M: typeid) {
	after:    proc(store: rawptr, delay_ms: u64, msg: ^M),
	focus:    proc(store: rawptr, key: string),
	scroll:   proc(store: rawptr, key: string, index: int),
	scroll_visible: proc(store: rawptr, key: string),
	add_task: proc(store: rawptr, th: ^thread.Thread, q: ^Task_Queue(M), cancelled: ^bool, data: rawptr) -> Task_Id,
	cancel:   proc(store: rawptr, id: Task_Id),
}

Effects :: struct($M: typeid) {
	store:  rawptr,
	api:    ^Store_Api(M),
	window: platform.Window_Id,
}

// Runs `task` on a library-managed thread; its return value is sent to `update` as a message.
// Arguments are copied by value.
start_task :: proc(fx: ^Effects($M), task: proc(t: ^Task_Context(M), arg: $A) -> M, arg: A) -> Task_Id {
	when ODIN_DEBUG {
		assert(fx.store != nil, "myod: an effect was used outside update")
	}
	d := new(Task_Run(M, A))
	d.task = task
	d.arg = arg
	d.ctx.queue = &d.queue
	d.ctx.cancelled = &d.cancelled
	d.ctx.window = fx.window
	d.ctx.start = time.tick_now()
	d.ctx.last = d.ctx.start
	th := thread.create(task_entry(M, A), name = "myod task")
	th.data = d
	d.ctx.id = fx.api.add_task(fx.store, th, &d.queue, &d.cancelled, d)
	record_task_start(d.ctx.id)
	thread.start(th)
	if d.ctx.window != 0 {
		platform.wake(d.ctx.window)
	}
	return d.ctx.id
}

// Requests cancellation; the task must check `cancelled` itself.
cancel_task :: proc(fx: ^Effects($M), id: Task_Id) {
	fx.api.cancel(fx.store, id)
}

// Sends a message to `update` immediately; wakes the UI thread.
emit :: proc(t: ^Task_Context($M), msg: M) {
	sync.mutex_lock(&t.queue.mu)
	append(&t.queue.msgs, msg)
	sync.mutex_unlock(&t.queue.mu)
	t.last = time.tick_now()
	record_task_activity(t.id)
	if t.window != 0 {
		platform.wake(t.window)
	}
}

// Whether the task has been asked to stop.
cancelled :: proc(t: ^Task_Context($M)) -> bool {
	return sync.atomic_load(t.cancelled)
}

// Sends `msg` to `update` when `delay` has passed. Timers are not cancelled: filter stale ones with
// a generation token in the message.
after :: proc(fx: ^Effects($M), delay: time.Duration, msg: M) {
	deadline := platform.ticks_ms() + u64(max(time.duration_milliseconds(delay), 0))
	m := msg
	fx.api.after(fx.store, deadline, &m)
}

// Focuses the widget that declared `key` (ARCHITECTURE.md, "API design → 3").
focus :: proc(fx: ^Effects($M), key: string) {
	fx.api.focus(fx.store, key)
}

// Scrolls the virtual list that declared `key` so row `index` is visible, moving as little as
// possible. Like `focus`, it resolves the key against the last pass.
scroll_to_index :: proc(fx: ^Effects($M), key: string, index: int) {
	fx.api.scroll(fx.store, key, index)
}

// Scrolls the nearest scroll containers so the widget that declared `key` is fully visible, moving
// as little as possible (ARCHITECTURE.md, "API design → 15").
scroll_to :: proc(fx: ^Effects($M), key: string) {
	fx.api.scroll_visible(fx.store, key)
}

@(private)
Task_Run :: struct($M, $A: typeid) {
	task:      proc(t: ^Task_Context(M), arg: A) -> M,
	arg:       A,
	ctx:       Task_Context(M),
	queue:     Task_Queue(M),
	cancelled: bool,
}

// The thread's entry point. The returned proc is monomorphized with the task's types.
@(private)
task_entry :: proc($M: typeid, $A: typeid) -> thread.Thread_Proc {
	return proc(t: ^thread.Thread) {
		d := (^Task_Run(M, A))(t.data)
		msg := d.task(&d.ctx, d.arg)
		emit(&d.ctx, msg)
	}
}

// ---- Store ----

Store_Ops :: struct {
	process:        proc(store: rawptr) -> bool,
	pending:        proc(store: rawptr) -> bool,
	commit:         proc(store: rawptr),
	discard:        proc(store: rawptr),
	timer_deadline: proc(store: rawptr) -> (u64, bool),
	timer_due:      proc(store: rawptr, now: u64) -> bool,
	run_timers:     proc(store: rawptr, now: u64) -> bool,
	join:           proc(store: rawptr),
}

@(private)
Task_Handle :: struct($M: typeid) {
	id:        Task_Id,
	th:        ^thread.Thread,
	q:         ^Task_Queue(M),
	cancelled: ^bool,
	data:      rawptr,
}

Store :: struct($S, $M: typeid) {
	window:     ^Window,
	state:      S,
	update:     proc(s: ^S, msg: M, fx: ^Effects(M)),
	destroy_proc: proc(s: ^S),
	mail:       ^Mailbox(M),
	api:        Store_Api(M),
	ops:        Store_Ops,
	tasks:      [dynamic]Task_Handle(M),
}

// Creates the store and attaches it to `w`. `destroy` (optional) is called by store_destroy after
// all tasks have stopped.
store_init :: proc(
	store: ^Store($S, $M),
	w: ^Window,
	state: S,
	update: proc(s: ^S, msg: M, fx: ^Effects(M)),
	destroy: proc(s: ^S) = nil,
) {
	store.window = w
	store.state = state
	store.update = update
	store.destroy_proc = destroy
	store.mail = new(Mailbox(M))
	store.mail.window = w
	store.api = Store_Api(M) {
		after    = api_after(S, M),
		focus    = api_focus(S, M),
		scroll   = api_scroll(S, M),
		scroll_visible = api_scroll_visible(S, M),
		add_task = api_add_task(S, M),
		cancel   = api_cancel(S, M),
	}
	store.ops = Store_Ops {
		process        = ops_process(S, M),
		pending        = ops_pending(S, M),
		commit         = ops_commit(S, M),
		discard        = ops_discard(S, M),
		timer_deadline = ops_timer_deadline(S, M),
		timer_due      = ops_timer_due(S, M),
		run_timers     = ops_run_timers(S, M),
		join           = ops_join(S, M),
	}
	w.store = store
	w.ops = &store.ops
}

store_destroy :: proc(store: ^Store($S, $M)) {
	ops_join(S, M)(store)
	if store.destroy_proc != nil {
		store.destroy_proc(&store.state)
	}
	delete(store.mail.sent)
	delete(store.mail.queue)
	delete(store.mail.timers)
	free(store.mail)
	delete(store.tasks)
	store.window.store = nil
	store.window.ops = nil
}

// The dispatch function for `view`.
dispatcher :: proc(store: ^Store($S, $M)) -> Dispatch(M) {
	return {mail = store.mail}
}

// ---- The ops, monomorphized ----

@(private)
ops_commit :: proc($S: typeid, $M: typeid) -> proc(store: rawptr) {
	return proc(store: rawptr) {
		s := (^Store(S, M))(store)
		append(&s.mail.queue, ..s.mail.sent[:])
		clear(&s.mail.sent)
	}
}

@(private)
ops_discard :: proc($S: typeid, $M: typeid) -> proc(store: rawptr) {
	return proc(store: rawptr) {
		s := (^Store(S, M))(store)
		clear(&s.mail.sent)
	}
}

@(private)
ops_pending :: proc($S: typeid, $M: typeid) -> proc(store: rawptr) -> bool {
	return proc(store: rawptr) -> bool {
		s := (^Store(S, M))(store)
		if len(s.mail.sent) > 0 || len(s.mail.queue) > 0 {
			return true
		}
		for &t in s.tasks {
			sync.mutex_lock(&t.q.mu)
			n := len(t.q.msgs)
			sync.mutex_unlock(&t.q.mu)
			if n > 0 {
				return true
			}
		}
		return false
	}
}

@(private)
ops_process :: proc($S: typeid, $M: typeid) -> proc(store: rawptr) -> bool {
	return proc(store: rawptr) -> bool {
		s := (^Store(S, M))(store)
		ops_commit(S, M)(store)
		// Collect what the tasks sent, then let go of finished threads.
		for &t in s.tasks {
			sync.mutex_lock(&t.q.mu)
			append(&s.mail.queue, ..t.q.msgs[:])
			clear(&t.q.msgs)
			sync.mutex_unlock(&t.q.mu)
		}
		reap_tasks(S, M)(store)
		n := len(s.mail.queue)
		fx := Effects(M){store = store, api = &s.api}
		if s.window.p != nil {
			fx.window = s.window.p.id
		}
		for i := 0; i < n; i += 1 {
			s.update(&s.state, s.mail.queue[i], &fx)
			if s.mail.focus_key != "" {
				request_focus(s.window, s.mail.focus_key)
				s.mail.focus_key = ""
			}
			if s.mail.scroll_has {
				s.mail.scroll_has = false
				if id, ok := core.name_id(&s.window.ctx, s.mail.scroll_key); ok {
					if s.mail.scroll_visible {
						core.ensure_visible(&s.window.ctx, id)
					} else {
						core.request_scroll_to_index(&s.window.ctx, id, s.mail.scroll_index)
					}
				}
			}
		}
		clear(&s.mail.queue)
		return n > 0
	}
}

@(private)
reap_tasks :: proc($S: typeid, $M: typeid) -> proc(store: rawptr) {
	return proc(store: rawptr) {
		s := (^Store(S, M))(store)
		for i := len(s.tasks) - 1; i >= 0; i -= 1 {
			t := &s.tasks[i]
			if !thread.is_done(t.th) {
				continue
			}
			thread.join(t.th)
			thread.destroy(t.th)
			record_task_end(t.id)
			free(t.data)
			ordered_remove(&s.tasks, i)
		}
	}
}

@(private)
ops_join :: proc($S: typeid, $M: typeid) -> proc(store: rawptr) {
	return proc(store: rawptr) {
		s := (^Store(S, M))(store)
		for &t in s.tasks {
			sync.atomic_store(t.cancelled, true)
		}
		for &t in s.tasks {
			thread.join(t.th)
			thread.destroy(t.th)
			record_task_end(t.id)
			free(t.data)
		}
		clear(&s.tasks)
	}
}

@(private)
ops_timer_deadline :: proc($S: typeid, $M: typeid) -> proc(store: rawptr) -> (u64, bool) {
	return proc(store: rawptr) -> (deadline: u64, ok: bool) {
		s := (^Store(S, M))(store)
		for t in s.mail.timers {
			if !ok || t.deadline < deadline {
				deadline = t.deadline
				ok = true
			}
		}
		return
	}
}

@(private)
ops_timer_due :: proc($S: typeid, $M: typeid) -> proc(store: rawptr, now: u64) -> bool {
	return proc(store: rawptr, now: u64) -> bool {
		s := (^Store(S, M))(store)
		for t in s.mail.timers {
			if t.deadline <= now {
				return true
			}
		}
		return false
	}
}

@(private)
ops_run_timers :: proc($S: typeid, $M: typeid) -> proc(store: rawptr, now: u64) -> bool {
	return proc(store: rawptr, now: u64) -> bool {
		s := (^Store(S, M))(store)
		fired := false
		for i := 0; i < len(s.mail.timers); {
			if s.mail.timers[i].deadline <= now {
				append(&s.mail.queue, s.mail.timers[i].msg)
				ordered_remove(&s.mail.timers, i)
				fired = true
			} else {
				i += 1
			}
		}
		return fired
	}
}

@(private)
api_after :: proc($S: typeid, $M: typeid) -> proc(store: rawptr, deadline: u64, msg: ^M) {
	return proc(store: rawptr, deadline: u64, msg: ^M) {
		s := (^Store(S, M))(store)
		append(&s.mail.timers, Timer(M){deadline = deadline, msg = msg^})
	}
}

@(private)
api_focus :: proc($S: typeid, $M: typeid) -> proc(store: rawptr, key: string) {
	return proc(store: rawptr, key: string) {
		s := (^Store(S, M))(store)
		n := min(copy(s.mail.focus[:], key), len(s.mail.focus))
		s.mail.focus_key = string(s.mail.focus[:n])
	}
}

@(private)
api_scroll :: proc($S: typeid, $M: typeid) -> proc(store: rawptr, key: string, index: int) {
	return proc(store: rawptr, key: string, index: int) {
		s := (^Store(S, M))(store)
		n := min(copy(s.mail.scroll[:], key), len(s.mail.scroll))
		s.mail.scroll_key = string(s.mail.scroll[:n])
		s.mail.scroll_index = index
		s.mail.scroll_visible = false
		s.mail.scroll_has = true
	}
}

@(private)
api_scroll_visible :: proc($S: typeid, $M: typeid) -> proc(store: rawptr, key: string) {
	return proc(store: rawptr, key: string) {
		s := (^Store(S, M))(store)
		n := min(copy(s.mail.scroll[:], key), len(s.mail.scroll))
		s.mail.scroll_key = string(s.mail.scroll[:n])
		s.mail.scroll_visible = true
		s.mail.scroll_has = true
	}
}

@(private)
api_add_task :: proc($S: typeid, $M: typeid) -> proc(store: rawptr, th: ^thread.Thread, q: ^Task_Queue(M), cancelled: ^bool, data: rawptr) -> Task_Id {
	return proc(store: rawptr, th: ^thread.Thread, q: ^Task_Queue(M), cancelled: ^bool, data: rawptr) -> Task_Id {
		s := (^Store(S, M))(store)
		s.mail.next_task += 1
		id := s.mail.next_task
		append(&s.tasks, Task_Handle(M){id = id, th = th, q = q, cancelled = cancelled, data = data})
		return id
	}
}

@(private)
api_cancel :: proc($S: typeid, $M: typeid) -> proc(store: rawptr, id: Task_Id) {
	return proc(store: rawptr, id: Task_Id) {
		s := (^Store(S, M))(store)
		for &t in s.tasks {
			if t.id == id {
				sync.atomic_store(t.cancelled, true)
			}
		}
	}
}
