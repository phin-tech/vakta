# Vakta

A native macOS terminal app for driving terminal multiplexers (herdr, tmux, zellij) and the coding agents running in them.

## Language

### Multiplexers

**Session**:
One multiplexer session hosted in Vakta, shown as one terminal.
_Avoid_: Window, tab

**Workspace**:
A grouping inside a Session: a herdr workspace, tmux window, or zellij tab.
_Avoid_: Project, repo

### Extensions

**Extension**:
A separately installed program that adds functionality to Vakta without being compiled into it.
_Avoid_: Plugin (reserved for herdr plugins), add-on, integration

**Extension Context**:
A Session's location as given to an Extension: its Session Key, its active pane's working directory, that directory's git repository root and branch (if any), its Workspace, and whether it is the focused Session. An Extension receives one per Session.

**Session Key**:
The identity of a Session that stays the same across Vakta restarts: its multiplexer backend plus the multiplexer's session name.
_Avoid_: Session id (changes every launch)
_Avoid_: Workspace, scope, root

**Linked Extension**:
An Extension registered with Vakta by pointing at a local directory holding its manifest.
_Avoid_: Installed extension

**Trust**:
The user's explicit approval for a Linked Extension to run. It is lost when what was approved changes.
_Avoid_: Permission, consent

**Contribution**:
Something an Extension puts into Vakta's interface: a Panel View, a Status Item, or a Session Badge.

**Panel View**:
An Extension's view shown as a mode of the right-hand panel, alongside Files and Changes.
_Avoid_: Tab, sidebar

**Status Item**:
An Extension's segment in the status bar; it may open a Popover.
_Avoid_: Widget, indicator

**Session Badge**:
A short label an Extension attaches to one Session's row in the sidebar; it may open a Popover.
_Avoid_: Tag (collides with git and Kata labels), annotation

**Popover**:
A transient list or detail shown from a Status Item or Session Badge, drawn from a View Document.

**View Document**:
The data an Extension sends to describe what a Panel View or Popover shows; Vakta draws it natively.
_Avoid_: UI, template

**Callback**:
A request Vakta sends to an Extension when the user activates a button in a View Document, carrying the button's payload. A View Document never names a program to run.
_Avoid_: Command, action handler

**Effect**:
Something an Extension asks Vakta to do in reply to a Callback, such as refreshing a view or opening a Session. Vakta carries it out.

**herdr plugin**:
An add-on to herdr, declared in `herdr-plugin.toml`; not a Vakta concept.
_Avoid_: Plugin (unqualified)
