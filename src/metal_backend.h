// Metal 后端接口（Objective-C++）
#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

@interface SAMetalRenderer : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (void)uploadMesh:(const float *)vertices
            vcount:(int)vcount
           indices:(const unsigned int *)indices
            icount:(int)icount
            bounds:(const float *)bounds;
- (int)uploadTexture:(const unsigned char *)rgba width:(int)w height:(int)h;
// 子网格：每段索引对应的贴图槽位（-1 表示无贴图）
- (void)uploadSubmeshes:(const unsigned int *)firstIndex
                 counts:(const unsigned int *)indexCount
              texSlots:(const int *)texSlots
                   num:(int)num;
// 子网格：每段索引对应的贴图槽位（-1 表示无贴图）
- (void)uploadSubmeshes:(const unsigned int *)firstIndex
                counts:(const unsigned int *)indexCount
             texSlots:(const int *)texSlots
                  num:(int)num;
- (void)drawInView:(MTKView *)view;
- (void)setSceneMode:(BOOL)scene;
- (void)setDebugMode:(int)m;
- (void)setOrbitScale:(float)s;
- (void)getBounds:(float *)out;
- (void)getCameraYaw:(float *)yaw pitch:(float *)pitch distance:(float *)dist;
- (void)setCameraYaw:(float)yaw pitch:(float)pitch;
- (void)zoomBy:(float)factor;
- (int)textureCount;
- (int)subDrawCount;
- (int)subDrawnCount;
- (int)indexCount;
@end

#endif
