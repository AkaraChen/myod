// Test pattern: a window border, a center crosshair and a grid line every 32 logical pixels,
// all 1 logical pixel wide.
//
// M0 uses it to check that content re-renders live while a window edge is dragged: if the image were
// stretched instead of redrawn, the lines would blur, thicken or drift off center. It is also handy
// for checking pixel snapping later.
package backend

import wgpu "../third_party/odin/wgpu"

Test_Pattern :: struct {
	module:     wgpu.ShaderModule,
	pipeline:   wgpu.RenderPipeline,
	buffer:     wgpu.Buffer,
	bind_group: wgpu.BindGroup,
}

Test_Pattern_Colors :: struct {
	bg, fg, grid: [3]u8,
}

@(private)
Test_Pattern_Params :: struct {
	size:  [2]f32,
	scale: f32,
	_:     f32,
	bg:    [4]f32,
	fg:    [4]f32,
	grid:  [4]f32,
}

@(private)
TEST_PATTERN_WGSL :: `
struct Params {
	size: vec2<f32>,
	scale: f32,
	_pad: f32,
	bg: vec4<f32>,
	fg: vec4<f32>,
	grid: vec4<f32>,
}

@group(0) @binding(0) var<uniform> p: Params;

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
	// One large triangle covering the whole window
	let x = f32((i << 1u) & 2u);
	let y = f32(i & 2u);
	return vec4<f32>(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
	let px = floor(pos.xy);
	let t = max(1.0, round(p.scale)); // physical pixels per logical pixel

	// Window border
	if (px.x < t || px.y < t || px.x >= p.size.x - t || px.y >= p.size.y - t) {
		return p.fg;
	}

	// Center crosshair
	let c = floor(p.size * 0.5);
	if ((px.x >= c.x && px.x < c.x + t) || (px.y >= c.y && px.y < c.y + t)) {
		return p.fg;
	}

	// Grid
	let step = round(32.0 * p.scale);
	let g = px - floor(px / step) * step;
	if (g.x < t || g.y < t) {
		return p.grid;
	}

	return p.bg;
}
`

test_pattern_init :: proc(gpu: Gpu, surface: Surface) -> (tp: Test_Pattern) {
	tp.module = wgpu.DeviceCreateShaderModule(
		gpu.device,
		&{
			label = "myod test pattern",
			nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = TEST_PATTERN_WGSL},
		},
	)

	tp.pipeline = wgpu.DeviceCreateRenderPipeline(
		gpu.device,
		&{
			label = "myod test pattern",
			vertex = {module = tp.module, entryPoint = "vs_main"},
			fragment = &{
				module = tp.module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState{
					format = surface.config.format,
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
			primitive = {topology = .TriangleList},
			multisample = {count = 1, mask = 0xFFFFFFFF},
		},
	)

	tp.buffer = wgpu.DeviceCreateBuffer(
		gpu.device,
		&{label = "myod test pattern params", usage = {.Uniform, .CopyDst}, size = size_of(Test_Pattern_Params)},
	)

	layout := wgpu.RenderPipelineGetBindGroupLayout(tp.pipeline, 0)
	defer wgpu.BindGroupLayoutRelease(layout)
	tp.bind_group = wgpu.DeviceCreateBindGroup(
		gpu.device,
		&{
			label = "myod test pattern",
			layout = layout,
			entryCount = 1,
			entries = &wgpu.BindGroupEntry{binding = 0, buffer = tp.buffer, size = size_of(Test_Pattern_Params)},
		},
	)
	return
}

test_pattern_destroy :: proc(tp: ^Test_Pattern) {
	wgpu.BindGroupRelease(tp.bind_group)
	wgpu.BufferRelease(tp.buffer)
	wgpu.RenderPipelineRelease(tp.pipeline)
	wgpu.ShaderModuleRelease(tp.module)
}

test_pattern_draw :: proc(gpu: Gpu, surface: Surface, frame: Frame, tp: Test_Pattern, scale: f32, colors: Test_Pattern_Colors) {
	params := Test_Pattern_Params {
		size  = {f32(surface.config.width), f32(surface.config.height)},
		scale = scale,
		bg    = encode_color(surface, colors.bg),
		fg    = encode_color(surface, colors.fg),
		grid  = encode_color(surface, colors.grid),
	}
	wgpu.QueueWriteBuffer(gpu.queue, tp.buffer, 0, &params, size_of(params))

	bg := params.bg
	pass := wgpu.CommandEncoderBeginRenderPass(
		frame.encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment{
				view = frame.view,
				loadOp = .Clear,
				storeOp = .Store,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				clearValue = {f64(bg.r), f64(bg.g), f64(bg.b), 1},
			},
		},
	)
	wgpu.RenderPassEncoderSetPipeline(pass, tp.pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, tp.bind_group)
	wgpu.RenderPassEncoderDraw(pass, vertexCount = 3, instanceCount = 1, firstVertex = 0, firstInstance = 0)
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)
}
