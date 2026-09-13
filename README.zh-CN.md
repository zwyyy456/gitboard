# GitStride · 迹程

[English](README.md) · 简体中文

GitStride 是一款原生 macOS 应用，让你在菜单栏中快速查看 GitHub Projects，也可以在 app 中通过看板或表格整理工作，并直接编辑 Issue。

[官网与下载](https://gitstride.zwyyy456.tech) · [GitHub Releases](https://github.com/zwyyy456/GitStride/releases) · [使用指南（英文）](docs/usage.md)

## 功能

- **菜单栏与工作区**：从菜单栏快速查看项目，也可以打开完整的项目窗口。
- **看板与表格**：调整条目状态、按字段排序、过滤，并保存本地工作视图。
- **我的工作**：添加项目，跨项目筛选和查看工作。
- **Issue 编辑**：创建 Issue，管理负责人、标签、里程碑、父子 Issue 和依赖关系。
- **项目提醒**：启用后，在 App 运行期间定期检查“我的工作”中的项目，提醒状态变更、任务分配变动、临期或逾期等事项。
- **可选的 PR 自动化**：根据 PR 的进展，更新关联 Issue 在个人 Project 中的状态；退出 GitStride 后自动化切换依然生效。

## 使用要求

- macOS 14（Sonoma）或更新版本。
- GitHub.com 账号。桌面端支持个人和组织 Projects；PR 自动化目前支持个人 Projects。暂不支持 GitHub Enterprise Server。

## 安装与登录

1. 从 [官网](https://gitstride.zwyyy456.tech) 或 [GitHub Releases](https://github.com/zwyyy456/GitStride/releases) 下载 GitStride。
2. 打开 DMG，将 GitStride 拖入“应用程序”文件夹。
3. 首次启动时，在欢迎窗口中选择 **打开 GitHub 设置**，然后点击 **登录 GitHub…**。也可以直接进入 **设置 → GitHub → 账户**。
4. 点击 **复制代码并打开 GitHub**，在 GitHub 的设备激活页面粘贴验证码，并确认授权。
5. 选择你的个人账号或组织，再选择要查看的 Project。

新安装的 App 会显示一次欢迎窗口。选择 **稍后设置** 可以跳过，也可以随时从 **帮助 → 欢迎使用 GitStride…** 重新打开。已有账号配置的用户会直接进入工作区。PR 自动化可以稍后单独设置。

桌面登录请求 `repo project read:org offline_access` 权限。其中，`repo` 包含仓库代码的读写权限，也涵盖私有仓库，权限范围大于单纯查看看板所需的范围。登录令牌和刷新令牌保存在这台 Mac 的钥匙串中。

GitHub Release 版还支持 GitHub CLI 登录。断开当前连接后，在 **设置 → GitHub → 连接方式** 中选择 **GitHub CLI**。先安装 [GitHub CLI](https://cli.github.com)，然后运行：

```bash
gh auth login --hostname github.com
gh auth refresh --hostname github.com --scopes project,read:org
```

GitStride 会使用本次连接选定的 CLI 账号，直到你重新连接。断开 GitStride 的连接不会退出终端中的 `gh` 登录。升级时，已有账号配置会继续使用 CLI 模式；新安装默认使用 App 内的 OAuth 登录。

你能查看和编辑的内容取决于 GitHub 账号的权限。组织策略或 SSO 可能要求额外授权。浏览和编辑项目只需完成桌面登录；PR 自动化有独立的授权流程，可以按需开启。

## 日常使用

点击菜单栏图标可快速查看项目，也可以在主窗口中使用 **看板**、**表格**、**我的工作** 和条目详情。搜索支持标题、Issue 编号和 `@负责人用户名`。在项目或菜单栏的搜索框中输入 `>` 后接标题，按回车打开已填入内容的创建表单；确认仓库和状态后，点击 **创建 Issue**。使用 **筛选** 和 **显示选项** 调整项目的显示方式。

| 快捷键 | 操作 |
| --- | --- |
| `⌘ R` | 刷新 |
| `⌘ K` | 打开命令面板 |
| `⌘ ←` / `⌘ →` | 切换到上一个 / 下一个状态标签页 |
| `> 标题` + `回车` | 从项目或菜单栏搜索框打开已填入内容的创建表单 |
| `Esc` | 取消搜索框中的快速创建输入 |

保存的工作视图和显示偏好只保存在这台 Mac 上，不会修改 GitHub 上保存的视图。视图、表格列、交付汇总和工作规划的详细用法见 [使用指南（英文）](docs/usage.md)。

## PR 自动化（可选）

进入 **设置 → GitHub → PR 自动化 → 设置自动化**，按引导完成连接。自动化服务由 [zwyyy456](https://github.com/zwyyy456) 运行在 Cloudflare Workers 上，退出 GitStride 后仍会处理 PR 事件。

设置过程中需要完成两项 GitHub 授权：

- 安装 **GitHub App**，允许它读取所选仓库的元数据、Issue 和 PR。
- 授权自动化专用的 **OAuth App**，授予 `project offline_access` 权限，用于更新个人 Projects 并续期授权。这与桌面登录分别管理。

选择一个个人 Project 作为状态映射模板，指定状态字段及其中的 `In Progress` 和 `Done` 选项。自动化会处理 GitHub App 当前获准访问的所有仓库，并按模板中的字段名和状态名称，更新关联 Issue 所在的所有匹配的个人 Projects。所选模板不是唯一会被更新的 Project。

触发自动化的 PR 需要与 Issue 建立关闭关联。例如，在同一仓库的 PR **描述**中写入 `Closes #123`，并将 PR 的目标分支设为仓库的默认分支。这里的 `#123` 是实际 Issue 编号。将这个 Issue 加入 Project 后，自动化更新的是它在 Project 中的状态。

状态变化遵循以下规则：

- 只要还有一个关联的 Draft PR 处于打开状态，Issue 就保持在 `In Progress`。
- 没有打开的 Draft PR，但还有等待评审的 Ready PR 时，按你选择的策略处理：**移至 In review** 或 **保持在 In progress**。
- 至少有一个关联 PR，且所有关联 PR 都已合并时，Issue 才会进入 `Done`。

选择 **移至 In review** 后，如果匹配的 Project 缺少该状态，自动化会在首次需要时添加橙色的 `In review` 选项。每次 PR 事件会先延迟至少 3 秒，再读取最新状态并处理；实际耗时还包括队列和网络请求。

> 建议关闭与这些规则重叠的 GitHub Project 内置状态工作流，避免同时修改状态。更多规则见 [完整说明（英文）](docs/usage.md#pull-request-automation)。

你可以在 **设置 → GitHub → PR 自动化** 中暂停、恢复、重新授权或删除连接。删除连接会停止后续自动化处理，已修改的 Project 状态会保留。若要同时撤销 GitHub 侧的访问授权，请在 [Authorized OAuth Apps](https://github.com/settings/applications) 中撤销相应 OAuth 授权，并在 [Installed GitHub Apps](https://github.com/settings/installations) 中卸载 GitHub App。

如需将服务部署到自己的 Cloudflare 账号，参见 [自动化服务部署说明（英文）](Automation/README.md)。在 **设置 → GitHub → PR 自动化 → 自动化服务** 中选择 **自定义地址**，填写 Worker 的 HTTPS 服务地址并保存，重启 GitStride 后生效，无需重新编译。也可以选择 **默认服务** 或 **禁用**。切换或禁用服务只改变这台 Mac 的连接；如需停止旧服务器上的自动化，请先暂停或删除原连接。

从源码构建时，`GITSTRIDE_AUTOMATION_BASE_URL` 用于指定默认服务地址；留空表示不提供默认服务，仍可在设置中填写自定义地址来启用。管理凭据按服务地址隔离。

## 数据与隐私

**桌面 App。** 浏览和编辑操作由 GitStride 直接请求 GitHub。OAuth 访问令牌和刷新令牌保存在钥匙串中；CLI 凭据只读入内存，不会复制到 GitStride 的持久化存储。

显示偏好和可重建的项目快照保存在本机。快照可能包含私有项目及 Issue 信息，并且未经加密；只有确认账号身份匹配后才会恢复，断开或切换连接时会删除。GitHub Release 版的缓存位于 `~/Library/Application Support/GitStride/project-cache-v2.json`，沙盒版则使用 App 容器。

断开连接会删除 GitStride 本地保存的 OAuth 凭据。若要撤销 GitHub 侧的授权，请前往 [Authorized OAuth Apps](https://github.com/settings/applications)。桌面登录和自动化使用不同的 OAuth App。

**自动化服务。** 开启后，Worker 会处理 GitHub Webhook 和 API 响应，定位并更新匹配的 Project 条目。服务会保存账号和安装标识、仓库标识、状态映射与连接设置、加密的 OAuth 凭据，以及事件投递状态记录。它不会持久化或记录私有 Issue 的标题、正文，也不会保存完整的 Webhook 请求内容。桌面端的自动化管理令牌保存在 macOS 钥匙串中，服务端只保存其哈希值。

已进入最终状态的事件投递记录在满 30 天后可被清理；过期的设置会话在过期一天后由每日维护任务清理。删除自动化连接时，会删除不再使用的凭据、安装及账号记录；仍被有效设置会话引用的记录会保留到引用解除。这些规则适用于应用数据库，Cloudflare 基础设施日志和备份有各自的保留策略。实现细节见 [Worker 文档（英文）](Automation/README.md)。

**应用更新。** GitHub Release 版使用 Sparkle 检查 [本仓库的更新源](https://github.com/zwyyy456/GitStride/blob/main/appcast.xml)，并从 GitHub 下载更新。你可以在设置中控制自动检查。App Store 构建使用商店更新，不包含 Sparkle。使用 GitHub 和 Cloudflare 服务时，相应服务会接收网络请求元数据。

## 常见问题

| 现象 | 检查方法 |
| --- | --- |
| 提示需要 GitHub CLI | 安装 `gh`，确认 `gh --version` 能正常执行。支持 Homebrew 在 Apple Silicon 和 Intel Mac 上的标准安装路径。 |
| 提示登录 GitHub | 打开 **设置 → GitHub**，使用你选择的方式重新连接。 |
| 提示需要项目访问权限 | 在设置中重新进行 OAuth 授权，或为 CLI 登录授予 `project` 权限。 |
| 看不到组织或私有 Project | 检查当前连接的账号是否有访问权限，以及组织的 SSO 和应用访问限制。 |
| 显示缓存数据或刷新失败 | 检查网络和登录状态后重新刷新。缓存快照可能落后于 GitHub 上的最新数据。 |
| 自动化提示需要授权 | 在设置中对自动化连接重新授权。桌面端重新登录不会续期 Worker 的 OAuth 授权。 |

遇到可复现的问题，请在 [GitHub Issues](https://github.com/zwyyy456/GitStride/issues) 中提供 App 版本、macOS 版本和复现步骤。发送诊断信息或截图前，请移除令牌及私有仓库、Issue 内容。

## 从源码构建

当前开发工具链为 Xcode 26.5。macOS 14 是 App 支持的最低系统版本，不是 Xcode 的版本要求。

```bash
git clone https://github.com/zwyyy456/GitStride.git gitstride
cd gitstride
xcodebuild -project GitStride.xcodeproj -scheme GitStride \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

要从 Xcode 运行，打开 `GitStride.xcodeproj`，选择 GitStride target，在 **Signing & Capabilities** 中选择自己的开发团队。Sparkle 使用强化运行时的库验证，因此未签名的编译检查通过，不代表 App 能直接在本机启动。

`GITSTRIDE_OAUTH_CLIENT_ID` 是桌面 OAuth App 的公开 Client ID。如果你要发行自己的版本，请注册 OAuth App、启用 Device Flow，并在两个 App target 中设置对应的 Client ID。不要嵌入 Client Secret。App Store 版的 scheme 为 `GitStrideAppStore`，请为其选择适合该发行方式的签名配置。

更多信息见 [验证命令](docs-index.md#5-常用验证命令)、[工程架构](architecture.md) 和 [发布指南（英文）](docs/releasing.md)。Worker 开发另外需要 Node.js 22 或更新版本，参见 [Automation/README.md](Automation/README.md)。

## 项目来源与许可证

GitStride 起源于 [yogesharc/GitBoard](https://github.com/yogesharc/GitBoard)，现由 [zwyyy456](https://github.com/zwyyy456) 独立维护并进行了大量重构。项目保留原作者的版权声明，并列明当前维护者的版权声明。

本项目采用 [MIT 许可证](LICENSE)，App 安装包内也包含许可证。GitStride 与 GitHub, Inc. 无关联关系。
