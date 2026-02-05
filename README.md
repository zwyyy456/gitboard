# GitBoard

A native macOS menu bar app for GitHub Projects. View your kanban board, filter by status, search issues, and create new ones — all without leaving your workflow.

![GitBoard Menu Bar](https://yogesh.co/gitboard-menubar.webp)

## Features

- **Menu bar access** — click the icon, see your board
- **Status filtering** — switch between Todo, In Progress, Done
- **Search issues** — by title, number, or @assignee
- **Quick create** — type `>` to create issues inline
- **Full kanban window** — drag and drop between columns
- **Status notifications** — know when issues move
- **GitHub CLI auth** — no API tokens needed

![GitBoard Kanban](https://yogesh.co/gitboard-kanban.webp)

## Requirements

- macOS 14 (Sonoma) or later
- [GitHub CLI](https://cli.github.com) installed and authenticated

## Installation

1. Download the latest release from [Releases](https://github.com/yogesharc/GitBoard/releases/latest)
2. Unzip and move GitBoard.app to your Applications folder
3. Make sure you're logged in to GitHub CLI (`gh auth login`)
4. Launch GitBoard from Applications

## Usage

### Menu Bar
Click the GitBoard icon in your menu bar to see your projects. Select a project and browse issues by status.

### Search
Type in the search bar to filter issues by title or number. Use `@username` to filter by assignee.

### Quick Create
Type `>` followed by your issue title to quickly create a new issue. Press Enter to create.

### Kanban View
Click "Open Board" or use the keyboard shortcut to open the full kanban window. Drag and drop issues between columns to change their status.

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
2. Open `GitBoard.xcodeproj` in Xcode
3. Build and run

## License

MIT License. See [LICENSE](LICENSE) for details.

## Author

Built by [Yogesh](https://yogesh.co)
