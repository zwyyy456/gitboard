# GitStride · 迹程

A native macOS app for GitHub Projects. Keep your board in the menu bar, organize work in Board or Table, and edit issues without switching to the browser.

[Website & download](https://gitstride.zwyyy456.tech) · [GitHub Releases](https://github.com/zwyyy456/GitStride/releases) · [User guide](docs/usage.md)

## Features

- **Menu bar and workspace** — browse projects quickly or open a full project window.
- **Board and Table** — move items between statuses, sort fields, and save local work views.
- **My Work** — follow projects and filter work across them.
- **Issue editing** — create issues and manage assignees, labels, milestones, parent/sub-issues, and dependencies.
- **Monitoring** — follow project changes with configurable refresh intervals and notifications.
- **Optional PR automation** — update closing Issues in matching personal Projects as pull requests progress, even when GitStride is closed.
- **GitHub login** — sign in from the app, or reuse an existing `gh` login in the GitHub Release build.

## Requirements

- macOS 14 (Sonoma) or later.
- A GitHub.com account. Desktop browsing supports personal and organization Projects; PR automation currently targets personal Projects. GitHub Enterprise Server is not a supported configuration.

## Install and connect

1. Download GitStride from [gitstride.zwyyy456.tech](https://gitstride.zwyyy456.tech) or [GitHub Releases](https://github.com/zwyyy456/GitStride/releases).
2. Open the DMG and drag GitStride into Applications.
3. On first launch, choose **Open GitHub Settings** in the welcome window, then **Log In to GitHub**. You can also open **Settings → GitHub → Account** directly.
4. Choose **Copy Code and Open GitHub**, paste the code into GitHub’s Device activation page, and approve access.
5. Choose your personal account or organization and select a Project.

The welcome window appears once for new installations. Choose **Set Up Later** to skip it, or reopen it at any time from **Help → Welcome to GitStride…**. Existing account setups continue directly to the workspace. Pull request automation is optional and can be configured later.

Desktop OAuth requests `repo project read:org offline_access`. GitHub’s `repo` scope includes reading and writing repository code, including private repositories; it is broader than board access. Login and refresh credentials stay in macOS Keychain.

The GitHub Release build also supports **Settings → GitHub → Connection method → GitHub CLI** when disconnected. Install [GitHub CLI](https://cli.github.com), run `gh auth login --hostname github.com`, and grant Projects access with `gh auth refresh --hostname github.com --scopes project,read:org`. GitStride keeps the selected CLI account until you reconnect. Disconnecting GitStride leaves your terminal login intact. Existing installations with a saved owner keep CLI mode on upgrade; new installations default to OAuth.

The `GitStrideAppStore` build provides OAuth login only. This build target does not imply the app is already published in the Mac App Store.

Your GitHub permissions determine what you can view and edit. Organization policies and SSO may require additional authorization. PR automation has its own optional authorization flow; it is not required for desktop browsing or editing.

## Everyday use

Click the menu bar icon for quick access, or use the main window for Board, Table, My Work, and item details. Search by title, issue number, or `@assignee`; type `>` followed by a title for quick creation. Use Filter and Display Options to organize each Project.

| Shortcut | Action |
| --- | --- |
| `⌘ R` | Refresh |
| `⌘ K` | Open command palette |
| `⌘ ←` / `⌘ →` | Previous / next status tab |
| `>` | Enter quick create mode |
| `Esc` | Exit quick create mode |

See the [user guide](docs/usage.md) for saved views, table columns, delivery summaries, and planning workflows. Saved views and display preferences stay on this Mac and do not modify GitHub's saved views.

## Optional pull request automation

Open **Settings → GitHub → Pull Request Automation → Set Up Automation** to connect. The hosted service is operated by [zwyyy456](https://github.com/zwyyy456) on Cloudflare Workers. It continues running while GitStride is closed.

The setup uses two separate GitHub authorizations:

- A **GitHub App** reads metadata, Issues, and pull requests in the repositories you allow it to access.
- An **OAuth App** requests `project offline_access` to update your personal Projects and renew authorization. This is separate from your desktop GitHub login.

Choose a personal Project as the Status mapping template, with In Progress and Done options. Automation applies the matching field and option names across compatible personal Projects containing the closing Issue; the template is not the only Project it can update. Every repository currently available to the GitHub App is included.

Open Draft PRs keep an Issue In Progress. Ready PRs follow your selected review policy, and a nonempty set of closing PRs must all be merged before the Issue moves to Done. Updates wait at least three seconds before reloading current PR state. With **Move to In review**, automation can add that Status option to a matching Project if needed. See the [full behavior](docs/usage.md#pull-request-automation).

Pause, resume, reauthorize, or delete the connection under **Settings → GitHub → Pull Request Automation**. Deleting the connection stops future automation processing; it does not undo earlier changes to GitHub Project statuses. To revoke GitHub access completely, also remove the OAuth authorization under [Authorized OAuth Apps](https://github.com/settings/applications) and uninstall the GitHub App under [Installed GitHub Apps](https://github.com/settings/installations).

For deployment on your own Cloudflare account, see [Automation setup and deployment](Automation/README.md). Source builds can use a different service origin or disable Automation with an empty `GITSTRIDE_AUTOMATION_BASE_URL` build setting.

## Data and privacy

**Desktop app.** GitStride sends interactive requests directly to GitHub. OAuth access/refresh tokens are stored in Keychain; CLI credentials are read into memory and are not copied into GitStride’s persistent storage. Display preferences and a rebuildable project snapshot are stored on your Mac. The snapshot can include private project and issue information and is not encrypted. It is restored only after the account identity matches, and deleted when you disconnect or change connections. The Release build’s cache is at `~/Library/Application Support/GitStride/project-cache-v2.json`; the sandboxed build uses its app container. Disconnecting removes GitStride’s local OAuth credentials; to revoke the grant at GitHub, use [Authorized OAuth Apps](https://github.com/settings/applications). Desktop and automation use separate OAuth Apps.

**Automation service.** When you enable Automation, the Worker processes GitHub webhooks and API responses to locate and update matching Project items. It stores account and installation identifiers, repository identities, your mapping and connection settings, encrypted OAuth credentials, and delivery status records. It does not persist or log private Issue titles/bodies or complete webhook payloads. Desktop management tokens stay in macOS Keychain; the service stores their hashes.

Terminal delivery records are eligible for cleanup after 30 days. Expired setup sessions are reclaimed by daily maintenance after one day past expiry. Deleting an automation removes unused credentials and installation/account records; records still referenced by an active setup session remain until that reference is cleared. These are application database retention rules; Cloudflare infrastructure logs and backups have their own retention. See the [Worker documentation](Automation/README.md) for implementation details.

**Updates.** The GitHub Release build uses Sparkle to check the update feed in [this repository](https://github.com/zwyyy456/GitStride/blob/main/appcast.xml) and downloads releases from GitHub. Automatic checks can be controlled in Settings. The App Store build uses store updates and does not include Sparkle. GitHub and Cloudflare receive network request metadata when their services are used.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| GitHub CLI Required | Install `gh` and confirm `gh --version` works. Homebrew's standard Apple Silicon and Intel paths are recognized. |
| Sign in to GitHub | Open Settings → GitHub and reconnect using your chosen method. |
| Project Access Required | Reauthorize OAuth in Settings, or grant the CLI login the `project` scope. |
| Organization or private Project unavailable | Confirm access in GitHub, the connected account, and any organization SSO or application restrictions. |
| Cached data or refresh failure | Check the connection and authentication, then refresh. Cached snapshots may be older than GitHub. |
| Automation needs authorization | Reauthorize the connection in Settings; desktop authentication does not renew Worker OAuth access. |

Report reproducible problems in [GitHub Issues](https://github.com/zwyyy456/GitStride/issues), including the app version, macOS version, and reproduction steps. Redact tokens and private repository or issue content from diagnostics and screenshots.

## Building from source

The current development toolchain is Xcode 26.5. macOS 14 is the app's deployment target, not the required version of Xcode.

```bash
git clone https://github.com/zwyyy456/GitStride.git gitstride
cd gitstride
xcodebuild -project GitStride.xcodeproj -scheme GitStride \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

For running from Xcode, open `GitStride.xcodeproj`, select the GitStride target, and choose your own development team under Signing & Capabilities. Sparkle uses hardened-runtime library validation, so an unsigned compile check does not establish that the app can launch locally.

The `GITSTRIDE_OAUTH_CLIENT_ID` build setting is a public desktop OAuth App ID. For your own distribution, register an OAuth App, enable Device Flow, and set its Client ID on both app targets. Do not embed a Client Secret. The App Store scheme is `GitStrideAppStore`; select the appropriate signing setup for that distribution.

See [validation commands](docs-index.md#5-常用验证命令), [architecture](architecture.md), and the [release guide](docs/releasing.md). Worker development separately requires Node.js 22 or later; instructions are in [Automation/README.md](Automation/README.md).

## Origin and license

GitStride originated from [yogesharc/GitStride](https://github.com/yogesharc/GitStride) and is now independently maintained and substantially reworked by [zwyyy456](https://github.com/zwyyy456). The original copyright notice is preserved alongside the current maintainer's notice.

Released under the [MIT License](LICENSE). The license is also included in the app bundle. GitStride is not affiliated with GitHub, Inc.
