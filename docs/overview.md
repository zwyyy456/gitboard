# GitStride 代码导览

- 权威性：Informational
- 加载方式：需要快速定位代码和执行链路时按需读取
- 状态：Active
- 最后验证日期：2026-08-29
- 适用范围：代码阅读、新成员上手和任务定位

本文只提供代码入口和当前实现地图，不定义工程规范、产品设计或验收门槛。工程边界以根目录 `architecture.md` 为准。

## 1. 项目定位

GitStride 是 macOS 14+ 的原生 SwiftUI 菜单栏应用。工程入口为 `GitStride.xcodeproj`，包含 `GitStride` app target 和聚焦确定性边界的 `GitStrideTests` unit test target；GitHub 数据通过本机 `gh` CLI 与 GitHub GraphQL/API 获取，应用更新由 Sparkle 提供。

## 2. 最短阅读路径

1. `GitStride/GitStrideApp.swift`：App composition、菜单栏和窗口 scene。
2. `GitStride/Store/GitStrideModel.swift`：app 级组合、My Work 协调、监控和通知动作。
3. `GitStride/Store/ProjectStore.swift`：远程项目快照真源、目录/选择、加载和 mutation 编排。
4. `GitStride/Store/MyWorkStore.swift`：关注引用与筛选偏好。
5. `GitStride/Services/GitHubService.swift`：`gh` 定位、进程执行、GraphQL/API 调用和错误转换。
6. `GitStride/Services/ProjectMonitor.swift`：关注项目的后台快照与变化事件流。
7. `GitStride/Services/GraphQLQueries.swift`：GitHub Projects 查询与 mutation 文本。
8. `GitStride/Models/Project.swift`、`ProjectItem.swift`、`MyWork.swift`：领域模型、搜索/筛选规则和响应解码结构。
9. `GitStride/Views/MyWork/MainWorkspaceView.swift`：项目看板与 My Work 的主工作区。

## 3. 目录地图

- `GitStride/GitStrideApp.swift`：应用入口、scene 和平台窗口适配。
- `GitStride/Models/`：项目、条目、状态、用户和 GitHub response models。
- `GitStride/Services/`：GitHub、项目缓存、后台监控、系统通知和 Sparkle 更新边界。
- `GitStride/Store/`：共享的 `GitStrideModel`、远程快照 owner `ProjectStore` 与偏好 owner `MyWorkStore`。
- `GitStride/Views/MenuBar/`：菜单栏浏览、筛选、搜索与快速操作入口。
- `GitStride/Views/Kanban/`：看板窗口和拖放入口。
- `GitStride/Views/Settings/`：设置与更新入口。
- `GitStride/Views/Shared/`：当前由多个 surface 使用的行视图。
- 仓库根目录脚本：release build、DMG 与 appcast 操作入口；其内容不属于普通开发规范。

## 4. 关键执行链路

项目加载：

```text
View task / refresh action
  -> ProjectStore.loadProjects or refresh
  -> optional ProjectCache restore
  -> GitHubService
  -> gh api graphql
  -> typed Models
  -> ProjectStore observable state
  -> menu bar and kanban surfaces
```

My Work：

```text
View intent
  -> GitStrideModel.refreshMyWork
  -> ProjectStore refreshes followed project IDs
  -> one canonical projectSnapshots dictionary
  -> MyWorkStore filters derived MyWorkItem values
```

远程 mutation：

```text
View intent
  -> ProjectStore mutation orchestration
  -> optional pending status presentation
  -> GitHubService GraphQL/API/gh operation
  -> commit a patch to the current confirmed snapshot, or remove pending presentation + error
```

监控通知：

```text
GitStrideModel restarts monitoring
  -> ProjectMonitor requests snapshots through the closure supplied by GitStrideModel
  -> ProjectStore reads, validates and commits followed projects
  -> ProjectMonitor compares complete accepted cycles and yields change events
  -> GitStrideModel routes changes to NotificationService
```

## 5. 改动定位

- Scene、窗口生命周期或依赖装配：从 `GitStrideApp.swift` 开始。
- App 级 My Work、监控、通知动作或跨功能协调：从 `GitStrideModel.swift` 开始。
- 项目快照、选择、筛选、加载、刷新或 mutation 一致性：从 `ProjectStore.swift` 开始。
- 关注列表和 My Work 筛选偏好：从 `MyWorkStore.swift` 开始；远程数据仍回到 `ProjectStore.swift`。
- `gh` 路径、认证、子进程、GraphQL、解码或 GitHub 错误：从 `GitHubService.swift` 与 `GraphQLQueries.swift` 开始。
- 外部响应字段和实体身份：从 `Models/` 开始，并同步检查 GraphQL selection set。
- 菜单栏、工作区或快速新增的局部状态：从对应 `Views/` surface 开始；共享业务状态再按所有权回到 `GitStrideModel`、`ProjectStore` 或 `MyWorkStore`。
- 更新检查：从 `UpdateController.swift`、`SettingsView.swift` 和 `Info.plist` 的 Sparkle 配置开始。
