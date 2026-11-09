// The instanced quad renderer: one pipeline, two atlases bound at once, one instance per quad.
// See ARCHITECTURE.md, "Rendering backend".
package backend

import "core:math"
import "core:time"

import wgpu "../third_party/odin/wgpu"
import "../render"

// Atlas size for M1. M2 replaces this with paged atlases.
@(private)
ATLAS_SIZE :: 256

@(private)
RENDERER_WGSL :: `
struct Globals {
	viewport: vec2<f32>,
	_pad: vec2<f32>,
}

@group(0) @binding(0) var<uniform> g: Globals;
@group(0) @binding(1) var mask_atlas: texture_2d<f32>;
@group(0) @binding(2) var color_atlas: texture_2d<f32>;
@group(0) @binding(3) var atlas_sampler: sampler;

struct Instance {
	@location(0) pos: vec2<f32>,   // top-left corner, physical pixels
	@location(1) size: vec2<f32>,  // physical pixels
	@location(2) uv0: vec2<f32>,
	@location(3) uv1: vec2<f32>,
	@location(4) color: vec4<f32>, // already encoded for the target format
	@location(5) mode: u32,        // 0 = mask atlas, 1 = color atlas
}

struct Varyings {
	@builtin(position) pos: vec4<f32>,
	@location(0) uv: vec2<f32>,
	@location(1) color: vec4<f32>,
	@location(2) @interpolate(flat) mode: u32,
}

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, inst: Instance) -> Varyings {
	var corners = array<vec2<f32>, 6>(
		vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
		vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
	);
	let c = corners[vi];
	let p = inst.pos + c * inst.size;

	var out: Varyings;
	out.pos = vec4<f32>(p.x / g.viewport.x * 2.0 - 1.0, 1.0 - p.y / g.viewport.y * 2.0, 0.0, 1.0);
	out.uv = mix(inst.uv0, inst.uv1, c);
	out.color = inst.color;
	out.mode = inst.mode;
	return out;
}

@fragment
fn fs_main(in: Varyings) -> @location(0) vec4<f32> {
	if (in.mode == 0u) {
		let coverage = textureSampleLevel(mask_atlas, atlas_sampler, in.uv, 0.0).r;
		return vec4<f32>(in.color.rgb, in.color.a * coverage);
	}
	let t = textureSampleLevel(color_atlas, atlas_sampler, in.uv, 0.0);
	return vec4<f32>(t.rgb, t.a * in.color.a);
}
`

Instance_Mode :: enum u32 {
	Mask  = 0, // sample the R8 atlas, multiply by the instance color
	Color = 1, // sample the RGBA8 atlas, output its color
}

@(private)
Instance :: struct {
	pos:   [2]f32,
	size:  [2]f32,
	uv0:   [2]f32,
	uv1:   [2]f32,
	color: [4]f32,
	mode:  Instance_Mode,
	_:     [3]u32,
}

@(private)
Batch :: struct {
	first, count: u32,
	scissor:      [4]u32, // x, y, w, h in physical pixels
}

Render_Stats :: struct {
	commands:   int,
	instances:  int,
	draw_calls: int,
	cpu_time:   time.Duration, // building instances and recording the pass
}

Renderer :: struct {
	format:          wgpu.TextureFormat,
	srgb:            bool,
	module:          wgpu.ShaderModule,
	pipeline:        wgpu.RenderPipeline,
	uniforms:        wgpu.Buffer,
	instance_buffer: wgpu.Buffer,
	instance_cap:    int,
	mask_atlas:      wgpu.Texture,
	mask_view:       wgpu.TextureView,
	color_atlas:     wgpu.Texture,
	color_view:      wgpu.TextureView,
	sampler:         wgpu.Sampler,
	bind_group:      wgpu.BindGroup,
	instances:       [dynamic]Instance,
	batches:         [dynamic]Batch,
	stats:           Render_Stats,
}

// The texel holding the white pixel used for solid rectangles, as a UV at its center.
@(private)
WHITE_UV :: [2]f32{0.5 / ATLAS_SIZE, 0.5 / ATLAS_SIZE}

renderer_init :: proc(gpu: Gpu, format: wgpu.TextureFormat, srgb: bool) -> (r: Renderer) {
	r.format = format
	r.srgb = srgb

	r.module = wgpu.DeviceCreateShaderModule(
		gpu.device,
		&{label = "myod renderer", nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = RENDERER_WGSL}},
	)

	attributes := [?]wgpu.VertexAttribute {
		{format = .Float32x2, offset = u64(offset_of(Instance, pos)), shaderLocation = 0},
		{format = .Float32x2, offset = u64(offset_of(Instance, size)), shaderLocation = 1},
		{format = .Float32x2, offset = u64(offset_of(Instance, uv0)), shaderLocation = 2},
		{format = .Float32x2, offset = u64(offset_of(Instance, uv1)), shaderLocation = 3},
		{format = .Float32x4, offset = u64(offset_of(Instance, color)), shaderLocation = 4},
		{format = .Uint32, offset = u64(offset_of(Instance, mode)), shaderLocation = 5},
	}
	blend := wgpu.BlendState {
		color = {operation = .Add, srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha},
		alpha = {operation = .Add, srcFactor = .One, dstFactor = .OneMinusSrcAlpha},
	}
	r.pipeline = wgpu.DeviceCreateRenderPipeline(
		gpu.device,
		&{
			label = "myod renderer",
			vertex = {
				module = r.module,
				entryPoint = "vs_main",
				bufferCount = 1,
				buffers = &wgpu.VertexBufferLayout {
					stepMode = .Instance,
					arrayStride = size_of(Instance),
					attributeCount = len(attributes),
					attributes = &attributes[0],
				},
			},
			fragment = &{
				module = r.module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState{format = format, blend = &blend, writeMask = wgpu.ColorWriteMaskFlags_All},
			},
			primitive = {topology = .TriangleList},
			multisample = {count = 1, mask = 0xFFFFFFFF},
		},
	)

	r.uniforms = wgpu.DeviceCreateBuffer(gpu.device, &{label = "myod globals", usage = {.Uniform, .CopyDst}, size = 16})

	// Two atlases, both with a white texel at (0, 0). M2 fills them with glyphs, icons and emoji.
	r.mask_atlas, r.mask_view = create_atlas(gpu, "myod mask atlas", .R8Unorm, 1)
	r.color_atlas, r.color_view = create_atlas(gpu, "myod color atlas", .RGBA8Unorm, 4)

	r.sampler = wgpu.DeviceCreateSampler(
		gpu.device,
		&{
			label = "myod atlas sampler",
			addressModeU = .ClampToEdge,
			addressModeV = .ClampToEdge,
			addressModeW = .ClampToEdge,
			magFilter = .Nearest,
			minFilter = .Nearest,
			mipmapFilter = .Nearest,
			maxAnisotropy = 1,
		},
	)

	layout := wgpu.RenderPipelineGetBindGroupLayout(r.pipeline, 0)
	defer wgpu.BindGroupLayoutRelease(layout)
	entries := [?]wgpu.BindGroupEntry {
		{binding = 0, buffer = r.uniforms, size = 16},
		{binding = 1, textureView = r.mask_view},
		{binding = 2, textureView = r.color_view},
		{binding = 3, sampler = r.sampler},
	}
	r.bind_group = wgpu.DeviceCreateBindGroup(
		gpu.device,
		&{label = "myod renderer", layout = layout, entryCount = len(entries), entries = &entries[0]},
	)
	return
}

@(private)
create_atlas :: proc(gpu: Gpu, label: string, format: wgpu.TextureFormat, bytes_per_texel: u32) -> (wgpu.Texture, wgpu.TextureView) {
	texture := wgpu.DeviceCreateTexture(
		gpu.device,
		&{
			label = label,
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {ATLAS_SIZE, ATLAS_SIZE, 1},
			format = format,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	white := [4]u8{255, 255, 255, 255}
	wgpu.QueueWriteTexture(
		gpu.queue,
		&{texture = texture, aspect = .All},
		&white,
		uint(bytes_per_texel),
		&{bytesPerRow = bytes_per_texel, rowsPerImage = 1},
		&{1, 1, 1},
	)
	return texture, wgpu.TextureCreateView(texture, nil)
}

renderer_destroy :: proc(r: ^Renderer) {
	delete(r.instances)
	delete(r.batches)
	wgpu.BindGroupRelease(r.bind_group)
	wgpu.SamplerRelease(r.sampler)
	wgpu.TextureViewRelease(r.color_view)
	wgpu.TextureRelease(r.color_atlas)
	wgpu.TextureViewRelease(r.mask_view)
	wgpu.TextureRelease(r.mask_atlas)
	if r.instance_buffer != nil {
		wgpu.BufferRelease(r.instance_buffer)
	}
	wgpu.BufferRelease(r.uniforms)
	wgpu.RenderPipelineRelease(r.pipeline)
	wgpu.ShaderModuleRelease(r.module)
	r^ = {}
}

// Records a render pass into `target` that clears it to `clear` and draws `list`.
// `size` is the target size in physical pixels; `scale` maps logical to physical pixels.
renderer_draw :: proc(
	gpu: Gpu,
	r: ^Renderer,
	encoder: wgpu.CommandEncoder,
	target: wgpu.TextureView,
	size: [2]u32,
	scale: f32,
	list: render.Command_List,
	clear: render.Color,
) {
	start := time.tick_now()
	build_instances(r, list, size, scale)

	if len(r.instances) > r.instance_cap {
		if r.instance_buffer != nil {
			wgpu.BufferRelease(r.instance_buffer)
		}
		r.instance_cap = max(1024, int(math.next_power_of_two(len(r.instances))))
		r.instance_buffer = wgpu.DeviceCreateBuffer(
			gpu.device,
			&{label = "myod instances", usage = {.Vertex, .CopyDst}, size = u64(r.instance_cap * size_of(Instance))},
		)
	}
	if len(r.instances) > 0 {
		wgpu.QueueWriteBuffer(gpu.queue, r.instance_buffer, 0, &r.instances[0], uint(len(r.instances) * size_of(Instance)))
	}
	globals := [4]f32{f32(size.x), f32(size.y), 0, 0}
	wgpu.QueueWriteBuffer(gpu.queue, r.uniforms, 0, &globals, size_of(globals))

	c := encode(r^, clear)
	pass := wgpu.CommandEncoderBeginRenderPass(
		encoder,
		&{
			label = "myod frame",
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view = target,
				loadOp = .Clear,
				storeOp = .Store,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				clearValue = {f64(c.r), f64(c.g), f64(c.b), 1},
			},
		},
	)
	draw_calls := 0
	if len(r.instances) > 0 {
		wgpu.RenderPassEncoderSetPipeline(pass, r.pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, r.bind_group)
		wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, r.instance_buffer, 0, u64(len(r.instances) * size_of(Instance)))
		for b in r.batches {
			if b.count == 0 || b.scissor[2] == 0 || b.scissor[3] == 0 {
				continue
			}
			wgpu.RenderPassEncoderSetScissorRect(pass, b.scissor[0], b.scissor[1], b.scissor[2], b.scissor[3])
			wgpu.RenderPassEncoderDraw(pass, vertexCount = 6, instanceCount = b.count, firstVertex = 0, firstInstance = b.first)
			draw_calls += 1
		}
	}
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	r.stats = {
		commands   = len(list.commands),
		instances  = len(r.instances),
		draw_calls = draw_calls,
		cpu_time   = time.tick_since(start),
	}
}

// Turns draw commands into pixel-snapped instances, split into batches at clip changes.
@(private)
build_instances :: proc(r: ^Renderer, list: render.Command_List, size: [2]u32, scale: f32) {
	clear(&r.instances)
	clear(&r.batches)

	full := [4]i32{0, 0, i32(size.x), i32(size.y)}
	clip_stack := make([dynamic][4]i32, 0, 16, context.temp_allocator)
	clip := full
	open_batch(r, clip)

	for cmd in list.commands {
		switch c in cmd {
		case render.Cmd_Clip_Push:
			append(&clip_stack, clip)
			x0, y0, x1, y1 := snap(c.rect, scale)
			clip = intersect(clip, {i32(x0), i32(y0), i32(x1), i32(y1)})
			open_batch(r, clip)
		case render.Cmd_Clip_Pop:
			if len(clip_stack) > 0 {
				clip = pop(&clip_stack)
			} else {
				clip = full
			}
			open_batch(r, clip)
		case render.Cmd_Rect:
			if clip.z <= clip.x || clip.w <= clip.y {
				continue // fully clipped
			}
			push_rect(r, c, scale)
		}
	}
	r.batches[len(r.batches) - 1].count = u32(len(r.instances)) - r.batches[len(r.batches) - 1].first
}

// Clip rects are kept as [x0, y0, x1, y1]; batches store [x, y, w, h].
@(private)
open_batch :: proc(r: ^Renderer, clip: [4]i32) {
	first := u32(len(r.instances))
	if n := len(r.batches); n > 0 {
		last := &r.batches[n - 1]
		last.count = first - last.first
		if last.count == 0 {
			ordered_remove(&r.batches, n - 1)
		}
	}
	w := max(clip.z - clip.x, 0)
	h := max(clip.w - clip.y, 0)
	append(&r.batches, Batch{first = first, scissor = {u32(max(clip.x, 0)), u32(max(clip.y, 0)), u32(w), u32(h)}})
}

@(private)
intersect :: proc(a, b: [4]i32) -> [4]i32 {
	return {max(a.x, b.x), max(a.y, b.y), min(a.z, b.z), min(a.w, b.w)}
}

// Snaps each edge of a logical rect to the nearest physical pixel independently, so adjacent
// rectangles share edges exactly and rounding error never accumulates.
@(private)
snap :: proc(rect: render.Rect, scale: f32) -> (x0, y0, x1, y1: f32) {
	x0 = math.round(rect.x * scale)
	y0 = math.round(rect.y * scale)
	x1 = math.round((rect.x + rect.w) * scale)
	y1 = math.round((rect.y + rect.h) * scale)
	return
}

// A bordered rectangle becomes up to five non-overlapping quads (fill + four edges), so
// translucent fills and borders never blend over each other.
@(private)
push_rect :: proc(r: ^Renderer, c: render.Cmd_Rect, scale: f32) {
	x0, y0, x1, y1 := snap(c.rect, scale)
	if c.snap == .Size {
		x1 = x0 + max(1, math.round(c.rect.w * scale))
		y1 = y0 + max(1, math.round(c.rect.h * scale))
	}
	if x1 <= x0 || y1 <= y0 {
		return
	}
	bw: f32 = 0
	if c.border_width > 0 && c.border_color.a > 0 {
		bw = max(1, math.round(c.border_width * scale))
		bw = min(bw, (x1 - x0) / 2, (y1 - y0) / 2)
	}
	if c.fill.a > 0 {
		push_quad(r, x0 + bw, y0 + bw, x1 - bw, y1 - bw, c.fill)
	}
	if bw > 0 {
		push_quad(r, x0, y0, x1, y0 + bw, c.border_color) // top
		push_quad(r, x0, y1 - bw, x1, y1, c.border_color) // bottom
		push_quad(r, x0, y0 + bw, x0 + bw, y1 - bw, c.border_color) // left
		push_quad(r, x1 - bw, y0 + bw, x1, y1 - bw, c.border_color) // right
	}
}

@(private)
push_quad :: proc(r: ^Renderer, x0, y0, x1, y1: f32, color: render.Color) {
	if x1 <= x0 || y1 <= y0 {
		return
	}
	append(&r.instances, Instance {
		pos = {x0, y0},
		size = {x1 - x0, y1 - y0},
		uv0 = WHITE_UV,
		uv1 = WHITE_UV,
		color = encode(r^, color),
		mode = .Mask,
	})
}

// Encodes an sRGB color for the target format: sRGB formats need linear RGB values.
@(private)
encode :: proc(r: Renderer, c: render.Color) -> [4]f32 {
	out := [4]f32{f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
	if r.srgb {
		for i in 0 ..< 3 {
			out[i] = srgb_to_linear(out[i])
		}
	}
	return out
}
