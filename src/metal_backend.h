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
- (void)uploadTexture:(const unsigned char *)rgba width:(int)w height:(int)h;
- (void)drawInView:(MTKView *)view;
- (void)getBounds:(float *)out;
- (void)getCameraYaw:(float *)yaw pitch:(float *)pitch distance:(float *)dist;
- (void)setCameraYaw:(float)yaw pitch:(float)pitch;
- (int)textureCount;
- (int)indexCount;
@end

#endif
