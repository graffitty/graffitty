extends CompositorEffect
## Source-footprint depth of field for linear premultiplied transparent ink.
const CODE := """
#version 450
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D source_image;
layout(set=0,binding=1) uniform sampler2D depth_image;
layout(rgba16f,set=0,binding=2) uniform writeonly image2D destination;
layout(set=0,binding=3) uniform sampler2D source_footprint;
layout(rgba16f,set=0,binding=4) uniform image2D destination_footprint;
layout(push_constant,std430) uniform Params {
    mat4 inverse_projection;
    vec4 lens; // focus, radius, relative depth range, pass (-1=footprint, 0=x, 1=y, 2=resolve)
    vec4 raster; // width, height, blur limit, minimum radius
    vec4 band; // previous radius, current radius, next radius, accumulation index
} p;
layout(r32f,set=0,binding=5) uniform image2D tile_max;
shared uint group_max;
const int MAX_RADIUS = 24;
shared float taps[MAX_RADIUS + 1];
float kernel(float offset, float radius) {
    if (radius <= .45) return offset == 0. ? 1. : 0.;
    float t = abs(offset) / radius;
    return exp(-3. * t * t) * (1. - smoothstep(.85, 1., t));
}
float inverse_normalization(float radius) {
    float normalization=1.;
    for(int i=1;i<=MAX_RADIUS;i++) {
        if(float(i)>=radius)break;
        normalization+=2.*kernel(float(i),radius);
    }
    return 1./normalization;
}
void main() {
    ivec2 pixel=ivec2(gl_GlobalInvocationID.xy), size=ivec2(p.raster.xy);
    bool outside=any(greaterThanEqual(pixel,size));
    if (p.lens.w < -.5) {
        if(gl_LocalInvocationIndex==0)group_max=0u;
        barrier();
        float alpha=outside?0.:texelFetch(source_image,pixel,0).a;
        float radius=0.;
        if (alpha > .000001) {
            vec2 uv=(vec2(pixel)+.5)/p.raster.xy;
            float z=texelFetch(depth_image,pixel,0).r;
            vec4 v=p.inverse_projection*vec4(uv*2.-1.,z,1.);
            float d=max(-v.z/v.w,.001);
            radius=min(min(p.raster.z,float(MAX_RADIUS)),max(p.raster.w,
                abs(1.-p.lens.x/d)*p.lens.y/max(p.lens.z,.001)));
        }
        atomicMax(group_max,floatBitsToUint(radius));
        barrier();
        if(gl_LocalInvocationIndex==0)imageStore(tile_max,ivec2(gl_WorkGroupID.xy),vec4(uintBitsToFloat(group_max)));
        if(!outside)imageStore(destination_footprint,pixel,vec4(radius,0,0,0));
        return;
    }
    if (p.lens.w > 1.5) {
        if(outside)return;
        int active_grids=int(p.band.w);
        vec4 ink=(active_grids & 1)!=0 ? imageLoad(destination_footprint,pixel) : vec4(0.);
        if((active_grids & 2)!=0)ink+=textureLod(source_image,(vec2(pixel)+.5)/vec2(2*textureSize(source_image,0)),0.);
        imageStore(destination,pixel,ink/max(1.,ink.a));
        return;
    }
    // Interpolate each source between fixed-radius bands. Filtering each band
    // separately keeps both axes isotropic even where different depths overlap.
    ivec2 axis=p.lens.w<.5?ivec2(1,0):ivec2(0,1);
    vec4 sum=vec4(0.);
    bool wide=p.band.y>=12.;
    int stride=wide?2:1;
    ivec2 grid=(size+stride-1)/stride;
    outside=any(greaterThanEqual(pixel,grid));
    int reach=int(ceil(p.band.y/float(stride)));
    // All 64 pixels use the same normalized taps. Partial workgroups
    // participate in the barrier too, before out-of-bounds pixels return.
    int lane=int(gl_LocalInvocationIndex);
    if(lane<=reach)taps[lane]=kernel(float(lane),p.band.y/float(stride))*inverse_normalization(p.band.y/float(stride));
    barrier();
    if(outside)return;
    if(p.band.y>0.) {
        ivec2 start=ivec2(gl_WorkGroupID.xy)*8*stride;
        int margin=reach*stride+stride;
        ivec2 lo=max(start-ivec2(margin),ivec2(0))/8;
        ivec2 hi=min(start+ivec2(8*stride-1+margin),size-1)/8;
        bool relevant=false;
        for(int y=lo.y;y<=hi.y && !relevant;y++)
            for(int x=lo.x;x<=hi.x;x++)
                if(imageLoad(tile_max,ivec2(x,y)).x>p.band.x){relevant=true;break;}
        if(!relevant){
            if(p.lens.w<.5) imageStore(destination,pixel,vec4(0));
            else if(p.band.w==0.)imageStore(destination_footprint,pixel,vec4(0));
            return;
        }
    }
    for(int i=-reach;i<=reach;i++) {
        ivec2 q=pixel+axis*i;
        if(any(lessThan(q,ivec2(0)))||any(greaterThanEqual(q,grid)))continue;
        float weight=taps[abs(i)];
        if(p.lens.w<.5) {
            for(int yy=0;yy<stride;yy++) for(int xx=0;xx<stride;xx++){
                ivec2 src=min(q*stride+ivec2(xx,yy),size-1);
                float radius=texelFetch(source_footprint,src,0).x;
                float fraction=radius<=p.band.y
                ? (p.band.y==p.band.x?1.:clamp((radius-p.band.x)/(p.band.y-p.band.x),0.,1.))
                : (p.band.z==p.band.y?1.:clamp((p.band.z-radius)/(p.band.z-p.band.y),0.,1.));
                if(fraction>0.)sum+=texelFetch(source_image,src,0)*(weight*fraction/float(stride*stride));
            }
            continue;
        }
        if(weight>0.)sum+=texelFetch(source_image,q,0)*weight;
    }
    if(p.lens.w<.5)imageStore(destination,pixel,sum);
    else {
        if(p.band.w>0.)sum+=imageLoad(destination_footprint,pixel);
        imageStore(destination_footprint,pixel,sum);
    }
}
"""
const FIRST_WIDE_BAND := 3
const BAND_RADII := [0.0, 3.0, 6.0, 12.0, 24.0]
const RETRY_INITIAL_MSEC := 250
const RETRY_MAX_MSEC := 4000

var rd: RenderingDevice
var shader := RID()
var pipeline := RID()
var sampler := RID()
var temporary := RID()
var footprints: Array[RID] = []
var tile := RID()
var half_tmp := RID()
var half_sum := RID()
var texture_size := Vector2i.ZERO
var mutex := Mutex.new()
var lens := Vector4(1, 0, 1, 24)
var minimum_radius := 0.0
# Optional GPU resources and their retry state belong to the render thread.
# Zero means initialization failed independently of the texture dimensions.
var _retry_texture_pixels := 0
var _retry_after_msec := 0
var _retry_delay_msec := RETRY_INITIAL_MSEC


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	rd = RenderingServer.get_rendering_device()


func set_lens(focus: float, radius: float, depth_range: float, blur_limit: float = 24.0, minimum: float = 0.0) -> void:
	mutex.lock()
	lens = Vector4(focus, radius, depth_range, maxf(blur_limit, 0.0))
	minimum_radius = minimum
	mutex.unlock()


func presentation_copy() -> CompositorEffect:
	var copy := get_script().new() as CompositorEffect
	mutex.lock()
	copy.set_lens(lens.x, lens.y, lens.z, lens.w, minimum_radius)
	mutex.unlock()
	return copy


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		for resource in [shader, sampler, temporary, tile, half_tmp, half_sum] + footprints:
			if resource.is_valid():
				rd.free_rid(resource)


func _create_target(format: RDTextureFormat) -> RID:
	return rd.texture_create(format, RDTextureView.new())


func _monotonic_msec() -> int:
	return Time.get_ticks_msec()


func _create_pipeline() -> RID:
	return rd.compute_pipeline_create(shader)


func _create_sampler() -> RID:
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return rd.sampler_create(state)


func _initialize_resources() -> bool:
	if not shader.is_valid():
		var source := RDShaderSource.new()
		source.source_compute = CODE
		var spirv := rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_compute.is_empty():
			push_error(spirv.compile_error_compute)
			return false
		shader = rd.shader_create_from_spirv(spirv)
		if not shader.is_valid(): return false
		pipeline = _create_pipeline()
		sampler = _create_sampler()
	if pipeline.is_valid() and sampler.is_valid(): return true
	# Freeing the shader also releases its dependent pipeline.
	if shader.is_valid(): rd.free_rid(shader)
	if sampler.is_valid(): rd.free_rid(sampler)
	shader = RID()
	pipeline = RID()
	sampler = RID()
	return false


func _prepare_resources(size: Vector2i) -> bool:
	var pixels := size.x * size.y
	if _retry_texture_pixels > 0 and pixels < _retry_texture_pixels:
		# Only a cheaper texture request may bypass cooldown. Growing resizes
		# and size-independent initialization failures must remain bounded.
		_retry_after_msec = 0
		_retry_delay_msec = RETRY_INITIAL_MSEC
	if _monotonic_msec() < _retry_after_msec: return false
	var initialized := _initialize_resources()
	if not initialized or not _resize_targets(size):
		_retry_texture_pixels = pixels if initialized else 0
		_retry_after_msec = _monotonic_msec() + _retry_delay_msec
		_retry_delay_msec = mini(_retry_delay_msec * 2, RETRY_MAX_MSEC)
		return false
	_retry_texture_pixels = 0
	_retry_after_msec = 0
	_retry_delay_msec = RETRY_INITIAL_MSEC
	return true


func _release_targets() -> void:
	for resource in [temporary, tile, half_tmp, half_sum] + footprints:
		if resource.is_valid(): rd.free_rid(resource)
	temporary = RID()
	tile = RID()
	half_tmp = RID()
	half_sum = RID()
	footprints.clear()
	texture_size = Vector2i.ZERO


func _resize_targets(size: Vector2i) -> bool:
	if texture_size == size: return true
	_release_targets()
	var format := RDTextureFormat.new()
	format.width = size.x
	format.height = size.y
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	for i in 3:
		var target := _create_target(format)
		if not target.is_valid():
			# A failed resize must neither dispatch invalid images nor cache the
			# size as complete. Release partial work before the retry cooldown.
			_release_targets()
			return false
		if i == 0: temporary = target
		else: footprints.append(target)
	format.width = ceili(size.x / 2.0)
	format.height = ceili(size.y / 2.0)
	half_tmp = _create_target(format)
	half_sum = _create_target(format)
	format.width = ceili(size.x / 8.0)
	format.height = ceili(size.y / 8.0)
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	tile = _create_target(format)
	if not half_tmp.is_valid() or not half_sum.is_valid() or not tile.is_valid():
		_release_targets()
		return false
	texture_size = size
	return true


func _render_callback(kind: int, data: RenderData) -> void:
	if rd == null or kind != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	mutex.lock()
	var parameters := lens
	var minimum := minimum_radius
	mutex.unlock()
	if (parameters.y <= 0 and minimum <= 0) or parameters.w <= 0:
		return
	var buffers: RenderSceneBuffersRD = data.get_render_scene_buffers()
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	# Scene attachments can also be absent after a failed engine allocation.
	if not rd.texture_is_valid(buffers.get_color_texture()) or not rd.texture_is_valid(buffers.get_depth_texture()):
		return
	if not _prepare_resources(size):
		return
	var inverse: Projection = data.get_render_scene_data().get_cam_projection().inverse()
	# Only adjacent bands receive a source's coverage. Fly Away's authored
	# arrival has one uniform radius, often between the 3 and 6 px bands.
	var lower := clampf(minimum, 0.0, minf(parameters.w, BAND_RADII.back()))
	var upper := minf(parameters.w, BAND_RADII.back()) if parameters.y > 0.0 else lower
	var first := 0
	var last := BAND_RADII.size() - 1
	while first < last and BAND_RADII[first + 1] <= lower: first += 1
	while last > first and BAND_RADII[last - 1] >= upper: last -= 1
	var resolve_step := 1 + (last - first + 1) * 2
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		if not rd.texture_is_valid(color) or not rd.texture_is_valid(depth): return
		for step in resolve_step + 1:
			var axis := -1 if step == 0 else (2 if step == resolve_step else (step - 1) % 2)
			var band_index := clampi(first + (step - 1) / 2, first, last)
			var uniforms: Array[RDUniform] = []
			var textures := [color if axis <= 0 else temporary, depth,
				temporary if axis <= 0 else color,
				# The radius pass writes footprints[0]. One texture cannot be sampled and
				# written in the same dispatch, so that pass binds the other as its unused input.
				footprints[1] if axis == -1 else footprints[0],
				footprints[0] if axis == -1 else footprints[1]]
			var wide := axis in [0, 1] and band_index >= FIRST_WIDE_BAND
			if wide:
				if axis == 0: textures[2] = half_tmp
				else:
					textures[0] = half_tmp
					textures[4] = half_sum
			if axis == 2: textures[0] = half_sum
			textures.append(tile)
			for binding in textures.size():
				var uniform := RDUniform.new()
				uniform.binding = binding
				var storage := binding in [2, 4, 5]
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE if storage else RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				if not storage: uniform.add_id(sampler)
				uniform.add_id(textures[binding])
				uniforms.append(uniform)
			# Each resolution initializes its own sum on its first active band.
			var accumulation := band_index - (maxi(FIRST_WIDE_BAND, first) if wide else first)
			if axis == 2:
				accumulation = int(first < FIRST_WIDE_BAND) | (int(last >= FIRST_WIDE_BAND) << 1)
			var constants := PackedFloat32Array()
			for column in [inverse.x, inverse.y, inverse.z, inverse.w]:
				constants.append_array([column.x, column.y, column.z, column.w])
			constants.append_array(
				[
					parameters.x,
					parameters.y,
					parameters.z,
					float(axis),
					float(size.x),
					float(size.y),
					parameters.w,
					minimum,
				]
			)
			constants.append_array([BAND_RADII[maxi(band_index - 1, 0)], BAND_RADII[band_index],
				BAND_RADII[mini(band_index + 1, BAND_RADII.size() - 1)], float(accumulation)])
			var uniform_set := UniformSetCacheRD.get_cache(shader, 0, uniforms)
			if not uniform_set.is_valid(): return
			var list := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list, pipeline)
			rd.compute_list_bind_uniform_set(
				list,
				uniform_set,
				0,
			)
			rd.compute_list_set_push_constant(list, constants.to_byte_array(), constants.size() * 4)
			var extent := 16.0 if wide else 8.0
			rd.compute_list_dispatch(list, ceili(size.x / extent), ceili(size.y / extent), 1)
			rd.compute_list_end()
