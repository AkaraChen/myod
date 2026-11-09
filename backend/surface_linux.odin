package backend

import sdl "../third_party/odin/sdl3"
import wgpu "../third_party/odin/wgpu"
import "../platform"

@(private)
create_surface :: proc(instance: wgpu.Instance, window: ^platform.Window) -> wgpu.Surface {
	props := sdl.GetWindowProperties(window.handle)
	switch sdl.GetCurrentVideoDriver() {
	case "wayland":
		return wgpu.InstanceCreateSurface(
			instance,
			&wgpu.SurfaceDescriptor{
				nextInChain = &wgpu.SurfaceSourceWaylandSurface{
					chain = {sType = .SurfaceSourceWaylandSurface},
					display = sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nil),
					surface = sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WAYLAND_SURFACE_POINTER, nil),
				},
			},
		)
	case "x11":
		return wgpu.InstanceCreateSurface(
			instance,
			&wgpu.SurfaceDescriptor{
				nextInChain = &wgpu.SurfaceSourceXlibWindow{
					chain = {sType = .SurfaceSourceXlibWindow},
					display = sdl.GetPointerProperty(props, sdl.PROP_WINDOW_X11_DISPLAY_POINTER, nil),
					window = u64(sdl.GetNumberProperty(props, sdl.PROP_WINDOW_X11_WINDOW_NUMBER, 0)),
				},
			},
		)
	}
	return nil
}
