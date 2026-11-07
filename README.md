# SA Viewer — GTA SA 原版资源 iOS 查看器

用 iPhone 原生 Metal 渲染 GTA SA（PC 原版）的 DFF 模型与 TXD 贴图。

**本项目不包含任何游戏资源**，仅提供解析与渲染代码。使用时需自备合法持有的原版游戏文件。

---

## 当前状态（v0.2.0）

| 项 | 状态 |
|---|---|
| IMG VER2 解析 | ✅ 全量 16,316 条目 |
| DFF 几何解析 | ✅ 12,964 / 12,964（100%），尾部剩余 0 字节 |
| TXD 纹理解码 | ✅ DXT1 / DXT3 / DXT5 / 8888 / 565 / 调色板 |
| Metal 渲染 | ✅ 已编译进 app（default.metallib） |
| 多材质子网格 | ✅ 按 materialId 分组，逐段绑定各自贴图 |
| 触摸交互 | ✅ 拖拽旋转 |
| 无资源自测 | ✅ 显示立方体，验证 GPU 管线 |

### 已验证的解析规模
- 全量 `gta3.img`：**4,588,916 三角形 / 6,608,816 顶点**
- 解析速度：约 0.2 ms/模型（iPhone 上的 C++ 单线程）

---

## 安装

IPA 未签名，需要自签名安装（Sideloadly / SideStore / iCSM / TrollStore 均可）。

1. 用签名工具安装 `SAViewer-x.x.x-unsigned.ipa`
2. **首次打开会显示一个立方体**——这表示 Metal 管线工作正常
3. 把游戏资源拷进 App 沙盒：
   - 在「文件」App → 我的 iPhone → **SA Viewer** 中新建 `models` 文件夹
   - 把 `gta3.img`（940 MB）复制进去
   - 完整路径：`SA Viewer/models/gta3.img`
4. 重新启动 App，即可看到 `farmhouse01` 农舍模型（带贴图）

可通过 Xcode 环境变量 `SA_MODEL` 指定其他模型名（如 `sfn_roadblockld.dff`）。

---

## 技术要点

### DFF 解析：必须按 librw 的字段顺序

GTA SA 的 Geometry Struct 不能用 flags 猜字段顺序（各模型 flags 差异极大：
`0x1002F` / `0x1004F` / `0x10076` / `0x200B3` / `0x200F3`）。正确顺序见
`librw/src/geometry.cpp` 的 `Geometry::streamRead()`：

```
flags, numTris, numVerts, numMorph
[version < 0x34000]  SurfaceProperties (12B)
[非 NATIVE]
    [PRELIT 0x08]   RGBA × numVerts
    [UV 0x04/0x80]  float2 × numVerts
    三角形          uint32 × numTris（每 4B 打包：v0<<16|v1，v2<<16|matId）
每个 morphTarget:
    边界球 4f(16B) + hasVertices(int32) + hasNormals(int32)
    [hasVertices] float3 × numVerts
    [hasNormals ] float3 × numVerts
```

**正确性硬指标：几何块解析完剩余字节必须为 0。**

实现上还为 flags 与实际布局不符的模型准备了候选回退（UV 套数 0/1/2 × 是否有
surface 段），选「尾部最少」的解——这使成功率从 98% 提升到 100%。

### 三角形材质索引
每个三角形的第 2 个 uint32 低 16 位是 **materialId**，据此把三角形分到各材质，
每个材质一个 draw call 并绑定自己的贴图。

### TXD 字段偏移
```
platform@0  name@8(32B)  mask@40(32B)  rasterFormat@72
d3dFormat@76（整型枚举：0x31545844="DXT1", 0x33545844="DXT3", 0x35545844="DXT5"）
width@80  height@82  depth@84  levels@85  rasterType@86  alpha@87  mip@88
```
`d3dFormat` 为 0 时按 rasterType 判定：1=4444 2=1555 3=565 4=8888。

### 踩过的坑
1. **IMG VER2 条目是 32 字节**（扇区偏移 u32 + 扇区数 u32 + 名称 24B），不是 VC 的 6 字节
2. **模板推导陷阱**：`template<class T> read(T*)` 传入 `float arr[4]` 时 `sizeof(T)` 只有 4，
   必须逐元素读取
3. **`if (!a.read(..) || !b.read(..))` 短路求值**会让后续字段根本没被读取
4. **IMG 条目按 2048 对齐，尾部有 0 填充**，块遍历遇到全零伪块要立即停止
5. 纹理常不在模型同名 TXD 里，需要全局纹理索引（3,159 个 TXD → 11,302 张）

---

## 目录结构

```
src/
  assets.h/cpp      IMG 归档 + TXD 解析与解码
  dff.cpp           DFF/Geometry 解析（librw 顺序）
  store.cpp         AssetStore（模型/纹理加载）
  renderer.h/cpp    网格构建（按材质分组）+ 矩阵数学
  metal_backend.h/mm  Metal 管线、子网格绘制
  main_ios.mm       iOS 宿主（MTKView + 触摸 + 资源发现）
shaders/
  ModelRenderer.metal  顶点/片段着色器
tools/
  probe.cpp         单模型解析检查
  verify.cpp        全量解析验证
  softraster.cpp    CPU 光栅化（无 GPU 环境下验证相机数学）
```

---

## 构建

GitHub Actions 自动构建（`.github/workflows/build-ios.yml`，macOS runner）：

```
cmake -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DSA_BUILD_IOS=ON ...
```

本地验证核心库（无需 iOS SDK）：

```bash
g++ -std=c++17 -O2 -Isrc tools/verify.cpp src/assets.cpp src/dff.cpp src/store.cpp -o verify
./verify /path/to/gta3.img
```

---

## 后续（阶段 4）

- [ ] Frame 层级矩阵（骨架/多部件模型的正确变换）
- [ ] IPL/IDE 地图实例放置与拼接
- [ ] IMG 直接 mmap 流式读取（免解包 940 MB）
- [ ] 骨骼蒙皮（IFP 动画 → 骨架驱动）
- [ ] COL 碰撞体
