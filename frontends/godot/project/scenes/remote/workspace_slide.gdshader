shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D workspace : hint_screen_texture, repeat_disable, filter_nearest;
uniform float slide;

void fragment() {
	COLOR = textureLod(workspace, SCREEN_UV - vec2(slide, 0.0), 0.0);
}
