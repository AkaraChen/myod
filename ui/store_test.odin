// Tests of the store's asynchronous half: tasks, timers and the inbox (ARCHITECTURE.md,
// "API design → 5, 7"). The harness has no window or GPU, so these test the queues and the message
// phase; the wake-up itself is the platform layer's job.
package ui

import "core:testing"
import "core:thread"
import "core:time"

Task_State :: struct {
	runs:  int,
	ticks: int,
}

Start_Task :: struct {}
Task_Done :: struct {}
Set_Timer :: struct {}
Tick :: struct {}

Task_Msg :: union {
	Start_Task,
	Task_Done,
	Set_Timer,
	Tick,
}

task_update :: proc(s: ^Task_State, msg: Task_Msg, fx: ^Effects(Task_Msg)) {
	switch m in msg {
	case Start_Task:
		start_task(fx, task_work, 0)
	case Task_Done:
		s.runs += 1
	case Set_Timer:
		after(fx, 5 * time.Millisecond, Tick{})
	case Tick:
		s.ticks += 1
	}
}

task_view :: proc(s: Task_State, d: Dispatch(Task_Msg)) {
	if column() {
		if button("run").clicked {
			dispatch(d, Start_Task{})
		}
		text("done")
	}
}

// The task runs on a library thread and its return value arrives as a message.
task_work :: proc(t: ^Task_Context(Task_Msg), arg: int) -> Task_Msg {
	time.sleep(5 * time.Millisecond)
	return Task_Done{}
}

// Polls until the store has something for `update`, with a deadline so a broken build fails instead
// of hanging.
wait_pending :: proc(h: ^Test_Harness(Task_State, Task_Msg)) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 2*time.Second {
		if h.window.ops.pending(h.window.store) {
			return true
		}
		time.sleep(time.Millisecond)
	}
	return false
}

@(test)
task_messages_reach_update :: proc(t: ^testing.T) {
	h := test_harness(Task_State{}, task_update, task_view)
	defer test_destroy(h)

	testing.expect(t, test_click(h, .Button, "run"), "the run button could not be clicked")
	testing.expect(t, wait_pending(h), "the task's message never reached the store")
	test_frame(h)
	testing.expect_value(t, h.store.state.runs, 1)
}

@(test)
timers_fire_through_update :: proc(t: ^testing.T) {
	h := test_harness(Task_State{}, task_update, task_view)
	defer test_destroy(h)

	dispatch(dispatcher(&h.store), Set_Timer{})
	test_frame(h)
	time.sleep(5 * time.Millisecond)
	test_frame(h)
	testing.expect_value(t, h.store.state.ticks, 1)
}

// Inbox is the low-level primitive the tasks are built on: safe to send to from any thread.
@(test)
inbox_roundtrip :: proc(t: ^testing.T) {
	ib: Inbox(int)
	th := thread.create(proc(th: ^thread.Thread) {
		ib := (^Inbox(int))(th.data)
		for i in 0 ..< 100 {
			inbox_send(ib, i)
		}
	})
	th.data = &ib
	thread.start(th)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, len(ib.q.msgs), 100)
	testing.expect_value(t, ib.q.msgs[99], 99)
	delete(ib.q.msgs)
}
