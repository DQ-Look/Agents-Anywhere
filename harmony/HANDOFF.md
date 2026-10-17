# HarmonyOS 端开发 Handoff（DevECode 接续说明）

仓库：D:\code\Agents-Anywhere，分支 feat/hmo/client-explore。
鸿蒙工程：D:\code\Agents-Anywhere\harmony\AgentsAnywhere（bundle com.agentsanywhere.app，API 26）。
参考实现：android/app/src/main/java/com/agentsanywhere/app（Kotlin，分层规则见 android/ARCHITECTURE.md）。
契约：contracts/ 与 docs/api/。Server 当前 2.1.0。

## 已完成
- 脚手架 + build（devecocli build 通过）
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
  - pages/FilesPage（设备选择、目录列表（目录优先排序）、进目录/上级、文本文件查看、binary/truncated 提示）

## 已知偏差/缺口（下轮可选）
1. 实时是 WebSocket（Server 无 SSE 端点），payload 简化为 {session,item,items,state,eventCursor}；notices 不走 WS（runtime.notice.* 事件触发重新拉取），capabilities/catalogs 未移植
2. 会话详情：附件只占位（上传 API 未接）；无 slash-command 解析；markdown 仅代码块分段，无标题/列表/加粗
3. 终端：无真实 resize（创建时 80x24）；无持久后台服务；断线仅手动/进入时重连（fromSeq=lastSeq）
4. 文件浏览：无根路径切换（固定 root='~'）、无重命名/上传/下载
5. 设备管理：配对流程仅占位（未做 create device + token 展示 / pair-code claim）
6. 首页会话列表未接 dashboard 实时刷新；无创建会话入口
7. 未在真机/模拟器做过 UI 验证（仅 headless build）

## 硬性约束（上一轮经验）
- ArkTS：不允许 any/unknown；build() 内禁止局部变量/switch/三元/console；ForEach 必须 key；catch 不写类型注解
- 接口若要用对象字面量实现（如 Listener），成员必须写成**函数类型属性**（`onOpen: () => void`），方法签名（`onOpen(): void`）会触发 arkts-no-untyped-obj-literals
- `webSocket.WebSocket`（API 26）没有 destroy()，用 off() + close() 释放
- `ctx.pathInfo.param` 是 unknown，需 `as string` 收敛后再 typeof 校验
- API 26 才支持 PATCH，工程已 target 26
- 不引入新 npm 依赖；如需先报告
- 每个模块写完先 arkts_check 再 build，失败立即修
