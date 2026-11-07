//
// ModelRenderer.metal — SA 模型渲染着色器
//
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
    float3   lightDir;
    float    ambient;
    float3   cameraPos;
    float    pad;
};

struct VSIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
    float4 color    [[attribute(3)]];
};

struct VSOut {
    float4 position [[position]];
    float3 normal;
    float2 uv;
    float4 color;
};

vertex VSOut vs_main(VSIn in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    VSOut out;
    float4 wp = u.model * float4(in.position, 1.0);
    out.position = u.mvp * float4(in.position, 1.0);
    out.normal = normalize((u.model * float4(in.normal, 0.0)).xyz);
    out.uv = in.uv;
    out.color = in.color;
    return out;
}

fragment float4 fs_main(VSOut in [[stage_in]],
                        constant Uniforms &u [[buffer(1)]],
                        texture2d<float> albedo [[texture(0)]],
                        sampler samp [[sampler(0)]],
                        constant int &hasTexture [[buffer(2)]]) {
    float4 base = in.color;
    if (hasTexture != 0) {
        float4 t = albedo.sample(samp, in.uv);
        base *= t;
    }
    // 双面 Lambert；无法线时给常量亮度
    float3 n = normalize(in.normal);
    float ndl = fabs(dot(n, normalize(-u.lightDir)));
    float lit = u.ambient + (1.0 - u.ambient) * ndl;
    float3 rgb = base.rgb * lit;
    // 轻微 gamma 校正，避免暗部死黑
    rgb = pow(rgb, float3(1.0 / 1.1));
    return float4(rgb, base.a);
}

// 无纹理路径（调试用棋盘格）
fragment float4 fs_solid(VSOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    float lit = u.ambient + (1.0 - u.ambient) * fabs(dot(n, normalize(-u.lightDir)));
    float2 g = floor(in.uv * 8.0);
    float checker = fmod(g.x + g.y, 2.0) > 0.5 ? 1.0 : 0.85;
    return float4(float3(0.62, 0.75, 0.85) * lit * checker, 1.0);
}
