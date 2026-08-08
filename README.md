# ReSized

**Window management, perfected.**

ReSized is a lightweight macOS window manager that lets you define custom layouts for each monitor and snap windows into place with keyboard shortcuts. Perfect for multi-monitor setups where you need consistent, repeatable window arrangements.

**Stop resizing windows one at a time.** With ReSized, you arrange all your windows together in one layout, then apply it instantly. No more dragging corners, no more pixel-perfect positioning — just define your layout once and let ReSized handle the rest.

## Features

- **Custom Layouts** — Design your own window arrangements with columns, rows, and flexible proportions
- **Multi-Monitor Support** — Create different layouts for each display in your setup
- **Presets** — Save up to 9 layouts per monitor and switch between them instantly
- **Workspace Presets** — Save and restore layouts across all monitors at once
- **Global Hotkeys** — Control everything without leaving your keyboard
- **Menu Bar App** — Runs quietly in your menu bar, always ready when you need it
- **7-Day Free Trial** — Try it free before you buy

## Requirements

- macOS 13.0 (Ventura) or later
- Accessibility permissions (required to manage windows)

## Installation

1. Download ReSized
2. Move to Applications folder
3. Launch and grant Accessibility permissions when prompted

## How to Use

### Setting Up a Layout

1. Click the ReSized icon in your menu bar and select **Show Config**
2. Select a monitor tab at the top
3. Your current windows will appear in the layout editor
4. Drag dividers to resize columns/rows
5. Click **Start** to begin managing windows

### Saving & Loading Presets

**Save a preset:**
1. Arrange your layout, then click the save icon in the toolbar and choose **Save Layout...**
2. Give it a name
3. Choose the scope — **Current Monitor Only** or **Full Workspace (All Monitors)**
4. Optionally assign it to a hotkey slot (1-9) with the **Assign to hotkey** picker

**Load a preset:**
- Pick it from the same menu, or use its keyboard shortcut if you assigned a slot

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌃⌥R` | Toggle window management on/off |
| `⌃⌥1-9` | Load preset 1-9 for the monitor under the pointer |
| `⌃⌥⇧1-9` | Load workspace preset 1-9 (all monitors) |

These deliberately avoid `⌘⇧`+number, which collides with the macOS screenshot
shortcuts (`⌘⇧3`/`⌘⇧4`/`⌘⇧5`). If another app has already claimed one of these,
Settings will list it as unregistered.

### Menu Bar

- **Start/Stop Managing** — Toggle window management
- **Show Config** — Open the layout editor
- **Settings** — License and preferences
- **Quit** — Exit ReSized

## Tips

- **Move your pointer** onto a monitor before pressing `⌃⌥1-9` — the preset loads for the display the cursor is on
- Use **workspace presets** (`⌃⌥⇧1-9`) to restore your entire multi-monitor setup at once
- Layouts automatically adjust when you connect/disconnect monitors

## License

ReSized is $5 for a lifetime license. Includes a 7-day free trial.

[Buy Now](https://resized.lemonsqueezy.com/buy/748344)

---

Made by [Sound Solutions](https://sound-solutions.github.io/sound-solutions-website)
