# 鸿蒙 vs 安卓 功能对齐状态（2026-10-20 第八轮更新）

调查对象：`android/`（Kotlin 参考端）与 `harmony/AgentsAnywhere`（ArkTS，API 26）。
本文档为**当前状态快照**：此前多轮差距清单中的项目已按批次实现并逐批通过 `devecocli build` 验证。每批实现均以安卓源码与 Server 契约（`server/agent_server/api/`）逐字段核对。
2026-10-19 第二轮：完成 8 页面逐元素代码级对比审查，随后按 B1–B5 五批修复全部审查差距（文件页/终端/会话详情/新建会话/首页/Profile）。
2026-10-19 第三轮（视觉对齐 V1/V2）：发现并修复设计令牌级偏差——鸿蒙 LightColors 此前是历史硬编码的 Tailwind 蓝灰系，与安卓暖纸色系完全不同。V1 重写 ColorTokens（明暗逐 token 对齐安卓 Theme.kt：canvas #FDFCFB、primaryAction 黑 #0A0A0B、border #E7E5E0、暗色 border=Transparent 等），新增 TypeTokens/SpacingTokens/RadiusTokens/IconSizeTokens；V2a/V2b 并行逐页清扫字号/字重/行高/间距/圆角/颜色（对照安卓同位置确切值），消除残留硬编码色。已部署验证：背景像素实测 #FDFBFA ≈ #FDFCFB。
2026-10-19 第四轮（品牌字）：安卓 AAWordmark 用 Caveat 手写体（caveat_wght.ttf），鸿蒙此前是系统默认字体。修复：字体复制到 rawfile，Index.aboutToAppear 用 UIContext.getFont().registerFont($rawfile) 注册（注意：EntryAbility.onCreate 里用字符串路径注册不生效；registerFont 为异步接口，需在页面渲染前注册），登录页 42sp/首页顶栏 31sp wordmark 应用 `.fontFamily('Caveat')`（首页顶栏同时从"Sessions"文案改为安卓同款 wordmark）。截图已验证草书字形生效。
2026-10-19 第五轮（首页布局重构 B6）：整体布局结构逐元素对齐安卓 HomeContent/HomeHeader/QuickEntries/QuickEntryCard/FloatingHomeButton（HomeScreen.kt 458–906）+ HomeProjectComponents/HomeProjectSessionRow/HomeLists。已部署截图验证：顶栏（左 42dp 圆形头像钮 + 居中 Caveat wordmark 31sp/40 + 右透明搜索钮）、QuickEntries 三卡（设备/终端/文件，76dp、r18、图标 22 + 14 Bold 标题）、Active/Archived 胶囊 tab（34dp，安卓 HomeTabPill 样式）、分组头（56dp、folder 21 + 16 Bold）、会话行（44dp、robot 16 + 15 Medium 标题 + 状态 pill/未读点）、右下 54dp 黑色 FAB（新建会话入口，替代原 navAction 行）全部就位。
2026-10-20 第六轮（B7 首页项目树 + Profile 抽屉，响应用户反馈"安卓只有项目/不该有全部标已读/项目格式与 Profile 页不对"）：
- **B7a 首页列表重构**：核实安卓首页为纯项目树模式（HomeProjectList，无 tab、无 mark-all-read 行）后，删除 Active/Archived 双 tab、"全部标已读/筛选/选择"按钮行与批量选择 footer；改为"已固定/项目"两个可折叠分区（分区头 44：label 13.2 ExtraBold faint + chevron 16 旋转；"项目"头带过滤 chevron_left + 新建项目 plus）；项目行 56（folder/folder_fill 21 + 16 Bold + more/square_and_pencil 38/19，长按或省略号弹 252×168 r22 操作卡：编辑/置顶/归档）；展开子项（错误重试/18 加载环/"暂无会话"）；会话行 44（agent 图标 16 + 15 Medium + 指示器：等待批准 pill/旋转弧 Circle+strokeDashArray/未读点）；编辑项目 sheet（r28、409 冲突自动改名）、归档确认弹窗（r26）；新建项目页 NewProjectPage（设备/名称/路径 → POST /projects）；锚定过滤菜单 + auth/HomeProjectPreferenceStore 偏好持久化；数据层改 listProjects() 真实项目列表 + per-(project,archived) 30s 会话缓存
- **B7b Profile 抽屉化**：核实安卓为 ProfileSettingsDrawer 左滑入抽屉而非路由页后，删除 pages/ProfilePage.ets 与 `profile` 路由；新增 components/ProfileDrawerOverlay.ets（Header 64 返回+居中标题；IdentityCard 头像/昵称/官方云标签 → Account 详情；外观卡 Moon+下拉三选；语言卡；版本卡+检查更新红点；归档会话卡；SignOutCard 红字；Account/Language/Updates 抽屉内详情子页；昵称/邮箱/改密/退出弹窗 r26 风格；TransitionEffect.move(START) 240ms）；新增 pages/ArchivedSessionsPage.ets（路由 `archived_sessions`，项目选择器 + 分组归档列表 + 单条/整项目恢复，对齐 ArchivedSessionsScreen）
- 修复编译坑：ArkUI 无 `Arc` 组件（用 Circle+strokeDashArray 画 100° 弧）、`FontWeight.ExtraBold` 不存在（用 800）、SymbolGlyph 无 `.textAlign`
- 部署截图验证：首页无 tab/无标已读行、"项目"分区头+过滤/加号、项目树行、FAB 就位；Profile 抽屉（返回+设置标题、身份卡 Bob/官方服务、外观/语言/版本 v2.1.0/检查更新/已归档会话/红色退出）全部生效
2026-10-20 第七轮（会话 agent 图标 + 折叠空态修复，响应用户反馈）：
- **会话 agent 品牌图标**：移植安卓 `ic_session_agent_{codex,claude,deepseek}.xml`（单 path 矢量）为 `resources/base/media/session_agent_*.svg`（viewport 100/125/50，`Image.fillColor` 着色 faint，仅对 SVG 生效）；新增 `components/SessionAgentIcon.ets`（`sessionAgentIconKind()` 复刻安卓 SessionAgentIcon 匹配：strip 空白/_/- 后 codex→Codex、claude/claudecode→Claude、dsh/deepseek/deepseekharness→DeepSeek，否则 sys.symbol robot 兜底；16vp；注意 V1 @Component 禁 getter，改为 build 内直接调函数）；首页会话行替换原统一 robot 图标。当前账号连接器仅 DSH runtime，全部会话显示 DeepSeek 鲸鱼图标，与安卓一致
- **修复折叠"项目"分区误显空态**（用户报告：点击项目按钮列表变空；安卓正确行为为收拢项目行、分区头保留）：根因 `treeHasContent()` 只认 project/session 行，折叠后 treeRows 仅剩 projects_header → 误判走"还没有活跃项目"空态。修复：对齐安卓 `HomeProjectList` 空态条件 `projects.isEmpty() && pinnedSessions.isEmpty()`（与折叠状态无关），`rebuildProjectTree()` 计算 `@State treeHasAnyContent`（visibleProjects 或过滤后 pinnedSessions 非空），折叠时仅隐藏分区内容、分区头照常渲染
- 验证：模拟器部署实测折叠（只剩"项目 >"头，无空态误显）↔ 展开（Mihu/Agents-Anywhere/11 三项目 + 会话行 + 鲸鱼图标）往返正常
- **修复折叠后分区头掉到屏幕底部**（用户报告：点击"项目"后项目跑到下面）：根因列表区宿主 `Stack({ alignContent: BottomEnd })`（FAB 定位用）内的 Refresh/List/加载/错误/空态分支用了 `layoutWeight(1)`——`layoutWeight` 仅在 Row/Column/Flex 内生效，Stack 内被忽略 → 子组件按内容高、短内容被 Stack 底部对齐推到屏幕底。修复：各分支改 `height('100%')`（Stack 内百分比有效）；ErrorState/EmptyState 包一层 `Column().height('100%').justifyContent(Center)`（`.justifyContent` 非通用属性，不能链在自定义组件上，编译报错实测）；折叠时"项目 >"头保持在快速入口下方（y≈703），不再掉底
- 沉淀规则：**Stack 子组件禁用 `layoutWeight`**（静默失效），需要撑满用 `height('100%')`；自定义组件只能链通用属性，布局属性（justifyContent 等）须由外层容器承担
2026-10-20 第八轮（外观菜单修复 + 侧边栏显示）：
- **修复 Profile 抽屉"外观"点击无反应**（用户报告：点击外观行无任何反应）：根因是单位混用——`getComponentUtils().getRectangleById()` 返回 **px**（约等于绝对屏幕坐标），而菜单 `position()` 按 **vp** 解释，未换算导致菜单弹到屏幕外底部（dumpLayout origBounds [237,2754][1238,3320]，仅 78px 露出屏底）。修复：`ProfileDrawerOverlay.openAppearanceMenu`、`HomePage.anchorFromRect`、`ArchivedSessionsPage.openPicker` 三处全部经 `getUIContext().px2vp()` 换算，并保留 fallback 锚点 + hilog.warn 兜底
- **第二个坑（坐标基准不一致）**：page-root 级 id（home_root）的测量返回 (0,0) 基准，而页内组件返回绝对屏幕坐标，直接相减恒差 137px（状态栏高）。修复：首页/归档页根 Stack 内加零尺寸 origin marker（`home_anchor_origin`/`archived_anchor_origin`，必须 `.position({x:0,y:0})` 钉原点，否则 Stack 默认 alignContent Center 会居中到 (640,1435)），锚点计算改为 marker 基准
- **侧边栏显示（B8，对齐安卓 HomeSidebarViewMode/SidebarViewPopup/HomeList）**：Profile 抽屉语言卡后新增"侧边栏显示"卡（list_bullet 图标 + trailing 当前视图 + 下拉弹层：项目视图 folder/会话视图 list_bullet，286 宽弹层锚定行下方含 px2vp 换算）；新增 `auth/SidebarViewModeStore.ets` 全局持久化（AppStorage `appSidebarViewMode` + preferences，normalize 仿安卓，EntryAbility 初始化）；首页消费：Project 模式维持项目树，Session 模式渲染平铺会话列表（置顶/最近可折叠分区 + 分区空文案 + 66 高会话行：agent 品牌图标 + 16 Bold 标题 + 11.2 "设备 · 项目"上下文标签 + 状态指示器，对齐安卓 HomeSessionRow/sidebarContextLabel；保持服务器顺序仅按 pinned 拆分）；会话视图空态改 home_no_sessions + 新建会话按钮；模式切换经 `@StorageProp + @Watch` 即时重渲染
- 验证：模拟器实测外观菜单锚定正确（三选项紧随行下）+ 深色/浅色切换生效；侧边栏弹层（菜单 y 1360 = 行底 1346 + 4vp）；会话视图分区渲染（"工作笔记本 · Mihu"上下文标签）、置顶分区折叠/展开往返、重启后偏好保持、切回项目视图恢复项目树
- 沉淀规则：**`getRectangleById` 返回 px、`position()` 接收 vp，必须 px2vp 换算**；**page-root 级 id 与页内组件坐标基准不一致，锚点测量须用页内零尺寸 marker 校准**；应用 JS hilog 不进 `hilog -x` 捕获缓冲（连 EntryAbility testTag 都不在），日志排查无效，测量类调试优先"界面 debug Text + dumpLayout origBounds"

---

## 一、已对齐（DONE）

### 认证 / 登录
- Web PKCE S256 登录 + 自托管服务器地址输入 + 健康检查（`LoginPage.ets`、`AuthApi.ets`）
- **扫码登录**：ScanKit 系统扫码 → `requestMobileLogin` → 轮询 `mobileLoginStatus` → `exchangeMobileLogin`（`auth/MobileLoginQrPayload.ets`、`common/AppConfig.ets`）
- **官方云一键登录**：`OFFICIAL_SERVER_URL = 'https://web.agents-anywhere.com'`（对齐安卓 `AppConfig.kt`）
- 登录页两选项结构对齐安卓 `AuthScreens.kt`（扫码主路径 / 账号密码次路径 + 官方云/自建选择）
- 会话持久化（`auth/AuthSessionStore.ets` EncryptedStore）+ 401 统一清栈（`authSessionExpiredTick`）

### 会话与首页
- 项目分组首页、Active/Archived tab、批量归档、标记已读、会话分享、重命名/置顶/归档（`HomePage.ets`）
- **按项目全部归档**：`POST /projects/{id}/sessions/archive-all` + 确认弹窗（批次 T2）
- **设备全部归档**：`archiveAllDeviceSessions` UI 接入（设备展开操作区，批次 T2）
- dashboard 实时 WS 刷新 + 指数退避
- 新建会话：设备/runtime 自动选择（在线设备 + running 激活 runtime）、cwd、首条消息（`NewSessionSheetOverlay.ets`）
- **新建会话 selections + 内联附件**：内联 base64 附件（≤10 个 / 单个 ≤25MiB，SHA256 作 fileId，对齐安卓 `toInlineAttachmentRef`）；runtimeId/selections 字段逐字段对齐 Server `SessionCreateAndStartRequest`（批次 T6）

### 会话详情 / 审批
- timeline 渲染、user/assistant 气泡、历史分页、乐观消息
- notice 审批卡片 + respond；**notice input 表单**（`input.schema`/`uiSchema`/`inputRequest` 问答，`feature/NoticeInputForm.ets`）
- **takeover 开关**：`POST/DELETE /sessions/{id}/takeover` 专用端点（修复了此前走 PATCH meta 被服务端忽略的功能性 bug，批次 T1）
- **实时事件批窗**：100ms 窗口聚合（上限 128 条，对齐安卓 MAX_WIRE_EVENT_BATCH_SIZE），一次重建/一次滚动/一次刷新（批次 T1）
- **`session.refetch_required` / `runtime.refetch_required` 事件处理**（批次 T1）
- **能力驱动门控**：`session.send_message`/`session.interrupt`/`session.interaction.approval`/`session.commands`/`session.command.execute`/`runtime.attachment` 六能力，capabilities 缺失时不门控（对齐安卓语义，批次 T1）
- **乐观消息跨页持久化**：`common/OptimisticMessageStore.ets` 内存单例（对齐安卓 `SessionOptimisticMessageStore`，同为进程内 Store 无磁盘持久化），发送/进页/确认/失败四点对账（批次 T8）
- slash-command 解析 + 前缀建议 + 执行；附件 URL 拉取上传

### 终端
- terminals-v2 复用/创建、WS 流式输出、重连、实时 resize（本地网格 + resize 帧）、断线输入队列 + replay（此前批次）
- **快捷键工具条**：17 键（ESC/`/`/`-`/HOME/↑/END/PGUP/TAB/CTRL/ALT/←/↓/→/PGDN + `^C`/`^D`/`^L`），CTRL/ALT 粘滞锁定，修饰键组合转义序列对齐安卓 KeyHandler（批次 T3）
- **终端模拟器渲染升级**：完整 SGR（16 色 Termux/xterm 表、256 色、RGB 真彩、加粗/反色）、scrollback 渲染（LazyForEach + 缓存 + sticky bottom + "回到底部"）、可视块光标、DECSET 25 光标可见性、IL/DL/DCH/ICH/ECH、`CSI 3J`（批次 T3，`common/TerminalEmulator.ets` + `common/TerminalRender.ets`）
- **后台保活**：`backgroundTaskManager.startBackgroundRunning(BackgroundMode.DATA_TRANSFER)` + `KEEP_BACKGROUND_RUNNING` 权限 + `backgroundModes: ["dataTransfer"]`，失败静默降级（批次 T3）

### 设备 / 配对
- 设备 CRUD（列表/重命名/删除/revoke）
- 完整配对流程：create + token 展示 + pair-code claim + 上线轮询（`feature/DevicePairingFlow.ets`、`pages/DevicePairingPage.ets`）
- **runtime 配置**：`POST /connectors/{id}/runtimes/discover`、`PUT .../runtimes/{rid}/config`、`PUT .../active`、`DELETE .../config` 四端点 + 配置底部弹层（schema 动态表单：executablePath 文本、environment 变量编辑器、uiSchema.order 排序，批次 T4，`components/RuntimeConfigureSheetOverlay.ets`）
- runtime 设激活/停用、删除（含运行中危险确认文案区分）

### 文件 / 附件
- 设备文件页（根路径切换、目录导航、文本查看、binary/truncated 提示）
- **会话内 agent 文件页**：复用 `fs/list`/`fs/readText`/`fs/read` 端点（`connectorId` + `root=session.cwd`，对齐安卓 `SessionAgentFilesScreen` 复用设备文件端点的方式），目录浏览 + 文本预览 + 保存到本机（`pages/SessionAgentFilesPage.ets`，路由表 `session_agent_files`，批次 T5b）
- 本地附件上传：相册 PhotoViewPicker + 文件 DocumentViewPicker.select + **相机拍摄**（`cameraPicker.pick`，免权限系统相机，批次 T5a）
- **非图片附件下载/保存**：带认证 base64 下载 → `DocumentViewPicker.save` → `fileIo` 写入（免权限，批次 T5a）
- 图片附件预览（base64 → PixelMap 缓存）

### Markdown / 富文本
- 完整 markdown 解析 + 表格 + 任务列表 + 自动链接 + diff 预览（`common/Markdown.ets`、`components/DiffCodeView.ets`）

### 新建会话（B3 重构，对齐安卓 NewSessionScreen）
- **配置卡**：Device/Runtime chips + Model/Reasoning(Effort)/Permission 三 catalog 选择（`GET /connectors/{id}/runtimes/{rid}/capabilities|catalogs/model|catalogs/permission`，逐字段对齐 `connector_runtimes.py` 契约），loading/失败/重试态，提交 payload 带 selections（`NewSessionSheetOverlay.ets` + `DevicesApi.ets` catalog DTOs）
- **权限本地化**：`common/RuntimePermissionLocalization.ets`（移植安卓 `SessionRuntimeState.kt` localizeRuntimePermission，22 条 label/desc 文案）
- **偏好记忆**：`auth/NewSessionPreferenceStore.ets`（preferences `last-selection-v2`，持久化 connector/runtime/model/permission/effort）
- **Workspace 目录浏览器**：fs/list 远程目录浏览（进入/上级/选定 cwd/loading/空/错误重试）
- **Setup 引导面板**：checking/devices-unavailable/no-devices/connect-device/offline/agents-unavailable/setup-agent/no-runtimes 全状态机（对齐安卓 NewSessionSetupPanel），检查重试 + "去设备页"
- 可编辑标题 + 保留鸿蒙独有的首条消息/附件能力；全量 i18n + 主题化（消除硬编码颜色/英文）

### 文件页（B1 对齐安卓 FilesScreen/DeviceFilesContent）
- 路径条复制按钮（Copy/Check 切换）、长按文件/目录 → 菜单复制路径（`components/FileRowMenuOverlay.ets`）
- 文件预览：文件内搜索（大小写不敏感、↑↓ 导航、当前/总数计数、行高亮定位）+ 复制内容
- Windows 盘符概览（`''` 路径 = "这台电脑"，`common/FileViewSupport.ets` 盘符/上级目录工具）
- 空态引导：未配对设备 → "先配对" + 跳转设备页；全部离线 → files_all_devices_offline
- 语义文件图标（文件夹/代码/文本/普通，替换 emoji）；会话 agent 文件页同步以上能力
- 保留鸿蒙领先项：根路径显式切换、下拉刷新、25MB 保存到本机

### 会话详情（B2 对齐）
- **takeover 确认弹窗**：开关/关闭均弹确认（对齐安卓 session_enable/disable_takeover 文案，DSH 专属正文），确认才调 API，失败回弹，busy 防重入
- **附件全屏预览**：`components/AttachmentPreviewOverlay.ets`（Swiper 翻页 + 底部缩略图条 + 双指缩放 1–4x + LoadingProgress 占位 + 失败文件名 fallback + 远程附件下载/保存）；`loadAttachmentPixelMap` 缓存与并发去重（`AttachmentImageView.ets` 抽出共用）

### 终端
- **清屏按钮**：状态行垃圾桶按钮，本地清屏（清屏幕+scrollback+光标归零，`TerminalEmulator.clearScreen()`；安卓为重启 shell，语义差异见下）

### 首页（B4 + B6 布局重构对齐）
- **项目过滤器**：status/device/agent 三维过滤 + Clear（`components/HomeProjectFilterOverlay.ets`，对齐安卓 HomeProjectMenus/SidebarSelectors 谓词）；安卓顶栏搜索按钮实为"敬请期待"占位 toast（HomeScreen.kt:221），鸿蒙对齐为同语义占位
- **公告/更新弹层整改**：`AnnouncementGateOverlay`/`AppUpdatePromptOverlay` 全量 i18n（中/英）+ getColors 主题化（支持暗色），挂载移至 `Index.ets` 根部（对齐安卓 App 级挂载，登录页同样被公告覆盖）
- **布局结构（B6）**：顶栏 46dp（头像圆钮 42/人形图标 21 + wordmark 31sp/40 + 搜索钮 42/图标 24，间距 12）；QuickEntries 三卡 76dp（r18、padding 12/13、图标 22 灰 + 标题 14 Bold/17，间距 10）替代原四胶囊 navAction 行；Active/Archived tab 改为安卓 HomeTabPill 样式（pill 34/r17、选中底 亮#ECECE9/暗#27272A、14sp 选中 Bold/未选 600）；分组头 56dp（folder 21 + 16 Bold + more/square_and_pencil 38/19）；会话行 44dp（robot 16 + 15 Medium + 状态指示 pill 12.5/h18 + busy 20 + 未读点 9）；右下 FAB 54dp 黑底白 plus 24（margin 18/32，打开新建会话 sheet）；外层 Column padding 18/18/6、子项间距 15；空态对齐 AppEmptyState（消息 16 Medium + 药丸按钮 44/r22）
- **侧边栏显示（B8）**：Profile 抽屉"侧边栏显示"卡 + 项目视图/会话视图下拉弹层（`auth/SidebarViewModeStore.ets` 全局持久化）；Session 模式首页渲染置顶/最近平铺会话列表（66 行高 + agent 品牌图标 + "设备 · 项目"上下文标签 + 状态指示器）；模式切换即时重渲染、重启保持

### 设置 / 多语言
- displayName、修改密码、**邮箱绑定**、**头像上传/清除**（`PUT/DELETE /auth/me/avatar`，256px PNG data URL 对齐安卓压缩策略，批次 T7）
- **多语言**：中/英三份 string.json（base/en/zh_CN）全量维护
- **外观模式**：Follow system/Light/Dark 三选 + 持久化（`designsystem/AppearanceSettings.ets`，getColors 强制色板 + 全页响应，B5 对齐安卓 AppearancePopup）
- **版本/更新检查行**：当前版本号 + 静默检查 + 新版本红点 + 手动检查更新（对齐安卓 ProfileRow，复用 AppUpdateIgnoreStore/openLink 流程，B5）

### 公告
- 公告 gate + 已读（`AnnouncementGateOverlay.ets`，Index 根挂载）

---

## 二、部分对齐（PARTIAL）

| 功能点 | 安卓现状 | 鸿蒙现状 | 说明 |
| --- | --- | --- | --- |
| 终端选区复制 | Termux emulator 选区 + 复制 | 无选区交互 | 需自定义手势 + 命中测试，建议独立批次 |
| 终端备用屏幕缓冲区 | CSI ?1049 完整支持 | 私有序列安全吞掉，不污染 scrollback，但全屏应用仍画主屏 | 已知偏差 |
| 终端清屏语义 | 清屏按钮实为重启 shell | 本地清屏（保留 shell 连接） | B1 采用本地清屏，语义更温和；如需对齐安卓改重启 |
| 终端多实例池 | `RemoteTerminalPool` 多页共享 | 每页单实例 | 鸿蒙页面栈结构不同，影响有限 |
| runtime 状态枚举文案 | Server 10 种 `RuntimeStatus` 本地化 | 仅 active/present/absent 三态徽章，状态码原样显示 | T4 未尽事项 |
| 发送中按钮状态跨页恢复 | `sending = hasPendingOptimisticSend()` | 仅恢复消息气泡，按钮不跨页（旧实例 Promise 无法通知新实例） | T8 未尽事项 |
| 发送失败草稿跨页 | 失败草稿持久化 | 离页后失败草稿丢失 | T8 未尽事项 |
| notice 草稿/状态机 | `RuntimeNoticeDraftStore` + 状态合并 | `respondingNoticeId` 单条锁，无草稿 | 现有实现可用，缺草稿续填 |
| model/permission catalog 预览 | runtime 配置 sheet 内预览 | API 字段已解析（`schemaRecord` 等），UI 未做预览区；新建会话流程已消费三 catalog（B3） | T4 未尽事项 |
| 代码高亮 | TextMate 语法高亮（消息代码块 + Sora 文件预览） | 纯代码块 + diff 预览；文件预览为纯文本（B1 已加文件内搜索/复制） | 中期增强 |
| 文件路径点击跳转 | `parseFileRef` + onOpenFile | 缺失 | P2 |
| 文件重命名/上传 | 安卓亦未实现 | 未实现 | 两端共同缺口，随 Server fs 能力评估 |
| 附件预览聚合范围 | 全会话图片合并翻页 | 当前消息附件内翻页 | B2 未尽事项 |
| 首页 agentLabel 副标题 | 过滤激活时项目行显示 agent 副标题（行高 64） | 未实现（恒 56） | B7a 未尽事项 |
| 首页折叠指示 | FolderOpen/Folder 双图标变体 | folder/folder_fill 代替（sys.symbol 无 folder_open） | B7a 已知视觉偏差 |
| 首页归档访问 | Profile 侧栏 → ArchivedSessionsScreen | 项目过滤选"已归档"或 Profile 抽屉 → 归档会话页 | B7 对齐 |
| 抽屉内弹窗返回键 | 弹窗单独拦截返回 | 系统返回会整个关闭抽屉 | B7b 已知行为偏差 |
| Profile 更新详情页 | 版本行进入更新详情页（下载进度等） | toast + 复用更新弹层（打开下载页） | B5 最小一致方案；应用内下载两端同为占位 |
| 会话视图行尾时间 | SessionList 行尾 updatedAt 相对时间 | 未显示（仅状态指示器） | B8 会话视图行未实现时间标签；sortKey 为原始 ISO 串，需相对时间格式化，后续批次补 |

---

## 三、未对齐 / 平台差异（KNOWN GAP）

| 功能点 | 状态 | 说明 |
| --- | --- | --- |
| 应用内更新下载安装 | 平台差异 | 安卓 `UPDATE_DOWNLOAD_URL` 同为占位 `.invalid`（发布前需替换）；鸿蒙 `AppUpdatePromptOverlay` 走"打开下载页"，HAP 安装需 AppGallery/签名分发，无法复刻安卓 APK 直装。两端当前同为占位状态，视为对齐 |
| 终端后台保活的推送级保活 | 平台差异 | 安卓前台服务 vs 鸿蒙 continuousTask，机制不同已按各平台最佳实践实现 |

---

## 四、验证状态与遗留风险

- 每批次均通过 `arkts_check`（0 错误）与 `devecocli build`（BUILD SUCCESSFUL）。
- **未做运行时验证**：所有端点调用链（takeover、runtime discover/configure、catalog 三端点、相机拍摄、附件保存、agent 文件保存、头像上传、内联附件创建、终端渲染、后台保活、目录浏览器、文件内搜索）仅静态与构建验证，未在真机/模拟器实测。
- 已知遗留：`LoginPage.ets`/`WebLoginModels.ets` 存量弃用 API 警告（各批次未触碰）；`SessionActionMenuOverlay` 等早期组件存量硬编码文案待后续批次 i18n 化。
