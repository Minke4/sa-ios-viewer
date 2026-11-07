//
// metal_backend.mm — Metal 渲染后端（Objective-C++）
//
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "metal_backend.h"
#include "renderer.h"

struct Uniforms {
    float mvp[16];
    float model[16];
    float lightDir[3];
    float ambient;
    float cameraPos[3];
    float pad;
};

@implementation SAMetalRenderer {
    id<MTLDevice>       _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipelineTextured;
    id<MTLRenderPipelineState> _pipelineSolid;
    id<MTLSamplerState> _sampler;
    id<MTLDepthStencilState> _depthState;

    id<MTLBuffer> _vertexBuffer;
    struct SubDraw { unsigned int first, count; int tex; };
    std::vector<SubDraw> _subs;
    id<MTLBuffer> _indexBuffer;
    std::vector<id<MTLTexture>> _textures;

    float _yaw, _pitch, _distance;
    float _bounds[6];
    int   _indexCount;
    int   _textureCount;
    BOOL  _freeCam;       // YES = 场景模式（绕场景中心大轨道飞行）
    float _orbitScale;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _device = device;
        _queue = [device newCommandQueue];
        _yaw = 0.6f;
        _pitch = 0.35f;
        _distance = 1.0f;
        _freeCam = NO;
        _orbitScale = 1.0f;
        [self buildPipelines];
    }
    return self;
}

- (void)buildPipelines {
    NSError *err = nil;
    id<MTLLibrary> lib = [_device newDefaultLibrary];
    if (!lib) {
        NSLog(@"SA: newDefaultLibrary 失败");
        return;
    }
    id<MTLFunction> vs = [lib newFunctionWithName:@"vs_main"];
    id<MTLFunction> fsTex = [lib newFunctionWithName:@"fs_main"];
    id<MTLFunction> fsSolid = [lib newFunctionWithName:@"fs_solid"];

    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat3;  // position
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat3;  // normal
    vd.attributes[1].offset = sizeof(float) * 3;
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatFloat2;  // uv
    vd.attributes[2].offset = sizeof(float) * 6;
    vd.attributes[2].bufferIndex = 0;
    vd.attributes[3].format = MTLVertexFormatFloat4;  // color
    vd.attributes[3].offset = sizeof(float) * 8;
    vd.attributes[3].bufferIndex = 0;
    vd.layouts[0].stride = sizeof(float) * 12;

    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction = vs;
    d.vertexDescriptor = vd;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

    d.fragmentFunction = fsTex;
    _pipelineTextured = [_device newRenderPipelineStateWithDescriptor:d error:&err];
    if (err) NSLog(@"SA: textured pipeline 失败: %@", err);

    err = nil;
    d.fragmentFunction = fsSolid;
    _pipelineSolid = [_device newRenderPipelineStateWithDescriptor:d error:&err];
    if (err) NSLog(@"SA: solid pipeline 失败: %@", err);

    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.mipFilter = MTLSamplerMipFilterNearest;
    sd.sAddressMode = MTLSamplerAddressModeRepeat;
    sd.tAddressMode = MTLSamplerAddressModeRepeat;
    _sampler = [_device newSamplerStateWithDescriptor:sd];

    MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:dd];
}

- (void)uploadMesh:(const float *)vertices
             vcount:(int)vcount
            indices:(const unsigned int *)indices
             icount:(int)icount
             bounds:(const float *)bounds {
    _vertexBuffer = [_device newBufferWithBytes:vertices
                                         length:(size_t)vcount * sizeof(float) * 12
                                        options:MTLResourceStorageModeShared];
    _indexBuffer = [_device newBufferWithBytes:indices
                                        length:(size_t)icount * sizeof(unsigned int)
                                       options:MTLResourceStorageModeShared];
    _indexCount = icount;
    std::memcpy(_bounds, bounds, sizeof(_bounds));

    float dx = bounds[3] - bounds[0], dy = bounds[4] - bounds[1], dz = bounds[5] - bounds[2];
    float radius = std::sqrt(dx * dx + dy * dy + dz * dz) * 0.5f;
    _distance = radius > 0.01f ? radius * 2.2f : 20.0f;
    // 场景很大时拉近一些，避免全是天空
    if (_freeCam && radius > 50.0f) _distance = radius * 1.4f;
    NSLog(@"SA: mesh 上传 %d 顶点 %d 索引，半径 %.2f", vcount, icount, radius);
}

- (void)uploadTexture:(const unsigned char *)rgba width:(int)w height:(int)h {
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    id<MTLTexture> tex = [_device newTextureWithDescriptor:td];
    [tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
           mipmapLevel:0
             withBytes:rgba
           bytesPerRow:(NSUInteger)w * 4];
    _textures.push_back(tex);
    _textureCount = (int)_textures.size();
}

- (void)uploadSubmeshes:(const unsigned int *)firstIndex
                counts:(const unsigned int *)indexCount
             texSlots:(const int *)texSlots
                  num:(int)num {
    _subs.clear();
    for (int i = 0; i < num; ++i)
        _subs.push_back({firstIndex[i], indexCount[i], texSlots[i]});
}

- (void)setSceneMode:(BOOL)scene { _freeCam = scene; }
- (void)setOrbitScale:(float)s { _orbitScale = s; }
- (void)getBounds:(float *)out { std::memcpy(out, _bounds, sizeof(_bounds)); }
- (void)getCameraYaw:(float *)yaw pitch:(float *)pitch distance:(float *)dist {
    *yaw = _yaw; *pitch = _pitch; *dist = _distance;
}
- (void)setCameraYaw:(float)yaw pitch:(float)pitch { _yaw = yaw; _pitch = pitch; }
- (void)zoomBy:(float)factor { _distance = std::fmax(0.5f, std::fmin(20000.0f, _distance * factor)); }
- (int)textureCount { return _textureCount; }
- (int)indexCount { return _indexCount; }

- (void)drawInView:(MTKView *)view {
    if (!_indexBuffer) return;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable) return;
    MTLRenderPassDescriptor *rp = view.currentRenderPassDescriptor;
    if (!rp) return;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.07, 0.09, 0.12, 1.0);
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.clearDepth = 1.0;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];

    const float cx = (_bounds[0] + _bounds[3]) * 0.5f;
    const float cy = (_bounds[1] + _bounds[4]) * 0.5f;
    const float cz = (_bounds[2] + _bounds[5]) * 0.5f;

    const float cp = std::cos(_pitch), sp = std::sin(_pitch);
    const float cyaw = std::cos(_yaw), syaw = std::sin(_yaw);
    const float eye[3] = {cx + _distance * cp * syaw,
                          cy + _distance * sp,
                          cz + _distance * cp * cyaw};
    const float target[3] = {cx, cy, cz};
    const float up[3] = {0, 1, 0};

    const float aspect = (float)view.drawableSize.width / (float)view.drawableSize.height;
    const float nearZ = _freeCam ? std::max(0.5f, _distance * 0.01f)
                                 : (_distance * 0.01f + 0.05f);
    const float farZ  = _freeCam ? std::max(8000.0f, _distance * 40.0f)
                                 : (_distance * 20.0f + 2000.0f);
    sa::Mat4 proj = sa::Mat4::perspective(_freeCam ? 1.15f : 1.0f, aspect, nearZ, farZ);
    sa::Mat4 vw = sa::Mat4::lookAt(eye, target, up);
    sa::Mat4 model = sa::Mat4::identity();
    sa::Mat4 mvp = proj * vw * model;

    Uniforms u;
    std::memcpy(u.mvp, mvp.m, sizeof(u.mvp));
    std::memcpy(u.model, model.m, sizeof(u.model));
    u.lightDir[0] = -0.4f; u.lightDir[1] = -0.85f; u.lightDir[2] = -0.3f;
    u.ambient = 0.45f;
    u.cameraPos[0] = eye[0]; u.cameraPos[1] = eye[1]; u.cameraPos[2] = eye[2];
    u.pad = 0;

    [enc setDepthStencilState:_depthState];
    [enc setCullMode:MTLCullModeNone];
    [enc setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];

    [enc setFragmentSamplerState:_sampler atIndex:0];

    if (_subs.empty()) {
        int hasTex = _textureCount > 0 ? 1 : 0;
        [enc setFragmentBytes:&hasTex length:sizeof(hasTex) atIndex:2];
        if (hasTex) {
            [enc setRenderPipelineState:_pipelineTextured];
            [enc setFragmentTexture:_textures[0] atIndex:0];
        } else {
            [enc setRenderPipelineState:_pipelineSolid];
        }
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:_indexCount
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:_indexBuffer
                 indexBufferOffset:0];
    } else {
        for (const auto &sd : _subs) {
            if (sd.count == 0) continue;
            const bool hasTex = sd.tex >= 0 && sd.tex < (int)_textures.size();
            int hasTexFlag = hasTex ? 1 : 0;
            [enc setFragmentBytes:&hasTexFlag length:sizeof(hasTexFlag) atIndex:2];
            if (hasTex) {
                [enc setRenderPipelineState:_pipelineTextured];
                [enc setFragmentTexture:_textures[sd.tex] atIndex:0];
            } else {
                [enc setRenderPipelineState:_pipelineSolid];
            }
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:sd.count
                             indexType:MTLIndexTypeUInt32
                           indexBuffer:_indexBuffer
                     indexBufferOffset:(NSUInteger)sd.first * sizeof(unsigned int)];
        }
    }
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

@end
