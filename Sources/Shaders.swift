import Foundation

// Metal shader source, compiled at runtime (no Xcode / metallib step required).
// Implements the classic Cthugha loop: a feedback buffer that is warped and
// decayed every frame (the "flame map"), the audio waveform drawn on top
// (the oscilloscope), and a palette lookup that colours the intensity buffer.
let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;      // simulation resolution in pixels
    float  time;
    float  dt;
    float  mode;            // warp/motion mode (0..3)
    float  decay;           // per-frame feedback decay (<1)
    float  zoom;            // motion strength multiplier
    float  swirl;           // rotational strength multiplier
    float  waveAmp;         // oscilloscope amplitude in NDC
    float  intensityScale;  // maps buffer intensity -> palette index
    float  paletteIndex;
    float  paletteCount;
    float  paletteRotation; // 0..1 colour cycling offset
    float  waveBrightness;
    float  waveCount;
    float  mirror;          // 0 none, 1 left-right, 2 quad kaleidoscope
    float2 _pad;            // keep the struct a multiple of 8 bytes
};

// ---- Feedback warp + decay (the "flame map") -------------------------------
kernel void warp(texture2d<float, access::sample> src [[texture(0)]],
                 texture2d<float, access::write>  dst [[texture(1)]],
                 constant Uniforms& u                 [[buffer(0)]],
                 uint2 gid                            [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    float2 res    = u.resolution;
    float  aspect = res.x / res.y;
    float2 uv = (float2(gid) + 0.5) / res;     // 0..1
    float2 p  = uv * 2.0 - 1.0;                // -1..1
    p.x *= aspect;                             // square space

    int   mode = int(u.mode + 0.5);
    float t    = u.time;
    float2 srcP = p;

    if (mode == 0) {
        // Flame: content rises and sways gently.
        srcP.y += 0.012 * u.zoom;
        srcP.x += 0.006 * sin(p.y * 4.0 + t * 1.5) * u.swirl;
    } else if (mode == 1) {
        // Outward swirl: rotate and expand (sample slightly inside).
        float a = 0.030 * u.swirl;
        float2 r = float2(srcP.x * cos(a) - srcP.y * sin(a),
                          srcP.x * sin(a) + srcP.y * cos(a));
        srcP = r * (1.0 - 0.010 * u.zoom);
    } else if (mode == 2) {
        // Ripple: radial breathing.
        float rr = length(srcP);
        srcP = srcP * (1.0 - 0.020 * sin(rr * 10.0 - t * 3.0) * u.swirl);
    } else {
        // Tunnel: rotate and contract inward.
        float a = -0.020 * u.swirl;
        float2 r = float2(srcP.x * cos(a) - srcP.y * sin(a),
                          srcP.x * sin(a) + srcP.y * cos(a));
        srcP = r * (1.0 + 0.012 * u.zoom);
    }

    // Back to 0..1 uv space.
    float2 sUV;
    sUV.x = (srcP.x / aspect) * 0.5 + 0.5;
    sUV.y = srcP.y * 0.5 + 0.5;

    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 px = 1.0 / res;

    // 5-tap blur gives the smeared flame look.
    float c = src.sample(smp, sUV).r;
    float n = src.sample(smp, sUV + float2(0.0,  px.y)).r;
    float s = src.sample(smp, sUV + float2(0.0, -px.y)).r;
    float e = src.sample(smp, sUV + float2( px.x, 0.0)).r;
    float w = src.sample(smp, sUV + float2(-px.x, 0.0)).r;
    float val = (c * 0.40 + (n + s + e + w) * 0.15) * u.decay;

    dst.write(float4(val, 0.0, 0.0, 1.0), gid);
}

// ---- Oscilloscope wave (drawn additively into the feedback buffer) ---------
struct WaveOut {
    float4 pos    [[position]];
    float  bright;
};

vertex WaveOut waveVertex(uint vid                [[vertex_id]],
                          constant float*  samples [[buffer(0)]],
                          constant Uniforms& u     [[buffer(1)]])
{
    WaveOut o;
    float count = max(u.waveCount, 2.0);
    float x = (float(vid) / (count - 1.0)) * 2.0 - 1.0;
    float sVal = samples[vid];
    float y = sVal * u.waveAmp;
    o.pos = float4(x, y, 0.0, 1.0);
    o.bright = u.waveBrightness * (0.55 + 0.75 * abs(sVal));
    return o;
}

fragment float4 waveFragment(WaveOut in [[stage_in]]) {
    return float4(in.bright, 0.0, 0.0, 1.0);
}

// ---- Present: intensity buffer -> palette colour ---------------------------
struct FSOut {
    float4 pos [[position]];
    float2 uv;
};

vertex FSOut presentVertex(uint vid [[vertex_id]]) {
    float2 verts[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    FSOut o;
    o.pos = float4(verts[vid], 0.0, 1.0);
    float2 uv = verts[vid] * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;
    o.uv = uv;
    return o;
}

fragment float4 presentFragment(FSOut in                     [[stage_in]],
                                texture2d<float> intensity    [[texture(0)]],
                                texture2d<float> palette      [[texture(1)]],
                                constant Uniforms& u          [[buffer(0)]])
{
    constexpr sampler smpI(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler smpP(coord::normalized, address::clamp_to_edge, filter::linear);

    // Optional mirror symmetry (fold the sampling coordinate about the centre).
    float2 uv = in.uv;
    int mir = int(u.mirror + 0.5);
    if (mir == 1) {
        uv.x = 0.5 - abs(uv.x - 0.5);
    } else if (mir == 2) {
        uv.x = 0.5 - abs(uv.x - 0.5);
        uv.y = 0.5 - abs(uv.y - 0.5);
    }

    float v = intensity.sample(smpI, uv).r;
    float idx = clamp(v * u.intensityScale, 0.0, 1.0);
    float pv = fract(idx + u.paletteRotation);
    float row = (u.paletteIndex + 0.5) / max(u.paletteCount, 1.0);
    float3 col = palette.sample(smpP, float2(pv, row)).rgb;
    return float4(col, 1.0);
}
"""
