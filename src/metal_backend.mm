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
#include <memory>

#include "metal_backend.h"
#include "renderer.h"
#include "ground.h"
#include "collision.h"

// 必须与 Metal 侧布局完全一致：Metal 的 float3 按 16 字节对齐，
// 因此每个 float3 后面都要显式补 1 个 float，否则后续字段全部错位。
struct Uniforms {
    float mvp[16];       // 0..64
    float model[16];     // 64..128
    float lightDir[3];   // 128..140
    float lightPad;      // 140..144
    float ambient;       // 144..148
    float ambientPad[3]; // 148..160
    float cameraPos[3];  // 160..172
    float pad;           // 172..176  ← 调试模式
    float tail[4];       // 176..192 与 Metal 侧 float4 对齐一致
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

    // 车辆（独立绘制，带自身变换）
    id<MTLBuffer> _carVerts;
    id<MTLBuffer> _carIdx;
    int _carIndexCount;
    struct CarSub { unsigned first, count; int tex; };
    std::vector<CarSub> _carSubs;

    float _yaw, _pitch, _distance;
    float _bounds[6];
    int   _indexCount;
    int   _textureCount;
    BOOL  _freeCam;       // YES = 场景模式（绕场景中心大轨道飞行）
    float _orbitScale;
    float _debugMode;   // 0=正常 1=贴图 2=法线 3=光照

    // 第一人称
    BOOL  _fpsMode;
    float _fpsPos[3];       // 摄像机世界坐标
    float _fpsYaw, _fpsPitch;
    std::unique_ptr<sa::GroundGrid> _ground;
    std::unique_ptr<sa::CollisionWorld> _coll;
    float _eyeHeight;
    float _walkSpeed;

    // 驾驶
    BOOL  _driveMode;
    float _carPos[3];
    float _carYaw;        // 车头朝向（弧度）
    float _carSpeed;      // m/s
    float _carSteer;      // 前轮转角（弧度）
    float _carWheelSpin;  // 车轮累计旋转
    float _camYaw;        // 跟随相机朝向
    float _camPitch;
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
        _debugMode = 0.0f;
        _fpsMode = NO;
        _eyeHeight = 1.7f;
        _walkSpeed = 12.0f;
        _fpsYaw = 0.0f;
        _fpsPitch = 0.0f;
        _driveMode = NO;
        _carPos[0] = _carPos[1] = _carPos[2] = 0.0f;
        _carYaw = 0.0f;
        _carSpeed = 0.0f;
        _carSteer = 0.0f;
        _carWheelSpin = 0.0f;
        _camYaw = 0.6f;
        _camPitch = 0.32f;
        _fpsPos[0] = _fpsPos[1] = _fpsPos[2] = 0.0f;
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

- (int)uploadTexture:(const unsigned char *)rgba width:(int)w height:(int)h {
    if (!rgba || w <= 0 || h <= 0) return -1;
    @autoreleasepool {
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:w
                                        height:h
                                     mipmapped:NO];
        id<MTLTexture> tex = [_device newTextureWithDescriptor:td];
        if (!tex) {
            NSLog(@"SA: 纹理创建失败 %dx%d", w, h);
            return -1;
        }
        [tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
               mipmapLevel:0
                 withBytes:rgba
               bytesPerRow:(NSUInteger)w * 4];
        _textures.push_back(tex);
    }
    _textureCount = (int)_textures.size();
    return _textureCount - 1;   // 返回实际槽位
}

- (void)uploadVehicle:(const float *)verts
               vcount:(int)vcount
              indices:(const unsigned int *)indices
               icount:(int)icount {
    _carVerts = [_device newBufferWithBytes:verts
                                     length:(size_t)vcount * sizeof(float) * 12
                                    options:MTLResourceStorageModeShared];
    _carIdx = [_device newBufferWithBytes:indices
                                   length:(size_t)icount * sizeof(unsigned int)
                                  options:MTLResourceStorageModeShared];
    _carIndexCount = icount;
}

- (void)uploadVehicleSubmeshes:(const unsigned int *)firstIndex
                        counts:(const unsigned int *)indexCount
                      texSlots:(const int *)texSlots
                           num:(int)num {
    _carSubs.clear();
    for (int i = 0; i < num; ++i)
        _carSubs.push_back({firstIndex[i], indexCount[i], texSlots[i]});
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

- (void)setGroundData:(const float *)verts
               vcount:(int)vcount
              indices:(const unsigned int *)indices
               icount:(int)icount
          groundPath:(NSString *)path {
    sa::MeshData md;
    md.vertices.resize(vcount);
    for (int i = 0; i < vcount; ++i) {
        md.vertices[i].pos[0] = verts[i * 12 + 0];
        md.vertices[i].pos[1] = verts[i * 12 + 1];
        md.vertices[i].pos[2] = verts[i * 12 + 2];
        md.vertices[i].uv[0] = verts[i * 12 + 6];
        md.vertices[i].uv[1] = verts[i * 12 + 7];
    }
    md.indices.assign(indices, indices + icount);
    auto g = std::make_unique<sa::GroundGrid>();
    if (g->load([path UTF8String], md)) {
        _ground = std::move(g);
    }
}

- (void)setCollisionPath:(NSString *)path {
    auto w = std::make_unique<sa::CollisionWorld>();
    if (w->load([path UTF8String])) {
        _coll = std::move(w);
        NSLog(@"SA: 碰撞世界 %d 三角形", _coll->triangleCount());
    }
}

- (void)setFirstPerson:(BOOL)on {
    _fpsMode = on;
    if (on) {
        // 从场景中心开始
        _fpsPos[0] = (_bounds[0] + _bounds[3]) * 0.5f;
        _fpsPos[2] = (_bounds[2] + _bounds[5]) * 0.5f;
        _fpsYaw = 0.0f;
        _fpsPitch = -0.05f;
        // 贴地
        float y = 0;
        const bool gotY = _coll ? _coll->groundAt(_fpsPos[0], _fpsPos[2], y)
                                : (_ground && _ground->heightAt(_fpsPos[0], _fpsPos[2], y));
        if (gotY) {
            _fpsPos[1] = y + _eyeHeight;
        } else {
            _fpsPos[1] = (_bounds[1] + _bounds[4]) * 0.5f + _eyeHeight;
        }
    }
}

- (BOOL)isFirstPerson { return _fpsMode; }

// 以「屏幕拖拽量」转动视角
- (void)lookByDX:(float)dx dy:(float)dy {
    if (!_fpsMode) return;
    _fpsYaw -= dx * 0.004f;
    _fpsPitch -= dy * 0.004f;
    const float lim = 1.45f;
    if (_fpsPitch > lim) _fpsPitch = lim;
    if (_fpsPitch < -lim) _fpsPitch = -lim;
}

// 按输入方向移动（前=+1，右=+1），并贴地
- (void)moveForward:(float)fwd right:(float)right dt:(float)dt {
    if (!_fpsMode) return;
    const float cy = std::cos(_fpsYaw), sy = std::sin(_fpsYaw);
    // 前方向（水平）
    const float fx = -sy, fz = -cy;
    // 右方向
    const float rx = cy, rz = -sy;
    float nx = _fpsPos[0] + (fx * fwd + rx * right) * _walkSpeed * dt;
    float nz = _fpsPos[2] + (fz * fwd + rz * right) * _walkSpeed * dt;

    float gy = 0;
    const bool haveGround = _coll ? _coll->groundAt(nx, nz, gy)
                                  : (_ground && _ground->heightAt(nx, nz, gy));
    if (!haveGround) return;   // 前方无地面不动

    // 墙体阻挡：脚部高度做水平射线检测
    if (_coll && _coll->blocked(_fpsPos[0], _fpsPos[2], nx, nz,
                                _fpsPos[1] - _eyeHeight)) {
        // 被挡住：尝试只沿 X 或只沿 Z 滑动
        float yx = 0, yz = 0;
        const float sx = _fpsPos[0] + (fx * fwd + rx * right) * _walkSpeed * dt;
        const float sz = _fpsPos[2] + (fz * fwd + rz * right) * _walkSpeed * dt;
        if (!_coll->blocked(_fpsPos[0], _fpsPos[2], sx, _fpsPos[2],
                            _fpsPos[1] - _eyeHeight) &&
            _coll->groundAt(sx, _fpsPos[2], yx)) {
            _fpsPos[0] = sx;
            _fpsPos[1] += (yx + _eyeHeight - _fpsPos[1]) * std::min(1.0f, dt * 12.0f);
        } else if (!_coll->blocked(_fpsPos[0], _fpsPos[2], _fpsPos[0], sz,
                                   _fpsPos[1] - _eyeHeight) &&
                   _coll->groundAt(_fpsPos[0], sz, yz)) {
            _fpsPos[2] = sz;
            _fpsPos[1] += (yz + _eyeHeight - _fpsPos[1]) * std::min(1.0f, dt * 12.0f);
        }
        return;
    }

    _fpsPos[0] = nx;
    _fpsPos[2] = nz;
    // 平滑贴地，避免台阶瞬跳
    const float want = gy + _eyeHeight;
    _fpsPos[1] += (want - _fpsPos[1]) * std::min(1.0f, dt * 12.0f);
}

// ---------------- 驾驶 ----------------
- (void)enableDriveMode:(BOOL)on {
    _driveMode = on;
    if (on) {
        _fpsMode = NO;
        // 车放在场景中心附近的地面上
        const float cx = (_bounds[0] + _bounds[3]) * 0.5f;
        const float cz = (_bounds[2] + _bounds[5]) * 0.5f;
        float gy = 0;
        if (_coll && _coll->groundAt(cx, cz, gy)) {
            _carPos[0] = cx; _carPos[1] = gy; _carPos[2] = cz;
        } else {
            _carPos[0] = cx; _carPos[1] = (_bounds[1] + _bounds[4]) * 0.5f; _carPos[2] = cz;
        }
        _carYaw = 0.0f;
        _carSpeed = 0.0f;
        _carSteer = 0.0f;
    }
}

- (BOOL)isDriving { return _driveMode; }

// throttle: -1(倒车)..1(前进)  steer: -1(左)..1(右)  brake: 0..1
- (void)updateDriveWithThrottle:(float)throttle steer:(float)steer brake:(float)brake dt:(float)dt {
    if (!_driveMode || dt <= 0) return;
    const float maxSpeed = 45.0f;      // ~160 km/h
    const float accel = 14.0f;
    const float brakeDecel = 22.0f;
    const float friction = 4.5f;

    // 转向：速度越高，最大转角越小（防止高速甩尾）
    const float speedRatio = std::fmin(std::fabs(_carSpeed) / maxSpeed, 1.0f);
    const float maxSteer = 0.55f * (1.0f - 0.72f * speedRatio);
    _carSteer += (steer * maxSteer - _carSteer) * std::fmin(1.0f, dt * 8.0f);

    if (brake > 0.1f) {
        const float d = brakeDecel * brake * dt;
        if (_carSpeed > 0) _carSpeed = std::fmax(0.0f, _carSpeed - d);
        else _carSpeed = std::fmin(0.0f, _carSpeed + d);
    } else if (std::fabs(throttle) > 0.05f) {
        _carSpeed += throttle * accel * dt;
    } else {
        // 自然减速
        const float d = friction * dt;
        if (_carSpeed > 0) _carSpeed = std::fmax(0.0f, _carSpeed - d);
        else _carSpeed = std::fmin(0.0f, _carSpeed + d);
    }
    _carSpeed = std::fmax(-maxSpeed * 0.35f, std::fmin(maxSpeed, _carSpeed));

    // 转向改变朝向（速度越快转得越快）
    if (std::fabs(_carSpeed) > 0.3f) {
        const float turn = _carSteer * _carSpeed * 0.055f * dt;
        _carYaw += turn;
    }

    // 位移：车头朝 -Z
    const float fx = -std::sin(_carYaw);
    const float fz = -std::cos(_carYaw);
    const float nx = _carPos[0] + fx * _carSpeed * dt;
    const float nz = _carPos[2] + fz * _carSpeed * dt;

    // 碰撞：撞墙则停下
    if (_coll && _coll->blocked(_carPos[0], _carPos[2], nx, nz, _carPos[1] + 0.4f)) {
        _carSpeed *= -0.25f;
    } else {
        _carPos[0] = nx;
        _carPos[2] = nz;
    }
    // 贴地
    float gy = 0;
    const bool got = _coll ? _coll->groundAt(_carPos[0], _carPos[2], gy)
                           : (_ground && _ground->heightAt(_carPos[0], _carPos[2], gy));
    if (got) _carPos[1] += (gy - _carPos[1]) * std::fmin(1.0f, dt * 8.0f);

    _carWheelSpin += _carSpeed * dt * 3.0f;
}

- (void)lookCarByDX:(float)dx dy:(float)dy {
    _camYaw -= dx * 0.004f;
    _camPitch += dy * 0.003f;
    _camPitch = std::fmax(-0.2f, std::fmin(1.2f, _camPitch));
}

- (float)carSpeedKmh { return _carSpeed * 3.6f; }
- (void)getCarPos:(float *)out { std::memcpy(out, _carPos, sizeof(_carPos)); }

- (void)getFpsPosition:(float *)out { std::memcpy(out, _fpsPos, sizeof(_fpsPos)); }
- (void)setDebugMode:(int)m { _debugMode = (float)m; }
- (void)setOrbitScale:(float)s { _orbitScale = s; }
- (void)getBounds:(float *)out { std::memcpy(out, _bounds, sizeof(_bounds)); }
- (void)getCameraYaw:(float *)yaw pitch:(float *)pitch distance:(float *)dist {
    *yaw = _yaw; *pitch = _pitch; *dist = _distance;
}
- (void)setCameraYaw:(float)yaw pitch:(float)pitch { _yaw = yaw; _pitch = pitch; }
- (void)zoomBy:(float)factor { _distance = std::fmax(0.5f, std::fmin(20000.0f, _distance * factor)); }
- (int)textureCount { return _textureCount; }
- (int)subDrawCount { return (int)_subs.size(); }
- (int)subDrawnCount {
    int n = 0;
    for (const auto &sd : _subs) if (sd.count) ++n;
    return n;
}
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

    float eye[3];
    float target[3];
    const float up[3] = {0, 1, 0};

    if (_driveMode) {
        // 第三人称跟随：相机在车后上方，朝向由 _camYaw/_camPitch 控制
        const float back = 7.0f + _carSpeed * 0.12f;
        const float cp3 = std::cos(_camPitch), sp3 = std::sin(_camPitch);
        const float cy3 = std::cos(_carYaw + _camYaw), sy3 = std::sin(_carYaw + _camYaw);
        eye[0] = _carPos[0] + back * cp3 * sy3;
        eye[1] = _carPos[1] + 2.4f + back * sp3;
        eye[2] = _carPos[2] + back * cp3 * cy3;
        target[0] = _carPos[0];
        target[1] = _carPos[1] + 0.9f;
        target[2] = _carPos[2];
    } else if (_fpsMode) {
        // 第一人称：站在地面上，视线由 yaw/pitch 决定
        eye[0] = _fpsPos[0]; eye[1] = _fpsPos[1]; eye[2] = _fpsPos[2];
        const float cp2 = std::cos(_fpsPitch), sp2 = std::sin(_fpsPitch);
        const float cy2 = std::cos(_fpsYaw), sy2 = std::sin(_fpsYaw);
        // 前方向：yaw=0 朝 -Z
        target[0] = eye[0] + cp2 * (-sy2);
        target[1] = eye[1] + sp2;
        target[2] = eye[2] + cp2 * (-cy2);
    } else {
        const float cp = std::cos(_pitch), sp = std::sin(_pitch);
        const float cyaw = std::cos(_yaw), syaw = std::sin(_yaw);
        eye[0] = cx + _distance * cp * syaw;
        eye[1] = cy + _distance * sp;
        eye[2] = cz + _distance * cp * cyaw;
        target[0] = cx; target[1] = cy; target[2] = cz;
    }

    const CGSize ds = view.drawableSize;
    if (ds.width < 1.0 || ds.height < 1.0) return;   // 旋转瞬间可能为 0
    const float aspect = (float)ds.width / (float)ds.height;
    const float nearZ = _driveMode ? 0.2f
                       : _fpsMode ? 0.15f
                       : (_freeCam ? std::max(0.5f, _distance * 0.01f)
                                   : (_distance * 0.01f + 0.05f));
    const float farZ  = _driveMode ? 4000.0f
                       : _fpsMode ? 3000.0f
                       : (_freeCam ? std::max(8000.0f, _distance * 40.0f)
                                   : (_distance * 20.0f + 2000.0f));
    sa::Mat4 proj = sa::Mat4::perspective(
        _driveMode ? 1.25f : (_fpsMode ? 1.35f : (_freeCam ? 1.15f : 1.0f)),
        aspect, nearZ, farZ);
    sa::Mat4 vw = sa::Mat4::lookAt(eye, target, up);
    sa::Mat4 model = sa::Mat4::identity();
    if (_driveMode) {
        // 平移 + 绕 Y 轴旋转 + 车轮自转（先不拆轮，整体旋转即可）
        const float cy4 = std::cos(_carYaw), sy4 = std::sin(_carYaw);
        sa::Mat4 rot = sa::Mat4::identity();
        rot.m[0] = cy4; rot.m[2] = -sy4;
        rot.m[8] = sy4; rot.m[10] = cy4;
        sa::Mat4 tr = sa::Mat4::identity();
        tr.m[12] = _carPos[0]; tr.m[13] = _carPos[1]; tr.m[14] = _carPos[2];
        model = tr * rot;
    }
    sa::Mat4 mvp = proj * vw * model;

    Uniforms u;
    std::memcpy(u.mvp, mvp.m, sizeof(u.mvp));
    std::memcpy(u.model, model.m, sizeof(u.model));
    u.lightPad = 0;
    u.ambientPad[0] = u.ambientPad[1] = u.ambientPad[2] = 0;
    u.tail[0] = u.tail[1] = u.tail[2] = u.tail[3] = 0;
    u.lightDir[0] = -0.4f; u.lightDir[1] = -0.85f; u.lightDir[2] = -0.3f;
    u.ambient = 0.45f;
    u.cameraPos[0] = eye[0]; u.cameraPos[1] = eye[1]; u.cameraPos[2] = eye[2];
    u.pad = _debugMode;

    [enc setDepthStencilState:_depthState];
    [enc setCullMode:MTLCullModeNone];
    [enc setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];

    [enc setFragmentSamplerState:_sampler atIndex:0];
    struct { int hasTexture; int p0, p1, p2; } fragParams = {0, 0, 0, 0};

    if (_subs.empty()) {
        int hasTex = _textureCount > 0 ? 1 : 0;
        fragParams.hasTexture = hasTex;
        [enc setFragmentBytes:&fragParams length:sizeof(fragParams) atIndex:2];
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
        // 先画有贴图的（pipeline 只设一次），再画无贴图的
        [enc setRenderPipelineState:_pipelineTextured];
        fragParams.hasTexture = 1;
        [enc setFragmentBytes:&fragParams length:sizeof(fragParams) atIndex:2];
        int lastTex = -1;
        for (const auto &sd : _subs) {
            if (sd.count == 0 || sd.tex < 0 || sd.tex >= (int)_textures.size()) continue;
            if (sd.tex != lastTex) {
                [enc setFragmentTexture:_textures[sd.tex] atIndex:0];
                lastTex = sd.tex;
            }
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:sd.count
                             indexType:MTLIndexTypeUInt32
                           indexBuffer:_indexBuffer
                     indexBufferOffset:(NSUInteger)sd.first * sizeof(unsigned int)];
        }
        // 无贴图部分统一走棋盘格
        BOOL hasSolid = NO;
        for (const auto &sd : _subs)
            if (sd.count && (sd.tex < 0 || sd.tex >= (int)_textures.size())) { hasSolid = YES; break; }
        if (hasSolid) {
            [enc setRenderPipelineState:_pipelineSolid];
            for (const auto &sd : _subs) {
                if (sd.count == 0 || (sd.tex >= 0 && sd.tex < (int)_textures.size())) continue;
                [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:sd.count
                                 indexType:MTLIndexTypeUInt32
                               indexBuffer:_indexBuffer
                         indexBufferOffset:(NSUInteger)sd.first * sizeof(unsigned int)];
            }
        }
    }
    // ---- 车辆（用独立变换重算 MVP）
    if (_driveMode && _carVerts && _carIdx && _carIndexCount > 0) {
        sa::Mat4 mv = proj * vw * model;
        Uniforms u2 = u;
        std::memcpy(u2.mvp, mv.m, sizeof(u2.mvp));
        std::memcpy(u2.model, model.m, sizeof(u2.model));
        [enc setVertexBuffer:_carVerts offset:0 atIndex:0];
        [enc setVertexBytes:&u2 length:sizeof(u2) atIndex:1];
        [enc setFragmentBytes:&u2 length:sizeof(u2) atIndex:1];
        int hasT = 1;
        [enc setFragmentBytes:&hasT length:sizeof(hasT) atIndex:2];
        [enc setRenderPipelineState:_pipelineTextured];
        int lastT = -1;
        for (const auto &cs : _carSubs) {
            if (cs.count == 0) continue;
            int slot = cs.tex;
            if (slot < 0 || slot >= (int)_textures.size()) {
                int zero = 0;
                [enc setFragmentBytes:&zero length:sizeof(zero) atIndex:2];
                [enc setRenderPipelineState:_pipelineSolid];
                [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:cs.count indexType:MTLIndexTypeUInt32
                               indexBuffer:_carIdx indexBufferOffset:(NSUInteger)cs.first * 4];
                [enc setRenderPipelineState:_pipelineTextured];
                [enc setFragmentBytes:&hasT length:sizeof(hasT) atIndex:2];
                continue;
            }
            if (slot != lastT) {
                [enc setFragmentTexture:_textures[slot] atIndex:0];
                lastT = slot;
            }
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:cs.count indexType:MTLIndexTypeUInt32
                           indexBuffer:_carIdx indexBufferOffset:(NSUInteger)cs.first * 4];
        }
    }

    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

@end
