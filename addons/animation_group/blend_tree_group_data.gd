@tool
extends Resource
class_name ManualBlendTreeGroupData

## The sidecar: every group defined for one blend tree resource.
##
## Kept beside the blend tree and never referenced by it, so grouping cannot
## alter what the AnimationTree plays -- and so it survives
## an owning project can rewrite the blend tree from scratch without affecting
## the sidecar.
##
## Groups form a forest: each one names its parent, and a node is a member of
## exactly one of them, the innermost. Every query that walks that forest is
## bounded by MAX_DEPTH and by a visited set, so a hand-edited file with a cycle
## in it cannot hang the editor -- it just renders oddly until repair_parents()
## breaks the loop.

const FORMAT_VERSION := 2

## How deep groups may nest. A hang guard for the walks below, and the point
## where the Group command refuses to nest any further.
const MAX_DEPTH := 8

@export var format_version: int = FORMAT_VERSION
@export var groups: Array[ManualBlendTreeGroup] = []


## "res://a/b.tres" -> "res://a/b.groups.tres"
static func sidecar_path_for(tree_path: String) -> String:
	if tree_path.is_empty():
		return ""
	var dir := tree_path.get_base_dir()
	if not dir.ends_with("/"):
		dir += "/"
	return "%s%s.groups.tres" % [dir, tree_path.get_file().get_basename()]


func groups_for(p_tree_key: String) -> Array[ManualBlendTreeGroup]:
	var result: Array[ManualBlendTreeGroup] = []
	for group in groups:
		if group != null and group.tree_key == p_tree_key:
			result.append(group)
	return result


func group_with_id(p_id: String) -> ManualBlendTreeGroup:
	if p_id.is_empty():
		return null
	for group in groups:
		if group != null and group.id == p_id:
			return group
	return null


## The group a node belongs to.
##
## Under nesting that is always the innermost one, and no search is needed to
## know it: only the innermost group carries the node in its members, because
## add_group() takes it away from whatever held it before.
func group_containing(p_tree_key: String, node_name: String) -> ManualBlendTreeGroup:
	for group in groups_for(p_tree_key):
		if group.has_member(node_name):
			return group
	return null


#region Nesting

## One tree's forest, resolved once: id -> group, and parent id -> children.
##
## Every walk below is otherwise a linear scan of the whole array per step, so a
## rebuild that asks for each group's depth and each group's descendants is
## cubic in the group count. Passing this in makes it linear. It is a plain
## Dictionary and nothing caches it: the caller builds it for the span it needs
## and drops it, so no mutation can leave a stale index behind.
##
## Every method that takes one still works without it, which is what lets the
## commands and the tests go on calling them plainly.
func build_index(p_tree_key: String) -> Dictionary:
	var by_id := {}
	for group in groups:
		if group != null and group.tree_key == p_tree_key:
			by_id[group.id] = group

	# Insertion order follows the groups array, so children come out in the same
	# order child_groups' scan would have produced them.
	var children := {}
	for id in by_id:
		var group: ManualBlendTreeGroup = by_id[id]
		# The same rule parent_of applies: an id naming nothing, or the group
		# itself, is no parent at all.
		if group.parent_id.is_empty() or group.parent_id == group.id \
				or not by_id.has(group.parent_id):
			continue
		if not children.has(group.parent_id):
			children[group.parent_id] = []
		children[group.parent_id].append(group)
	return {"by_id": by_id, "children": children}


## The enclosing group, or null when this one is top level.
##
## A parent id that names nothing, or something in another blend tree, reads as
## no parent at all: a half-broken file still draws rather than erroring.
func parent_of(group: ManualBlendTreeGroup, index: Dictionary = {}) -> ManualBlendTreeGroup:
	if group == null or group.parent_id.is_empty():
		return null
	var parent: ManualBlendTreeGroup = index["by_id"].get(group.parent_id) if index.has("by_id") \
		else group_with_id(group.parent_id)
	if parent == null or parent == group or parent.tree_key != group.tree_key:
		return null
	return parent


func child_groups(group: ManualBlendTreeGroup, index: Dictionary = {}) -> Array[ManualBlendTreeGroup]:
	var children: Array[ManualBlendTreeGroup] = []
	if group == null:
		return children
	if index.has("children"):
		for candidate in index["children"].get(group.id, []):
			children.append(candidate)
		return children
	for candidate in groups_for(group.tree_key):
		if candidate != group and candidate.parent_id == group.id:
			children.append(candidate)
	return children


func root_groups(p_tree_key: String) -> Array[ManualBlendTreeGroup]:
	var roots: Array[ManualBlendTreeGroup] = []
	for group in groups_for(p_tree_key):
		if parent_of(group) == null:
			roots.append(group)
	return roots


## Every group around this one, innermost first.
func ancestors_of(group: ManualBlendTreeGroup, index: Dictionary = {}) -> Array[ManualBlendTreeGroup]:
	var chain: Array[ManualBlendTreeGroup] = []
	var seen := {}
	var current := parent_of(group, index)
	while current != null and chain.size() <= MAX_DEPTH:
		if seen.has(current.id):
			break
		seen[current.id] = true
		chain.append(current)
		current = parent_of(current, index)
	return chain


## Every group inside this one, breadth first.
func descendants_of(group: ManualBlendTreeGroup, index: Dictionary = {}) -> Array[ManualBlendTreeGroup]:
	var found: Array[ManualBlendTreeGroup] = []
	if group == null:
		return found
	var seen := {group.id: true}
	var frontier := child_groups(group, index)
	var depth := 0
	while not frontier.is_empty() and depth <= MAX_DEPTH:
		var next: Array[ManualBlendTreeGroup] = []
		for child in frontier:
			if seen.has(child.id):
				continue
			seen[child.id] = true
			found.append(child)
			next.append_array(child_groups(child, index))
		frontier = next
		depth += 1
	return found


## This group and every group inside it, outermost first.
##
## The order matters for the same reason sorted_by_depth's does: a caller that
## walks it has always seen a parent before its children.
func subtree_of(group: ManualBlendTreeGroup) -> Array[ManualBlendTreeGroup]:
	var found: Array[ManualBlendTreeGroup] = []
	if group == null:
		return found
	found.append(group)
	found.append_array(descendants_of(group))
	return found


## Every animation node inside this group, at any depth, without duplicates.
##
## members is flat and per-group, so "everything in this group" is this union
## rather than a field. Bounded by descendants_of, which is MAX_DEPTH- and
## cycle-bounded, so a hand-edited sidecar with a loop cannot hang the mouse
## press that calls this.
func subtree_members(group: ManualBlendTreeGroup) -> PackedStringArray:
	var names := PackedStringArray()
	if group == null:
		return names
	for member in group.members:
		if not names.has(member):
			names.append(member)
	for descendant in descendants_of(group):
		for member in descendant.members:
			if not names.has(member):
				names.append(member)
	return names


func depth_of(group: ManualBlendTreeGroup, index: Dictionary = {}) -> int:
	return ancestors_of(group, index).size()


## How deep the deepest group inside this one sits, counted from the forest root.
##
## What a wrapper has to be checked against: putting a new group around this one
## pushes its whole subtree down a level, so the group that decides whether that
## is allowed is the innermost descendant, not this one.
func deepest_depth_of(group: ManualBlendTreeGroup, index: Dictionary = {}) -> int:
	if group == null:
		return -1
	var deepest := depth_of(group, index)
	for descendant in descendants_of(group, index):
		deepest = maxi(deepest, depth_of(descendant, index))
	return deepest


func is_ancestor_of(maybe_ancestor: ManualBlendTreeGroup, group: ManualBlendTreeGroup) -> bool:
	if maybe_ancestor == null or group == null:
		return false
	return ancestors_of(group).has(maybe_ancestor)


## Whether group may be moved under new_parent. Null means "make it top level",
## which is always allowed.
func can_reparent(group: ManualBlendTreeGroup, new_parent: ManualBlendTreeGroup) -> bool:
	if group == null:
		return false
	if new_parent == null:
		return true
	if new_parent == group or new_parent.tree_key != group.tree_key:
		return false
	# Moving a group under its own descendant would close a loop.
	return not is_ancestor_of(group, new_parent)


func set_parent(group: ManualBlendTreeGroup, new_parent: ManualBlendTreeGroup) -> bool:
	if not can_reparent(group, new_parent):
		return false
	group.parent_id = "" if new_parent == null else new_parent.id
	return true


## Parents before children, stable within a depth.
##
## Frames are created in this order so a child frame's parent is always already
## a child of the GraphEdit by the time the attach happens.
func sorted_by_depth(p_tree_key: String, index: Dictionary = {}) -> Array[ManualBlendTreeGroup]:
	var buckets: Array = []
	for _i in MAX_DEPTH + 2:
		buckets.append([])
	for group in groups_for(p_tree_key):
		buckets[mini(depth_of(group, index), MAX_DEPTH + 1)].append(group)

	var ordered: Array[ManualBlendTreeGroup] = []
	for bucket in buckets:
		for group in bucket:
			ordered.append(group)
	return ordered


## Whether anything inside this group still exists to draw a frame around.
##
## A group whose own members have all moved into its children is not empty: it
## is exactly what nesting a whole selection produces.
func has_rendered_members(group: ManualBlendTreeGroup, index: Dictionary = {}) -> bool:
	if group == null:
		return false
	if not group.members.is_empty():
		return true
	for descendant in descendants_of(group, index):
		if not descendant.members.is_empty():
			return true
	return false


## Clear parent ids that name nothing, name another tree, name the group itself,
## or close a cycle. True when something was repaired.
func repair_parents() -> bool:
	var changed := false
	for group in groups:
		if group == null or group.parent_id.is_empty():
			continue
		var parent := group_with_id(group.parent_id)
		if parent == null or parent == group or parent.tree_key != group.tree_key:
			group.parent_id = ""
			changed = true
			continue
		# Walk up from here; meeting ourselves again means this link closes a
		# loop, so this is the link to cut.
		var seen := {group.id: true}
		var current := parent
		var steps := 0
		while current != null and steps <= MAX_DEPTH + 1:
			if seen.has(current.id):
				group.parent_id = ""
				changed = true
				break
			seen[current.id] = true
			current = parent_of(current)
			steps += 1
	return changed

#endregion


#region Mutation

## Add a group, taking its members away from whatever held them before.
##
## Single membership is enforced here rather than at the frame layer: GraphEdit
## attaches an element to exactly one frame, so two groups claiming the same
## node would render as one of them silently losing it. This is also what makes
## nesting work -- a new child group takes its nodes out of the parent, leaving
## the parent holding only what was not selected.
func add_group(group: ManualBlendTreeGroup) -> void:
	if group == null:
		return
	for member in group.members:
		_strip_member(group.tree_key, member, group)
	if not groups.has(group):
		groups.append(group)
	_drop_empty()


## Ungroup, and the exact inverse of the implicit nest that made it: an inner
## group's members go back to the group that held it, and its own children move
## up a level. A top-level group's members simply become ungrouped.
func remove_group(group: ManualBlendTreeGroup) -> void:
	if group == null:
		return
	var index := groups.find(group)
	if index == -1:
		return

	var parent := parent_of(group)
	var parent_id := "" if parent == null else parent.id
	for child in child_groups(group):
		child.parent_id = parent_id
	if parent != null:
		for member in group.members:
			if not parent.has_member(member):
				parent.members.append(member)

	groups.remove_at(index)
	_drop_empty()


## Drop members that no longer exist in the tree. True when something changed.
func prune(p_tree_key: String, valid_names: PackedStringArray) -> bool:
	var changed := false
	for group in groups_for(p_tree_key):
		if group.prune(valid_names):
			changed = true
	return changed


func _strip_member(p_tree_key: String, node_name: String, keep: ManualBlendTreeGroup) -> void:
	for group in groups:
		if group == null or group == keep or group.tree_key != p_tree_key:
			continue
		group.remove_member(node_name)


## A group with neither members nor children draws no frame, so it is litter.
## One with children is not, however empty its own member list has become.
##
## Iterated to a fixed point because dropping a childless leaf can leave its
## parent droppable in turn. Nothing is orphaned: a group removed here provably
## has no children.
func _drop_empty() -> void:
	var dropped := true
	while dropped:
		dropped = false
		for i in range(groups.size() - 1, -1, -1):
			var group: ManualBlendTreeGroup = groups[i]
			if group == null or (group.members.is_empty() and child_groups(group).is_empty()):
				groups.remove_at(i)
				dropped = true

#endregion
