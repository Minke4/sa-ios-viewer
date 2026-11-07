//
// ModelRenderer.metal — SA 模型渲染着色器
//
// 关于预光照（prelit / vertex color）：
//   SA 的 DFF 里存的顶点色普遍是极暗值（如 2/255），它不是"最终颜色"，
//   而是占位/调制值，真实亮度靠引擎的动态光照。因此这里完全不用它当基色，
//   只用作 ±7% 的轻微明暗提示。
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
    out.position = u.mvp * float4(in.position, 1.0);
    out.normal = normalize((u.model * float4(in.normal, 0.0)).xyz);
    out.uv = in.uv;
    out.color = in.color;
    return out;
}

// 有贴图：贴图色 × 光照 × 微弱预光照提示
fragment float4 fs_main(VSOut in [[stage_in]],
                        constant Uniforms &u [[buffer(1)]],
                        texture2d<float> albedo [[texture(0)]],
                        sampler samp [[sampler(0)]],
                        constant int &hasTexture [[buffer(2)]]) {
    float3 base;
    float alpha = 1.0;

    if (hasTexture != 0) {
        float4 t = albedo.sample(samp, in.uv);
        base = t.rgb;
        alpha = t.a;
        // 采样异常（全黑/NaN）时退回中性色，避免整片消失
        if (!all(isfinite(base)) || dot(base, float3(1.0)) < 0.02)
            base = float3(0.72, 0.74, 0.72);
    } else {
        base = float3(0.66, 0.70, 0.72);
    }

    // 预光照只做 ±7% 的明暗提示，绝不作为基色
    float preAvg = saturate((in.color.r + in.color.g + in.color.b) * 0.3333);
    float preMod = 0.93 + 0.07 * preAvg;

    // 法线：SA 很多模型不带法线（全 0），此时用屏幕空间导数求面法线
    float3 n = in.normal;
    if (dot(n, n) < 1e-12)
        n = normalize(cross(dfdx(in.position.xyz), dfdy(in.position.xyz)));
    float ndl = fabs(dot(normalize(n), normalize(-u.lightDir)));
    float lit = u.ambient + (1.0 - u.ambient) * ndl;

    // 调试：u.pad 用于切换输出（0=正常，1=贴图原色，2=法线，3=光照）
    if (u.pad > 2.5) return float4(lit, lit, lit, 1.0);
    if (u.pad > 1.5) return float4(fabs(n) * 0.5 + 0.5, 1.0);
    if (u.pad > 0.5) return float4(base, 1.0);

    float3 rgb = base * lit * preMod;
    rgb = pow(saturate(rgb), float3(1.0 / 1.15));
    return float4(rgb, alpha);
}

// 无贴图：棋盘格（用于直观确认 UV 与几何是否正确）
fragment float4 fs_solid(VSOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float3 n = in.normal;
    if (dot(n, n) < 1e-12)
        n = normalize(cross(dfdx(in.position.xyz), dfdy(in.position.xyz)));
    float lit = u.ambient + (1.0 - u.ambient) * fabs(dot(normalize(n), normalize(-u.lightDir)));
    float2 g = floor(in.uv * 4.0);
    float checker = fmod(g.x + g.y, 2.0) > 0.5 ? 1.0 : 0.82;
    return float4(float3(0.66, 0.72, 0.78) * lit * checker, 1.0);
}
