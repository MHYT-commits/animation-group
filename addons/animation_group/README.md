# Animation Group Manual

A portable Godot editor addon for organizing nodes in the built-in `AnimationNodeBlendTree` editor.

This package is intentionally manual-only. It does not inspect project scripts, infer groups from node names, seed groups on startup, or provide an Auto-group command.

## Install

Copy `addons/animation_group_manual` into a Godot project, then enable **Animation Group Manual** in **Project > Project Settings > Plugins**.

The addon integrates with Godot's internal AnimationTree editor control hierarchy. It is designed for Godot 4.7 and may need an update if that internal hierarchy changes.

## Workflow

Open a saved `AnimationTree` containing an `AnimationNodeBlendTree`. Select graph nodes, then use the toolbar to create and edit groups manually. Groups can be nested, renamed, tinted, tidied, moved, collapsed, and expanded.

Group metadata is stored beside the blend tree:

```text
res://path/my_tree.tres
res://path/my_tree.groups.tres
```

The addon stores group metadata separately from animation playback data. It does not change animation connections or playback behavior.

## Saved resources

Grouping commands require a saved blend-tree resource with a sidecar path. Unsaved or embedded blend trees remain visible, but persistence commands are disabled until the resource can be saved independently.

## Limitations

- Membership uses animation node names. Renaming a node removes its stale membership on the next refresh.
- Synthetic frames remain non-selectable by GraphEdit so Godot's delete handler cannot treat them as animation nodes.
- Collapsed crossing wires are drawn by the addon and are not draggable until the group is expanded.
- The addon supports the built-in blend-tree editor integration; it does not add frames to arbitrary custom graph controls.
- There is no automatic grouping in this package. Projects that need seeding should use their own separate integration.
