# 阅读Pro / ReaderPro（自用 · TrollStore 侧载）

仿「开源阅读 / Legado」的 iOS 阅读器。原生 SwiftUI 编写，自用、不上架，通过 **TrollStore 侧载**（永久签名，无需 Apple 开发者账号）。App 图标与显示名已定制为「阅读Pro」。

本仓库在 [原起步包](https://github.com/najiuwanan511/CialloReaderIOS) 基础上改写阅读器、书源引擎和管理界面。当前仍是持续开发的 iOS 实现，功能和规则兼容性并未完全等同于 legado-E。

## 构建与安装（无需 Mac）

1. 把本仓库推到你的 GitHub（`.github/workflows/` 必须在根目录）。
2. GitHub → Actions → **iOS unsigned build** → Run workflow。
3. 构建完成后在 Artifacts 下载 `unsigned-ipa`，得到 `ReaderPro-unsigned.ipa`。
4. **TrollStore 安装**：把 IPA 通过 AirDrop / 文件 传到手机，用 TrollStore 的「Install IPA」直接装即可（永久签名，比 AltStore 7 天过期省心）。

> 构建产物是未签名 IPA（`CODE_SIGNING_ALLOWED=NO`），TrollStore 会自行伪签名，无需证书。

## 功能清单

**阅读器（核心）**
- TextKit 分页：按屏幕、字号、行距、段距和边距排版，并用相同的单页布局渲染
- **五档翻页动画**：覆盖 / 平移 / 滚动 / 无 / **仿真（pageCurl 卷曲，开源阅读同款）**，翻页速度可调
- 点按三区翻页 + 中间弹菜单（开源阅读同款交互）
- **8 套背景主题** + 自定义字体（苹方/宋体/楷体/黑体/圆体 + 全部系统字体）
- 完整排版设置：字号、行距、段距、边距、亮度（跟随系统）、页眉页脚
- **朗读续读**：从当前页读到章末，语速 / 音色可调
- **自动翻页**：间隔可调
- **书内搜索**：本章 / 全文跨章
- **书签**：阅读中加书签，书签列表可跳转
- 进度记忆（章 + 字符偏移）+ **阅读时长统计**

**书架**
- 网格 / 列表视图切换、排序、搜索、多选删除
- **收藏**（星标）与收藏过滤
- 封面（网络封面 + 标题取色占位）、进度、阅读时长显示

**书源**
- Legado JSON 书源导入（粘贴 / 网络订阅 / 扫码），多源并发搜索、目录拉取、换源
- **书源详情**：查看全部规则（搜索 / 目录 / 正文）+ 单源测试搜索
- **换源**：阅读中一键换源重拉目录；**整本缓存**：一键下载全书离线读
- **专门适配 yckceo 源仓库**：书源详情页链接自动转 JSON 接口导入

**订阅源（Legado rssSource）**
- 订阅源导入（粘贴 JSON / 网络链接），启用 / 停用 / 删除
- **源仓库导航**：singleUrl 订阅源（如 yckceo 官方源仓库）点开用内置浏览器进源仓库找书源
- 识别 RSS 规则源（带 ruleArticles 的源会标注）

**同步**
- 本地备份互传（.ciallo，实为 ZIP）
- **WebDAV 云备份**：坚果云 / Nextcloud / 自建，备份到云端 + 从云端恢复

**内置浏览器 & 视频小窗**
- 内置 WKWebView 浏览器：地址栏、前进后退、刷新、网页视频原生画中画
- **ALOOK 式视频弹窗**：自动探测网页 `<video>` → 一键「小窗」进入系统画中画，退出浏览器 / 切 App 仍悬浮播放
- 入口：设置 → 内置浏览器；书源详情 → 在浏览器打开书源网站

**其他**
- 本地导入：TXT / EPUB / DOCX / FB2 / MOBI / AZW3 / PDF / CBZ（漫画）
- 漫画：单页 / 条漫、缩放、本机滤镜增强、OCR、图片磁盘缓存
- **在线漫画**：漫画书源（bookSourceType=2 或正文带 imageUrl 规则）自动识别，按章节拉图、翻页 / 条漫、自动缓存离线看
- 替换净化（正则去广告）、导出 EPUB / TXT

## 目录结构

```
ReaderPro/
├── App.swift                    # 入口
├── ContentView.swift            # 书架 / 书源 / 设置（含 WebDAV 配置）
├── ReaderView.swift             # ★ 阅读器（重写，含仿真翻页/书签/全文搜索/换源/缓存）
├── MangaView.swift              # ★ 漫画（本地 CBZ + 在线漫画书源，图片缓存/OCR）
├── ReaderCore.swift             # ★ 主题 / 精确分页 / 朗读 / 字体枚举 / pageCurl 控制器
├── BrowserView.swift            # ★ 内置浏览器 + 视频画中画小窗
├── WebDAV.swift                 # ★ WebDAV 客户端（云备份）
├── BookEngine.swift             # 数据模型 / BookStore / TXT/EPUB/CBZ 解析 / 备份
├── SourceEngine.swift           # 书源 / 订阅源（RssSource）模型与导入 / 网络
├── LegadoRuleEngine.swift       # Legado 书源规则引擎
├── ExtraFormats.swift           # MOBI/PDF/ZIP/OCR
├── MoreFormats.swift            # DOCX/FB2/导出
├── DiscoveryAndManagement.swift # 发现 / 书源管理 / 订阅源管理 / 书源详情 / 替换规则编辑
├── Info.plist                   # 含 ATS 例外 + 后台音频（画中画需要）
└── project.yml                  # XcodeGen 配置
```

## yckceo 源仓库接口清单

「阅读 / 开源阅读」最大的书源社区之一。域名：主站 `www.yckceo.com`、备用 `www.yck2026.fun`、防失联发布页 `yckceo.vip`。

| 用途 | 地址 |
|---|---|
| 书源列表页 | `https://www.yckceo.com/yuedu/shuyuans/index.html` |
| 书源详情页（单源） | `https://www.yckceo.com/yuedu/shuyuans/content/id/{id}.html` |
| 书源 JSON 接口（可直接网络导入） | `https://www.yckceo.com/yuedu/shuyuan/json/id/{id}.json`（或 `shuyuans`） |
| 订阅源列表页 | `https://www.yckceo.com/yuedu/rss/index.html` |
| 订阅源详情页 | `https://www.yckceo.com/yuedu/rss/content/id/{id}.html` |
| 订阅源 JSON 接口（可直接网络导入） | `https://www.yckceo.com/yuedu/rss/json/id/{id}.json` |
| 官方源仓库订阅（纯净） | `https://www.yckceo.com/yuedu/rss/json/id/193.json` |

**用法**：App 里「书源管理 / 订阅源管理 → 网络导入」粘贴上面对应链接即可；详情页链接会自动转成 JSON 接口再拉取，无需手动改。

## 书源校验与回归测试

- 管理页常驻搜索栏可搜索名称、分组、网址和失败原因；状态筛选包含成功、失败、未完整验证和未校验。
- 校验依次检查已配置的搜索入口、已启用发现的首个分类、样本书详情、完整目录分页和首章正文分页；漫画额外检查首张图片响应。书源关闭发现时跳过该项，与发现页一致。
- 成功表示这次抽样阅读链路通过，不表示每本书、每个分类或以后一直可用。搜索无结果、部分能力可用或脚本不兼容标记为未完整验证；没有可用入口且请求失败才标记为失败。失败仅描述本次检查，不自动停用书源。
- 报告保存关键词、时间、失败阶段及原因，修改书源规则后旧结果失效。
- 与 Android 一致，封面和简介脚本出错时保留书籍及阅读入口，详情和校验报告记录附加信息警告；书名、作者、详情地址、目录和正文的错误仍会报告，取消及总超时不会被忽略。
- 网络导入同时展开直接书源与嵌套子合集，显示实际新增、更新、重复及失败文件地址；子合集循环会去重，单次超过 5000 个子合集明确报告。
- GitHub Actions 必须先通过单元测试、iOS 模拟器界面测试、正文像素检查和用户合集整包搜索测试，才生成 IPA。测试覆盖 1500 条导入、混合合集、请求头/POST/中文关键词、发现→详情→目录→正文、分页和校验记录持久化。
- 用户提供的 yckceo/1325 合集固定为 1466 条，以 SHA256 验证原始文件，逐条核对导入和规则保存。整包测试用生产引擎搜索「斗罗大陆」，每个配置了搜索的源都必须返回结果或明确错误，并导出逐源 JSON 报告；证书错误另测旧站点兼容模式。这不等于每个源、每个分类、每本书均可阅读。
- 创世中文网另有真实公开网站集成测试，覆盖搜索、分类、发现、详情、完整目录与首个免费章节；七猫、茄子另测真实搜索、目录及首章解密。其他回归使用本仓库原创样本及本地 HTTP/HTTPS 服务，证据上传为 `source-regression-evidence`。模拟器测试不能代替真机和用户所在网络的验证。
- 搜索按源持续返回结果，显示完成数与失败原因，可随时取消和重新搜索；发现分类、分类列表与目录加载有超时和重试提示。
- 支持脚本内书籍字段模板、节点列表转换、带排除索引的组合 CSS、嵌套替换模板、原始源身份保留与请求网址空白清理，以及带 type 的 Base64 内嵌/二进制请求。登录脚本字段随书源保存；交互登录界面仍未完整实现。
- 常用 JavaImporter 加密接口提供 AES/DES Cipher、HMAC Mac、SecretKeySpec、IV、Base64、Arrays、HashMap 与 RSA SHA-1/256/384/512 签名适配；测试使用 NIST/RFC 向量和独立 OpenSSL 生成的 RSA 签名。测试密钥仅用于回归，无任何账户用途。
- 动态执行的书源备注解密库同样适配 Java 字符串 `length()`，兼容 Rhino 简单数组解构箭头参数；`book.getVariable/putVariable` 按书源与书籍隔离并持久保存，支持缺失值和删除。
- 网络超时同时约束脚本执行：针对部分合集中的无限 `while/catch` 重试，JSC watchdog 会直接终止脚本，避免搜索永久等待。相关测试包含无限循环、取消和后续脚本恢复。此侧载实现使用 JavaScriptCore 导出的执行中断 SPI；未来如上架 App Store，需要替换这部分实现。系统不提供该接口时会明确拒绝执行脚本。

## Android 可用但 iOS 报 SSL 错误

legado-E 的网络客户端默认忽略 HTTPS 证书及域名校验。ReaderPro 默认使用系统证书校验，因此过期、自签名或域名不匹配的证书可能在两端产生不同结果。对于你信任的旧站点，可到「书源管理 → 该源详情 → 旧站点证书兼容」单独开启后重新校验；开启会跳过该书源请求的 HTTPS 证书校验。

这项选择仅保存在本机，不由导入的 JSON 自动开启，不影响其他书源或 WebDAV。自动化 HTTPS 测试验证默认拒绝、明确开启后可用、关闭后恢复验证，以及普通请求、脚本网络和 WebView 之间的隔离。兼容选项不能修复已失效的域名或系统不再支持的 TLS 协议。

## 已知限制

- 使用 JavaScriptCore 执行 JS、SwiftSoup 解析 Jsoup/CSS 选择器、Kanna/libxml2 解析 XPath。已实现常用网络、DOM、对称加密及 RSA 签名接口；仍未完整实现 Android Java 环境、交互登录/验证码、RSA 加解密等所有扩展，不能承诺通用兼容。未知 Java 类会明确报错。
- 第三方网站的失效域名、证书、登录、验证码、地区限制及防盗链仍可能导致失败。客户端允许旧式 HTTP；HTTPS 默认校验证书，旧站点兼容需针对该源明确开启。
- 订阅源目前支持「导入 / 管理 / 源仓库导航」，带规则的 RSS 全文阅读（ruleArticles 解析渲染）尚未实现。
- 带 DRM 的加密书无法读取。
- 漫画增强是本机 CoreImage 滤镜，不是 MangaJaNai AI 画质模型。
- 视频小窗用 AVPlayer 直接播提取到的视频 URL，会丢失网页的 cookie/referer，带强防盗链的视频源可能 403；此类视频请用网页内嵌播放器自带的画中画按钮。
- 在线漫画图片同样可能被防盗链拦截；已带 UA 下载 + 本地缓存，但强 referer 防盗链的图床仍可能失败。

## 协议

自用项目，未引入额外版权素材。开源阅读（Legado）为 GPL-3.0；本仓库为独立 Swift 实现，如对外发布请自行遵循 GPL-3.0。
