//! tmux N-ary layout -> herdr binary BSP tree.
//!
//! cmux speaks herdr's BSP shape: every interior node has exactly
//! `first` and `second` children plus a single `ratio`. tmux's
//! native layout grammar lets a split hold three or more children
//! (e.g. `select-layout even-horizontal`). The converter below
//! re-shapes those into right-leaning binary chains while
//! preserving each child's effective ratio against the remaining
//! siblings.
//!
//! Vocabulary mapping pinned by both projects' enums:
//!
//! | tmux                | herdr        |
//! |---------------------|--------------|
//! | `{}` LeftRight      | horizontal   |
//! | `[]` TopBottom      | vertical     |
//!
//! Direction names look swapped because both sides describe the
//! resulting *children layout*, not the divider direction:
//! "horizontal" panes sit side-by-side; "vertical" panes stack.

use serde::Serialize;

use crate::parse::{Geometry, LayoutNode, Orientation};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum BspSplitDirection {
    Horizontal,
    Vertical,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum BspNode {
    Pane {
        pane_id: String,
    },
    Split {
        direction: BspSplitDirection,
        ratio: f32,
        first: Box<BspNode>,
        second: Box<BspNode>,
    },
}

impl BspNode {
    /// Recursively collect every pane id in the tree, in
    /// left-to-right order.
    pub fn pane_ids(&self) -> Vec<String> {
        let mut out = Vec::new();
        self.collect(&mut out);
        out
    }

    fn collect(&self, out: &mut Vec<String>) {
        match self {
            BspNode::Pane { pane_id } => out.push(pane_id.clone()),
            BspNode::Split { first, second, .. } => {
                first.collect(out);
                second.collect(out);
            }
        }
    }
}

/// Convert a parsed tmux layout tree into the herdr BSP shape.
/// Pure data-to-data; safe to call from anywhere.
pub fn tmux_to_bsp(node: &LayoutNode) -> BspNode {
    match node {
        LayoutNode::Leaf { pane_id, .. } => BspNode::Pane {
            pane_id: pane_id.clone(),
        },
        LayoutNode::Split {
            orientation,
            children,
            ..
        } => bsp_from_n_children(*orientation, children),
    }
}

/// Information about the BSP split node that a path resolves
/// to. The bin uses this to translate `pane.set_split_ratio`
/// into a `tmux resize-pane` call: pin down the first child's
/// leftmost pane, multiply the target ratio by `total_dim`
/// along the split axis, and tell tmux to make that pane that
/// many cells wide / tall.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SplitTarget {
    pub direction: BspSplitDirection,
    pub leftmost_first_pane_id: String,
    pub total_dim: u32,
}

/// Walk `path` (false = first, true = second) over the BSP
/// projection of `tree` and return information about the split
/// the path lands on. Returns `None` if the path leaves the
/// tree, lands on a leaf, or otherwise can't be resolved.
pub fn walk_split_path(tree: &LayoutNode, path: &[bool]) -> Option<SplitTarget> {
    walk_view(SplitView::from(tree), path)
}

/// Internal view of an N-ary tmux split treated as a
/// right-leaning binary split. `Single` is a leaf; `Many` keeps
/// the orientation + the rest of the children for further
/// `second`-side recursion.
enum SplitView<'a> {
    Single,
    Many {
        orientation: Orientation,
        children: &'a [LayoutNode],
    },
}

impl<'a> From<&'a LayoutNode> for SplitView<'a> {
    fn from(n: &'a LayoutNode) -> Self {
        match n {
            LayoutNode::Leaf { .. } => SplitView::Single,
            LayoutNode::Split {
                orientation,
                children,
                ..
            } => SplitView::Many {
                orientation: *orientation,
                children,
            },
        }
    }
}

fn walk_view<'a>(view: SplitView<'a>, path: &[bool]) -> Option<SplitTarget> {
    if let Some((step, rest)) = path.split_first() {
        match view {
            SplitView::Single => None,
            SplitView::Many {
                orientation,
                children,
            } => {
                if children.len() < 2 {
                    return None;
                }
                if !*step {
                    walk_view(SplitView::from(&children[0]), rest)
                } else {
                    let tail = &children[1..];
                    if tail.len() == 1 {
                        walk_view(SplitView::from(&tail[0]), rest)
                    } else {
                        walk_view(
                            SplitView::Many {
                                orientation,
                                children: tail,
                            },
                            rest,
                        )
                    }
                }
            }
        }
    } else {
        // Path consumed; the current view must be a Split.
        match view {
            SplitView::Single => None,
            SplitView::Many {
                orientation,
                children,
            } => {
                if children.len() < 2 {
                    return None;
                }
                let direction = match orientation {
                    Orientation::LeftRight => BspSplitDirection::Horizontal,
                    Orientation::TopBottom => BspSplitDirection::Vertical,
                };
                let total: u32 = children.iter().map(|c| dim(c, orientation)).sum();
                let leftmost = leftmost_pane_id(&children[0])?;
                Some(SplitTarget {
                    direction,
                    leftmost_first_pane_id: leftmost,
                    total_dim: total,
                })
            }
        }
    }
}

fn dim(node: &LayoutNode, orientation: Orientation) -> u32 {
    let g: Geometry = match node {
        LayoutNode::Leaf { geometry, .. } | LayoutNode::Split { geometry, .. } => *geometry,
    };
    match orientation {
        Orientation::LeftRight => g.w,
        Orientation::TopBottom => g.h,
    }
}

fn leftmost_pane_id(node: &LayoutNode) -> Option<String> {
    match node {
        LayoutNode::Leaf { pane_id, .. } => Some(pane_id.clone()),
        LayoutNode::Split { children, .. } => children.first().and_then(leftmost_pane_id),
    }
}

fn bsp_from_n_children(orientation: Orientation, children: &[LayoutNode]) -> BspNode {
    debug_assert!(
        !children.is_empty(),
        "tmux never emits an empty split — corrupt layout string"
    );
    if children.len() == 1 {
        return tmux_to_bsp(&children[0]);
    }
    let direction = match orientation {
        Orientation::LeftRight => BspSplitDirection::Horizontal,
        Orientation::TopBottom => BspSplitDirection::Vertical,
    };
    let dim = |n: &LayoutNode| -> u32 {
        let g = match n {
            LayoutNode::Leaf { geometry, .. } | LayoutNode::Split { geometry, .. } => geometry,
        };
        match orientation {
            Orientation::LeftRight => g.w,
            Orientation::TopBottom => g.h,
        }
    };
    let total: u32 = children.iter().map(dim).sum();
    let first_size = dim(&children[0]);
    let ratio = if total == 0 {
        0.5
    } else {
        first_size as f32 / total as f32
    };
    let first = tmux_to_bsp(&children[0]);
    let second = bsp_from_n_children(orientation, &children[1..]);
    BspNode::Split {
        direction,
        ratio,
        first: Box::new(first),
        second: Box::new(second),
    }
}
