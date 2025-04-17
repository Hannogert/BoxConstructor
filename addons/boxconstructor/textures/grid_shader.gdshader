shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley;

uniform float grid_scale = 2.0;
uniform float camera_distance = 0.0;

void fragment() {
    vec2 uv = UV * 4000.0;
    float base_grid = grid_scale;
    
    if (grid_scale == 0.0) {
        base_grid = 1.0;
        if(camera_distance > 50.0) {
            base_grid = 10.0;
        }
        if(camera_distance > 500.0) {
            base_grid = 100.0;
        }
        if(camera_distance > 5000.0) {
            base_grid = 1000.0;
        }
    }

    vec2 scaled_uv = uv / base_grid;
    vec2 grid = abs(fract(scaled_uv)) / fwidth(scaled_uv);
    vec2 grid_sub = abs(fract(scaled_uv * 10.0)) / fwidth(scaled_uv * 10.0);
    
    float line = min(grid.x, grid.y);
    float line_sub = min(grid_sub.x, grid_sub.y);

    if (line < 1.0) {
        ALBEDO = vec3(0.4);
        ALPHA = 0.8;
    } else if (line_sub < 1.0) {
        ALBEDO = vec3(0.4);
        ALPHA = 0.3;
    } else {
        ALBEDO = vec3(0.15);
        ALPHA = 0.1;
    }
}