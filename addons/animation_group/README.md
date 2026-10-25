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

Select one or more nodes and choose **Group**. All blend-tree node types are
supported: Animation clips, OneShot, Blend2/3, Add/Subtract, TimeScale/Seek,
transitions, BlendSpaces, state machines, and nested blend trees. You can then:

- Rename the group and choose its color.
- Move the group by dragging its title bar; selected groups move together in one undoable action.
- Choose **Members** to add existing clip nodes or remove members.
- Choose **Tidy** to arrange its nodes.
- Put groups inside other groups.
- Collapse a group with the arrow in its title bar.
- Expand it again whenever you need to edit the nodes inside.
- Use **Ungroup** to remove the frame without removing the nodes.

Click a group's title bar to select the group. This lets you rename, tidy, move,
or group it with another group. You can hold Ctrl or Shift to select more than
one group. You can also left-drag from blank canvas across group title bars
to box-select them, including collapsed groups. Ctrl/Shift-drag adds to the
selection, right-click cancels the rectangle, and a blank-canvas click clears
the group selection. A rectangle that stays inside a frame selects nodes as usual.

## Edit an existing group

Pick a group and choose **Members**. Search by node name, animation clip name,
or current group. Check nodes to add them and uncheck direct members to remove
them, then choose **Apply Members**. Nodes from another group move to this one.
Cancel leaves membership unchanged. The list contains all existing blend-tree
node types, including custom AnimationNode types.

Nested members are shown checked and locked. Edit their own nested group to
change them. The output node cannot join a group. Removing the last member of a
group without children removes its frame. Membership changes are saved to the
sidecar and, like rename and collapse, are outside the undo history.

Select several groups and drag any selected title bar to move their nodes and
collapsed boxes together. Ctrl+Z undoes the entire move. Selecting both a parent
and child moves their shared contents once; wrapping them preserves their nesting.

## Create nodes inside a group

Pick exactly one group's title bar, then use
Godot's normal add-node controls. Newly created nodes automatically join that
group, including OneShot, Blend2, and other non-clip nodes. The destination stays
picked after creation so you can add several nodes in a row. Nested and collapsed
groups work too; a collapsed group hides the new member until expanded. With no
group picked, or multiple groups picked, new nodes remain ungrouped. Renaming a
node or refreshing the graph does not count as creation. Undo removes a newly
created node from its group; redo restores its original group while that
blend-tree view stays open. Nodes created while the addon is suspended are not
adopted when you return to the graph.

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
- This package never creates groups automatically. Nodes created while one
	group is picked automatically join that existing group.

## Regression checks

From the repository root, run `bash tests/animation_group/run.sh`. Set
`GODOT_BIN=/absolute/path/to/godot` if Godot is not on your PATH. The runner
copies the addon into a temporary project and checks membership, real mouse
selection and dragging, nesting, persistence, and move undo/redo.
