# GitStride

A native macOS menu bar app for GitHub Projects. View your kanban board, filter by status, search issues, and create new ones — all without leaving your workflow.

![GitStride Menu Bar](https://yogesh.co/gitstride-menubar.webp)

## Features

- **Menu bar access** — click the icon, see your board
- **Status filtering** — switch between Todo, In Progress, Done
- **Search issues** — by title, number, or @assignee
- **Quick create** — type `>` to create issues inline
- **Full kanban window** — drag and drop between columns
- **Status notifications** — know when issues move
- **Native issue planning** — view and edit milestones, parent/sub-issues, and dependencies
- **Pull request automation** — keep closing Issues in matching personal Projects aligned with PR progress
- **GitHub CLI auth** — no API tokens needed

![GitStride Kanban](https://yogesh.co/gitstride-kanban.webp)

## Requirements

- macOS 14 (Sonoma) or later
- [GitHub CLI](https://cli.github.com) installed and authenticated

## Installation

1. Download from [yogesh.co/gitstride](https://yogesh.co/gitstride?utm_source=gitstride_repo)
2. Open the DMG and drag GitStride to your Applications folder
3. Make sure you're logged in to GitHub CLI (`gh auth login`)
4. Launch GitStride from Applications

## Usage

### Menu Bar
Click the GitStride icon in your menu bar to see your projects. Select a project and browse issues by status.

### Search
Type in the search bar to filter issues by title or number. Use `@username` to filter by assignee.

### Quick Create
Type `>` followed by your issue title to quickly create a new issue. Press Enter to create.

### Project Layouts
Click "Open Board" or use the keyboard shortcut to open the project window. Switch between **Board** and **Table** in the toolbar; GitStride remembers the layout for each project locally.

In Board, drag issues between status columns. Table uses aligned issue IDs, spacious rows, and collapsible status groups. Click a title to open details, or use native row selection and the item context menu. Click a column header to sort; when grouped, sorting applies within each status group.

Use **Display Options** to switch between status grouping and an ungrouped table, choose visible fields, or restore **Project Order**. On macOS 14.4 and later, multiple project fields can be shown as independent resizable, sortable columns. macOS 14.0–14.3 supports one selected project field column. Layout, grouping, column settings, and sorting are remembered per project locally.

Search carries across layouts. Hidden board status columns do not filter the table. Both layouts support the existing item context menu and bulk selection actions; layout preferences do not change saved views on GitHub.

### Work Views and Delivery

Use the toolbar’s Filter button for status, assignee, type, and label conditions; More Conditions contains milestone, parent issue, and completion. Display Options separately controls grouping, sorting, and visible fields. The ellipsis menu manages views saved on this Mac. Open in GitHub, My Work, and multiple selection remain direct toolbar actions. Filter by status, issue type, label, milestone, parent issue, or completion. The content area has no permanent view/filter bar. Active conditions appear only while filtering and can be removed individually; Clear All also clears search and reveals hidden board columns. The item count shows the displayed subset of the project's total items.

Saved Views → Save Current View keeps the current filters, Board/Table layout, table sorting and columns, card fields, and hidden board columns. Each saved view has independent display preferences. Filter edits are marked Modified until you choose Update Saved Filters; display preferences are remembered automatically. Search text is temporary. These preferences do not create or modify GitHub saved views.

For a defect view, choose the actual issue type or label your project uses, then save the view with a name such as Bugs. Filtering preserves the current layout and display preferences. Single-select fields use their configured option order when sorting.

Choose Delivery by Milestone or Delivery by Parent Issue to see completed and blocked counts, with All, Unfinished, and Blocked shortcuts. Counts cover only issues present in the current project, including hidden board columns, and ignore other active filters. A milestone remains repository-scoped; a parent can collect children from different repositories. Completion follows GitHub issue state, and blocked counts include only unfinished issues with unresolved dependencies.

Board cards emphasize a two-line title, repository and issue number, assignees, and selected project fields. Unresolved blockers remain visible. Display Options → Show Fields can add milestone, labels, engineering signals, and project fields using their GitHub names and identities. Both layouts keep Filter and Display Options together after the layout switcher.

In a wide workspace, selecting an item opens a right-hand detail pane with Description and Properties. Narrow windows use the existing detail page and Back navigation. You can also open the item in its own window.

### Pull Request Automation

Connect automation once from Settings. Every repository currently available to the GitHub App is included automatically, and closing Issues are updated in every matching personal Project. The selected Project supplies the Status mapping names used across Projects; In Progress and Done are required. For Ready pull requests, choose either `Move to In review` or `Keep in In progress`. The first choice reuses a case-insensitive `In review` match or adds an Orange `In review` only when a matching Project first needs it. The second never changes Project options. Automation never adds Backlog. The hosted Worker runs even when GitStride is closed, and a running app refreshes displayed Project data and Automation connection health when the Worker reports a change.

The Worker temporarily processes GitHub Project Item responses to locate exact item identities. It does not persist or log private Issue content, and the desktop app stores its management token only in Keychain.

### Planning Model

GitStride keeps GitHub's native concepts separate:

- **Project** collects and presents work. Most projects can stay focused on one repository, while a project may still contain issues from several repositories.
- **Status** is the Project workflow state used by the board, such as Todo, In Progress, and Done. Avoid a second `Phase` field when it represents the same workflow.
- **Milestone** is a repository-scoped delivery target. GitStride loads milestones from the issue's repository and stores the selected milestone on the issue itself.
- **Parent/sub-issues and dependencies** express cross-repository delivery structure. Use a parent issue as the cross-repository delivery target, then attach sub-issues and blocking relationships from any repository.
- **Release** can remain an optional Project custom field when a lightweight grouping across repositories is useful. It is not synchronized with repository milestones.

Project field configuration remains managed on GitHub. If an existing `Phase` field duplicates `Status`, remove or repurpose it in the GitHub Project settings rather than maintaining two workflow fields.

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘ R` | Refresh |
| `⌘ ←` | Previous status tab |
| `⌘ →` | Next status tab |
| `>` | Enter quick create mode |
| `Esc` | Exit quick create mode |

## Building from Source

1. Clone the repository
2. Open `GitStride.xcodeproj` in Xcode
3. Build and run

## License

MIT License. See [LICENSE](LICENSE) for details.

## Author

Built by [Yogesh](https://yogesh.co?utm_source=gitstride_repo)
