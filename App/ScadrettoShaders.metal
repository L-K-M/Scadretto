// Scadretto viewport shaders.
//
// Compiled into the app's .metallib at build time; the ScadrettoViewport
// package looks the entry points up by name in the supplied MTLLibrary and
// never compiles source at runtime (plan/04-macOS-Editor.md). Entry point
// names must match ScadrettoViewport's `ViewportShader` constants.
//
// Vertex layout (buffer 0, stride 24): float3 position in render space,
// float3 normal-or-color. Uniform block (buffer 1): `ViewportUniforms`,
// shared verbatim with the Swift side.

#include <metal_stdlib>
using namespace metal;

struct ViewportUniforms {
    float4x4 viewProjection;
    float4 baseColor;
    float4 edgeColor;
    float4 lightDirection; // xyz = direction toward the key light, render space
    float staleDim;        // 1 normal, <1 dims a scene superseded by a pending evaluation
    float3 _padding;
};

struct MeshVertex {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
};

struct MeshOut {
    float4 clip [[position]];
    float3 position;
    float3 normal;
};

vertex MeshOut scadrettoVertex(MeshVertex in [[stage_in]],
                               constant ViewportUniforms &uniforms [[buffer(1)]]) {
    MeshOut out;
    out.clip = uniforms.viewProjection * float4(in.position, 1.0);
    out.position = in.position;
    out.normal = in.normal;
    return out;
}

fragment float4 scadrettoFragment(MeshOut in [[stage_in]],
                                  constant ViewportUniforms &uniforms [[buffer(1)]]) {
    // Shade each CAD face with its geometric normal. The interpolated
    // outward normal supplies orientation without relying on screen winding.
    float3 outward = normalize(in.normal);
    float3 face = cross(dfdx(in.position), dfdy(in.position));
    float3 normal = dot(face, face) > 1e-16 ? normalize(face) : outward;
    if (dot(normal, outward) < 0.0) normal = -normal;
    float3 light = normalize(uniforms.lightDirection.xyz);
    float diffuse = max(dot(normal, light), 0.0);
    // Hemisphere fill keyed to the Z-up world: warm sky above, dark ground
    // below, so undersides read without a second light source.
    float sky = 0.5 + 0.5 * normal.z;
    float ambient = mix(0.26, 0.46, sky);
    float3 color = uniforms.baseColor.rgb * (ambient + 0.60 * diffuse);
    return float4(color * uniforms.staleDim, uniforms.baseColor.a);
}

// Flat dark triangles for the Show Edges wireframe pass, drawn with
// triangleFillMode = lines over the depth-biased fill.
fragment float4 scadrettoEdgeFragment(MeshOut in [[stage_in]],
                                      constant ViewportUniforms &uniforms [[buffer(1)]]) {
    return float4(uniforms.edgeColor.rgb * uniforms.staleDim, uniforms.edgeColor.a);
}

// Line pass for the world-axis overlay: attribute 1 carries RGB instead of a
// normal.
struct LineOut {
    float4 clip [[position]];
    float3 color;
};

vertex LineOut scadrettoLineVertex(MeshVertex in [[stage_in]],
                                   constant ViewportUniforms &uniforms [[buffer(1)]]) {
    LineOut out;
    out.clip = uniforms.viewProjection * float4(in.position, 1.0);
    out.color = in.normal;
    return out;
}

fragment float4 scadrettoLineFragment(LineOut in [[stage_in]],
                                      constant ViewportUniforms &uniforms [[buffer(1)]]) {
    return float4(in.color * uniforms.staleDim, 1.0);
}
