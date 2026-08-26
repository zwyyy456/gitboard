# GitBoard 工程验证参考

- 权威性：Informational Reference
- 加载方式：需要为改动选择最接近风险的验证范围时按需读取
- 状态：Active

本文帮助选择工程反馈面，不定义产品设计、发布清单或新的测试门禁。被验证的工程行为来自 `architecture.md`。

## 按影响域选择反馈面

| 影响域 | 先确认的真源 | 优先反馈面 |
| --- | --- | --- |
| App composition、scene 或窗口适配 | `architecture.md` | macOS app build；启动受影响 scene，确认依赖共享和窗口入口可达 |
| `ProjectStore` 状态或选择 | `architecture.md` | macOS app build；检查加载、项目切换、筛选和错误恢复不会产生第二状态真源 |
| async、轮询或取消 | `architecture.md` | macOS app build；定点检查启动/停止轮询、手动刷新与项目切换，不出现重复任务或过期结果 |
| GitHub CLI、GraphQL 或解码 | `architecture.md` | 对确定性分页、解码和错误分类运行 `GitBoardTests`；macOS app build；使用已认证 `gh` 验证受影响的只读链路；远程 mutation 仅在任务明确授权且目标安全时执行 |
| 远程 mutation 与乐观更新 | `architecture.md` | macOS app build；在安全目标上检查成功结果，以及可控失败下的回滚和错误反馈 |
| Models 或 GraphQL selection set | `architecture.md` | macOS app build；用受影响真实响应检查解码边界；若未来已有 model tests，运行对应定点测试 |
| 通知 | `architecture.md` | macOS app build；按改动风险检查授权、拒绝和状态变化通知，不重复请求或发送 |
| Sparkle 更新代码 | `architecture.md` 的依赖方向 | macOS app build；检查设置中的 updater 状态和手动检查入口；发布签名与 appcast 不属于本文范围 |

## 当前自动化边界

- 当前 Xcode 工程包含 `GitBoard` app target 和聚焦外部数据边界的 `GitBoardTests` unit test target，没有 UI test target。
- 普通改动至少运行与 `docs-index.md` 一致的 macOS app build；仅修改 Markdown 时可用文档一致性检查代替构建，并明确未运行构建。
- `GitBoardTests` 只为确定性的解析、输入建模、状态转换、远程响应解码和已确认回归提供少量定点测试。
- 不为了测试数量给简单 accessor、临时 View 结构或系统框架行为补测试。
- UI test target 只有在用户明确要求时才运行。

## 交接记录

交接只报告实际执行的构建、测试和人工检查，以及未执行范围与剩余风险。候选检查项不能描述为已经完成的证据。
