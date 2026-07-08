---
type: architecture_guideline
title: "Sixel Grid Allocation & Registry Model"
description: "Architectural design and migration plan to transition szn from coordinate-based sixel overlays to a cell-allocated grid registry model."
timestamp: 2026-07-08T04:02:37Z
---

# Design Document: Sixel Grid Allocation & Registry Model

This document outlines the architectural design and migration plan to transition `szn` from coordinate-based sixel overlays to a cell-allocated grid registry model.

## 1. Problem Statement
The current coordinate-based sixel model (`sixel_images` coordinate list) has the following limitations:
- **Scrolling Sync Issues**: Scrolling text requires manual coordinate adjustments of sixel anchor coordinates, which can fall out of sync with terminal-level scrolling.
- **Copy-Mode Persistence**: Since graphics are not stored in the grid cells, entering copy-mode or scrolling history renders the terminal graphics static, or causes them to vanish completely when the screen is redrawn from history.
- **Viewport Clipping**: Oversized images (taller than the viewport) cannot scroll off-screen line-by-line; they remain static or disappear entirely when their top anchor row scrolls past the top of the viewport.

---

## 2. Proposed Architecture

### A. Cell-Level Metadata Mapping
Instead of storing raw sixel data in cells, the 128-bit `Cell` structure will hold a lightweight reference to an image in a screen-level registry.

When a cell has the attribute `attr.sixel = true`, its standard fields are remapped:
- `cell.char` (21 bits): Unique Sixel Image ID.
- `cell.comb1` (13 bits): Horizontal cell offset (`dx`) from the top-left of the image.
- `cell.comb2` (13 bits): Vertical cell offset (`dy`) from the top-left of the image.

This allows any cell to dynamically specify:
- Which image it belongs to.
- Exactly where the top-left anchor of the image is physically located relative to that cell: `(x - dx, y - dy)`.

### B. Bounded Sixel Registry (Ring Buffer)
To avoid complex reference counting hooks during `GridLine` allocation and pruning, we use a fixed-capacity **Ring Buffer Sixel Registry** (capacity of 64 images per pane):
- The `Screen` owns a `SixelRegistry` storing `[64]?SixelImage`.
- Each `SixelImage` contains its unique `id` and the raw `data` (DCS bytes).
- When a new image is parsed:
  1. It is allocated a monotonically increasing `id`.
  2. It is inserted into the registry at `id % 64`.
  3. The slot's previous image (if any) is deallocated.
  4. The cells spanning the image's dimensions are filled in the grid with `attr.sixel = true`, `char = id`, and their local coordinate offsets `(dx, dy)`.

### C. Viewport Diffing & Rendering
During the render cycle:
1. `Display.renderAll` copies cells to the `merged_screen` as usual.
2. `Display.renderContent` compares the viewport with `last_cells`. If a cell changes from `attr.sixel = true` to `false` (meaning the graphic scrolled away), `last_cells` diffing automatically force-redraws that cell with space characters, clearing the sixel pixels.
3. `Display.renderSixelImages` scans the visible cells in the viewport:
   - When it encounters a cell with `attr.sixel == true`:
     - It extracts the `image_id` and the offsets `(dx, dy)`.
     - If the `image_id` has not been drawn in the current frame:
       - The top-left anchor is calculated as `abs_col = col - dx` and `abs_row = row - dy`.
       - If `abs_row >= 0`, we move the cursor to `(abs_col, abs_row)`, render the DCS bytes verbatim, and mark the `image_id` as drawn.
       - If `abs_row < 0` (partially scrolled off the top), we skip redrawing it, letting the terminal's native viewport scrolling handle display of the remaining visible bottom pixels.

---

## 3. Benefits
- **Zero Allocator Hooks**: Ring buffer eviction eliminates the need for reference counting hooks on grid row deallocations.
- **Perfect Scroll Sync**: Scrolling cells automatically scrolls the image references, matching viewport updates.
- **Copy-Mode Support**: Sixel image cells scroll into history and are automatically drawn when copy-mode loads them back into the viewport.

---

## 4. Limitations
Due to the cell-based grid updates of a terminal multiplexer and the lack of a pixel-level sixel encoder/decoder, the following constraints apply:
1. **Viewport Boundaries & Clipping**: Since we cannot crop the raw sixel DCS bytes, an image must fit entirely within the vertical and horizontal boundaries of its pane. If any portion of the image exceeds the pane boundaries (e.g., because the pane was split or resized, or the image's top edge scrolls past the top of the viewport), the image is hidden and its cells are erased. This prevents the graphic from breaking layout bounds and corrupting other panes.
2. **Terminal Erasure Quirks**: Sixel graphics are managed on a separate overlay layer by terminal emulators. Transparent space characters (`" "`) do not overwrite sixel pixels in most terminals. To guarantee clean removal when an image scrolls or is hidden, `szn` explicitly emits the `CSI X` (Erase Character) escape sequence when transitioning a cell from sixel to non-sixel.
3. **Optimized for Full-Screen TUIs**: This architecture is optimized for full-screen applications (like `yazi` or `ranger`) that manage their own layouts and handle window redrawing, while maintaining layout safety for multiplexer split-panes.
