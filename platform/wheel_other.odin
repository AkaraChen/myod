#+build !darwin
package platform

// Elsewhere SDL's wheel event is all there is.
@(private)
native_wheel :: proc() -> (info: Wheel_Info, ok: bool) {
	return {}, false
}
