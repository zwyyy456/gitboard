# GitStride 工程架构规范

- 权威性：Normative
- 加载方式：涉及 app composition、scene、状态所有权、并发、外部服务、持久化或目录边界时默认读取
- 状态：Active
- 适用平台：macOS 14+
- 职责：定义 GitStride 当前长期工程边界；不定义产品功能、视觉设计或发布流程

## App、Scene 与依赖方向

- `GitStrideApp` 是 composition root，创建 app-lifetime 的 `GitStrideModel`，并装配 `MenuBarExtra`、工作区窗口、快速新增窗口和设置窗口。
- 同一个 `GitStrideModel`、`ProjectStore` 和 `MyWorkStore` 实例由各 scene 共享。不得为不同 scene 创建相互竞争的项目、选择、关注列表或监控真源。
- App 层只负责 scene、窗口生命周期、依赖装配和平台 presentation。GitHub 查询、项目变更和筛选规则不进入 `GitStrideApp`。
- 生产依赖方向为 `App -> Views -> Store -> Services / Models`。Services 不依赖 SwiftUI View、窗口或 scene。
- `openWindow`、菜单栏关闭、`NSWorkspace` 打开链接和 `NSWindow` 外观等平台 presentation 留在 App 或 Views；它们不得进入 GitHub 数据访问层。

## 状态所有权

- `ProjectStore` 是全部远程 `Project` 快照、项目目录顺序、当前项目、状态筛选、远程 mutation、加载/错误状态、更新时间和当前用户的唯一可写真源。项目目录与 My Work 只保存排序或关注引用，不复制完整项目快照。
- `MyWorkStore` 只拥有关注项目引用和 My Work 筛选偏好，并从 `ProjectStore` 的快照派生列表；不得直接请求 GitHub、保存远程快照或执行远程 mutation。
- `GitStrideModel` 负责 app 级组合与跨功能编排，包括 My Work 刷新、监控生命周期、通知动作和静音/稍后提醒偏好。它不复制 `ProjectStore` 的远程实体状态。
- `AutomationSetupModel` 负责自动化的 setup session、配置草稿、连接健康和管理操作；它由 `GitStrideModel` 持有，设置窗口不得创建竞争实例。
- `ProjectStore` 保持 `@MainActor` 隔离。所有会改变可观察 UI 状态的结果必须回到该 owner 应用。
- Views 只持有搜索文本、输入草稿、表单校验、焦点、局部展开状态等 surface-local presentation state；不得复制可写的项目集合、当前项目或远程 mutation 状态。
- 工作区的已保存视图只持久化用户命名、筛选身份和显示偏好；筛选与交付统计从 `ProjectStore` 的完整项目投影派生。看板隐藏列只影响看板呈现，不缩小表格或交付统计的数据范围。
- `ProjectDisplayPreferences` 集中拥有展示偏好的键集合、项目/保存视图命名空间和复制、删除逻辑；View 通过其键继续使用 `@AppStorage`，不另建可写的偏好快照。
- `ProjectWorkPreferences` 通过 `@AppStorage` 集中管理已保存工作视图和项目布局的编码、更新及关联展示偏好的复制、删除；看板只持有当前筛选和选择，不维护第二份持久化视图集合。
- 菜单栏和看板可以采用不同的局部展示状态，但共享项目选择和远程数据。一个 surface 的出现或消失不得重建全局 store。
- `GitHubService`、`ProjectMonitor` 和 `ProjectCache` 以 actor 隔离外部副作用或后台任务，不发布第二套可观察业务状态。
- `AutomationService` 是桌面 App 与 Automation Worker 的唯一 HTTP/WebSocket 边界。View 不拼接 Worker 请求、不解析响应，也不接触 management token。

## 异步任务与轮询

- 监控生命周期由 `GitStrideModel` 单点拥有，`ProjectMonitor` 通过 `GitStrideModel` 装配的读取闭包消费 Store 已接受的远程快照，只负责轮询、变化检测和通知事件。任一时刻最多存在一个有效监控流；重新启动前先取消旧任务，不再需要监控时必须停止任务。
- `ProjectMonitor` 流终止时只能取消创建该流的 producer，不能通过共享 `stop` 操作取消后来启动的 producer。
- 项目详情、手动刷新、关注刷新和监控读取都经过 `ProjectStore` 的统一快照提交入口。仅当前请求、有效关注 generation、未跨越相关 mutation 且项目仍被保留的结果可以提交；失败和取消只能结束自己所属的加载状态。mutation 期间失效的读取按项目合并补刷，普通读取失败不自动循环重试。
- 监控的一轮读取被取代或不完整时，跳过该轮比较并保留上次基线；不得把被拒绝的结果作为空项目参与变化检测。
- 任务取消是正常控制流。新增循环、延迟、子进程或网络桥接时必须保留取消路径，不能用无界 detached task 绕过 owner 生命周期。
- 加载标记、错误和 `lastUpdated` 必须描述实际完成的操作；失败不能被写成成功刷新，也不能在没有替代反馈时静默吞掉。
- 不在 View 中直接执行 GitHub 子进程或 GraphQL 请求。View 通过 `ProjectStore` 或 `GitStrideModel` 的 intent 发起用户操作。

## GitHub CLI 与 GraphQL 边界

- `GitHubService` 是仓库中定位和执行 `gh`、调用 GitHub API/GraphQL、解析传输错误的唯一边界。
- `GraphQLQueries` 集中保存查询与 mutation 文本。Models 负责已知响应结构；Views 和 Store 不解析原始 JSON 字典。
- 子进程使用明确的 executable URL 与 arguments 数组传参。不得把查询、标题、登录名、URL 或其它外部输入拼进 shell 命令字符串。
- GitHub CLI 认证是凭据真源。应用可以为当前调用读取 token，但不得把 token 复制到 `UserDefaults`、文件、日志、错误文案或测试 fixture。
- 外部失败必须保留可诊断类别，例如找不到 `gh`、未认证、进程失败、GraphQL 失败或解码失败；UI 只消费经过整理的错误，不接收完整敏感 payload。
- GitHub API 或 `gh` 行为变化时，在此边界完成适配；不得在不同 View 中增加各自的兼容分支。

## 身份、模型与远程变更

- `Project.id`、`ProjectItem.id`、`StatusOption.id` 等 GitHub node ID 是远程实体和 mutation 的稳定身份。标题、状态名称、序号或 URL 只承担各自的展示或定位职责，不替代 node ID。
- Issue/PR 内容身份与 Project item 身份保持区分；需要操作内容实体时使用对应的 `contentId` 或由受控 GitHub 边界解析。
- 远程响应先转换为 `Models` 中的明确类型，再进入 Store。不要让 GraphQL 响应容器成为 View 的长期接口。
- 状态移动的乐观展示只保存进行中操作的目标字段值，不修改已确认快照。成功时在最新快照提交目标字段，失败时只移除本次操作的展示值；展示投影不进入缓存。
- 同一 Project item 的状态、字段和成员移除操作共用冲突控制；内容修改按 `contentId` 共用冲突控制，并更新或刷新全部已加载的关联项目、失效关联详情缓存。内容 mutation 与项目读取重叠时，旧读取不得提交，包括当时尚未加载出内容关联的新项目。
- 内容 mutation 的内部入口必须指定应用补丁或刷新关联项目。补丁在受保护的写入阶段提交，项目补刷在该阶段结束后发起；缓存保存和需要主动重载的详情由同一入口编排。
- 创建、删除、指派和状态移动都通过 `ProjectStore` 编排，以维持菜单栏与看板窗口的一致状态。
- Issue 创建由 `ProjectStore` 创建和更新 `IssueCreation` 操作，View 只持有只读引用。操作在内存中保留原项目、已确认身份、未完成字段和下一阶段；恢复只继续未完成步骤。已经取得身份或创建结果不确定时，不得重新执行创建命令；操作引用释放后不提供跨启动恢复。

## 本地持久化与可重建状态

- `UserDefaults` 只保存明确的轻量用户偏好和稳定选择，例如项目选择、My Work 关注/筛选、监控设置与更新设置。
- `ProjectCache` 只保存可重建的版本化项目快照，并使用原子写入；缓存不可用时回到远程加载或显示明确错误，不能改写到临时目录作为静默兜底。
- GitHub 项目、条目、assignee、加载状态、错误、更新时间和搜索输入均不成为本地业务真源。缓存内容只能作为启动展示和失败时的只读回退。
- 启动后若已保存的项目或状态身份不再存在，应用必须回到可操作状态；不得长期保留指向缺失远程实体的半初始化选择。
- GitHub token、完整 API 响应和私有项目内容不得进入本地偏好存储。
- Worker management token 只保存在系统 Keychain；OAuth access/refresh token 只保存在 Worker 的加密凭据表，不进入桌面 App、`UserDefaults`、缓存、日志或错误文案。

## Automation Worker 边界

- `Automation/` 中的 Worker 独立承担 webhook 验证、Queue 编排、GitHub App installation 读取、个人 Project Item 定位、状态写入、OAuth 轮换与管理 API。
- 每个个人账号的 GitHub App installation 只对应一条账户级 automation。其来源范围由 installation 当前可访问仓库集合决定，仓库增删不创建或复制 automation。
- setup 中选择的个人 Project、Status 字段和选项只定义语义映射模板。运行时按 Issue 身份在该账号的个人 Projects 中定位实际 Project item，并按字段名和选项名解析每个 Project 自己的 node ID；目标 Project 集合不持久化为配置。
- setup 提交时，模板 Project 的所选 Status 字段必须包含 `In Progress` 和 `Done`，并记录用户选择的 Ready PR 策略；只是浏览、选择或 Enable 不得修改远程字段。
- 运行时目标 Project 的 Status 选项先按模板名称精确匹配，再做仅忽略大小写的匹配；空格及其它字符仍须一致。用户选择 `Move to In review` 时，Worker 仅在 Ready PR 的 closing Issue 已精确定位于该 Project 后，才复用对应选项，或在缺失时保留全部现有 option identity 并添加橙色 `In review`；用户选择 `Keep in In progress` 时不得添加选项。任何策略都不得自动添加 `Backlog`。
- PR 事件通过 Queue 延迟 3 秒后重新读取当前事实；恢复未入队事件保留该延迟，installation 生命周期事件不增加此延迟。关联 closing PR 非空且全部合并才写 Done；任一打开的 Draft 优先写 In Progress，否则存在打开的 Ready 时使用配置的 Ready 策略。这两类打开 PR 即使 Issue 已关闭也参与计算；没有打开 PR 且未全部合并时，仅对仍打开且全部 PR 未合并关闭的 Issue 写 In Progress，其余不修改。
- Worker 确认至少一次 Project Status 写入或 automation 连接健康发生变化后，通过按 automation 隔离的 Durable Object WebSocket 只发送带单调 revision 的分类失效事件，不发送 Project 或 Issue 内容。App 收到任一事件后重新加载 automation 连接状态；Project 数据变化或初次连接事件还会刷新当前和 followed Project 快照，以补偿 App 未运行期间错过的事件。
- Gateway 在每次确认 Status 写入后向 Runner 回执；Runner 在本轮调用中保留该事实，包括 OAuth 重试和后续目标失败的情况，并在处理 delivery 结果后发送项目数据失效通知。回执不替代原有错误分类、重试或停用流程。
- 已存在的账户级 automation 通过完成 OAuth 与 installation 归属验证的 setup session 恢复本机管理权限；恢复保留原映射和启停状态，不创建重复 automation。管理 token 在本机 Keychain 保存后才提交，服务端只保存其哈希，重复提交不得重复授予凭据。
- 桌面 App 原有 `gh` 认证继续只服务交互式浏览与编辑；后台 automation 不读取或复制本机 `gh` token。
- Worker 为完成自动化会瞬时接收 GitHub Project Item 响应，但应用层只传播必要 identity 字段，不持久化或记录私人 Issue 内容，也不保存 Issue 到 Project Item 的映射。
- Webhook 与运行日志只能包含 delivery ID、automation ID、处理阶段、状态码和稳定错误码，不得包含完整 payload、Issue 标题/正文或凭据。

## 目录边界

- `GitStrideApp.swift`：app 入口、scene、composition 与必要的平台适配。
- `GitStride/Models/`：稳定领域模型和外部响应的 typed decoding structures。
- `GitStride/Services/`：GitHub、项目缓存、后台监控、通知和更新等外部副作用边界。
- `GitStride/Store/`：业务状态 owner 与 app 级跨功能编排。
- `GitStride/Views/`：SwiftUI surface、局部 presentation state 和平台交互。
- 新代码放入拥有其职责的现有目录。只有出现多个真实消费者或明确外部边界时才新增共享模块；不创建无明确所有权的 `Utilities`、`Helpers` 或 pass-through wrapper 作为默认落点。

## 规范演进

- 当前 ownership、依赖方向、外部边界或持久化规则变化时，直接更新本文。
- 产品功能说明、视觉与交互设计、发布步骤、实施计划、迁移进度和验证结果不写入本文。
- 一次代码重排若不改变长期边界，不需要为其增加新规范。
