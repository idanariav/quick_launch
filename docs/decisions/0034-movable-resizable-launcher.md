# 0034. A movable, resizable launcher

Status: Accepted
Date: 2026-11-05

## Context
The user wants to drag the launcher somewhere else and resize it. It was a fixed 680×500 borderless panel, opened centered and a fifth of the way down the screen with the pointer. The SwiftUI card inside hugs its content: an empty search is only the field, and lists grew up to `Theme.Size.maxContent` (400) and then scrolled. The rest of the window is transparent, and clicks there fall through to the app behind.

Two questions came up, and the user answered both:
- **What's remembered?** Size and position, across restarts, with a menu item to go back to the default.
- **What does resizing change?** The width, and how tall the card can grow before its list or output scrolls. Short content still shrinks the card.

## Decision
- **The window's frame is the card's largest frame.** The card is as wide as the window. Lists and output take what's left of the window's height after the card's fixed parts (`.frame(maxHeight:)` in place of a fixed maximum), so the card hugs short content and scrolls long content within the window. `Theme.Size.maxContent` is gone. The hosting view's `sizingOptions` are empty, so the content never sizes the window.
- **Moving:** dragging the card's bars (the search bar, a form's or output's header, and the action bar) moves the window, including when the drag starts on their labels and icons. This is a SwiftUI `DragGesture` (`movesWindow()`), not an AppKit view behind the bars. A view behind never gets the clicks that land on a bar's labels, and a gesture does, while buttons and text fields on the bars still take their own clicks. Rows aren't drag areas: a click on one runs it.
- **Resizing:** AppKit grips (`ResizeHandles`) over the card's left and right sides, bottom, and bottom corners, with resize cursors. The top edge stays put. The bottom follows the pointer, not the drag's distance: the card's bottom may sit above the window's when the content is short, and dragging it then sets the height to where the pointer is. Minimum 480×160; at most the screen's visible frame.
- **Remembered as `LauncherPlacement`** in `launcher-window.json` (app state, `FileStateStore`): the size, plus the frame's top-center as fractions of the screen's visible frame. So it opens at the same spot on whichever screen has the pointer, kept within that screen. It's saved when the launcher hides, and only if the user moved or resized it while it was open.
- **Reset:** the menu's "Reset Launcher Size & Position" saves the default placement (680×500, centered, a fifth down) and applies it at once if the launcher is open.

## Consequences
- The launcher stays one fixed-size window while it's open. It doesn't grow or shrink with its content, so nothing jumps while you type.
- There's no top-edge grip, because the top is where the card sits. To make the card taller upwards, move it, then drag its bottom.
- The grips cover a few points at the card's edges, so a click right on a row's edge resizes instead of running it.
- `placement.frame(in:minSize:)` is pure and tested in the app's hosted tests (`LauncherPlacementTests`).
