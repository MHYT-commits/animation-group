@tool
extends SceneTree

## Run in an isolated project containing this addon (see the addon README).
const OVERLAY := preload("res://addons/animation_group/group_overlay.gd")
const TOOLBAR := preload("res://addons/animation_group/group_toolbar.gd")
const MEMBERS := preload("res://addons/animation_group/group_members_dialog.gd")

class TestPlugin extends EditorPlugin:
	var overlay
	func refresh_group_positions() -> void:
		overlay.refresh_positions()
	func set_group_collapsed_positions(positions: Dictionary) -> void:
		overlay.apply_collapsed_positions(positions)

var _failures := 0
var _checks := 0
var _overlay
var _plugin: TestPlugin
var _graph: GraphEdit
var _tree: AnimationNodeBlendTree
var _data: BlendTreeGroupData
var _a: BlendTreeGroup
var _b: BlendTreeGroup


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + description)


func _run() -> void:
	await process_frame
	_test_membership()
	await _make_fixture()
	await _test_marquee()
	await _test_move()
	_test_members_dialog()
	_test_nested_selection()
	await _test_all_node_types_and_creation()
	_overlay.teardown()
	_plugin.overlay = null
	_overlay = null
	_graph.queue_free()
	_plugin.queue_free()
	await process_frame
	print("Animation Group: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)


func _group(title: String, names: Array, key: String = "") -> BlendTreeGroup:
	return BlendTreeGroup.make(title, PackedStringArray(names), Color.CORNFLOWER_BLUE, key)


func _test_membership() -> void:
	var data := BlendTreeGroupData.new()
	var parent := _group("Parent", ["a"])
	var nested := _group("Nested", ["child"])
	nested.parent_id = parent.id
	var source := _group("Source", ["b"])
	var other_tree := _group("Other tree", ["b"], "other")
	data.groups.assign([parent, nested, source, other_tree])
	_check(data.set_members(parent, PackedStringArray(["a", "b", "b", "child", "output"])),
		"adding existing nodes changes membership")
	_check(parent.members == PackedStringArray(["a", "b"]), "members are unique and output is excluded")
	_check(nested.members == PackedStringArray(["child"]) and nested.parent_id == parent.id,
		"nested membership and hierarchy survive editing a parent")
	_check(not data.groups.has(source), "moving a source's last member cleans up its empty frame")
	_check(other_tree.members == PackedStringArray(["b"]), "membership changes stay within one tree")
	_check(not data.set_members(parent, parent.members), "unchanged membership is a no-op")
	data.set_members(parent, PackedStringArray())
	_check(data.groups.has(parent), "an empty parent with children is retained")
	data.set_members(nested, PackedStringArray())
	_check(not data.groups.has(nested) and not data.groups.has(parent), "empty child and parent frames are removed")
	_check(not data.set_members(source, PackedStringArray(["new"])), "a stale target cannot steal members")


func _make_fixture() -> void:
	_graph = GraphEdit.new()
	_graph.position = Vector2(10, 70)
	_graph.size = Vector2(1100, 600)
	_graph.z_index = 100
	_graph.minimap_enabled = false
	_graph.snapping_enabled = false
	EditorInterface.get_base_control().add_child(_graph)
	_tree = AnimationNodeBlendTree.new()
	var positions := {"a": Vector2(200, 200), "a2": Vector2(200, 320),
		"b": Vector2(650, 200), "extra": Vector2(850, 420)}
	for node_name in positions:
		var clip := AnimationNodeAnimation.new()
		clip.animation = StringName("library/" + node_name)
		_tree.add_node(node_name, clip, positions[node_name])
	for node_name in _tree.get_node_list():
		var node := GraphNode.new()
		node.name = node_name
		node.title = node_name
		var label := Label.new()
		label.text = "Animation clip " + node_name
		node.add_child(label)
		_graph.add_child(node)
		node.position_offset = _tree.get_node_position(node_name)
	_data = BlendTreeGroupData.new()
	_a = _group("A", ["a", "a2"])
	_b = _group("B", ["b"])
	_b.collapsed = true
	_b.collapsed_position = Vector2(650, 180)
	_data.groups.assign([_a, _b])
	_plugin = TestPlugin.new()
	EditorInterface.get_base_control().add_child(_plugin)
	_overlay = OVERLAY.new()
	_plugin.overlay = _overlay
	_overlay._plugin = _plugin
	_overlay._graph = _graph
	_overlay._editor = _graph
	_overlay._blend_tree = _tree
	_overlay._data = _data
	ResourceSaver.save(_tree, "res://fixture.tres")
	_tree.take_over_path("res://fixture.tres")
	var animation_tree := AnimationTree.new()
	animation_tree.tree_root = _tree
	_plugin.add_child(animation_tree)
	_overlay._animation_tree = animation_tree
	_overlay._sidecar_path = "res://fixture.groups.tres"
	_overlay._resolved_change_serial = 0
	_overlay._toolbar = TOOLBAR.new()
	if _overlay.get("_toolbar_include_seed") != null:
		_overlay._toolbar_include_seed = false
		_overlay._toolbar.inject(_graph, false)
	else:
		_overlay._toolbar.inject(_graph)
	_overlay._members_dialog = MEMBERS.new()
	_overlay._members_dialog.applied.connect(_overlay._on_members_applied)
	_graph.gui_input.connect(_overlay._on_graph_input)
	_graph.node_selected.connect(_overlay._on_selection_changed)
	_graph.node_deselected.connect(_overlay._on_selection_changed)
	_overlay._apply()
	await process_frame
	await process_frame
	_graph.zoom = 0.8
	_graph.scroll_offset = Vector2(40, 10)
	await process_frame


func _button(local: Vector2, pressed: bool, ctrl: bool = false, right: bool = false) -> void:
	var event := InputEventMouseButton.new()
	event.position = _graph.get_global_transform() * local
	event.global_position = event.position
	event.button_index = MOUSE_BUTTON_RIGHT if right else MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and not right else 0
	event.pressed = pressed
	event.ctrl_pressed = ctrl
	root.push_input(event)


func _motion(local: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = _graph.get_global_transform() * local
	event.global_position = event.position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(event)


func _title_rect(group: BlendTreeGroup) -> Rect2:
	var bar: Control = _overlay._titlebar_of(group.id)
	var transform := _graph.get_global_transform().affine_inverse() * bar.get_global_transform()
	return Rect2(transform * Vector2.ZERO, bar.size * _graph.zoom)


func _test_marquee() -> void:
	var a_rect := _title_rect(_a)
	var b_rect := _title_rect(_b)
	var from := a_rect.position.min(b_rect.position) - Vector2(20, 10)
	var to := a_rect.end.max(b_rect.end) + Vector2(10, 2)
	_button(from, true)
	_motion(to)
	await process_frame
	_button(to, false)
	await process_frame
	_check(_overlay._selected_group_ids.has(_a.id) and _overlay._selected_group_ids.has(_b.id),
		"native left-drag marquee selects expanded and collapsed groups at non-default zoom and pan")
	_check(_overlay._selected_names().is_empty(), "a group marquee clears native node selection")
	for group in [_a, _b]:
		var frame: GraphFrame = _graph.get_node(NodePath(_overlay.FRAME_PREFIX + group.id))
		_check(not frame.selected and not frame.selectable, "synthetic group frames remain safe from native Delete")
	_button(Vector2(1000, 530), true)
	_button(Vector2(1000, 530), false)
	await process_frame
	_check(_overlay._selected_group_ids.is_empty(), "blank canvas click clears groups")
	# Interior node selection must remain usable.
	var node: GraphNode = _graph.get_node("a")
	var node_rect := Rect2(node.position, node.size * _graph.zoom)
	from = node_rect.position + Vector2(-18, 10)
	to = node_rect.end + Vector2(3, 3)
	_button(from, true)
	_motion(to)
	await process_frame
	_button(to, false)
	await process_frame
	_check(_overlay._selected_names().has("a") and _overlay._selected_group_ids.is_empty(),
		"marquee inside a group still selects animation nodes")
	_overlay._select_group(_a.id, false)
	_button(b_rect.position - Vector2(15, 5), true, true)
	_motion(b_rect.end + Vector2(5, 5))
	await process_frame
	_button(b_rect.end + Vector2(5, 5), false, true)
	await process_frame
	_check(_overlay._selected_group_ids.size() == 2, "Ctrl marquee adds groups to the previous selection")
	_button(from, true)
	_motion(to)
	await process_frame
	_button(to, true, false, true)
	_button(to, false)
	_button(to, false, false, true)
	await process_frame
	_check(_overlay._selected_group_ids.size() == 2, "right-click cancels marquee and restores picked groups")


func _test_move() -> void:
	_overlay._selected_group_ids = PackedStringArray([_a.id, _b.id])
	var before_a := _tree.get_node_position(&"a")
	var before_b := _tree.get_node_position(&"b")
	var before_box := _b.collapsed_position
	var start := _title_rect(_a).get_center()
	var end := start + Vector2(64, 32)
	_button(start, true)
	_motion(end)
	_button(end, false)
	await process_frame
	await process_frame
	var delta: Vector2 = Vector2(64, 32) / _graph.zoom / EditorInterface.get_editor_scale()
	_check(_tree.get_node_position(&"a").is_equal_approx(before_a + delta), "drag moves first selected group's nodes")
	_check(_tree.get_node_position(&"b").is_equal_approx(before_b + delta), "drag also moves hidden members of selected collapsed group")
	_check(_b.collapsed_position.is_equal_approx(before_box + delta), "collapsed box moves with its hidden members")
	var manager := _plugin.get_undo_redo()
	var undo := manager.get_history_undo_redo(manager.get_object_history_id(_tree))
	_check(undo.has_undo(), "multi-group move creates an undo action")
	undo.undo()
	await process_frame
	await process_frame
	_check(_tree.get_node_position(&"a").is_equal_approx(before_a)
		and _tree.get_node_position(&"b").is_equal_approx(before_b)
		and _b.collapsed_position.is_equal_approx(before_box), "one undo restores all nodes and collapsed boxes")
	undo.redo()
	await process_frame
	await process_frame
	_check(_tree.get_node_position(&"b").is_equal_approx(before_b + delta), "redo restores the whole multi-group move")
	# A short press must not mutate even the on-screen positions.
	start = _title_rect(_a).get_center()
	var node: GraphNode = _graph.get_node("a")
	var offset := node.position_offset
	_button(start, true)
	_motion(start + Vector2.ONE)
	_check(node.position_offset.is_equal_approx(offset), "sub-threshold motion never moves nodes")
	_button(start + Vector2.ONE, false)
	await process_frame


func _test_members_dialog() -> void:
	_overlay._selected_group_ids = PackedStringArray([_a.id])
	_overlay._edit_members()
	var dialog = _overlay._members_dialog
	_check(dialog._entries.size() == 4, "Members lists existing nodes and excludes output")
	dialog._search.text = "library/extra"
	dialog._rebuild()
	var item: TreeItem = dialog._list.get_root().get_first_child()
	_check(item != null and item.get_text(0) == "extra", "membership search matches animation clip names")
	dialog._checked.append("extra")
	dialog._search.clear()
	dialog._rebuild()
	_check(dialog._checked.has("extra"), "searching preserves pending membership choices")
	dialog._on_confirmed()
	_check(_a.members.has("extra") and _a.title == "A", "Apply adds a clip to the existing group")
	var saved := ResourceLoader.load("res://fixture.groups.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as BlendTreeGroupData
	_check(saved != null and saved.group_with_id(_a.id).members.has("extra"), "membership changes persist to the sidecar")
	_overlay._edit_members()
	_overlay._members_tree = AnimationNodeBlendTree.new()
	_overlay._on_members_applied(PackedStringArray())
	_check(_data.groups.has(_a), "a dialog opened for a different tree cannot change the current group")
	dialog._dialog.hide()


func _test_nested_selection() -> void:
	var child := _group("Child", ["a2"])
	child.parent_id = _a.id
	_data.add_group(child)
	var picked: Array[BlendTreeGroup] = [_a, child, _b]
	var roots: Array[BlendTreeGroup] = _overlay._group_selection_roots(picked)
	_check(roots == ([_a, _b] as Array[BlendTreeGroup]), "selected ancestor and child use the subtree once")
	_overlay._selected_group_ids = PackedStringArray([_a.id, child.id, _b.id])
	var before := _tree.get_node_position(&"a2")
	var before_box := _b.collapsed_position
	var node: GraphNode = _graph.get_node("a2")
	var offset := node.position_offset
	var start: Vector2 = _graph.get_global_transform() * _title_rect(_a).get_center()
	_overlay._begin_drag(_a.id, start)
	_check(_overlay._drag_member_positions.size() == 4, "nested multi-selection snapshots every member once")
	_overlay._drive_drag(start + Vector2(50, 30))
	_overlay._cancel_drag()
	_check(node.position_offset.is_equal_approx(offset)
		and _tree.get_node_position(&"a2").is_equal_approx(before)
		and _b.collapsed_position.is_equal_approx(before_box), "cancelling a nested multi-group drag restores the entire gesture")
	_overlay._wrap_groups(picked)
	_check(child.parent_id == _a.id and _data.parent_of(_a) == _data.parent_of(_b),
		"wrapping selected parent and child preserves their nesting")


func _add_visual(node_name: String) -> GraphNode:
	var node := GraphNode.new()
	node.name = node_name
	node.title = node_name
	var label := Label.new()
	label.text = node_name
	node.add_child(label)
	_graph.add_child(node)
	node.position_offset = _tree.get_node_position(StringName(node_name))
	return node


func _settle() -> void:
	await process_frame
	await process_frame
	await process_frame


func _test_all_node_types_and_creation() -> void:
	await _settle()
	# Use the real resource signal, child-order notifications, and native-style
	# replacement of GraphNodes; none of these additions call addon internals.
	_graph.child_order_changed.connect(_overlay._on_graph_changed)
	var classes := ["AnimationNodeAnimation", "AnimationNodeOneShot", "AnimationNodeBlend2",
		"AnimationNodeBlend3", "AnimationNodeAdd2", "AnimationNodeAdd3", "AnimationNodeSub2",
		"AnimationNodeTimeScale", "AnimationNodeTimeSeek", "AnimationNodeTransition",
		"AnimationNodeBlendSpace1D", "AnimationNodeBlendSpace2D", "AnimationNodeStateMachine",
		"AnimationNodeBlendTree"]
	_overlay._selected_group_ids = PackedStringArray([_a.id])
	for type_name in classes:
		var node: AnimationNode = ClassDB.instantiate(type_name)
		_tree.add_node(StringName(type_name), node, Vector2(900, 500))
		var visual := _add_visual(type_name)
		visual.selected = true # Native creation may select the node during redraw.
		await _settle()
		_check(_a.members.has(type_name), "%s automatically joins the picked group" % type_name)
		_check(_overlay._selected_group_ids == PackedStringArray([_a.id]),
			"creation preserves the destination through native selection and redraw")
		_check(_graph.get_element_frame(StringName(type_name)) != null,
			"%s is attached to the group frame" % type_name)
	_check(not _a.members.has("output"), "automatic membership excludes the tree output")
	var before := _a.members.duplicate()
	var visuals: Array[Node] = []
	for child in _graph.get_children():
		if child is GraphNode:
			visuals.append(child)
	for child in visuals:
		_graph.remove_child(child)
		child.queue_free()
	for node_name in _tree.get_node_list():
		_add_visual(String(node_name))
	await _settle()
	_check(_a.members == before and _overlay._selected_group_ids.has(_a.id),
		"recreating editor GraphNodes preserves membership and group selection")
	_overlay._selected_group_ids.clear()
	_tree.add_node(&"unpicked", AnimationNodeOneShot.new())
	_add_visual("unpicked")
	await _settle()
	_check(_data.group_containing("", "unpicked") == null, "no group selection leaves new nodes ungrouped")
	_overlay._selected_group_ids = PackedStringArray([_a.id, _b.id])
	_tree.add_node(&"ambiguous", AnimationNodeBlend2.new())
	_add_visual("ambiguous")
	await _settle()
	_check(_data.group_containing("", "ambiguous") == null, "multiple picked groups do not guess a destination")
	# Every subtype must also be offered by the existing Members editor.
	_overlay._selected_group_ids = PackedStringArray([_a.id])
	_overlay._edit_members()
	var offered := PackedStringArray()
	for entry in _overlay._members_dialog._entries:
		offered.append(entry["detail"])
	_check(offered.has("AnimationNodeOneShot") and offered.has("AnimationNodeBlend2")
		and offered.has("AnimationNodeBlendSpace2D"), "Members lists non-clip node types")
	_overlay._on_members_applied(_a.members + PackedStringArray(["unpicked", "ambiguous"]))
	_overlay._members_dialog._dialog.hide()
	await _settle()
	_check(_a.members.has("unpicked") and _a.members.has("ambiguous"), "existing OneShot and Blend2 nodes can be added to a group")
	_overlay._selected_group_ids.clear()
	for node_name in ["unpicked", "ambiguous", "AnimationNodeBlendSpace2D"]:
		(_graph.get_node(NodePath(node_name)) as GraphNode).selected = true
	_overlay._group_selection()
	await _settle()
	var mixed := _data.group_containing("", "unpicked")
	_check(mixed != null and mixed.has_member("ambiguous") and mixed.has_member("AnimationNodeBlendSpace2D"),
		"Group creates one frame from a selection of OneShot, Blend2, and BlendSpace nodes")
	# A collapsed destination must hide a new member and restore its real position.
	_overlay._selected_group_ids = PackedStringArray([_b.id])
	var position := Vector2(810, 470)
	var created := AnimationNodeOneShot.new()
	_tree.add_node(&"collapsed_new", created, position)
	var hidden := _add_visual("collapsed_new")
	await _settle()
	_check(_b.members.has("collapsed_new") and not hidden.visible,
		"a new OneShot joins a collapsed group and is hidden")
	_check(_tree.get_node_position(&"collapsed_new") == position, "automatic grouping leaves resource positions unchanged")
	# Undo creation removes membership; redo restores the original destination,
	# even if a different group is selected in between.
	_tree.remove_node(&"collapsed_new")
	_graph.remove_child(hidden)
	hidden.queue_free()
	await _settle()
	_check(not _b.members.has("collapsed_new"), "undoing creation removes automatic membership")
	_overlay._selected_group_ids = PackedStringArray([_a.id])
	_tree.add_node(&"collapsed_new", created, position)
	hidden = _add_visual("collapsed_new")
	await _settle()
	_check(_b.members.has("collapsed_new") and not _a.members.has("collapsed_new"),
		"redo creation restores the original group rather than the newly picked group")
	# Renaming an existing node cannot be mistaken for creating a new one.
	_overlay._selected_group_ids = PackedStringArray([_a.id])
	_tree.rename_node(&"AnimationNodeOneShot", &"renamed_shot")
	var renamed := _graph.get_node("AnimationNodeOneShot")
	renamed.name = "renamed_shot"
	_overlay._on_graph_changed()
	await _settle()
	_check(not _a.members.has("renamed_shot"), "renaming is not classified as node creation")
	# Nested destination and a one-frame gap before the native node appears.
	var nested := _data.group_containing("", "a2")
	_overlay._selected_group_ids = PackedStringArray([nested.id])
	_tree.add_node(&"delayed_blend", AnimationNodeBlend2.new())
	await process_frame
	_add_visual("delayed_blend")
	await _settle()
	_check(nested.members.has("delayed_blend") and nested.parent_id == _a.id,
		"new nodes join a nested group even when the native rebuild is delayed")
	var saved := ResourceLoader.load("res://fixture.groups.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as BlendTreeGroupData
	_check(saved.group_with_id(nested.id).members.has("delayed_blend"), "automatic membership persists to the sidecar")
	# Stop watching immediately on suspension and establish a fresh baseline on
	# return; nodes created while another editor is active must not be adopted.
	_overlay._stop_watching_tree()
	_overlay._selected_group_ids = PackedStringArray([_a.id])
	_tree.add_node(&"while_hidden", AnimationNodeBlend2.new())
	_add_visual("while_hidden")
	_overlay._watch_blend_tree()
	await _settle()
	_check(not _a.members.has("while_hidden"), "resuming establishes a baseline without adopting existing nodes")
	var previous_tree := _tree
	var next_tree := AnimationNodeBlendTree.new()
	next_tree.add_node(&"other_clip", AnimationNodeAnimation.new())
	ResourceSaver.save(next_tree, "res://other_fixture.tres")
	next_tree.take_over_path("res://other_fixture.tres")
	_overlay._animation_tree.tree_root = next_tree
	_tree = next_tree
	visuals.clear()
	for child in _graph.get_children():
		if child is GraphNode:
			visuals.append(child)
	for child in visuals:
		_graph.remove_child(child)
		child.queue_free()
	for node_name in _tree.get_node_list():
		_add_visual(String(node_name))
	await _settle()
	_check(_overlay._blend_tree == next_tree and _overlay._selected_group_ids.is_empty(),
		"navigating to a different tree clears the previous destination")
	_check(not previous_tree.tree_changed.is_connected(_overlay._on_tree_structure_changed),
		"navigation disconnects automatic membership from the old resource")
	_check(_overlay._data.groups.is_empty(), "opening another tree does not inherit old groups or adopt its existing nodes")
