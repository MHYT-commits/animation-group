# Animation Group

Organize an `AnimationNodeBlendTree` with colorful frames and collapsible groups.

This version is made for general Godot projects. It only creates groups when you
ask it to. It does not scan your project or try to guess how your nodes should
be organized.

## Install

1. Copy the `addons/animation_group` folder into your project.
2. Open **Project > Project Settings > Plugins**.
3. Enable **Animation Group**.
4. Open a saved `AnimationTree` that contains an `AnimationNodeBlendTree`.

The addon adds a few buttons to the blend tree editor's toolbar.

## Use groups

Select one or more nodes and choose **Group**. You can then:

- Rename the group and choose its color.
- Move the group by dragging its title bar.
- Choose **Tidy** to arrange its nodes.
- Put groups inside other groups.
- Collapse a group with the arrow in its title bar.
- Expand it again whenever you need to edit the nodes inside.
- Use **Ungroup** to remove the frame without removing the nodes.

Click a group's title bar to select the group. This lets you rename, tidy, move,
or group it with another group. You can hold Ctrl or Shift to select more than
one group.

## Where your groups are saved

Groups are saved in a small file beside the blend tree:

```text
res://path/my_tree.tres
res://path/my_tree.groups.tres
```

The group file is separate from the animation resource. The addon does not
change animation connections or playback behavior.

The blend tree must be saved before grouping commands can be used. Unsaved or
embedded trees can still be viewed, but their group-editing buttons stay
disabled until Godot can give the tree its own save path.

## Collapsed groups

When a group is collapsed, the addon redraws any connections that cross its
boundary so the graph remains easy to follow. Connections entirely inside the
group are hidden until you expand it again. These connections are visual only;
the underlying animation tree is unchanged.

## Notes

- Node membership follows node names. Renaming a node removes its old membership
	the next time the graph refreshes.
- Group frames cannot be selected by Godot's normal delete tool. This prevents
	Godot from treating a visual frame as an animation node.
- Connections around collapsed groups cannot be dragged. Expand the group first
	when you need to rewire something.
- The addon works with Godot's built-in blend tree editor. It does not add frames
	to custom graph controls or the state machine editor.
- This package has no automatic grouping. Projects that need custom automation
	can add their own separate tool.
