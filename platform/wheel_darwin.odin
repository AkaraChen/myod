#+build darwin
package platform

import NSApp "vendor:darwin/AppKit"

// SDL reports wheel events in "lines" and drops what macOS knows about them. While SDL dispatches
// the event (the event watch runs synchronously inside AppKit's event handling), the NSEvent that
// caused it is still `[NSApp currentEvent]`: read the precise deltas and the gesture phases there.
@(private)
native_wheel :: proc() -> (info: Wheel_Info, ok: bool) {
	e := NSApp.Application_currentEvent(NSApp.Application_sharedApplication())
	if e == nil || NSApp.Event_type(e) != .ScrollWheel {
		return {}, false
	}
	info.precise = NSApp.Event_hasPreciseScrollingDeltas(e)
	// scrollingDelta follows the user's scroll direction setting: positive y moves content down.
	// Precise deltas are in points; others are in lines.
	info.delta = {-f32(NSApp.Event_scrollingDeltaX(e)), f32(NSApp.Event_scrollingDeltaY(e))}
	info.phase = phase(NSApp.Event_phase(e), false)
	if momentum := NSApp.Event_momentumPhase(e); momentum != NSApp.EventPhase_None {
		info.phase = phase(momentum, true)
	}
	return info, true
}

@(private = "file")
phase :: proc(p: NSApp.EventPhase, momentum: bool) -> Wheel_Phase {
	switch {
	case .Began in p, .MayBegin in p:
		return .Momentum if momentum else .Began
	case .Changed in p, .Stationary in p:
		return .Momentum if momentum else .Changed
	case .Ended in p:
		return .Momentum_Ended if momentum else .Ended
	case .Cancelled in p:
		return .Momentum_Ended if momentum else .Cancelled
	}
	return .None
}
