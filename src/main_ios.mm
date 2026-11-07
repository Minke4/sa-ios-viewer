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
#import "joystick.h"

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

static NSString *SAFindCarBundle(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *res = [[NSBundle mainBundle] resourcePath];
    NSMutableArray *c = [NSMutableArray array];
    [c addObject:[[res stringByAppendingPathComponent:@"Resources"] stringByAppendingPathComponent:@"car"]];
    [c addObject:[res stringByAppendingPathComponent:@"car"]];
    for (NSString *p in c) {
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
@property (nonatomic, assign) int debugMode;
@property (nonatomic, strong) SAJoystickView *joystick;
@property (nonatomic, strong) UIButton *modeButton;
@property (nonatomic, assign) BOOL fpsMode;
@property (nonatomic, assign) BOOL driveMode;
@property (nonatomic, assign) BOOL hasCar;
@property (nonatomic, assign) CFAbsoluteTime lastTick;
@property (nonatomic, strong) CADisplayLink *tick;
@end

@implementation SAViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:1.0];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    self.mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.mtkView.frame = self.view.bounds;
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
    [self.view addSubview:self.infoLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, self.view.bounds.size.height - 80,
                                                               self.view.bounds.size.width - 32, 60)];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.view addSubview:self.statusLabel];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.view addGestureRecognizer:pan];

    // 虚拟摇杆（左下）
    const CGFloat js = 150;
    self.joystick = [[SAJoystickView alloc] initWithFrame:
        CGRectMake(30, self.view.bounds.size.height - js - 40, js, js)];
    self.joystick.hidden = YES;
    [self.view addSubview:self.joystick];

    // 模式切换按钮（右下）
    self.modeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.modeButton.frame = CGRectMake(self.view.bounds.size.width - 130,
                                       self.view.bounds.size.height - 100, 110, 44);

    [self.modeButton setTitle:@"进入漫游" forState:UIControlStateNormal];
    [self.modeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.modeButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    self.modeButton.layer.cornerRadius = 10;
    [self.modeButton addTarget:self action:@selector(toggleMode) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.modeButton];
    self.modeButton.hidden = YES;
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    [self.view addGestureRecognizer:pinch];
    // 双击切换调试视图：正常 / 贴图 / 法线 / 光照
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    tap.numberOfTapsRequired = 2;
    [self.view addGestureRecognizer:tap];

    [self loadAssets];
}

- (BOOL)shouldAutorotate { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id ctx) {
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    } completion:^(id ctx) {
        [self layoutUI];
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutUI];
}

// 所有子视图位置在这里统一计算，支持旋转/尺寸变化
- (void)layoutUI {
    const CGSize sz = self.view.bounds.size;
    if (sz.width < 1 || sz.height < 1) return;

    self.mtkView.frame = self.view.bounds;
    self.infoLabel.frame = CGRectMake(16, 56, sz.width - 32, 90);

    const CGFloat js = 150;
    self.joystick.frame = CGRectMake(30, sz.height - js - 40, js, js);
    self.joystick.layer.cornerRadius = js * 0.5;

    self.modeButton.frame = CGRectMake(sz.width - 130, sz.height - 100, 110, 44);
    self.statusLabel.frame = CGRectMake(16, sz.height - 74, sz.width - 160, 60);
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    if (self.driveMode) {
        CGPoint loc2 = [g locationInView:self.view];
        if (loc2.x < self.view.bounds.size.width * 0.45) { [g setTranslation:CGPointZero inView:self.view]; return; }
        [self.renderer lookCarByDX:(float)t.x dy:(float)t.y];
        [g setTranslation:CGPointZero inView:self.view];
        return;
    }
    if (self.fpsMode) {
        // 只在屏幕右半区响应，避免和摇杆冲突
        CGPoint loc = [g locationInView:self.view];
        if (loc.x < self.view.bounds.size.width * 0.45) { [g setTranslation:CGPointZero inView:self.view]; return; }
        [self.renderer lookByDX:(float)t.x dy:(float)t.y];
        [g setTranslation:CGPointZero inView:self.view];
        return;
    }
    self.yaw -= (float)t.x * 0.008f;
    self.pitch += (float)t.y * 0.006f;
    self.pitch = fmaxf(-1.4f, fminf(1.4f, self.pitch));
    [g setTranslation:CGPointZero inView:self.view];
}

// 三态循环：环绕 → 步行 → 驾驶 → 环绕
- (void)toggleMode {
    if (!self.fpsMode && !self.driveMode) {
        self.fpsMode = YES;
        self.driveMode = NO;
    } else if (self.fpsMode) {
        self.fpsMode = NO;
        self.driveMode = self.hasCar;
    } else {
        self.fpsMode = NO;
        self.driveMode = NO;
    }

    [self.renderer setFirstPerson:self.fpsMode];
    [self.renderer enableDriveMode:self.driveMode];

    self.joystick.hidden = !(self.fpsMode || self.driveMode);
    NSString *title = self.driveMode ? @"退出驾驶"
                     : self.fpsMode ? @"退出漫游"
                     : (self.hasCar ? @"进入漫游" : @"进入漫游");
    [self.modeButton setTitle:title forState:UIControlStateNormal];
    self.statusLabel.text = self.driveMode ? @"左侧摇杆 前进/后退  ·  右侧拖拽转视角"
                          : self.fpsMode ? @"左侧摇杆移动  ·  右侧拖拽转视角"
                          : @"拖拽环绕  ·  双指缩放";

    const BOOL needTick = self.fpsMode || self.driveMode;
    if (needTick && !self.tick) {
        self.lastTick = CFAbsoluteTimeGetCurrent();
        self.tick = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick:)];
        [self.tick addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (!needTick && self.tick) {
        [self.tick invalidate];
        self.tick = nil;
    }
}

- (void)onTick:(CADisplayLink *)link {
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    float dt = (float)(now - self.lastTick);
    self.lastTick = now;
    if (dt > 0.1f) dt = 0.1f;
    if (self.driveMode) {
        const float throttle = self.joystick.valueY;
        const float steer = self.joystick.valueX;
        [self.renderer updateDriveWithThrottle:throttle steer:steer brake:0.0f dt:dt];
        self.infoLabel.text = [NSString stringWithFormat:@"驾驶模式  %.0f km/h",
                               [self.renderer carSpeedKmh]];
        return;
    }
    if (!self.fpsMode) return;
    const float fwd = self.joystick.valueY;
    const float right = self.joystick.valueX;
    if (fabsf(fwd) > 0.01f || fabsf(right) > 0.01f) {
        [self.renderer moveForward:fwd right:right dt:dt];
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    self.debugMode = (self.debugMode + 1) % 7;
    NSLog(@"SA: 调试视图切换到 %d", self.debugMode);
    [self.renderer setDebugMode:self.debugMode];
    NSArray *names = @[@"正常", @"贴图原色", @"法线", @"光照", @"UV", @"贴图有无", @"红通道"];
    int idx = self.debugMode % (int)names.count;
    self.statusLabel.text = [NSString stringWithFormat:@"调试视图：%@", names[idx]];
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
                // 用返回值作为真实槽位，避免上传失败导致索引错位
                int s2 = [self.renderer uploadTexture:t.rgba.data() width:t.width height:t.height];
                slot[t.name] = s2;
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
            // 场景模式先输出贴图原色，排除光照干扰后用户可双击切换
            self.debugMode = isScene ? 1 : 0;
            [self.renderer setDebugMode:self.debugMode];
            self.loaded = YES;
            const float *b = pack.mesh.bounds;
            int noTex = 0;
            for (const auto &sm : pack.mesh.submeshes)
                if (slot.find(sm.textureName) == slot.end()) ++noTex;
            // 第一人称需要地面网格
            if (isScene) {
                NSString *groundPath = [bundlePath stringByAppendingPathComponent:@"ground.bin"];
                [self.renderer setGroundData:(const float *)pack.mesh.vertices.data()
                                      vcount:(int)pack.mesh.vertices.size()
                                     indices:pack.mesh.indices.data()
                                      icount:(int)pack.mesh.indices.size()
                                  groundPath:groundPath];
                [self.renderer setCollisionPath:
                    [bundlePath stringByAppendingPathComponent:@"collision.bin"]];
            }
            // ---- 车辆资源
            NSString *carPath = SAFindCarBundle();
            if (carPath) {
                sa::PackInfo cp;
                if (sa::loadBundle([carPath UTF8String], cp)) {
                    [self.renderer uploadVehicle:(const float *)cp.mesh.vertices.data()
                                          vcount:(int)cp.mesh.vertices.size()
                                         indices:cp.mesh.indices.data()
                                          icount:(int)cp.mesh.indices.size()];
                    std::map<std::string, int> cslot;
                    for (int i = 0; i < (int)cp.textures.size(); ++i) {
                        const auto &t = cp.textures[i];
                        int s4 = [self.renderer uploadTexture:t.rgba.data()
                                                        width:t.width height:t.height];
                        cslot[t.name] = s4;
                    }
                    std::vector<unsigned int> cf, cc;
                    std::vector<int> cs;
                    for (const auto &sm : cp.mesh.submeshes) {
                        cf.push_back(sm.firstIndex);
                        cc.push_back(sm.indexCount);
                        auto it = cslot.find(sm.textureName);
                        cs.push_back(it == cslot.end() ? -1 : it->second);
                    }
                    [self.renderer uploadVehicleSubmeshes:cf.data() counts:cc.data()
                                                 texSlots:cs.data() num:(int)cf.size()];
                    self.hasCar = YES;
                }
            }
            self.modeButton.hidden = !isScene;
            self.infoLabel.text = [NSString stringWithFormat:
                @"%@\n%d 顶点  %d 三角形\n子网格 %zu  ·  贴图 %zu（未绑定 %d）\n尺寸 %.0f×%.0f×%.0f",
                isScene ? @"地图场景（Grove Street）" : @"资源包模式",
                pack.vertexCount, pack.triangleCount, pack.mesh.submeshes.size(),
                pack.textures.size(), noTex, b[3] - b[0], b[4] - b[1], b[5] - b[2]];
            self.statusLabel.text = [NSString stringWithFormat:
                @"%@\nGPU 纹理 %d / 子网格 %d（绘制 %d）",
                isScene ? @"拖拽环绕  ·  双指缩放" : @"拖拽旋转  ·  双指缩放",
                [self.renderer textureCount], [self.renderer subDrawCount],
                [self.renderer subDrawnCount]];
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
                int s3 = [self.renderer uploadTexture:rgba.data() width:t.width height:t.height];
                texSlot[want] = s3 >= 0 ? s3 : -1;
                if (s3 >= 0) ++texLoaded;
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
    if (!self.loaded) return;
    @autoreleasepool {
        if (!self.fpsMode) {
            [self.renderer setCameraYaw:self.yaw pitch:self.pitch];
        }
        [self.renderer drawInView:view];
    }
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
