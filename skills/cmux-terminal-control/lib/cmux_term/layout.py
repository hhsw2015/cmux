"""tmux-style layout engine for cmux multi-panel teams.

cmux's `surface.split` accepts an `initial_divider_position` ∈ [0.1, 0.9].
This module computes the exact divider positions to reproduce common
tmux preset layouts.

Five presets supported:

    main-vertical        ┌────┬───┐
                         │MAIN│ a │
                         │    ├───┤
                         │    │ b │
                         │    ├───┤
                         │    │ c │
                         └────┴───┘

    main-horizontal      ┌────────┐
                         │  MAIN  │
                         ├──┬──┬──┤
                         │a │b │c │
                         └──┴──┴──┘

    even-horizontal      ┌──┬──┬──┬──┐
                         │a │b │c │d │
                         └──┴──┴──┴──┘

    even-vertical        ┌──────┐
                         │  a   │
                         ├──────┤
                         │  b   │
                         ├──────┤
                         │  c   │
                         └──────┘

    tiled                ┌──┬──┐
                         │a │b │
                         ├──┼──┤
                         │c │d │
                         └──┴──┘   (then 4→6→9 → 4×N grid)


Limits:
- cmux panels are binary tree splits, so to land EXACT proportions we
  derive each split's divider from the remaining fraction. Example:
  even-horizontal with 4 panels = splits at 0.25, 1/3, 0.5 of each
  successive remaining strip.
- divider clamped server-side to [0.1, 0.9]; an extreme layout (very
  many even splits) gets approximate proportions near the edges.
"""

from dataclasses import dataclass
from typing import List, Literal, Optional, Tuple


LayoutKind = Literal["main-vertical", "main-horizontal",
                     "even-horizontal", "even-vertical", "tiled"]


@dataclass
class SplitOp:
    """One step in a layout plan: split `parent_index` in `direction`
    with the given divider position."""
    parent_index: int            # index into the running panel list
    direction: Literal["right", "down"]
    divider: float               # ∈ [0.1, 0.9]


@dataclass
class LayoutPlan:
    """Output of the engine. Apply ops in order; each adds one panel.

    `panels[0]` is the root (already exists; the dispatcher panel).
    `panels[i]` for i ≥ 1 is the panel created by `ops[i-1]`.
    """
    ops: List[SplitOp]
    main_index: int = 0          # which panel is "main" (dispatcher / coordinator)


def _clamp(x: float) -> float:
    return max(0.1, min(0.9, x))


def main_vertical(n_workers: int, *, main_fraction: float = 0.6) -> LayoutPlan:
    """Dispatcher on left taking `main_fraction` of width; workers stack
    vertically on the right at even heights.

    Total panels = 1 (dispatcher) + n_workers.
    """
    if n_workers < 1:
        return LayoutPlan(ops=[])
    ops: List[SplitOp] = []
    # 1st split: dispatcher | worker_0 ; dispatcher gets main_fraction
    ops.append(SplitOp(parent_index=0, direction="right", divider=_clamp(main_fraction)))
    # Subsequent splits stack workers under the previous one.
    # Worker index j (0-indexed) in the right column: split parent
    # = the worker just placed (panel index j+1), with divider chosen
    # so that the remaining fraction divides evenly.
    # If we want N total workers in the right column, after placing
    # worker j there are N-j-1 still to place; they share the
    # bottom slot. The current top section (worker_j) should occupy
    # 1/(N-j) of the remaining column. Divider = 1/(N-j).
    for j in range(1, n_workers):
        # parent_index = the most-recently spawned worker
        parent = j  # panels[1] is worker_0, panels[2] is worker_1, ...
        remaining = n_workers - j + 1
        divider = _clamp(1.0 / remaining)
        ops.append(SplitOp(parent_index=parent, direction="down", divider=divider))
    return LayoutPlan(ops=ops, main_index=0)


def main_horizontal(n_workers: int, *, main_fraction: float = 0.6) -> LayoutPlan:
    """Dispatcher on top, workers in a row underneath."""
    if n_workers < 1:
        return LayoutPlan(ops=[])
    ops: List[SplitOp] = [
        SplitOp(parent_index=0, direction="down", divider=_clamp(main_fraction))
    ]
    # The "down" split made panel index 1 the bottom strip; subsequent
    # workers split panel 1 horizontally (right) into the remaining
    # bottom strip.
    for j in range(1, n_workers):
        parent = j      # panels[1] is the bottom strip / worker_0
        remaining = n_workers - j + 1
        divider = _clamp(1.0 / remaining)
        ops.append(SplitOp(parent_index=parent, direction="right", divider=divider))
    return LayoutPlan(ops=ops, main_index=0)


def even_horizontal(n_panels: int) -> LayoutPlan:
    """All N panels share width equally in a single row.

    This treats panels[0] as the leftmost; subsequent splits split the
    rightmost panel further with computed divider so each ends up at
    1/N of the parent width.
    """
    if n_panels <= 1:
        return LayoutPlan(ops=[])
    ops: List[SplitOp] = []
    # First split: panel 0 is left 1/N, the rest is right (N-1)/N
    # divider = 1/N (panel 0 keeps that fraction)
    ops.append(SplitOp(parent_index=0, direction="right", divider=_clamp(1.0 / n_panels)))
    # Each subsequent worker splits the rightmost panel: its width is
    # (N-i)/N of original; we want this worker to be 1/N of original
    # = 1/(N-i) of current.
    for i in range(2, n_panels):
        parent = i - 1                # the most-recently created panel (rightmost)
        remaining = n_panels - i + 1
        divider = _clamp(1.0 / remaining)
        ops.append(SplitOp(parent_index=parent, direction="right", divider=divider))
    return LayoutPlan(ops=ops, main_index=0)


def even_vertical(n_panels: int) -> LayoutPlan:
    """All N panels share height equally in a single column."""
    if n_panels <= 1:
        return LayoutPlan(ops=[])
    ops: List[SplitOp] = [
        SplitOp(parent_index=0, direction="down", divider=_clamp(1.0 / n_panels))
    ]
    for i in range(2, n_panels):
        parent = i - 1
        remaining = n_panels - i + 1
        divider = _clamp(1.0 / remaining)
        ops.append(SplitOp(parent_index=parent, direction="down", divider=divider))
    return LayoutPlan(ops=ops, main_index=0)


def tiled(n_panels: int) -> LayoutPlan:
    """tmux-tiled: roughly square grid. Algorithm:

    Compute cols = ceil(sqrt(n)), rows = ceil(n/cols).
    Build by:
      1. Split right (cols - 1) times to make `cols` columns of equal width.
      2. In each column, split down (rows - 1) times to fill rows.
    The last column may have fewer rows.
    """
    import math
    if n_panels <= 1:
        return LayoutPlan(ops=[])
    cols = math.ceil(math.sqrt(n_panels))
    rows_per_col = [n_panels // cols + (1 if i < n_panels % cols else 0) for i in range(cols)]
    # If rows_per_col has a zero at the end (cols too aggressive), trim.
    while rows_per_col and rows_per_col[-1] == 0:
        cols -= 1
        rows_per_col.pop()

    ops: List[SplitOp] = []

    # Step 1: build cols.
    # Even-horizontal of `cols` panels uses panel indices 0..cols-1.
    # We re-use the even_horizontal computation:
    if cols >= 2:
        for i in range(1, cols):
            parent = i - 1
            remaining = cols - i + 1
            ops.append(SplitOp(parent_index=parent, direction="right", divider=_clamp(1.0 / remaining)))

    # After step 1, panels are indices [0..cols-1] in left-to-right order.
    # Step 2: in each column, split down to make rows.
    next_index = cols
    for col_idx in range(cols):
        rows_here = rows_per_col[col_idx]
        # column root is at index col_idx; we need rows_here total panels
        # in this column (already 1: the column root). Add rows_here - 1
        # by stacking down.
        column_top = col_idx
        prev = column_top
        for r in range(1, rows_here):
            remaining = rows_here - r + 1
            ops.append(SplitOp(parent_index=prev, direction="down", divider=_clamp(1.0 / remaining)))
            prev = next_index
            next_index += 1
    return LayoutPlan(ops=ops, main_index=0)


def for_kind(kind: LayoutKind, n_workers: int, *, main_fraction: float = 0.6) -> LayoutPlan:
    """Dispatcher convenience — pick a layout by name.

    For `main-*`, the count is **workers** (dispatcher is panel 0 already).
    For `even-*` and `tiled`, the count is **total panels including the
    dispatcher**, so passing 4 with `even-horizontal` makes 4 strips
    counting the dispatcher as the leftmost.
    """
    if kind == "main-vertical":
        return main_vertical(n_workers, main_fraction=main_fraction)
    if kind == "main-horizontal":
        return main_horizontal(n_workers, main_fraction=main_fraction)
    if kind == "even-horizontal":
        return even_horizontal(n_workers + 1)     # +1 for dispatcher
    if kind == "even-vertical":
        return even_vertical(n_workers + 1)
    if kind == "tiled":
        return tiled(n_workers + 1)
    raise ValueError(f"unknown layout kind: {kind!r}")
