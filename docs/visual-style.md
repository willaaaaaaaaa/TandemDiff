# Visual style

The [TandemDiff icon](../assets/TandemDiff.png) pairs two teal tracks on porcelain. The orange bend marks their point of divergence. The comparison views reserve most of their space for file names and text. Home uses paired folders and paired pages to distinguish the two launchers.

## Appearance

Use the shared `TandemDiffStyle` tokens for branded surfaces. AppKit resolves their values for the current appearance. [Style tokens and session artwork](../Sources/TandemDiff/SessionArtwork.swift)

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `canvas` | `#F3F8F6` | `#172726` | Home background and comparison chrome |
| `surface` | `#FFFFFF` | `#213533` | Launcher cards and character detail |
| `border` | `#CEDDD8` | `#4B645F` | Outlines between adjacent surfaces |
| `accent` | `#175653` | `#7ABCB1` | Active navigation, launcher hover, and drop feedback |
| `marker` | `#C45100` | `#FFAD65` | Unsaved text and the active change pointer |

Use native label colors, system type, and visible keyboard focus. Reserve monospaced type for file content and values that align by character. Pair status colors with symbols and readable labels. Give active drop targets an outline that reads against the card and the surrounding canvas.

## Session artwork and controls

Use `SessionArtwork(tool:)` for launcher illustrations. Sea-glass folders and porcelain pages use teal ink. An orange index mark and an orange bracket identify the changing detail. Keep the folder and page illustrations at the same scale and preserve their aspect ratio. Use the compact variant for session lists and tabs. Use SF Symbols for toolbar operations where the symbol matches the action. Name the control for accessibility and hide its decorative artwork from the accessibility tree. [Home launchers](../Sources/TandemDiff/HomeView.swift)

Use teal for navigation, file access, and transfer actions. Use muted blue-green for document and rule tools. Reserve red for differences and Stop. Toolbar captions use the native label color and the accent color for a selected command. A tinted background and stronger caption weight also mark selection. Disabled commands use the native disabled label color. [Comparison controls](../Sources/TandemDiff/ComparisonControls.swift)

## Folder differences

Default and one-sided file names use neutral ink. When paired files have different bytes and modification times, the newer file name uses red and the older one uses gray. Equal modification times leave both names red. The status column identifies the row state independently of the file name colors. [Folder comparison colors](../Sources/TandemDiff/FolderComparisonColor.swift)

## Text differences

Tint changed rows and use stronger red ink for changed characters. Unchanged characters keep their normal color. In a one-sided row, hatch the gap in the other pane. Minor changes use a neutral tint. Line-ending changes use a blue tint. The gutter uses distinct symbols as a second cue. [Text palette](../Sources/TandemDiff/TextDiffPalette.swift) · [Native editor drawing](../Sources/TandemDiff/TextNativeView.swift)

Keep both tracks of the overview in the same aligned document space. Mark the sides that contain text, outline the visible region, and keep marker positions stable when rows fold. [Difference overview](../Sources/TandemDiff/TextDifferenceMap.swift)
