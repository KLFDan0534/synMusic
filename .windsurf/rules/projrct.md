---
trigger: always_on
---

【UI 接入与可测试性强制规则（必须遵守）】
你在实现每一轮功能时，必须同时完成“前端 UI 接入”，保证开发者/用户可以立刻在手机上手动测试，而不是只能看日志或写单元测试。


当遇见解决多次的问题时，主动增加日志并且要求用户提供日志,但是日志必须便于搜索
当遇见多次问题无法解决的时候,主动提出更好的解决方案吗,确保解决方案能够生效
每次用户询问,阅读代码必须超过500行
在不影响功能的情况下,如果代码超过800行,进行拆分代码文件,如果影响功能就不用拆分

任何下载/hash/IO/长循环不得在 UI isolate 执行

所有同步消息必须幂等（epoch/seq）

seek 仅在 |delta|>1000ms

<1000ms 只允许 setSpeed，不允许 seek

任何 seek 必须有冷却与诊断日志

iOS 必须配置 audio_session 并处理 interruption 恢复

硬性要求：
1) 每一轮新增的核心能力，都必须在 App 内提供可点击的 UI 入口（按钮/页面/开关/卡片均可），并且能在真机上完成完整流程。
2) 必须提供一个统一的“Sync Lab / 同步实验室”页面（可放在首页入口、侧边栏、开发者菜单或长按入口）。
3) Sync Lab 页面必须包含以下区块（最少可用版本即可，不追求美观）：
   - 角色选择：Host / Client
   - 房间控制：创建房间（Host）、扫描房间（Client）、加入/离开
   - 音源控制（Host）：选择 MP3（文件选择器/固定 demo 文件/最近播放均可）
   - 分发/缓存状态（Client）：显示下载进度、缓存路径、hash 校验结果
   - 播放控制：Play/Pause/Seek（用于故意制造偏移）
   - 同步控制：开始同步（FutureStart）、开启/关闭 KeepSync、显示当前 speed
   - 校准按钮：一键校准 latencyCompMs（并显示保存值）
   - 诊断面板：实时显示关键指标（每 0.5~1s 刷新即可）：
     roomNowMs、rttMs、offsetEmaMs、jitterMs、
     hostPosMs、clientPosMs、latencyCompMs、
     deltaMs、speedSet、seekPerformed、lastSeekAt、状态机状态

4) UI 与业务分层约束：
   - UI 只能调用 SyncV2Controller（或类似 Facade）公开方法，不允许 UI 直接操作 WebSocket、RoomClock、下载器等底层对象。
   - 所有状态通过 notifier/stream/provider 暴露给 UI；UI 只负责展示和触发动作。

5) 可测试性验收（每轮都要满足）：
   - 从“Sync Lab”页面可以完成本轮最关键的路径（例如：发现→加入→下载→开播/追帧→对齐）。
   - 若本轮功能失败，UI 必须给出明确错误提示（toast/snackbar + 错误码/原因），同时日志包含同样原因。
   - 必须提供一个“模拟场景”按钮（例如：人为 seek 偏移 +500ms、模拟网络抖动/断连重连），方便快速验证 KeepSync 策略。

6) 不允许只做“后台代码完成”就结束。任何 PR/提交都必须包含：
   - UI 入口可见
   - 可手动操作的测试流程
   - 实时诊断显示
否则视为未完成本轮任务。

输出要求：
- 不要输出整项目代码；只在需要时展示关键片段/文件清单/新增路由与页面入口位置。
- 怎样算测试成功
- 每轮结束必须列出：新增/修改文件清单 + Sync Lab 的测试步骤（1~5 步即可）。
