#version 330 core

// MadhurVision — Panel Vertex Shader
// Transforms floating window quads into 3D space with MVP matrix.

layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec2 aTexCoord;

uniform mat4 uModel;
uniform mat4 uView;
uniform mat4 uProjection;

out vec2 vTexCoord;
out vec3 vWorldPos;

void main() {
    vec4 worldPos = uModel * vec4(aPosition, 1.0);
    vWorldPos = worldPos.xyz;
    vTexCoord = aTexCoord;
    gl_Position = uProjection * uView * worldPos;
}
