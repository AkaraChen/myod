package backend

import sdl "../third_party/odin/sdl3"
import wgpu "../third_party/odin/wgpu"
import "../platform"

@(private)
create_surface :: proc(instance: wgpu.Instance, window: ^platform.Window) -> wgpu.Surface {
	// Create the Metal view once per window and keep it, so recovering from device loss
	// reuses the same layer instead of stacking new views.
	if window.gpu_view == nil {
		window.gpu_view = rawptr(sdl.Metal_CreateView(window.handle))
	}
	layer := sdl.Metal_GetLayer(sdl.MetalView(window.gpu_view))
	return wgpu.InstanceCreateSurface(
		instance,
		&wgpu.SurfaceDescriptor{
			nextInChain = &wgpu.SurfaceSourceMetalLayer{
				chain = {sType = .SurfaceSourceMetalLayer},
				layer = layer,
			},
		},
	)
}
