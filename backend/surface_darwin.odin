package backend

import sdl "../third_party/odin/sdl3"
import wgpu "../third_party/odin/wgpu"
import "../platform"

@(private)
create_surface :: proc(instance: wgpu.Instance, window: ^platform.Window) -> wgpu.Surface {
	view := sdl.Metal_CreateView(window.handle)
	layer := sdl.Metal_GetLayer(view)
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
