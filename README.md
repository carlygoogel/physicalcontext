# Physical Context

**Granola for physical design.** A macOS menu bar app that silently tracks your CAD sessions, captures design decisions, flags spec deviations, and generates structured summaries — all without interrupting your flow.

---

## Overview

Physical Context detects when you open a supported CAD or EDA tool, starts a note session automatically, and gives you a lightweight floating panel to log justifications as you work. When you close the app (or end manually), you get a structured session summary with flagged deviations.

### Supported Applications
- **Altium Designer** (`com.altium.AltiumDesigner`)
- **KiCad** (`org.kicad.kicad`)
- **EAGLE** (`com.autodesk.eagle`)
- **Fusion 360** (`com.autodesk.mas.fusion360`)
- **SolidWorks** (`com.dassault-systemes.solidworks`)
- **VS Code** (`com.microsoft.VSCode`)
- **Xcode** (`com.apple.dt.Xcode`)

---

## Setup

### Requirements
- macOS 13.0+
- Xcode 15+
- Swift 5.9+

### Build & Run

1. Open `PhysicalContext.xcodeproj` in Xcode
2. Select your development team in **Signing & Capabilities**
3. Set bundle identifier to something unique (e.g. `com.yourname.physicalcontext`)
4. Run with **⌘R**

The app will appear in your menu bar (CPU icon) and hide from the Dock.

### First Run
- Grant **Accessibility** access in System Settings → Privacy & Security → Accessibility
- Optionally grant **Automation** access if you want deeper integration

---

## Architecture

```
PhysicalContext/
├── PhysicalContextApp.swift      # @main — no Dock window
├── AppDelegate.swift             # Menu bar, panel + window management
├── Theme.swift                   # Design tokens, color helpers, modifiers
│
├── Models/
│   └── Models.swift              # Session, Note, Change, Deviation, CADApp
│
├── Managers/
│   ├── AppMonitor.swift          # NSWorkspace notifications → CAD detection
│   ├── SessionManager.swift      # ObservableObject — central state
│   └── StorageManager.swift      # JSON persistence (~/.../PhysicalContext/)
│
├── Views/
│   ├── SessionPromptView.swift   # "Start session?" popup on CAD open
│   ├── SessionPanelView.swift    # Floating side panel (NSPanel)
│   ├── MenuBarPopoverView.swift  # Popover from menu bar icon
│   ├── SessionSummaryView.swift  # Post-session review with deviations
│   ├── AllSessionsView.swift     # Full history browser (HSplitView)
│   └── SettingsView.swift        # Preferences window
│
└── Resources/
    └── Info.plist
```

---

## Key UX Flows

### 1. Session Start
- Open KiCad / Altium / etc.
- Physical Context detects it via `NSWorkspace.didActivateApplicationNotification`
- Floating prompt: **"Start Session?"** / **"Not now"**
- On confirm: side panel slides in, timer starts

### 2. During Session
- **Side panel** shows live timeline of saves + notes
- Press the **⚠️ button** to flag a deviation from spec
- Press **+** to add a free-form note
- **⌘⇧N** globally to open/focus the panel
- Collapse to a slim header with one click

### 3. Session End
- Click **End** in the panel or menu bar popover
- Session summary window opens:
  - "What you did" bullets (from notes + changes)
  - Files modified
  - Deviations requiring justification (with checkbox + text field)
  - Additional notes field
  - **Save Summary** → archived to disk

### 4. Menu Bar Popover
- Click the CPU icon in the menu bar
- See active session stats + End/Show Panel buttons
- Recent sessions list with deviation badges
- Jump to All Sessions or Settings

---

## Extending

### Add More CAD Apps
Edit `knownCADApps` in `Models/Models.swift`:

```swift
CADApp(name: "Your App", bundleID: "com.yourapp.id", sfSymbol: "wrench.and.screwdriver")
```

### Add Change Tracking
In `SessionManager`, call `addChange()` after detecting events:

```swift
sessionManager.addChange(
    "Route updated on layer Top",
    file: "main.PcbDoc",
    type: .routeChange
)
```

### Git Commit Hook
Add a `.git/hooks/prepare-commit-msg` script that calls a helper to prompt Physical Context for a summary (use `open physicalcontext://commit` with a custom URL scheme registered in Info.plist).

---

## Data Storage

Sessions are stored as JSON at:
```
~/Library/Application Support/PhysicalContext/sessions.json
```

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘⇧N | Open / focus session panel |
| ⌘S (in CAD app) | Automatically logs a save event |

---

## Design Language

- **Background**: `#09090B` near-black
- **Surface**: `#111113`
- **Accent**: `#818CF8` indigo-400
- **Monospace**: SF Mono throughout for technical data
- All windows use `.darkAqua` appearance
- Floating panel is `NSPanel` with `.nonactivatingPanel` — never steals focus from your CAD tool

---

## License

MIT — use freely, extend liberally.
