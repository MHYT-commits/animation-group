# Animation Group

A Godot editor addon for organizing `AnimationNodeBlendTree` graphs with colorful, collapsible groups.

Group creation is manual-only. Nodes created while one group is picked automatically join it. It does not inspect project scripts, guess groups from node names, or create groups automatically.

## Install in a Godot project

Copy the `addons/animation_group` folder into your project, then enable **Animation Group** from **Project > Project Settings > Plugins**.

Open a saved `AnimationTree` containing an `AnimationNodeBlendTree`. The addon adds grouping controls to the blend tree editor toolbar.

## Features

- Group any blend-tree node type, including clips, OneShot, Blend2, and BlendSpaces.
- Automatically include nodes created while a single group is picked.
- Nest groups inside other groups.
- Rename groups and choose their colors.
- Add or remove existing clip nodes with a searchable **Members** editor.
- Box-select groups by left-dragging across their title bars.
- Move selected groups together by dragging a title bar, with undo/redo.
- Arrange group contents with **Tidy**.
- Collapse and expand groups.
- Draw collapsed-group connections clearly.
- Keep grouping data in a separate `.groups.tres` sidecar file.

The addon does not change animation connections, parameter paths, or playback behavior.

## Requirements

- Godot 4.7 or a compatible Godot 4 release.
- A saved `AnimationTree` with an `AnimationNodeBlendTree`.

The addon integrates with Godot's built-in AnimationTree editor controls. Future Godot editor changes may require an addon update.

## Documentation

Detailed usage instructions are available in [the addon README](addons/animation_group/README.md).
