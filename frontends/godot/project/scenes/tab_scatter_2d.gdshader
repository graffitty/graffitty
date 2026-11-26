shader_type canvas_item;
render_mode unshaded;
// Whole 2D transition panels: pane backings, chrome and depth-mode panes.
// Flying letters and dust render in 3D (FlightOverlay3D, cell_shatter).
uniform float progress = 0.0;
uniform float depth_blur = 0.0;
uniform float depth_alpha = 1.0;
varying float piece_alpha;
void vertex() {
 piece_alpha = 1.0 - progress;
}
// Normalized 1D weights for the original five Gaussian taps at half-radius spacing.
const float NEAR_WEIGHT = 0.2310643640;
const float FAR_WEIGHT = 0.0243540048;
const float CENTER_WEIGHT = 1.0 - 2.0 * (NEAR_WEIGHT + FAR_WEIGHT);

vec4 blur_row(sampler2D source, vec2 uv, vec2 dx) {
 return texture(source, uv) * CENTER_WEIGHT
      + (texture(source, uv - 0.5 * dx) + texture(source, uv + 0.5 * dx)) * NEAR_WEIGHT
      + (texture(source, uv - dx) + texture(source, uv + dx)) * FAR_WEIGHT;
}

void fragment() {
 vec4 ink = texture(TEXTURE,UV);
 if (depth_blur > 0.45) {
  vec2 dx = dFdx(UV) * depth_blur;
  vec2 dy = dFdy(UV) * depth_blur;
  vec2 reach = abs(dx) + abs(dy);
  bool interior = all(greaterThanEqual(UV - reach, vec2(0.0))) &&
                  all(lessThanEqual(UV + reach, vec2(1.0)));
  vec4 sum = vec4(0.0);
  if (interior) {
   sum = blur_row(TEXTURE, UV, dx) * CENTER_WEIGHT
       + (blur_row(TEXTURE, UV - 0.5 * dy, dx) + blur_row(TEXTURE, UV + 0.5 * dy, dx)) * NEAR_WEIGHT
       + (blur_row(TEXTURE, UV - dy, dx) + blur_row(TEXTURE, UV + dy, dx)) * FAR_WEIGHT;
  } else {
   float weights = 0.0;
   for (int y = -2; y <= 2; y++) {
    for (int x = -2; x <= 2; x++) {
     vec2 offset = vec2(float(x), float(y)) * 0.5;
     float weight = exp(-3.0 * dot(offset, offset));
     vec2 uv = UV + dx * offset.x + dy * offset.y;
     if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
      sum += texture(TEXTURE, uv) * weight;
     }
     weights += weight;
    }
   }
   sum /= weights;
  }
  ink = mix(ink, sum, smoothstep(0.45, 1.25, depth_blur));
 }
 COLOR = vec4(ink.rgb / max(ink.a,0.0001), ink.a * piece_alpha * depth_alpha);
}
