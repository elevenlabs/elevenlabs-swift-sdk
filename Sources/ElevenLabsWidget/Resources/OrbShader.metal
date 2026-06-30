//
//  OrbShader.metal
//  ElevenLabs swift components
//
//  Created by Louis Jordan on 06/17/2025.
//  Vendored from elevenlabs/components-swift (Apache 2.0).
//

#include <metal_stdlib>
using namespace metal;

constant float PI = 3.14159265358979323846;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct OrbUniforms {
    float time;
    float animation;
    float inverted;
    float _pad0; // padding to 16 bytes alignment
    float offsets[8]; // 8 offsets for alignment
    float4 color1;
    float4 color2;
    float agentLevel;  // agent (SDK output) scalar — drives petals + ring pulse
    float userLevel;   // user mic (SDK input) scalar — drives the flow swirl
    float2 _pad1; // 8 bytes padding to reach 96 bytes
};

vertex VertexOut orbVertexShader(uint vertexID [[vertex_id]],
                                 constant float2* vertices [[buffer(0)]]) {
    VertexOut out;
    float2 pos = vertices[vertexID];
    out.position = float4(pos, 0.0, 1.0);
    out.uv = pos * 0.5 + 0.5; // Convert from [-1,1] to [0,1]
    return out;
}

float2 hash2(float2 p) {
    return fract(sin(float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)))) * 43758.5453);
}

float noise2D(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);

    float2 u = f * f * (3.0 - 2.0 * f);
    float n = mix(
        mix(dot(hash2(i + float2(0.0, 0.0)), f - float2(0.0, 0.0)),
            dot(hash2(i + float2(1.0, 0.0)), f - float2(1.0, 0.0)), u.x),
        mix(dot(hash2(i + float2(0.0, 1.0)), f - float2(0.0, 1.0)),
            dot(hash2(i + float2(1.0, 1.0)), f - float2(1.0, 1.0)), u.x),
        u.y
    );

    return 0.5 + 0.5 * n;
}

float perlinTexture(float2 uv) {
    return noise2D(uv * 8.0);
}

bool drawOval(float2 polarUv, float2 polarCenter, float a, float b, bool reverseGradient, float softness, thread float4& color) {
    float2 p = polarUv - polarCenter;
    float oval = (p.x * p.x) / (a * a) + (p.y * p.y) / (b * b);

    float edge = smoothstep(1.0, 1.0 - softness, oval);

    if (edge > 0.0) {
        float gradient = reverseGradient ? (1.0 - (p.x / a + 1.0) / 2.0) : ((p.x / a + 1.0) / 2.0);
        color = float4(float3(gradient), min(1.2 * edge, 1.0));
        return true;
    }
    return false;
}

float3 colorRamp(float grayscale, float3 color1, float3 color2, float3 color3, float3 color4) {
    if (grayscale < 0.33) {
        return mix(color1, color2, grayscale * 3.0);
    } else if (grayscale < 0.66) {
        return mix(color2, color3, (grayscale - 0.33) * 3.0);
    } else {
        return mix(color3, color4, (grayscale - 0.66) * 3.0);
    }
}

float sharpRing(float3 decomposed, float time) {
    float ringStart = 1.0;
    float ringWidth = 0.5;
    float noiseScale = 5.0;

    float noise = mix(
        noise2D(float2(decomposed.x, time) * noiseScale),
        noise2D(float2(decomposed.y, time) * noiseScale),
        decomposed.z
    );

    noise = (noise - 0.5) * 4.0;

    return ringStart + noise * ringWidth * 1.5;
}

float smoothRing(float3 decomposed, float time) {
    float ringStart = 0.9;
    float ringWidth = 0.3;
    float noiseScale = 6.0;

    float noise = mix(
        noise2D(float2(decomposed.x, time) * noiseScale),
        noise2D(float2(decomposed.y, time) * noiseScale),
        decomposed.z
    );

    noise = (noise - 0.5) * 8.0;

    return ringStart + noise * ringWidth;
}

float flow(float3 decomposed, float time) {
    return mix(
        perlinTexture(float2(time, decomposed.x / 2.0)),
        perlinTexture(float2(time, decomposed.y / 2.0)),
        decomposed.z
    );
}

fragment float4 orbFragmentShader(VertexOut in [[stage_in]],
                                  constant OrbUniforms& uniforms [[buffer(0)]],
                                  constant float* agentBands [[buffer(1)]],
                                  constant float* userBands [[buffer(2)]]) {

    float2 uv = in.uv * 2.0 - 1.0;

    float radius = length(uv);
    float theta = atan2(uv.y, uv.x);
    if (theta < 0.0) theta += 2.0 * PI;

    float3 decomposed = float3(
        theta / (2.0 * PI),
        fmod(theta / (2.0 * PI) + 0.5, 1.0) + 1.0,
        abs(theta / PI - 1.0)
    );

    float noise = flow(decomposed, radius * 0.03 - uniforms.animation * 0.2) - 0.5;
    // `userLevel` (the mic) drives the swirl. The original mix(0.5, 1.0) was
    // imperceptible against the always-on baseline flow, so widen the range to
    // make speaking visibly distort/wobble the petals (distinct from the
    // agent's clean radial ring pulse driven by `agentLevel`).
    theta += noise * mix(0.5, 3.0, uniforms.userLevel);

    float4 color = float4(1.0, 1.0, 1.0, 1.0);

    float originalCenters[7] = {0.0, 0.5 * PI, 1.0 * PI, 1.5 * PI, 2.0 * PI, 2.5 * PI, 3.0 * PI};

    float centers[7];
    for (int i = 0; i < 7; i++) {
        centers[i] = originalCenters[i] + 0.5 * sin(uniforms.time / 20.0 + uniforms.offsets[i]);
    }

    float a, b;
    float4 ovalColor;

    for (int i = 0; i < 7; i++) {
        float noise = perlinTexture(float2(fmod(centers[i] + uniforms.time * 0.05, 1.0), 0.5));
        // This petal is driven by its own frequency band — the louder of the
        // agent and mic band at index i. (Direction unchanged for now: louder
        // still pulls the petal in via mix(4.5, 3.0, …); step 6 inverts it.)
        float band = max(clamp(agentBands[i], 0.0, 1.0), clamp(userBands[i], 0.0, 1.0));
        a = 0.5 + noise * 0.5; // Increased variance: goes from 0.0 to 1.0
        b = noise * mix(4.5, 3.0, band); // Tall semi-minor axis
        bool reverseGradient = (i % 2 == 1); // Reverse gradient for every second oval

        // Calculate the distance in polar coordinates
        float distTheta = min(
            abs(theta - centers[i]),
            min(
                abs(theta + 2.0 * PI - centers[i]),
                abs(theta - 2.0 * PI - centers[i])
            )
        );
        float distRadius = radius;

        float softness = 0.4; // Controls edge softness

        if (drawOval(float2(distTheta, distRadius), float2(0.0, 0.0), a, b, reverseGradient, softness, ovalColor)) {
            color.rgb = mix(color.rgb, ovalColor.rgb, ovalColor.a);
        }
    }

    float ringRadius1 = sharpRing(decomposed, uniforms.time * 0.1);
    float ringRadius2 = smoothRing(decomposed, uniforms.time * 0.1);

    float agentRadius1 = radius + uniforms.agentLevel * 0.3;
    float agentRadius2 = radius + uniforms.agentLevel * 0.2;
    float opacity1 = mix(0.3, 0.8, uniforms.agentLevel);
    float opacity2 = mix(0.25, 0.6, uniforms.agentLevel);

    float ringAlpha1 = (agentRadius2 >= ringRadius1) ? opacity1 : 0.0;
    float ringAlpha2 = smoothstep(ringRadius2 - 0.05, ringRadius2 + 0.05, agentRadius1) * opacity2;

    float totalRingAlpha = max(ringAlpha1, ringAlpha2);

    float3 ringColor = float3(1.0);
    color.rgb = 1.0 - (1.0 - color.rgb) * (1.0 - ringColor * totalRingAlpha);

    float3 color1 = float3(0.0, 0.0, 0.0); // Black
    float3 color2 = uniforms.color1.xyz; // Darker Color
    float3 color3 = uniforms.color2.xyz; // Lighter Color
    float3 color4 = float3(1.0, 1.0, 1.0); // White

    // Convert grayscale color to the color ramp
    float luminance = mix(color.r, 1.0 - color.r, uniforms.inverted);
    color.rgb = colorRamp(luminance, color1, color2, color3, color4);

    // Always fully opaque for the orb
    color.a = 1.0;

    return color;
}
