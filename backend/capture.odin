// Offscreen rendering with CPU readback, for automated pixel checks in tests and self-tests.
package backend

import "base:runtime"

import wgpu "../third_party/odin/wgpu"
import "../render"

// Pixels read back from the GPU, tightly packed RGBA8 in sRGB, row-major from the top-left.
Capture :: struct {
	width, height: u32,
	pixels:        []u8,
}

// Renders `list` into an offscreen texture of the renderer's format and reads it back.
// The result is allocated with `allocator`.
capture :: proc(
	gpu: Gpu,
	r: ^Renderer,
	size: [2]u32,
	scale: f32,
	list: render.Command_List,
	clear: render.Color,
	allocator := context.allocator,
) -> (out: Capture, ok: bool) {
	texture := wgpu.DeviceCreateTexture(
		gpu.device,
		&{
			label = "myod capture",
			usage = {.RenderAttachment, .CopySrc},
			dimension = ._2D,
			size = {size.x, size.y, 1},
			format = r.format,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	defer wgpu.TextureRelease(texture)
	view := wgpu.TextureCreateView(texture, nil)
	defer wgpu.TextureViewRelease(view)

	// Buffer rows must be aligned to 256 bytes.
	row_bytes := size.x * 4
	padded := (row_bytes + 255) & ~u32(255)
	buffer_size := u64(padded) * u64(size.y)
	buffer := wgpu.DeviceCreateBuffer(gpu.device, &{label = "myod capture readback", usage = {.CopyDst, .MapRead}, size = buffer_size})
	defer wgpu.BufferRelease(buffer)

	encoder := wgpu.DeviceCreateCommandEncoder(gpu.device, nil)
	renderer_draw(gpu, r, encoder, view, size, scale, list, clear)
	wgpu.CommandEncoderCopyTextureToBuffer(
		encoder,
		&{texture = texture, aspect = .All},
		&{layout = {bytesPerRow = padded, rowsPerImage = size.y}, buffer = buffer},
		&{size.x, size.y, 1},
	)
	commands := wgpu.CommandEncoderFinish(encoder, nil)
	wgpu.QueueSubmit(gpu.queue, {commands})
	wgpu.CommandBufferRelease(commands)
	wgpu.CommandEncoderRelease(encoder)

	Map_Result :: struct {
		done, ok: bool,
	}
	result: Map_Result
	wgpu.BufferMapAsync(
		buffer,
		{.Read},
		0,
		uint(buffer_size),
		{
			mode = .AllowProcessEvents,
			callback = proc "c" (status: wgpu.MapAsyncStatus, message: string, userdata1, userdata2: rawptr) {
				res := (^Map_Result)(userdata1)
				res.done = true
				res.ok = status == .Success
			},
			userdata1 = &result,
		},
	)
	for !result.done {
		wgpu.DevicePoll(gpu.device, true)
		wgpu.InstanceProcessEvents(gpu.instance)
	}
	if !result.ok {
		return
	}
	defer wgpu.BufferUnmap(buffer)

	mapped := wgpu.BufferGetConstMappedRange(buffer, 0, uint(buffer_size))
	pixels, err := make([]u8, int(row_bytes * size.y), allocator)
	if err != runtime.Allocator_Error.None {
		return
	}
	bgra := r.format == .BGRA8Unorm || r.format == .BGRA8UnormSrgb
	for y in 0 ..< size.y {
		src := mapped[y * padded:][:row_bytes]
		dst := pixels[y * row_bytes:][:row_bytes]
		for x := u32(0); x < row_bytes; x += 4 {
			if bgra {
				dst[x + 0], dst[x + 1], dst[x + 2], dst[x + 3] = src[x + 2], src[x + 1], src[x + 0], src[x + 3]
			} else {
				dst[x + 0], dst[x + 1], dst[x + 2], dst[x + 3] = src[x + 0], src[x + 1], src[x + 2], src[x + 3]
			}
		}
	}
	return {width = size.x, height = size.y, pixels = pixels}, true
}
