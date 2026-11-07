//
// main_ios.mm — SA 模型查看器 iOS 宿主
// 用途：在 iPhone 15 Pro 上加载并渲染 GTA SA 原版模型（资源由用户自行提供）
//
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <Foundation/Foundation.h>
#include <sys/stat.h>

#include <map>
#include <string>
#include <vector>

#include "assets.h"
#include "renderer.h"
#include "metal_backend.h"
#include "pack.h"

// ---------------------------------------------------------------- 资源定位
// 查找精简资源包（mesh.bin + tex/*.png），优先于 gta3.img
static NSString *SAFindBundle(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray array];
    [cands addObject:[[[[fm URLsForDirectory:NSDocumentDirectory
                                   inDomains:NSUserDomainMask] firstObject] path]
                      stringByAppendingPathComponent:@"pack"]];
    NSString *res = [[NSBundle mainBundle] resourcePath];
    // 地图场景优先（内容更丰富）
    [cands addObject:[[res stringByAppendingPathComponent:@"Resources"]
                      stringByAppendingPathComponent:@"scene"]];
    [cands addObject:[res stringByAppendingPathComponent:@"scene"]];
    [cands addObject:[[res stringByAppendingPathComponent:@"Resources"]
                      stringByAppendingPathComponent:@"pack"]];
    [cands addObject:[res stringByAppendingPathComponent:@"pack"]];
    // 也接受 Documents/bundles/<名字>
    [cands addObject:[[[[fm URLsForDirectory:NSDocumentDirectory
                                   inDomains:NSUserDomainMask] firstObject] path]
                      stringByAppendingPathComponent:@"bundles/farmhouse01"]];
    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"mesh.bin"]]) return p;
    }
    return nil;
}

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
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        const float s = (float)g.scale;
        if (s > 0.01f) {
            [self.renderer zoomBy:1.0f / s];
            g.scale = 1.0f;
        }
    }
}

// 无游戏资源时的自测几何：一个带 UV 与法线的立方体，
// 用于验证 Metal 管线（着色器/顶点格式/深度/相机）是否正常工作。
static void buildSelfTestCube(sa::MeshData &mesh) {
    const float s = 0.5f;
    struct Face { float n[3]; float v[4][3]; };
    const Face faces[6] = {
        {{1, 0, 0}, {{s, -s, -s}, {s, s, -s}, {s, s, s}, {s, -s, s}}},
        {{-1, 0, 0}, {{-s, -s, s}, {-s, s, s}, {-s, s, -s}, {-s, -s, -s}}},
        {{0, 1, 0}, {{-s, s, s}, {s, s, s}, {s, s, -s}, {-s, s, -s}}},
        {{0, -1, 0}, {{-s, -s, -s}, {s, -s, -s}, {s, -s, s}, {-s, -s, s}}},
        {{0, 0, 1}, {{-s, -s, s}, {s, -s, s}, {s, s, s}, {-s, s, s}}},
        {{0, 0, -1}, {{s, -s, -s}, {-s, -s, -s}, {-s, s, -s}, {s, s, -s}}},
    };
    for (const auto &f : faces) {
        const uint32_t base = (uint32_t)mesh.vertices.size();
        const float uv[4][2] = {{0, 1}, {0, 0}, {1, 0}, {1, 1}};
        for (int i = 0; i < 4; ++i) {
            sa::Vertex v{};
            v.pos[0] = f.v[i][0]; v.pos[1] = f.v[i][1]; v.pos[2] = f.v[i][2];
            v.normal[0] = f.n[0]; v.normal[1] = f.n[1]; v.normal[2] = f.n[2];
            v.uv[0] = uv[i][0]; v.uv[1] = uv[i][1];
            v.color[0] = v.color[1] = v.color[2] = v.color[3] = 1.0f;
            mesh.vertices.push_back(v);
        }
        mesh.indices.insert(mesh.indices.end(),
                            {base, base + 1, base + 2, base, base + 2, base + 3});
    }
    mesh.bounds[0] = mesh.bounds[1] = mesh.bounds[2] = -s;
    mesh.bounds[3] = mesh.bounds[4] = mesh.bounds[5] = s;
    sa::SubMesh sm;
    sm.firstIndex = 0;
    sm.indexCount = (uint32_t)mesh.indices.size();
    mesh.submeshes.push_back(sm);
}

- (void)loadAssets {
    // 1) 优先：精简资源包（不需要 gta3.img）
    NSString *bundlePath = SAFindBundle();
    if (bundlePath) {
        sa::PackInfo pack;
        if (sa::loadBundle([bundlePath UTF8String], pack)) {
            [self.renderer uploadMesh:(const float *)pack.mesh.vertices.data()
                               vcount:(int)pack.mesh.vertices.size()
                              indices:pack.mesh.indices.data()
                               icount:(int)pack.mesh.indices.size()
                               bounds:pack.mesh.bounds];

            std::map<std::string, int> slot;
            std::vector<unsigned int> firsts, counts;
            std::vector<int> slots;
            for (int i = 0; i < (int)pack.textures.size(); ++i) {
                const auto &t = pack.textures[i];
                [self.renderer uploadTexture:t.rgba.data() width:t.width height:t.height];
                slot[t.name] = i;
            }
            for (const auto &sm : pack.mesh.submeshes) {
                firsts.push_back(sm.firstIndex);
                counts.push_back(sm.indexCount);
                auto it = slot.find(sm.textureName);
                slots.push_back(it == slot.end() ? -1 : it->second);
            }
            [self.renderer uploadSubmeshes:firsts.data()
                                    counts:counts.data()
                                 texSlots:slots.data()
                                       num:(int)firsts.size()];

            // 子网格数量很多说明是场景包
            const BOOL isScene = pack.mesh.submeshes.size() > 40;
            [self.renderer setSceneMode:isScene];
            self.loaded = YES;
            const float *b = pack.mesh.bounds;
            int noTex = 0;
            for (const auto &sm : pack.mesh.submeshes)
                if (slot.find(sm.textureName) == slot.end()) ++noTex;
            self.infoLabel.text = [NSString stringWithFormat:
                @"%@\n%d 顶点  %d 三角形\n子网格 %zu  ·  贴图 %zu（未绑定 %d）\n尺寸 %.0f×%.0f×%.0f",
                isScene ? @"地图场景（Grove Street）" : @"资源包模式",
                pack.vertexCount, pack.triangleCount, pack.mesh.submeshes.size(),
                pack.textures.size(), noTex, b[3] - b[0], b[4] - b[1], b[5] - b[2]];
            self.statusLabel.text = isScene ? @"拖拽环绕  ·  双指缩放"
                                            : @"拖拽旋转  ·  双指缩放";
            return;
        }
    }

    // 2) 其次：完整 gta3.img
    NSString *root = SAFindModelsRoot();
    if (!root) {
        // 没有游戏资源：渲染自测立方体，确认 GPU 管线可用
        sa::MeshData cube;
        buildSelfTestCube(cube);
        [self.renderer uploadMesh:(const float *)cube.vertices.data()
                           vcount:(int)cube.vertices.size()
                          indices:cube.indices.data()
                           icount:(int)cube.indices.size()
                           bounds:cube.bounds];
        self.loaded = YES;
        self.infoLabel.text = @"GPU 自测模式（立方体）\n\n未找到 gta3.img\n请将 models/gta3.img 放入\n「文件」App → 我的 iPhone → SAViewer/";
        self.statusLabel.text = @"拖拽旋转  ·  放入游戏文件后重启即可显示真实模型";
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

    // 加载贴图：优先同名 TXD，其次在全局纹理索引里逐个查找
    int texLoaded = 0;
    std::vector<std::string> slotNames;   // 槽位 → 纹理名
    std::string txdName = modelName;
    auto dot = txdName.rfind('.');
    if (dot != std::string::npos) txdName = txdName.substr(0, dot);
    txdName += ".txd";

    // 从模型同名 TXD 里一次性建名字表（最常见的情况：贴图就在一起）
    std::map<std::string, sa::Texture> texBank;
    if (store.primary && store.primary->find(txdName)) {
        std::vector<uint8_t> txdData;
        if (store.primary->readEntry(txdName, txdData)) {
            for (auto &t : sa::parseTXD(txdData))
                if (!t.name.empty()) texBank[t.name] = std::move(t);
        }
    }

    std::map<std::string, int> texSlot;
    for (const auto &sub : mesh.submeshes) {
        const std::string &want = sub.textureName;
        if (want.empty()) { slotNames.push_back(""); continue; }
        if (texSlot.count(want)) { slotNames.push_back(want); continue; }

        sa::Texture t;
        bool got = false;
        auto it = texBank.find(want);
        if (it != texBank.end()) { t = it->second; got = true; }
        // 同名 TXD 里没有时，先试 gta3.img 中该名字对应的独立 TXD
        if (!got) got = store.loadTextureFrom(want + ".txd", want, t);
        if (!got) got = store.loadTexture(want + ".txd", t);
        if (got) {
            std::vector<uint8_t> rgba = t.decodeRGBA();
            if (!rgba.empty()) {
                [self.renderer uploadTexture:rgba.data() width:t.width height:t.height];
                texSlot[want] = texLoaded++;
            } else {
                texSlot[want] = -1;
            }
        } else {
            texSlot[want] = -1;
        }
        slotNames.push_back(want);
    }

    // 把子网格映射成 [首索引, 索引数, 贴图槽位]
    {
        std::vector<unsigned int> firsts, counts;
        std::vector<int> slots;
        for (const auto &sub : mesh.submeshes) {
            firsts.push_back(sub.firstIndex);
            counts.push_back(sub.indexCount);
            auto it = texSlot.find(sub.textureName);
            slots.push_back(it == texSlot.end() ? -1 : it->second);
        }
        [self.renderer uploadSubmeshes:firsts.data()
                                counts:counts.data()
                             texSlots:slots.data()
                                   num:(int)firsts.size()];
    }

    self.loaded = YES;
    float mnx = mesh.bounds[0], mny = mesh.bounds[1], mnz = mesh.bounds[2];
    float mxx = mesh.bounds[3], mxy = mesh.bounds[4], mxz = mesh.bounds[5];
    self.infoLabel.text = [NSString stringWithFormat:
        @"%s\n%zu 几何体  %d 顶点  %d 三角形\n子网格 %zu  ·  贴图 %d/%zu\n尺寸 %.1f×%.1f×%.1f",
        modelName.c_str(), model.geometries.size(), model.totalVertices,
        model.totalTriangles, mesh.submeshes.size(), texLoaded,
        model.textureNames.size(), mxx - mnx, mxy - mny, mxz - mnz];
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
