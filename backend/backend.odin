// Rendering backend: the wgpu device, surfaces, and beginning and ending a frame.
package backend

import "base:runtime"
import "core:fmt"
import "core:math"

import wgpu "../third_party/odin/wgpu"
import "../platform"

Gpu :: struct {
	instance: wgpu.Instance,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
}

Surface :: struct {
	surface: wgpu.Surface,
	config:  wgpu.SurfaceConfiguration,
	// Whether the surface format is sRGB-encoded. If true, the GPU blends in linear space and colors
	// must be converted to linear before they are written. See ARCHITECTURE.md, "Rendering backend".
	srgb:    bool,
}

Frame :: struct {
	texture: wgpu.Texture,
	view:    wgpu.TextureView,
	encoder: wgpu.CommandEncoder,
}

@(private)
g_context: runtime.Context

// Set by the device-lost callback; see device_lost and recover.
@(private)
g_device_lost: bool

// Set while shutting down, so an intentional device release is not reported as a loss.
@(private)
g_shutting_down: bool

// Creates the GPU device and the surface of the first window.
init :: proc(window: ^platform.Window) -> (gpu: Gpu, surface: Surface, ok: bool) {
	g_context = context
	g_device_lost = false

	gpu.instance = wgpu.CreateInstance(nil)
	if gpu.instance == nil {
		fmt.eprintln("myod: failed to create a wgpu instance")
		return
	}

	surface.surface = create_surface(gpu.instance, window)
	if surface.surface == nil {
		fmt.eprintln("myod: failed to create a surface for the window")
		return
	}

	// wgpu-native completes these requests synchronously: the callback runs before the call returns.
	Adapter_Result :: struct {
		adapter: wgpu.Adapter,
		message: string,
	}
	adapter_result: Adapter_Result
	wgpu.InstanceRequestAdapter(
		gpu.instance,
		&{compatibleSurface = surface.surface, powerPreference = .LowPower},
		{
			callback = proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: string, userdata1, userdata2: rawptr) {
				context = g_context
				result := (^Adapter_Result)(userdata1)
				if status == .Success {
					result.adapter = adapter
				} else {
					result.message = fmt.aprintf("%v: %s", status, message)
				}
			},
			userdata1 = &adapter_result,
		},
	)
	if adapter_result.adapter == nil {
		fmt.eprintln("myod: failed to request a GPU adapter:", adapter_result.message)
		return
	}
	gpu.adapter = adapter_result.adapter

	Device_Result :: struct {
		device:  wgpu.Device,
		message: string,
	}
	device_result: Device_Result
	wgpu.AdapterRequestDevice(
		gpu.adapter,
		&{
			label = "myod",
			deviceLostCallbackInfo = {
				mode = .AllowSpontaneos, // sic: the binding spells it this way
				callback = proc "c" (device: ^wgpu.Device, reason: wgpu.DeviceLostReason, message: string, userdata1, userdata2: rawptr) {
					context = g_context
					if !g_shutting_down {
						fmt.eprintfln("myod: GPU device lost [%v] %s", reason, message)
						g_device_lost = true
					}
				},
			},
			uncapturedErrorCallbackInfo = {
				callback = proc "c" (device: ^wgpu.Device, type: wgpu.ErrorType, message: string, userdata1, userdata2: rawptr) {
					context = g_context
					fmt.eprintfln("myod: wgpu error [%v] %s", type, message)
				},
			},
		},
		{
			callback = proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: string, userdata1, userdata2: rawptr) {
				context = g_context
				result := (^Device_Result)(userdata1)
				if status == .Success {
					result.device = device
				} else {
					result.message = fmt.aprintf("%v: %s", status, message)
				}
			},
			userdata1 = &device_result,
		},
	)
	if device_result.device == nil {
		fmt.eprintln("myod: failed to request a GPU device:", device_result.message)
		return
	}
	gpu.device = device_result.device
	gpu.queue = wgpu.DeviceGetQueue(gpu.device)

	configure_surface(gpu, &surface, platform.pixel_size(window))
	ok = true
	return
}

shutdown :: proc(gpu: ^Gpu, surface: ^Surface) {
	g_shutting_down = true
	defer g_shutting_down = false
	wgpu.SurfaceRelease(surface.surface)
	wgpu.QueueRelease(gpu.queue)
	wgpu.DeviceRelease(gpu.device)
	wgpu.AdapterRelease(gpu.adapter)
	wgpu.InstanceRelease(gpu.instance)
}

// Picks a surface format and configures the surface.
// macOS: a non-sRGB format, blending in gamma space (matches browsers).
// Linux: an sRGB format, blending in linear space.
@(private)
configure_surface :: proc(gpu: Gpu, surface: ^Surface, size: [2]u32) {
	caps, status := wgpu.SurfaceGetCapabilities(surface.surface, gpu.adapter)
	defer wgpu.SurfaceCapabilitiesFreeMembers(caps)
	assert(status == .Success && caps.formatCount > 0, "myod: failed to query the formats supported by the surface")

	when ODIN_OS == .Darwin {
		preferred := [?]wgpu.TextureFormat{.BGRA8Unorm, .RGBA8Unorm}
	} else {
		preferred := [?]wgpu.TextureFormat{.BGRA8UnormSrgb, .RGBA8UnormSrgb}
	}

	formats := caps.formats[:caps.formatCount]
	format := formats[0]
	find: for want in preferred {
		for f in formats {
			if f == want {
				format = f
				break find
			}
		}
	}

	surface.srgb = format == .BGRA8UnormSrgb || format == .RGBA8UnormSrgb
	surface.config = wgpu.SurfaceConfiguration {
		device      = gpu.device,
		usage       = {.RenderAttachment},
		format      = format,
		width       = max(size.x, 1),
		height      = max(size.y, 1),
		presentMode = .Fifo,
		alphaMode   = .Opaque,
	}
	wgpu.SurfaceConfigure(surface.surface, &surface.config)
}

// Begins a frame, reconfiguring the surface first if the window size changed.
// Returns false when there is nothing to draw (window occluded or minimized, or the surface needs rebuilding).
begin_frame :: proc(gpu: Gpu, surface: ^Surface, size: [2]u32) -> (frame: Frame, ok: bool) {
	if size.x == 0 || size.y == 0 {
		return
	}

	// Touch the device before the surface: on a lost device, creating an encoder reports the loss
	// through the device-lost callback, while surface calls abort the process in wgpu-native.
	frame.encoder = wgpu.DeviceCreateCommandEncoder(gpu.device, nil)
	if g_device_lost {
		wgpu.CommandEncoderRelease(frame.encoder)
		return {}, false
	}

	if size.x != surface.config.width || size.y != surface.config.height {
		surface.config.width = size.x
		surface.config.height = size.y
		wgpu.SurfaceConfigure(surface.surface, &surface.config)
	}

	st := wgpu.SurfaceGetCurrentTexture(surface.surface)
	switch st.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Timeout, .Outdated, .Lost:
		if st.texture != nil {
			wgpu.TextureRelease(st.texture)
		}
		wgpu.SurfaceConfigure(surface.surface, &surface.config)
		wgpu.CommandEncoderRelease(frame.encoder)
		return {}, false
	case .Occluded:
		wgpu.CommandEncoderRelease(frame.encoder)
		return {}, false
	case .Error:
		fmt.panicf("myod: failed to get the surface texture: %v", st.status)
	}

	frame.texture = st.texture
	frame.view = wgpu.TextureCreateView(st.texture, nil)
	ok = true
	return
}

end_frame :: proc(gpu: Gpu, surface: ^Surface, frame: Frame) {
	commands := wgpu.CommandEncoderFinish(frame.encoder, nil)
	wgpu.QueueSubmit(gpu.queue, {commands})
	wgpu.SurfacePresent(surface.surface)

	wgpu.CommandBufferRelease(commands)
	wgpu.CommandEncoderRelease(frame.encoder)
	wgpu.TextureViewRelease(frame.view)
	wgpu.TextureRelease(frame.texture)
}

// Encodes an sRGB color (0–255) for this surface: non-sRGB formats take the sRGB values directly;
// sRGB formats need linear values, which the GPU encodes back to sRGB when writing.
encode_color :: proc(surface: Surface, c: [3]u8) -> [4]f32 {
	out: [4]f32 = {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, 1}
	if surface.srgb {
		for i in 0 ..< 3 {
			out[i] = srgb_to_linear(out[i])
		}
	}
	return out
}

@(private)
srgb_to_linear :: proc(v: f32) -> f32 {
	return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
}

// Reports whether the GPU device was lost (driver update, GPU reset, external GPU unplugged).
// After a loss, call recover and recreate every GPU resource. Nothing lives only on the GPU,
// so the next frame draws normally (see ARCHITECTURE.md, "Rendering backend").
//
// wgpu-native reports a loss when an operation on the lost device fails, not when the device
// goes away: the frame that hits the loss is dropped, and the next frame recovers.
device_lost :: proc(gpu: Gpu) -> bool {
	wgpu.InstanceProcessEvents(gpu.instance)
	return g_device_lost
}

// Releases the lost device and creates a new one, along with a new surface for the window.
recover :: proc(gpu: ^Gpu, surface: ^Surface, window: ^platform.Window) -> bool {
	shutdown(gpu, surface)
	ok: bool
	gpu^, surface^, ok = init(window)
	return ok
}

// Destroys the device on purpose, to exercise the device-loss path.
debug_lose_device :: proc(gpu: Gpu) {
	wgpu.DeviceDestroy(gpu.device)
}
