@tool
extends Resource
class_name BlendTreeGroup

## One visual group: a titled, tinted GraphFrame drawn around a set of animation
## nodes in the built-in AnimationNodeBlendTree editor.
##
## Membership is by node name, which is the only stable handle that editor
## exposes. Renaming a node there therefore drops it from its group, and prune()
## clears the stale entry the next time the graph is drawn.
##
## Almost nothing about geometry is stored here: frames autoshrink around
## whatever their members are doing, so nothing in this resource can disagree
## with the blend tree -- including after the owning project has regenerated
## node positions from scratch. The one exception is
## collapsed_position, because a collapsed frame has no members to shrink onto
## and has to be told where to sit.

## Stable identity, and the suffix of the GraphFrame's node name. Retitling or
## reordering a group therefore never re-creates its frame.
@export var id: String = ""

## Which blend tree inside the owning resource this group belongs to: empty for
## the tree that owns the file, a slash-joined path for a nested one.
@export var tree_key: String = ""

@export var title: String = "Group"

@export var tint: Color = Color(0.35, 0.55, 1.0, 0.25)

## Animation node names, in the order they were added.
@export var members: PackedStringArray = PackedStringArray()

## Padding the frame keeps around its members.
@export var autoshrink_margin: int = 40

## Id of the enclosing group, empty for a top-level one.
##
## Nesting lives here, on the child, and never as group ids inside members:
## members stays a flat list of animation node names, so prune(), Tidy and
## external setup is untouched, and a node still belongs to exactly one group -- the
## innermost one. Every group around it contains it transitively.
@export var parent_id: String = ""

## Collapsed groups hide their members and draw as a title bar and nothing else.
@export var collapsed: bool = false

## Where the collapsed box sits, in blend tree units rather than editor pixels,
## so a sidecar written on a 200% display puts the box in the same place on a
## 100% one. Only meaningful while collapsed, and rewritten from the frame's
## live offset each time the group is collapsed, so it cannot drift from where
## the group actually was.
@export var collapsed_position: Vector2 = Vector2.ZERO


static func make(p_title: String, p_members: PackedStringArray, p_tint: Color,
		p_tree_key: String = "") -> BlendTreeGroup:
	var group := BlendTreeGroup.new()
	group.id = "%08x" % randi()
	group.title = p_title
	group.members = p_members.duplicate()
	group.tint = p_tint
	group.tree_key = p_tree_key
	return group


func has_member(node_name: String) -> bool:
	return members.has(node_name)


func remove_member(node_name: String) -> bool:
	var index := members.find(node_name)
	if index == -1:
		return false
	members.remove_at(index)
	return true


## Drop members the blend tree no longer has. True when something was dropped.
func prune(valid_names: PackedStringArray) -> bool:
	var kept := PackedStringArray()
	for member in members:
		if valid_names.has(member):
			kept.append(member)
	if kept.size() == members.size():
		return false
	members = kept
	return true


func is_root() -> bool:
	return parent_id.is_empty()
