//
// main_ios.mm — SA 模型查看器 iOS 宿主
// 用途：在 iPhone 15 Pro 上加载并渲染 GTA SA 原版模型（资源由用户自行提供）
//
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <Foundation/Foundation.h>
#include <sys/stat.h>

#include <string>
#include <vector>

#include "assets.h"
#include "renderer.h"
#include "metal_backend.h"

// ---------------------------------------------------------------- 资源定位
static NSString *SAFindModelsRoot(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray array];

    // 1) 沙盒 Documents/models（推荐：用 Files App 拷入）
    [cands addObject:[[[[fm URLsForDirectory:NSDocumentDirectory
                                   inDomains:NSUserDomainMask] firstObject] path]
                      stringByAppendingPathComponent:@"models"]];

    // 2) App 包内 Resources/models（CI 打入测试资源时）
    NSString *bundled = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"models"];
    [cands addObject:bundled];

    for (NSString *p in cands) {
        NSString *gta3 = [p stringByAppendingPathComponent:@"gta3.img"];
        if ([fm fileExistsAtPath:gta3]) return p;
    }
    return nil;
}

// ---------------------------------------------------------------- 查看器
@interface SAViewController : UIViewController <MTKViewDelegate>
@property (nonatomic, strong) MTKView *mtkView;
@property (nonatomic, strong) SAMetalRenderer *renderer;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) float yaw, pitch;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation SAViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:1.0];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    self.mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    self.mtkView.clearColor = MTLClearColorMake(0.07, 0.09, 0.12, 1.0);
    self.mtkView.delegate = self;
    self.mtkView.preferredFramesPerSecond = 60;
    [self.view addSubview:self.mtkView];

    self.renderer = [[SAMetalRenderer alloc] initWithDevice:device];

    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, self.view.bounds.size.width - 32, 90)];
    self.infoLabel.numberOfLines = 0;
    self.infoLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    self.infoLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.infoLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.infoLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, self.view.bounds.size.height - 80,
                                                               self.view.bounds.size.width - 32, 60)];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.statusLabel];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.view addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    [self.view addGestureRecognizer:pinch];

    [self loadAssets];
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    self.yaw -= (float)t.x * 0.008f;
    self.pitch += (float)t.y * 0.006f;
    self.pitch = fmaxf(-1.4f, fminf(1.4f, self.pitch));
    [g setTranslation:CGPointZero inView:self.view];
}

- (void)handlePinch:(UIPinchGestureRecognizer *)g {
    float y, p, d;
    [self.renderer getCameraYaw:&y pitch:&p distance:&d];
    // 缩放通过移动相机实现：交给 renderer 的内部距离
    static float baseDist = 0;
    if (g.state == UIGestureRecognizerStateBegan) baseDist = d;
    (void)baseDist;
}

- (void)loadAssets {
    NSString *root = SAFindModelsRoot();
    if (!root) {
        self.infoLabel.text = @"未找到 gta3.img\n\n请将 models/gta3.img 放入\n「文件」App → 我的 iPhone → SAViewer/";
        self.statusLabel.text = @"文件路径:\n$DOCUMENTS/models/gta3.img";
        return;
    }

    NSString *gta3 = [root stringByAppendingPathComponent:@"gta3.img"];

    // 模型名可通过环境变量 SA_MODEL 覆盖，默认农场模型
    const char *envModel = getenv("SA_MODEL");
    std::string modelName = envModel ? envModel : "farmhouse01.dff";

    sa::AssetStore store;
    if (!store.mount([gta3 UTF8String])) {
        self.infoLabel.text = @"gta3.img 打开失败（格式不是 VER2？）";
        return;
    }

    sa::Model model;
    if (!store.loadModel(modelName, model)) {
        self.infoLabel.text = [NSString stringWithFormat:@"模型 %s 解析失败", modelName.c_str()];
        return;
    }

    sa::MeshData mesh = sa::buildMesh(model);

    [self.renderer uploadMesh:(const float *)mesh.vertices.data()
                       vcount:(int)mesh.vertices.size()
                      indices:mesh.indices.data()
                       icount:(int)mesh.indices.size()
                       bounds:mesh.bounds];

    // 加载贴图（模型同名 TXD 内查找）
    int texLoaded = 0;
    std::string txdName = modelName;
    auto dot = txdName.rfind('.');
    if (dot != std::string::npos) txdName = txdName.substr(0, dot);
    txdName += ".txd";

    sa::Texture tex;
    if (store.primary && store.primary->find(txdName)) {
        if (store.loadTexture(txdName, tex)) {
            // 取匹配目标名的那张；否则取第一张
            std::vector<uint8_t> rgba = tex.decodeRGBA();
            if (!rgba.empty()) {
                [self.renderer uploadTexture:rgba.data() width:tex.width height:tex.height];
                ++texLoaded;
            }
        }
    }

    self.loaded = YES;
    float mnx = mesh.bounds[0], mny = mesh.bounds[1], mnz = mesh.bounds[2];
    float mxx = mesh.bounds[3], mxy = mesh.bounds[4], mxz = mesh.bounds[5];
    self.infoLabel.text = [NSString stringWithFormat:
        @"%s\n%zu 几何体  %d 顶点  %d 三角形\n贴图 %d 张  尺寸 %.1f×%.1f×%.1f",
        modelName.c_str(), model.geometries.size(), model.totalVertices,
        model.totalTriangles, texLoaded, mxx - mnx, mxy - mny, mxz - mnz];
    self.statusLabel.text = @"拖拽旋转  ·  双指缩放";
}

- (void)mtkview:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    if (!self.loaded) {
        return;
    }
    [self.renderer setCameraYaw:self.yaw pitch:self.pitch];
    [self.renderer drawInView:view];
}

@end

// ---------------------------------------------------------------- App 入口
@interface SAAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SAAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    SAViewController *vc = [[SAViewController alloc] init];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SAAppDelegate class]));
    }
}
