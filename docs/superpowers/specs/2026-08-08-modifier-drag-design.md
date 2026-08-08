# Modifier-Drag Window Placement — Design

2026-08-08. Approved by Kennith in conversation before writing.

## What it is

Hold **fn** or **⌥⇧** while dragging any real window by its title bar, and
ReSized treats the drag as a placement gesture: a seam highlight shows where
the window would land, and releasing over it places the window there and
reflows the layout. It works exactly like the config window's drag-and-drop,
lifted onto the desktop — for windows already in the grid (re-place) and for
unmanaged windows (add to the grid).

Both modifiers ship active. If fn proves unreliable (third-party keyboards
sometimes don't report it), it gets removed and ⌥⇧ remains.

## Behavior

### Arming

What decides the outcome is the state at **release**:

- Modifier held at mouse-up with a seam highlight showing → the window is
  placed at that seam.
- Modifier held at mouse-up with **no** highlight showing → a managed window
  **leaves the layout** and floats where it was dropped (the others reflow to
  fill, as if it had closed); an unmanaged window just stays put.
- Modifier released before mouse-up → the drag is an ordinary drag. For a
  managed window that means the existing snap-back puts it back in its slot.
- Modifier pressed mid-drag arms the gesture from that moment.

While armed and near a seam, the desktop seam overlay draws the same accent
band used for seam-hover at the insertion point. The user always sees what
release will do before releasing.

### Landing rules

Identical drop model to the config window — every drop resolves to a
`SeamDestination`:

- Between two cells of a column/row, or at either end → new cell, siblings
  make room.
- Between two columns/rows, or at either end of the layout → new column/row.
- Between the panes of a cell's split, or at its ends → joins the split.

Candidate insertion seams are derived from `expectedFrames` (the windows'
real frames), the same source the draggable seam handles use.

One deliberate difference from the config window: there, nearest-seam always
wins because the whole surface is the grid. On the desktop a nearest seam
always exists, which would make float-out impossible — so a **snap radius of
~50pt** applies. Inside it the seam lights up; outside it there is no target.

Multi-monitor: the drop resolves against the active layout of whichever
monitor the cursor is on. No active layout under the cursor → no targets.

## Mechanism

### Event tap

A **listen-only** `CGEventTap` (`.listenOnly` — never intercepts or modifies
events) watches `leftMouseDown` / `leftMouseDragged` / `leftMouseUp` /
`flagsChanged`. It exists only while at least one layout is active — created
alongside the maintenance timer, torn down when the last layout stops. fn is
read from the event flags (`.maskSecondaryFn`); ⌥⇧ is
`.maskAlternate + .maskShift`.

Accessibility permission (already required and held) covers listen-only taps.
If tap creation fails, the feature silently doesn't arm — nothing else in the
app is affected.

### Recognizing a window drag

"Modifier held + mouse moving" is **not** sufficient: ⌥-drag inside an editor
is column text selection and must never read as a placement gesture. The tap
therefore verifies the window under the cursor is actually **moving with**
the cursor:

- At mouse-down, record the topmost ordinary window under the cursor (window
  server query — the same front-to-back walk as the seam occlusion check,
  ignoring ReSized's own chrome) and its frame.
- During armed drags, confirm that window's origin tracks the cursor delta
  (window-server bounds, cheap, no AX). Only then is it a title-bar drag and
  the highlight machinery engages.
- Drags that begin on ReSized's own seam handles are ignored (the overlay
  owns that gesture).

### Snap-back suppression

Today any user drag of a managed window is put straight back by
`handleWindowEvent`'s `isMove` branch. That behavior stays for unmodified
drags — it is the other half of this feature. While a modifier-drag is armed
for a window, that re-apply is suppressed for it so the window flows freely
with the cursor; release then decides (placed / floated out), and an early
modifier release re-enables snap-back for the ordinary-drag ending.

### On release over a seam

- **Managed window:** vacated from its slot and inserted at the destination
  using the same model mutations the config-window seam drop uses, then the
  layout re-applies.
- **Unmanaged window:** resolved to an `ExternalWindow` (same discovery path
  as the config sidebar, matched by `CGWindowID`), inserted at the
  destination, and managed from then on. Observer registration and seam
  refresh already follow every apply.

## Out of scope

- Slimming the config window down to snapshots/presets + monitor selection —
  planned direction once desktop placement proves itself, separate effort.
- Hotkey/modifier customization UI.
- Any change to unmodified-drag snap-back behavior.

## Testing

Live-drag behavior is unverifiable by building; verification is a hand
run-through by Kennith:

1. Re-place a managed window at each destination kind (cell seam, column/row
   seam, layout ends, pane seam).
2. Pull an unmanaged window into the grid.
3. Float a managed window out (release away from any seam) — others reflow.
4. Press the modifier mid-drag (arms late), release the modifier before
   mouse-up (ordinary snap-back).
5. ⌥-drag a text selection inside an editor — nothing arms, selection works.
6. Drag across monitors into another monitor's active layout.
7. fn and ⌥⇧ both arm the gesture on the Mac's own keyboard.
