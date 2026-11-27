shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
// FlightOverlay3D renders premultiplied 8-bit sRGB to save memory; the world
// canvas it lands in is linear and premultiplied.
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
// Compatibility draws 2D in sRGB even into an HDR viewport.
uniform sampler2D overlay : filter_linear;
#else
uniform sampler2D overlay : source_color, filter_linear;
#endif
// Vertex color and modulate only: fragment COLOR already includes TEXTURE.
varying vec4 tint;
void vertex() {
 tint = COLOR;
}
void fragment() {
 // Modulate scales all premultiplied channels; warm-up draws it at zero.
 COLOR = texture(overlay, UV) * tint;
}
