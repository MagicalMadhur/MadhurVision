#version 330 core

// MadhurVision — Panel Fragment Shader
// Renders floating window panels with alpha blending, frosted glass effect,
// and focus highlight border.

in vec2 vTexCoord;
in vec3 vWorldPos;

uniform sampler2D uTexture;
uniform float uOpacity;
uniform bool uIsFocused;
uniform bool uHasTexture;
uniform vec4 uTintColor;      // Window tint (e.g., for title bar)
uniform float uBorderRadius;  // Rounded corner radius (normalized)
uniform float uTime;          // For subtle animation

out vec4 FragColor;

// Rounded rectangle SDF
float roundedBox(vec2 p, vec2 b, float r) {
    vec2 d = abs(p) - b + vec2(r);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

void main() {
    vec2 uv = vTexCoord;
    
    // ── Rounded Corners ────────────────────────────────────
    vec2 centered = uv - 0.5;
    float radius = uBorderRadius;
    float dist = roundedBox(centered, vec2(0.5 - radius), radius);
    
    // Anti-aliased edge
    float alpha = 1.0 - smoothstep(-0.005, 0.005, dist);
    
    if (alpha < 0.01) {
        discard;
    }
    
    // ── Base Color ─────────────────────────────────────────
    vec4 color;
    if (uHasTexture) {
        color = texture(uTexture, uv);
    } else {
        // Frosted glass gradient when no texture
        float gradient = mix(0.08, 0.12, uv.y);
        color = vec4(gradient, gradient, gradient + 0.02, 1.0);
    }
    
    // ── Frosted Glass Effect ───────────────────────────────
    // Slight color tint to simulate glass
    color.rgb = mix(color.rgb, uTintColor.rgb, uTintColor.a * 0.15);
    
    // Subtle noise for glass texture
    float noise = fract(sin(dot(uv * 100.0, vec2(12.9898, 78.233))) * 43758.5453);
    color.rgb += noise * 0.01;
    
    // ── Title Bar ──────────────────────────────────────────
    // Top 6% is the title bar area
    if (uv.y > 0.94) {
        float barGrad = (uv.y - 0.94) / 0.06;
        vec3 barColor = mix(vec3(0.15, 0.15, 0.20), vec3(0.10, 0.10, 0.15), barGrad);
        color.rgb = barColor;
    }
    
    // ── Focus Highlight ────────────────────────────────────
    if (uIsFocused) {
        // Glowing border
        float borderDist = abs(dist + 0.01);
        float borderGlow = exp(-borderDist * 200.0) * 0.5;
        
        // Animated pulse
        float pulse = sin(uTime * 2.0) * 0.1 + 0.9;
        vec3 focusColor = vec3(0.4, 0.5, 1.0) * pulse;
        color.rgb += focusColor * borderGlow;
    }
    
    // ── Edge Highlight ─────────────────────────────────────
    // Subtle edge lighting for depth
    float edgeDist = abs(dist + 0.005);
    float edgeGlow = exp(-edgeDist * 300.0) * 0.2;
    color.rgb += vec3(0.3, 0.3, 0.4) * edgeGlow;
    
    // ── Final Output ───────────────────────────────────────
    color.a = alpha * uOpacity;
    FragColor = color;
}
