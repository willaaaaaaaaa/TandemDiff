# Product and technical design

TandemDiff compares two local folders or two local text files on macOS. A folder comparison reports the bytes on disk. A text comparison aligns two editable buffers and saves each side independently. A folder copy writes whole-file bytes in a chosen direction after you review the destination paths. See [compatibility and releases](compatibility.md) for platform coverage and [acceptance checks](acceptance.md) for reproducible examples.

## Inputs and scope

TandemDiff accepts regular text files and directories on local APFS, including case-sensitive APFS. It rejects other filesystems, network mounts, and recognized cloud-managed locations. It treats file packages, archives, Finder aliases, symlinks, and special filesystem entries as opaque. The scanner does not follow links or descend across a mount within a comparison root. Use an ordinary local copy of a cloud-managed item. The same local access policy applies to open, restore, and write paths.

The text policy accepts empty files, strict UTF-8 with or without a byte order mark (BOM), and strict UTF-16LE or UTF-16BE with a matching BOM. Known binary signatures and opaque extensions such as `.zip` or `.png` take precedence. Other filenames, including extensionless files, pass through the same decoder. The decoder rejects unsupported BOMs, invalid code units, NUL characters, and C0 controls apart from tab, LF, and CR. Valid UTF-16 code units can contain zero bytes. These checks determine which files are eligible for comparison and writing. [Local access policy](../Sources/TandemDiffCore/FolderAccess.swift) · [Text eligibility](../Sources/TandemDiffCore/FolderText.swift)

The comparison scope is two-way folder and text comparison. Folder writes are limited to copying eligible text files. Binary comparisons, archive contents, remote connections, directory mirroring, deletion, renaming, patches, and three-way merges are outside this scope.

## Home and sessions

Open **Folder Compare** or **Text Compare** from Home. Drop one item to fill one side or drop a matching pair and confirm its order. You can also start with two blank text panes and type or paste into either one. A mismatched drop identifies the input type the launcher accepts.

Home groups automatic comparisons by date and named sessions by session folder. Search includes names, notes, folders, and saved paths. Choose a record to inspect its paths, then double-click or press Return to open it. Opening an automatic record whose live tab has switched paths reopens its recorded pair. Named sessions can be organized, edited, copied, or locked. Removing a session record affects only the session library.

**Save Session** records the current paths and settings. For a folder comparison, it also records the expansion and selection. **Save Session As** makes an independent named record. Later navigation stays in the tab until the next save. Saved records store paths, preferences, and session metadata locally. Unsaved text lives in the editor. Reopening a saved comparison revalidates the inputs. A missing or replaced root requires a new selection. Defaults edited on Home apply to future sessions, and saved comparisons retain their settings. [Workspace and session storage](../Sources/TandemDiff/Workspace.swift)

Both comparisons offer **All**, **Differences**, and **Same** with Command-1, Command-2, and Command-3. Command-Option-Up Arrow and Down Arrow move between differences. The Comparison menu names the destination in directional commands, and **Swap Sides** changes which inputs the commands address. The interface has English and Simplified Chinese labels. [Comparison commands](../Sources/TandemDiff/TandemDiffApp.swift)

## Folder comparison

Folder Compare aligns rows using exact relative path components. The left and right columns show each side's file information, with a shared status for the pair. Sort moves the row as a pair. The folder view offers tree modes, a relative path list, filename search, and selected-item **Compare Contents**. Refresh reevaluates the roots. **Stop** retains completed results and leaves unfinished work incomplete. Results from a superseded scan are discarded.

| Observation | Result |
| --- | --- |
| Both regular files pass the text policy | **Identical** when their original bytes match through EOF. **Different** when their lengths or bytes differ. |
| A paired file is opaque or fails decoding | **Not compared**, with a reason. Different lengths alone do not make an opaque pair **Different**. |
| An item is present on one side and absent on the other | **Left only** or **Right only**. An opaque item keeps its presence status and carries an eligibility reason. |
| Paired entries have incompatible kinds | **Type conflict**. The pair cannot be copied over itself. |
| Enumeration or a read fails, a path changes, or scanning stops | The affected row shows an error or incomplete coverage. Failed enumeration does not establish absence. |

Both text streams must pass complete eligibility checks before the scanner reports a final byte result. Size, modification time, and digests cannot establish equality. The scan compares streams without loading either file into the text editor. The folder summary includes skipped and unresolved descendants. An empty enumerated directory can match another empty directory. When name rules exclude items, the summary describes the included scope. A pruned or unreadable subtree counts once because its descendant count is unknown. [Folder scanner](../Sources/TandemDiffCore/FolderScanner.swift)

A bare glob matches a basename at any depth. A pattern containing an internal slash is relative to the root. A single `*` or `?` stays in one component, and `**` can cross separators. A trailing slash limits a pattern to directories. The **Name Filters** editor has separate include and exclude lists for files and folders. Enter one pattern per line. Entering `agents` under **Exclude folders** prunes both `agents/` and `plugins/agents/`. Files named `agents` elsewhere stay in scope. The toolbar also accepts `-agents/` in the quick filter. Matches are case-sensitive, and excludes take precedence. A directory include admits its matching subtree, and file includes narrow its contents. Excluding a directory prunes its subtree. Status filters change the visible rows independently of name rules, so their displayed count can differ from the totals for the included scope. **Show excluded items** reveals protected items for inspection. Revealing them does not make them copyable or editable. [Name rules](../Sources/TandemDiffCore/FolderRules.swift) · [Folder session](../Sources/TandemDiff/FolderSession.swift)

Open a paired text row to compare its two files. A supported unilateral file opens opposite a virtual empty side. An existing empty file stays bound to its actual path. The folder comparison continues to describe the files on disk while a child editor has unsaved changes. Saving or copying requests a refresh of affected comparisons. Returning from the editor preserves the available folder selection. [Workspace navigation](../Sources/TandemDiff/Workspace.swift)

Command-click selects each item on its own side. With one supported text file selected on each side, **Compare Selected Files** opens the two selected paths in one child comparison. Returning to the folder view restores the selection and scroll position. With one eligible folder selected on each side, **Set as Base Folders on Both Sides** changes both roots together. **Back** restores the previous roots in one step. Both commands preserve the left and right sides. The folder table continues to match paths relative to its roots.

## Text comparison

Text Compare aligns logical lines by exact content using one deterministic bounded alignment. It preserves each line's CRLF, LF, or CR terminator and retains Unicode scalar differences. Inline highlights follow grapheme boundaries. The overview and detail view use the same alignment, including when unchanged runs fold. The format strip reports encoding and BOM differences. The rows show line-ending and final-newline differences.

**Context** surrounds changes with a configurable number of lines. Case folding and ignoring spaces and tabs can classify differences as minor. Hiding minor changes affects the text view and navigation. It leaves both buffers and the folder byte result intact. You can reveal hidden minor changes from the text view. [Text alignment](../Sources/TandemDiffCore/TextAlignment.swift) · [Text view](../Sources/TandemDiff/TextSessionView.swift)

Applying a change or copying selected lines edits only the destination buffer. A transfer copies source line terminators and retains the destination encoding and BOM. At a join, it adds the destination's preferred separator when needed to keep the retained lines distinct. A transfer that reaches the end without a retained suffix preserves the copied final-newline state. Alignment gaps contribute no source text. You can undo the transfer as one edit. Literal find and replace use the active buffer, and **Replace All** is one undoable edit. During marked-text composition, realignment waits for the input method to commit or cancel. [Text buffer](../Sources/TandemDiffCore/TextBuffer.swift) · [Text session](../Sources/TandemDiff/TextSessionModel.swift)

The editor accepts up to 16 MiB of encoded bytes including the BOM and 200,000 logical lines per side. Edits that exceed either limit are refused as a unit. Earlier edits and undo history stay available. Folder Compare can stream eligible text that exceeds the editor limits. The alignment work budget and character-detail guard can stop comparison within those limits. When alignment fails, you can still edit and save, and commands that depend on the alignment are unavailable. [Editor limits](../Sources/TandemDiffCore/TextBuffer.swift) · [Alignment limits](../Sources/TandemDiffCore/TextAlignment.swift)

## Writes and recovery

**Save** writes the named pane. A clean save preserves its bytes. Saving a bound virtual side creates its missing file explicitly, even if the result is intentionally empty. An unbound pane asks for a path. **Save As** accepts the supported encodings and checks both the output bytes and filename against the open policy. Saving to another existing file requires a separate baseline and confirmation. The pane switches to the new path after success. A failed save keeps the buffer available. Closing, replacing, or reloading a dirty pane prompts for a decision. Swapping sides carries each buffer and its undo history with its path.

The folder write guard protects inherited child panes as well as folder copy. Revealed excluded items remain protected. A per-pane lock blocks editing, incoming changes, and writes for that pane. The workspace tracks file identity to prevent two independent writable bindings to the same file and reserves active copy paths against conflicting edits. [Workspace bindings](../Sources/TandemDiff/Workspace.swift) · [Text save and locks](../Sources/TandemDiff/TextSessionModel.swift)

A folder copy preview names the source and destination and identifies creates, replacements, unchanged files, skips, and blocks. A selected folder contributes its eligible descendants in scope, including collapsed descendants. Excluded and status-hidden entries stay outside the approved set. Copy creates missing destination directories only where an approved file needs them. Copying an empty directory alone creates nothing. The app rechecks the plan against the selected roots and file versions before writing. A path collision, unreadable or opaque input, stale version, overlapping roots, hard-linked or immutable target, protected metadata, or unresolved dirty binding can block a write. [Folder copy](../Sources/TandemDiff/FolderSession.swift)

When Command-click selects individual items, a directional copy takes its sources from the selected items on the source side. Each destination uses the same relative path on the opposite side.

The writer stages and verifies each file in its destination directory. An overwrite preserves the destination owner, group, mode, flags, ACL, and extended attributes or fails before replacement. A new file gets normal creation permissions. Folder copy transfers file bytes and refuses source metadata it cannot preserve, including resource forks. The writer atomically installs the staged file and uses an exclusive install for an absent target. File coordination reduces races with participating apps. An external writer that bypasses coordination can still change an item between the final check and installation. If the post-install check detects a change, inspect the destination before retrying. [File operations](../Sources/TandemDiffCore/WriteOperations.swift) · [Write access and metadata](../Sources/TandemDiffCore/WriteAccess.swift)

Each file commits independently. Stopping a batch prevents further commits after the current item reaches a cancellation point. Completed items remain. Retry builds a new preview from the current disk state.

## Code organization

[TandemDiffCore](../Sources/TandemDiffCore) owns local access, scanning, text codecs and alignment, and file operations. It keeps those decisions independent of AppKit. [TandemDiff](../Sources/TandemDiff) owns session state and presentation. SwiftUI hosts the workspace, comparison controls, and folder table. Native AppKit text editors map visible rows and selections back to the editable buffers. The [visual style](visual-style.md) describes shared appearance and controls.
