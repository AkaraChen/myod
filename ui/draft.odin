// API draft for what later milestones implement: signatures only, no implementation. It lets the API
// examples (counter, todomvc, download) type-check; the real implementation replaces it milestone by
// milestone (see ROADMAP.md). See ARCHITECTURE.md, "API design".
package ui

import "base:intrinsics"

// ---- Windows and the frame loop ----
Window_Options :: struct { title: string, size: [2]int }
Window :: struct { _: rawptr }
open_window :: proc(opts: Window_Options) -> Window { return {} }
close_window :: proc(w: ^Window) {}
next_frame :: proc(w: ^Window) -> bool { return false }
@(deferred_out = _window_scope_end) window_scope :: proc(w: ^Window) -> bool { return true }
_window_scope_end :: proc(ok: bool) {}

// ---- Store ----
Store :: struct($S, $M: typeid) { state: S, _: rawptr }
Dispatch :: struct($M: typeid) { _: rawptr }
Effects :: struct($M: typeid) { _: rawptr }
store_init :: proc(store: ^Store($S, $M), w: ^Window, state: S, update: proc(s: ^S, msg: M, fx: ^Effects(M)), destroy: proc(s: ^S) = nil) {}
store_destroy :: proc(store: ^Store($S, $M)) {}
dispatcher :: proc(store: ^Store($S, $M)) -> Dispatch(M) { return {} }
dispatch :: proc(d: Dispatch($M), msg: M) {}

// ---- Effects (only callable from update) ----
Task_Id :: distinct u64
Task_Context :: struct($M: typeid) { _: rawptr }
start_task :: proc(fx: ^Effects($M), task: proc(t: ^Task_Context(M), arg: $A) -> M, arg: A) -> Task_Id { return 0 }
cancel_task :: proc(fx: ^Effects($M), id: Task_Id) {}
focus :: proc(fx: ^Effects($M), key: string) {}
emit :: proc(t: ^Task_Context($M), msg: M) {}
cancelled :: proc(t: ^Task_Context($M)) -> bool { return false }

// ---- Low-level primitives for custom stores ----
Inbox :: struct($T: typeid) { _: rawptr }
wake :: proc(w: ^Window) {}

// ---- Widgets ----
Button_Variant :: enum { Outline, Primary, Ghost, Danger }
Control_Size :: enum { Default, Small }

button :: proc(label: string, icon: Icon = {}, variant: Button_Variant = .Outline, size: Control_Size = .Default, disabled := false) -> Response { return {} }
icon_button :: proc(icon: Icon, label: string, variant: Button_Variant = .Outline, size: Control_Size = .Default, disabled := false) -> Response { return {} }
checkbox :: proc(value: bool, label := "", disabled := false) -> Response { return {} }
text_input :: proc(label: string, value: string, width: Size = {}, hide_label := false, autofocus := false, key := "", error := "") -> (Response, string) { return {}, "" }
tabs :: proc(value: $E, labels: [E]string) -> (Response, E) where intrinsics.type_is_enum(E) { return {}, value }
progress :: proc(value: f32) -> Response { return {} }
tag :: proc(label: string, color: Color = .Muted) -> Response { return {} }
