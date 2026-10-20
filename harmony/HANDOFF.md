# HarmonyOS 端开发 Handoff（DevECode 接续说明）

仓库：D:\code\Agents-Anywhere，分支 feat/hmo/client-explore。
鸿蒙工程：D:\code\Agents-Anywhere\harmony\AgentsAnywhere（bundle com.agentsanywhere.app，API 26）。
参考实现：android/app/src/main/java/com/agentsanywhere/app（Kotlin，分层规则见 android/ARCHITECTURE.md）。
契约：contracts/ 与 docs/api/。Server 当前 2.1.0。

## 构建（重要：devecocli 已卸载）
- 当前仓库里 **devecocli 已被卸载**，不能再用于构建。改用 hvigorw：
  `D:\ProgramFiles\DevEco Studio\tools\hvigor\bin\hvigorw.bat --mode module -p product=default -p module=entry@default assembleHap`
  （Node 用 `D:\ProgramFiles\DevEco Studio\tools\node`，无需 devecocli。）
- 最近一次 hvigorw 构建：**BUILD SUCCESSFUL（EXIT=0，无 ERROR，仅 WARN：deprecated API / crypto may-throw / system-capacity，均不阻断）。**

## 已完成
- 脚手架 + build（hvigorw build 通过）
- 公共层：common/Json.ets、ApiUrls.ets、ApiException.ets
- API 层：api/ApiClient.ets、AuthApi、SessionsApi+SessionDtos（含 RuntimeNotice DTO + notices/respond 端点）、DevicesApi、FilesApi、TerminalApi、RealtimeApi+RealtimeDtos+RealtimeWebSocket
- 认证：auth/AuthSessionStore、LoginServer、WebLoginModels（PKCE S256）
- 导航：Index 为唯一 @Entry + Navigation(Stack) + 系统路由表（resources/base/profile/router_map.json，module.json5 已挂 "routerMap": "$profile:router_map"）；注意路由表字段名是 **buildFunction**（不是 buildMethod，schema 校验会拒绝）
- 页面：
  - pages/Index（登录门禁 + Navigation 宿主）
  - pages/LoginPage（Web PKCE 登录）
  - pages/HomePage（会话列表，入口：Devices/Terminal/Files）
  - pages/SessionDetailPage（timeline 渲染、user/assistant 气泡、markdown-lite 代码块分段、审批 notice 卡片 + respond、composer 乐观消息 + interrupt、历史分页、实时 WS 接入含 events 恢复与重试）
  - pages/DevicesPage（设备列表、展开 runtime 配置、重命名、删除、配对占位）
  - pages/TerminalPage（terminals-v2 复用/创建、WS 流式输出 base64 编解码、输入、重连、resize 占位、ANSI 清洗）
  - pages/FilesPage（设备选择、目录列表（目录优先排序）、进目录/上级、文本文件查看、binary/truncated 提示、**根路径切换（~ / / / 自定义路径选择器）**）
  - pages/ProfilePage（个人信息、改密码、**邮箱绑定：send-email-code → 验证码弹窗 bind-email 两步入驻流程**、语言切换、登出确认）
  - 会话详情能力驱动 UI（capability gating）：
    - GET /sessions/{id}/runtime/capabilities → `hasCapability(set, id)` + `RemoteRuntimeCapabilitySet`
    - Share：POST /sessions/{id}/shares（scope=session, itemIds=[]）→ 用 `context.openLink(shareUrl)` 拉起系统分享/浏览器
    - Takeover：patchSession 的 `takeover` 字段，由 capabilities 控制开关显示

## 已知偏差/缺口（下轮可选）
1. 实时是 WebSocket（Server 无 SSE 端点），payload 简化为 {session,item,items,state,eventCursor}；notices 不走 WS（runtime.notice.* 事件触发重新拉取），catalogs 未移植（capabilities 已移植）
2. 会话详情：附件只占位（上传 API 未接）；无 slash-command 解析；markdown 仅代码块分段，无标题/列表/加粗
3. 终端：无真实 resize（创建时 80x24）；无持久后台服务；断线仅手动/进入时重连（fromSeq=lastSeq）
4. 文件浏览：无重命名/上传/下载（根路径切换已完成）
5. 设备管理：配对流程仅占位（未做 create device + token 展示 / pair-code claim）
6. 首页会话列表未接 dashboard 实时刷新；创建会话入口为底部 Sheet（已做，是否与 Android 完全一致待 UI 验证）
7. 未在真机/模拟器做过 UI 验证（仅 headless build）；深色模式重渲染未订阅 APP_IS_DARK_KEY（全端既有缺口）
8. 客户端自动更新：downloadUpdate 目前用 `context.openLink(downloadUrl)` 兜底，未做真实下载/安装

## 本次补齐（P2）
- **暗色模式重渲染**：`getColors()` 原本以非响应式方式读 AppStorage，没有任何 `@Component` 订阅 `APP_IS_DARK_KEY`，导致系统/手动切换主题时页面不重绘。已在 14 个文件、17 个 struct 上加 `@StorageProp(APP_IS_DARK_KEY) themeIsDark: boolean = false;`（ConfirmDialog 是 `@CustomDialog`，不支持该装饰器，已跳过——dialog 在 open() 时重建，仍通过 getColors() 生效）。EntryAbility 的 `onConfigurationUpdate`→`syncTheme` 已正确维护该 key。
- **更新弹窗令牌化**：`AppUpdatePromptOverlay.ets` 原先硬编码 `#111827 / #2563EB` 等十六进制与 `Color.White`，违反 ColorTokens 规则；已改写为使用 `getColors()` 令牌（headingText / muted / inkSoft / secondaryActionSurface / onPrimaryAction / primaryAction / dialogSurface）。`downloadUrl` 字段保留以兼容调用点。
- 说明：HarmonyOS 端无法像 Android 那样自装 APK；真实 HAP 自更新需要 AppGallery/企业签名（ohos.permission.INSTALL_BUNDLE），本自托管分发模式不满足，故 `openLink` 仍是更新动作（即打开下载页人工侧载），属诚实的可达成对齐。

## 本次修复记录（编译通过前）
- ProfilePage.ets：修复 build() 末尾括号错位（`.title`/`.onReady` 误挂 Column → 改为挂 NavDestination），`$r(...) as string` 非法强转、errorMessage 类型不匹配、`.alignSelf(VerticalAlign.Center)`（Column 应用 ItemAlign）、`session_expired` 未知资源 → 改为字面量。
- SessionsApi.ets：补 `RemoteRuntimeCapabilitySet` import（getSessionRuntimeCapabilities 返回类型引用）。

## 硬性约束（上一轮经验）
- ArkTS：不允许 any/unknown；build() 内禁止局部变量/switch/三元/console；ForEach 必须 key；catch 不写类型注解
- 接口若要用对象字面量实现（如 Listener），成员必须写成**函数类型属性**（`onOpen: () => void`），方法签名（`onOpen(): void`）会触发 arkts-no-untyped-obj-literals
- `webSocket.WebSocket`（API 26）没有 destroy()，用 off() + close() 释放
- `ctx.pathInfo.param` 是 unknown，需 `as string` 收敛后再 typeof 校验
- API 26 才支持 PATCH，工程已 target 26
- 不引入新 npm 依赖；如需先报告
- 每个模块写完先 arkts_check 再 build，失败立即修
