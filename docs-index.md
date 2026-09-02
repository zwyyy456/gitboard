# GitBoard 文档索引

- 权威性：Index（不定义规则）
- 加载方式：需要定位工程规范、代码入口或验证命令时读取
- 状态：Active
- 最后更新：2026-09-03

本文只负责文档分类、任务路由和命令入口。所有路径均相对于仓库根目录。

## 1. 执行与导航

| 文档 | 权威性 | 加载方式 | 职责 |
| --- | --- | --- | --- |
| `AGENTS.md` | Execution Instructions | 默认 | 项目事实、文档路由、项目约束和验证边界 |
| `docs-index.md` | Index | 需要定位文档或命令时 | 文档分类、读取路由和常用命令；不定义工程规则 |

## 2. 工程规范

| 文档 | 权威性 | 加载方式 | 职责 |
| --- | --- | --- | --- |
| `architecture.md` | Normative | 涉及状态、scene、并发、外部服务、持久化或目录边界时 | GitBoard 的长期工程架构边界 |

## 3. 按需工程参考

| 文档 | 权威性 | 加载方式 | 职责 |
| --- | --- | --- | --- |
| `docs/overview.md` | Informational | 需要快速定位代码和执行链路时 | 项目与代码导览，不定义规则 |
| `docs/testing/validation-reference.md` | Informational Reference | 选择受影响范围的验证方式时 | 按工程风险定位构建和行为检查，不增加独立门禁 |

## 4. 读取原则

- 从 `AGENTS.md` 开始，只加载当前任务直接涉及的工程规范或参考。
- `architecture.md` 是当前唯一的工程规范真源；索引、导览和验证参考不得重复定义架构规则。
- `README.md` 面向用户和源码构建者，产品说明不能覆盖工程规范。
- 同一长期规则只保留在一个规范真源中。计划、过程和一次性证据不进入规范文档。

## 5. 常用验证命令

默认 macOS 构建：

```bash
xcodebuild -project GitBoard.xcodeproj -scheme GitBoard -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

单元测试：

```bash
xcodebuild -project GitBoard.xcodeproj -scheme GitBoard -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Automation Worker 本地验证：

```bash
cd Automation
npm run typecheck
npm test
npm run build
```

Automation 生产配置与发布步骤见 `Automation/README.md` 的
“Production release”一节。配置完整时运行：

```bash
cd Automation
npm run release:check
```
