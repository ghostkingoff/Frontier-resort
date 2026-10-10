# 边境度假村 · 素材制作规范（AI 生成）

> **给谁用**：用 AI 出图的人（或 AI 自己作为执行方）。
> **配套文件**：`docs/素材清单.md`（要生成什么、尺寸、优先级）｜`docs/素材制作规范_人工.md`（人工版）
>
> **先看第一节**：AI 出图跟人手画最大的差别不是画风，而是**尺寸、透明、图集**这三件事几乎一定会出错。
> 第一节就是把这些坑先堵掉；第二节开始才是提示词。
>
> 最近更新：10-08 ｜ 基准：**原生 32×32 像素 / 格**

---

## 一、AI 出图的五个硬性坑（先看这个）

### 坑 1：AI 不会给你精确的像素尺寸

扩散模型输出的是 512/1024 这类尺寸，**不会给你 96×64**。

**处理办法**：按 4 倍或 8 倍尺寸生成（例如要 96×64 就生成 768×512），再用
**最近邻（Nearest Neighbor）**缩到目标尺寸。

- ❌ 用双线性 / 双三次（Bilinear / Bicubic）缩放 → 边缘发糊，进游戏立刻看得出
- ✅ 用最近邻，或者支持 pixel-art 的降采样器
- ⚠️ 更稳的做法：让 AI 直接生成**像素画风格的放大版**（每个逻辑像素 = 8×8 实心方块），
  再用最近邻缩 8 倍 —— 这样能得到干净的硬边

**验收**：把成品按最近邻放大 3 倍看，应该是「大而整齐的方块」，
如果边缘有渐变灰边就是糊了。

### 坑 2：透明背景

多数模型不会输出真正的透明通道，会用「棋盘格」「纯白」「纯绿」来假装。

**处理办法（按优先级）**：

1. 优先生成**纯色键控底**，推荐 **`#FF00FF` 品红**（像素画里几乎不会出现这个颜色）
   —— 不要用白色或绿色，建筑里全是白色墙面和绿树，抠不干净
2. 生成后按键控色抠图，抠完检查边缘**不要留品红残留**
3. 抠完把边缘的**半透明像素清理成全透明或全不透明**（最近邻下半透明会出杂边）
4. 最后在贴图**四周留 1px 透明边**

> 如果用的是支持透明通道的模型，直接在提示词里写 `transparent background`，
> 但仍然要抠图检查一遍。

### 坑 3：图集与切片

角色 `walk.png` 要求 **4 列 × 4 行、每帧 32×32、列＝方向（下/上/左/右）**。
AI **几乎不可能一次画对**。

**处理办法**：

- 让 AI **单帧单图**生成（一帧一张 32×32），再用脚本拼成 128×128 图集
- 不要指望 AI 一次输出整齐的 4×4 网格
- 拼图集时严格对齐网格，**不要留缝、不要缩放**

### 坑 4：文字与招牌

AI 画不出可读的中文字，会生成乱码方块。

**处理办法**：提示词里明确 `no text, no letters, no signage text`，
招牌位置留空白色块，**文字后期用美术字贴上去**（或用引擎字体渲染）。

### 坑 5：系列一致性

生成 6 种金属锭、30 栋建筑时，AI 每次都会漂移，最后放在一起不像一套。

**处理办法**：

- **生成顺序**：先出「基准图」（例如铜锭、基础度假屋），
  后续用 **图生图 / 参考图 / ControlNet / LoRA** 以基准图为锚点
- **统一色板**：提示词里直接写死十六进制色值（见 2.2）
- **一批一批来**：同分类一次生成，不要跨分类混着出
- 出完做一次**并排目视检查**，明显跑偏的重出

---

## 二、通用提示词骨架

### 2.1 固定前缀（所有素材都加）

```
pixel art, 32x32 pixel grid, crisp hard edges, no anti-aliasing, no dithering,
limited palette, bold 1px dark outline, warm cheerful cartoon style,
light source from top-left, flat shading, no baked shadows on ground,
clean solid shapes, no text, no letters, no watermark, no signature,
transparent background
```

固定负面词：

```
blurry, soft edges, anti-aliased, gradient shading, photorealistic, 3d render,
jpeg artifacts, noise, text, letters, numbers, logo, watermark, signature,
multiple objects, cluttered, busy background, drop shadow on ground, outlines blur
```

### 2.2 项目色板（写进提示词，用来锚定风格）

| 分类 | 主色 | 色值 |
| --- | --- | --- |
| 度假屋 | 草绿 | `#8FBF6A` |
| 餐饮 | 暖橙 | `#E0A04A` |
| 商店 | 蓝 | `#5FA8D3` |
| 医疗 | 红 | `#D96A6A` |
| 休闲 | 紫 | `#B58AD8` |
| 特殊 | 金 | `#D8B34A` |
| 其他 | 灰蓝 | `#9AA7B4` |

- **描边色**统一 `#1A1526`（深紫黑，不要纯黑）
- 每种分类**只允许 3~5 个明度层次**，防止 30 栋建筑放一起花掉
- 光照方向**固定左上**，不要烘焙昼夜变化（游戏里有全局光照叠加）

---

## 三、逐类提示词模板

### 3.1 建筑

**模板**（把 `{名称}` `{分类主色}` `{造型特征}` 换掉）：

```
{pixel art 固定前缀},
a single {名称} building, front-facing elevation view,
{分类主色} roof, {造型特征},
door exactly at the horizontal center of the bottom edge,
chibi cartoon proportion, building occupies about 2/3 of the canvas height,
isolated single building, centered, no ground, no shadow
```

**造型特征参考**（避免同分类撞脸）：

| 建筑 | 造型特征关键词 |
| --- | --- |
| 小餐馆 | small one-story diner, red awning, open counter window |
| 面馆 | noodle shop, steam from a big pot, hanging lantern |
| 奶茶店 | tiny kiosk, bubble tea cup sign shape (no text), pastel awning |
| 酒吧 | two-story bar, neon sign block, barrels outside |
| 中餐店 | chinese restaurant, tiled roof with upturned eaves, red lanterns |
| 西餐店 | western restaurant, arched windows, small terrace |
| 小超市 | small grocery store, fruit crates outside, striped awning |
| 大型超市 | big-box supermarket, wide glass front, flat roof |
| 小型诊所 | small clinic, red cross sign, clean white walls |
| 招待厅 | reception hall, welcoming porch, notice board, wide entrance |
| 基础度假屋 | simple wooden cottage, single window, pitched roof |
| 自然风度假屋 | log cabin with vines and plants, warm wood, larger |
| 现代风度假屋 | modern villa, glass walls, flat roof, steel frame |
| 珍品展厅 | tall gallery hall, grand columns, glass display facade |
| 公共卫生间 | small public restroom hut, simple, clean |
| 保洁间 | small janitor shed, brooms and buckets visible |

**输出尺寸对照**（生成时用 8 倍，再最近邻缩回来）：

| 目标尺寸 | 生成尺寸 | 占地 |
| --- | --- | --- |
| 64×64 | 512×512 | 2×2 |
| 96×64 | 768×512 | 3×2 |
| 96×96 | 768×768 | 3×3 |
| 128×96 | 1024×768 | 4×3 |
| 128×128 | 1024×1024 | 4×4 |
| 192×192 | 1536×1536 | 6×6 |
| 160×224 | 1280×1792 | 5×7 |

> 建筑**不要生成成 3/4 俯视或等距视角** —— 项目用的是纯正面视角。
> 写 `front elevation, flat frontal view, no perspective`。

### 3.2 角色（单帧）

```
{pixel art 固定前缀},
a single chibi character standing, {朝向} facing,
{角色描述},
2-head-tall chibi proportion, feet near the bottom of the canvas,
{朝向} view, full body, centered
```

- `{朝向}` 取值：`front` / `back` / `side facing left` / `side facing right`
  （**左和右要分别生成，不要镜像** —— 镜像会让衣服图案和手性反掉）
- `{角色描述}` 参考：

  | 角色 | 描述关键词 |
  | --- | --- |
  | 游客 A（男） | young male tourist, casual shirt, backpack |
  | 游客 B（女） | young female tourist, sun hat, summer dress |
  | 游客 C（村民） | villager, simple work clothes, apron |
  | 贵客／富商 | wealthy merchant, fine coat, gold trim, confident |
  | 明星／贵宾 | celebrity, glamorous outfit, sunglasses, jewelry |
  | 保洁工人 | janitor, apron, cap, holding a broom |

- **走路 4 帧**：不要一次生成 4 帧，而是
  1. 先生成「站立帧」作为基准
  2. 用图生图，提示 `same character, walk cycle frame 2, one leg forward, arm swing`
  3. 依次出 4 帧，最后脚本拼 4×4 图集（列＝方向、行＝帧）

- 单帧生成尺寸：**256×256**（对应 32×32 的 8 倍）

### 3.3 物资图标

```
{pixel art 固定前缀},
a single {物品名} item icon, centered, chunky readable silhouette,
{品质描述}, {材质色} ,
filling about 80% of the canvas, 2px transparent margin all around
```

**系列化技巧（金属锭为例）**：
先出铜锭，然后**同一提示词只换颜色词**：

```
same shape, same silhouette, same lighting, only the color changes to {色}
```

| 物品 | 品质 | 色 |
| --- | --- | --- |
| 铜锭 | 普通 | copper orange-brown |
| 铁锭 | 普通 | grey steel |
| 银锭 | 稀有 | bright silver |
| 金锭 | 稀有 | warm gold |
| 紫金锭 | 稀有 | purple-tinted metal |
| 秘银锭 | 传说 | pale cyan-white metal |

- 生成尺寸：**256×256**（对应 32×32）
- 品质越高加一点点光泽/高光，**但轮廓必须完全一致**

### 3.4 地面图块（无缝）

无缝图块是 AI 的弱项，**必须用可平铺模式**。

```
{pixel art 固定前缀},
a seamless tileable {地面类型} ground texture, top-down view,
uniform texture with no distinct focal point, no border, no edge,
evenly distributed small details, tileable on all four sides
```

- 生成尺寸：**512×512**，然后缩到 32×32
- ⚠️ 提示词里的 `no distinct focal point` 很关键 —— 有焦点的图平铺后会看出规律重复
- **出图后必须实际平铺 5×5 检查接缝**：

  如果模型支持 tiling / seamless 模式（如 `--tile`），一定要开；
  不支持的话，用「镜像拼接法」做无缝处理后再缩尺寸。
- 三种地面用同一个提示词骨架只换材质词：
  - 地砖：`neatly laid paving stones`
  - 可行走草坪：`short trimmed lawn grass`
  - 普通草坪：`wild overgrown grass with small weeds`

### 3.5 自然装饰

```
{pixel art 固定前缀},
a single {装饰名}, front view, isolated on transparent background,
{造型特征}
```

- 树：`wide canopy, narrow trunk`（树冠要比树干宽，遮挡关系才自然）
- 生成尺寸按清单第六节的显示尺寸 × 4（例如 64×96 → 生成 256×384）

---

## 四、生成后的技术校验（必须做，不能跳过）

对每一张成品跑一遍：

| 检查项 | 方法 | 不通过怎么办 |
| --- | --- | --- |
| **尺寸精确** | 读 PNG 宽高，和清单逐项对比 | 最近邻重缩 |
| **是真透明** | 看是否有 alpha 通道，边缘像素 alpha 是否为 0 或 255 | 重新抠图 + 清理半透明边 |
| **无抗锯齿杂边** | 最近邻放大 3 倍目视 | 重新生成或手动修边 |
| **无色板外杂色** | 统计颜色数，检查是否有大量渐变中间色 | 做色板量化（限制到 16~24 色） |
| **无文字** | 目视 | 重生成，提示词加强 `no text` |
| **图集对齐** | 拼完后每帧严格 32×32 | 用脚本按网格切，不要手动拼 |
| **地面无缝** | 平铺 5×5 目视 | 用无缝处理或重生成 |

**色板量化建议**：像素画单张控制在 **16~24 色**以内。
颜色太多会失去像素画的统一感，也会和现有素材打架。

---

## 五、可以直接跑的工作流

### 5.1 单张建筑（完整流程）

1. 从 `素材清单.md` 查到目标尺寸（例：小餐馆 96×64）
2. 算生成尺寸：96×64 × 8 = **768×512**
3. 用第三节 3.1 的模板填好提示词，生成
4. 检查：正面视角？门在底边正中？没有地面投影？
5. 按键控色抠透明 → 清理半透明边缘 → 最近邻缩到 **96×64**
6. 四周留 1px 透明边（必要时把图形整体缩 2px）
7. 存成 `art/buildings/bld_food_diner.png`
8. 跑校验表

### 5.2 角色一个方向的 4 帧

1. 生成站立帧（256×256），确认造型满意 → 定为基准
2. 用基准图做图生图，依次出 4 个走路帧
3. 4 帧分别缩到 32×32
4. 脚本横向拼成 `128×32` 的一行
5. 换个方向重做，最后把 4 个方向行**纵向**拼成 `128×128`
   （**列＝方向，行＝帧**，别拼反）
6. 存成 `art/characters/<角色>/walk.png`
7. 同样方式出 `idle.png`（`128×32`，只有一行）

### 5.3 一批 30 栋建筑

1. **按分类分批**：度假屋 3 栋 → 餐饮 8 栋 → 商店 3 栋 → …
2. 每个分类先出「第一栋」当基准，后面全部用它做参考图
3. 出的过程中**每 5 栋就并排看一次**，跑偏立刻回退重出
4. 全部出完后按 `--mode=full_test` 截图，看 28 栋摆一起的整体协调性

---

## 六、AI 做不好、需要人工接手的地方

诚实列出来，别浪费时间硬试：

| 项目 | 说明 |
| --- | --- |
| **精确尺寸 / 图集切片** | 一定需要脚本处理，不要指望模型输出 |
| **可读文字** | 招牌文字建议人工用美术字贴，或引擎渲染 |
| **严格的帧间连贯** | 走路 4 帧的位移感，AI 出的常常「看不出在走」，需要人工修 1~2 帧 |
| **无缝地面** | 除非模型有专业 tiling 能力，否则需要后期做无缝处理 |
| **珍品展厅（160×224）** | 太小众的尺寸，AI 容易画成普通房子，需要人工强调「高大的展馆」 |
| **风格统一的 30 栋建筑** | 需要参考图 / LoRA 等一致性手段，纯文生图必然漂移 |

> 参考：`docs/素材清单.md` 第十一节列了「代码还不支持的结构」，
> 例如多朝向建筑、faceset 头像 —— 这些即使 AI 出了图，代码也不会用，先别做。

---

## 七、交付与登记

1. 按 1.4 的目录结构放好 PNG（`art/buildings/`、`art/characters/`、`art/items/`、`art/tiles/`、`art/ui/`）
2. **同时保留生成参数记录**（提示词、种子、模型、参考图），下次要出同系列素材靠它复现
   —— 建议每批素材附一个 `_prompts.txt` 放在同目录
3. 更新 `docs/素材清单.md` 对应行的「状态」为 `已完成`
4. 交给开发跑 `--smoke` 回归 + 截图目视

> 生成参数记录很重要：这套项目有 30 栋建筑 + 6 个角色 + 23 种物资，
> 一年后要补一栋新建筑时，没有参数记录就只能重新摸索风格。
