shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley;

uniform float grid_scale = 0.1;

void fragment() {
    vec2 world_uv = UV * 4000.0;
    
    vec2 scaled_uv = world_uv / grid_scale;
    
    vec2 grid = abs(fract(scaled_uv - 0.5) - 0.5);
    vec2 grid_width = fwidth(scaled_uv) * 1.0;
    vec2 grid_lines = smoothstep(vec2(0.0), grid_width, grid);
    float line = min(grid_lines.x, grid_lines.y);

    if (line < 0.5) {
        ALBEDO = vec3(0.4);
        ALPHA = 0.8;
    } else {
        ALBEDO = vec3(0.15);
        ALPHA = 0.1;
    }
}