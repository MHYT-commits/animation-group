@tool
extends RefCounted

## Draws the groups into Godot's built-in blend tree editor, and runs the five
## toolbar commands.
##
## The whole overlay is decoration: it adds GraphFrames to the editor's GraphEdit
## and attaches existing GraphNodes to them. It never adds, removes, renames or
## rewires an animation node. The one thing it writes to the blend tree is
## nodes/<name>/position, from an explicit Tidy, through the same undo path the
## built-in editor uses for a node drag.

const LOCATOR := preload("res://addons/animation_group/editor_locator.gd")
const LAYOUT := preload("res://addons/animation_group/group_layout.gd")
const TOOLBAR := preload("res://addons/animation_group/group_toolbar.gd")
const DIALOG := preload("res://addons/animation_group/group_edit_dialog.gd")

## Frame node names. Prefixed so a teardown after a script reload can still find
## every frame this addon ever added, with or without its bookkeeping.
const FRAME_PREFIX := "__anim_group_"

## The output node belongs to no group: it is the tree's single sink, and the
## built-in editor treats it differently from every other node.
const OUTPUT_NODE := "output"

const MIN_ROW_STEP := 60.0
const ROW_PADDING := 16.0
const CELL_PADDING := Vector2(60.0, 24.0)
const MAX_TREE_DEPTH := 8

## The collapse toggle button inside a frame's titlebar.
const CHEVRON_NAME := "__anim_group_chevron"

## Width of a collapsed box. Its height is the titlebar plus one row per wire
## crossing its edge.
const COLLAPSED_WIDTH := 220.0

## Vertical spacing of the stubs a collapsed box's wires hang off, before the
## editor scale.
const STUB_STEP := 22.0

## Radius of the nub drawn at a stub, so a collapsed box reads as having ports.
const STUB_RADIUS := 4.0

## The Control the collapsed groups' wires are drawn on.
const WIRE_LAYER_NAME := "__anim_group_wires"
const WIRE_LAYER := preload("res://addons/animation_group/group_wire_layer.gd")

const PALETTE: Array[Color] = [
	Color(0.35, 0.55, 1.0, 0.20),
	Color(1.0, 0.58, 0.25, 0.20),
	Color(0.40, 0.85, 0.50, 0.20),
	Color(0.78, 0.50, 0.95, 0.20),
]

## Gap left between a group's child frames and its own tidied column.
const NESTED_TIDY_GAP := 80.0

## Floor on a solved frame alpha, so a deep nest still reads as a box.
const MIN_TINT_ALPHA := 0.04

const GRAPH_BG_FALLBACK := Color(0.08, 0.08, 0.08, 1.0)
const BORDER_LIGHTEN := 0.3

## How far a press must travel, in graph pixels, before it counts as a drag.
## Below this, pressing a title bar writes nothing at all.
const DRAG_THRESHOLD := 4.0

## How much brighter a selected group is painted, and the alpha it stops at.
const SELECTED_TINT_BOOST := 0.18
const SELECTED_TINT_CEILING := 0.7

## Metadata guarding the installed panel stylebox against apply loops.
const STYLE_META := "__anim_group_style"

## Marks a titlebar whose gui_input the overlay has already taken over.
const DRAG_META := "__anim_group_drag"

## Records the size the last apply gave a collapsed box, so a rect change can be
## told from our own write.
const SIZE_META := "__anim_group_size"

const NO_TARGET_TIP := "Save the blend tree resource to enable grouping."

var _plugin: EditorPlugin
var _editor: Control
var _graph: GraphEdit
var _toolbar
var _dialog

var _animation_tree: AnimationTree
var _blend_tree: AnimationNodeBlendTree
var _data: BlendTreeGroupData
var _sidecar_path := ""
var _tree_key := ""

var _applying := false
var _apply_queued := false
var _sync_positions := false
var _save_queued := false
var _dragging := false
var _apply_after_drag := false
var _apply_count := 0

var _drag_group_id := ""
var _drag_origin := Vector2.ZERO
var _drag_press_local := Vector2.ZERO
var _drag_delta := Vector2.ZERO
var _drag_moved := false
var _drag_member_offsets := {}
var _drag_member_positions := {}
var _drag_box_offsets := {}
var _drag_box_positions := {}
var _warned_editor := false
var _warned_tree := false
var _drag_additive := false
var _graph_background := GRAPH_BG_FALLBACK

## Groups picked by clicking their title bars. Ids, never the resources: a
## reloaded sidecar hands out new BlendTreeGroup objects, and this outlives one.
##
## The frames themselves stay unselectable -- GraphEdit collects every selected
## GraphElement for delete_nodes_request, checking is_selected() and nothing
## else, so a selectable frame would hand __anim_group_<id> to the built-in
## handler's remove_node(). Selection is modelled here instead.
var _selected_group_ids := PackedStringArray()

## The group the rename dialog was opened for, held across its modal life.
var _editing_group_id := ""

## The forest, resolved once per rebuild. See BlendTreeGroupData.build_index.
var _index := {}

## Connections taken out of the GraphEdit because a collapsed group hides an end
## of them. Key -> the connection dictionary, so they can be put back exactly.
var _suppressed := {}
var _wire_layer: Control

## Last plan handed to the wire layer, so an unchanged one costs a comparison.
var _planned_wires: Array = []


func setup(plugin: EditorPlugin) -> void:
	_plugin = plugin
	_toolbar = TOOLBAR.new()
	_toolbar.command.connect(_on_command)
	_dialog = DIALOG.new()
	_dialog.applied.connect(_on_edit_applied)
	_ensure_editor()
	_queue_apply()


func teardown() -> void:
	_cancel_drag()
	_disconnect_signals()
	_clear_frames()
	_restore_all_hidden()
	# After the frames and the hidden nodes, in that order: a wire is only put
	# back once both its ends are on screen again.
	_restore_connections()
	_release_wire_layer()
	if _toolbar != null:
		_toolbar.remove()
	if _dialog != null:
		_dialog.teardown()
	_selected_group_ids.clear()
	_editing_group_id = ""
	_toolbar = null
	_dialog = null
	_editor = null
	_graph = null
	_blend_tree = null
	_data = null
	_animation_tree = null


## The AnimationTree the inspector is on. Never cleared: the bottom panel keeps
## showing a tree after the selection moves elsewhere, and so do the frames.
func set_animation_tree(tree: AnimationTree) -> void:
	if tree == null:
		return
	_animation_tree = tree
	if _ensure_editor():
		_queue_apply()


## Move the on-screen nodes back onto whatever the resource now says.
##
## Called from the tidy undo action, because nothing in the engine announces a
## node position change.
func refresh_positions() -> void:
	if _ensure_editor():
		# UndoRedo changes the blend-tree resource before GraphEdit has finished
		# rebuilding its visual nodes and connection cache. Do not apply during
		# that transient state; the next-frame pass is the authoritative refresh.
		_refresh_positions_next_frame.call_deferred()


func _refresh_positions_next_frame() -> void:
	if _plugin == null or not is_instance_valid(_plugin.get_tree()):
		return
	await _plugin.get_tree().process_frame
	if _ensure_editor():
		_queue_apply(true)


func notify_visible() -> void:
	if _ensure_editor():
		_queue_apply()


#region Editor wiring

func _ensure_editor() -> bool:
	if is_instance_valid(_editor) and is_instance_valid(_graph):
		return true

	_disconnect_signals()
	_editor = LOCATOR.find_editor()
	_graph = LOCATOR.find_graph_edit(_editor)
	if _editor == null or _graph == null:
		_editor = null
		_graph = null
		if _animation_tree != null and not _warned_editor:
			_warned_editor = true
			push_warning("Animation Group: the built-in AnimationNodeBlendTreeEditor was not "
				+ "found, so grouping is disabled. The blend tree editor itself is unaffected.")
		return false

	_graph.child_order_changed.connect(_on_graph_changed)
	_graph.node_selected.connect(_on_selection_changed)
	_graph.node_deselected.connect(_on_selection_changed)
	_editor.visibility_changed.connect(_on_graph_changed)
	_graph.frame_rect_changed.connect(_on_frame_rect_changed)
	_toolbar.inject(_graph)
	return true


func _disconnect_signals() -> void:
	if is_instance_valid(_graph):
		if _graph.child_order_changed.is_connected(_on_graph_changed):
			_graph.child_order_changed.disconnect(_on_graph_changed)
		if _graph.node_selected.is_connected(_on_selection_changed):
			_graph.node_selected.disconnect(_on_selection_changed)
		if _graph.node_deselected.is_connected(_on_selection_changed):
			_graph.node_deselected.disconnect(_on_selection_changed)
		if _graph.frame_rect_changed.is_connected(_on_frame_rect_changed):
			_graph.frame_rect_changed.disconnect(_on_frame_rect_changed)
	if is_instance_valid(_editor):
		if _editor.visibility_changed.is_connected(_on_graph_changed):
			_editor.visibility_changed.disconnect(_on_graph_changed)


func _on_graph_changed() -> void:
	_queue_apply()


## Selecting a node drops the group selection, so the two never both claim the
## toolbar. Guarded on something actually being selected: _select_group and
## _apply_members both deselect nodes, and clearing on their echo would undo the
## very selection that caused it.
func _on_selection_changed(_node: Node = null) -> void:
	if not _selected_group_ids.is_empty() and not _selected_names().is_empty():
		_clear_group_selection()
	_update_buttons()


## GraphEdit re-shrinks a frame on its own schedule, which lands after the apply
## that sized a collapsed box -- measured: a 220x45 box came back as 333x885, the
## wrap of the stack it was hiding. Re-assert, but only when the rect is actually
## wrong: queueing on our own writes would be the runaway loop all over again.
func _on_frame_rect_changed(frame: GraphFrame, _new_rect: Rect2) -> void:
	if _dragging:
		return
	if _data == null or not is_instance_valid(frame):
		return
	var frame_name := String(frame.name)
	if not frame_name.begins_with(FRAME_PREFIX):
		return
	var group := _data.group_with_id(frame_name.substr(FRAME_PREFIX.length()))
	if group == null or not group.collapsed:
		return

	# Against the size the last apply actually wrote, not a size recomputed here:
	# a collapsed box is as tall as its stub count, which only the wire plan
	# knows, and a stale expectation here would queue an apply on every rect
	# change a collapsed frame ever emits.
	var scale := EditorInterface.get_editor_scale()
	var wanted_size: Vector2 = frame.get_meta(SIZE_META, Vector2.ZERO)
	var right_place := frame.position_offset.is_equal_approx(group.collapsed_position * scale)
	if frame.size.is_equal_approx(wanted_size) and right_place:
		return
	_queue_apply()


#endregion


#region Apply loop

func _queue_apply(sync_positions: bool = false) -> void:
	if sync_positions:
		_sync_positions = true
	# A rebuild mid-drag would re-attach, re-park and re-sync underneath the
	# gesture, so every request is folded into the one apply that runs when the
	# drag ends. _sync_positions is latched above, so a refresh asked for during a
	# drag is still honoured, just later.
	if _dragging:
		_apply_after_drag = true
		return
	# Adding or freeing our own frames re-emits child_order_changed synchronously.
	# Swallowing those here is what keeps the loop from feeding itself.
	if _applying or _apply_queued:
		return
	_apply_queued = true
	_apply.call_deferred()


func _apply() -> void:
	_apply_queued = false
	_apply_count += 1
	if _applying:
		return
	_applying = true
	_rebuild()
	_applying = false
	_sync_positions = false


func _rebuild() -> void:
	if not _ensure_editor():
		return
	if not _resolve_blend_tree():
		_update_buttons()
		return
	_graph_background = _graph_background_colour()

	# Names the tree no longer has are dropped from the groups in memory. The
	# sidecar is only written by an explicit command, so merely opening the panel
	# after a rename cannot touch a tracked file.
	_data.prune(_tree_key, _blend_tree.get_node_list())

	# One resolved view of the forest for the whole rebuild, instead of a linear
	# scan of the group array per ancestor step, per group, per query.
	_index = _data.build_index(_tree_key)

	var ordered: Array[BlendTreeGroup] = []
	var wanted := {}
	for group in _data.sorted_by_depth(_tree_key, _index):
		if _data.has_rendered_members(group, _index):
			ordered.append(group)
			wanted[group.id] = group

	for child in _graph.get_children():
		if child is GraphFrame and String(child.name).begins_with(FRAME_PREFIX):
			if not wanted.has(String(child.name).substr(FRAME_PREFIX.length())):
				_release_frame(child)

	# Create every frame before configuring any of them. sorted_by_depth puts
	# parents first, so pass two can attach a child frame to its parent knowing
	# the parent is already a child of the graph.
	for group in ordered:
		_ensure_frame(group)

	# The resource is the truth for node positions, so it has its say before the
	# frames do -- otherwise a Tidy refresh would un-park the members of a
	# collapsed group every time it ran.
	if _sync_positions:
		_sync_node_positions()

	# Contexts first, and without touching a single frame. A collapsed box is
	# sized by how many wires cross its edge, so the whole wire plan has to exist
	# before any geometry is written -- and the plan needs to know what is hidden.
	var contexts := {}
	var hidden_now := {}
	for group in ordered:
		var context := _frame_context(group, contexts)
		contexts[group.id] = context
		_note_hidden(group, context, hidden_now)

	var plan: Dictionary = LAYOUT.wire_plan(_all_connections(), hidden_now)

	for group in ordered:
		_apply_frame(group, contexts[group.id], plan)

	# Geometry last, and in a pass of its own: a collapsed box can only hold its
	# size once nothing is attached to it, and the frames above only finish
	# detaching when the whole loop above has run. See _apply_frame_geometry.
	for group in ordered:
		_apply_frame_geometry(group, contexts[group.id], plan)

	# Anything still hidden that no group claimed this pass belongs to nobody --
	# a group ungrouped while collapsed, or a tree the panel has navigated away
	# from. It goes back to the built-in editor rather than staying invisible.
	for child in _graph.get_children():
		var node_name := String(child.name)
		if child is GraphNode and not child.visible and not hidden_now.has(node_name):
			_restore_element(node_name)

	_apply_connections(plan)
	_apply_wires(plan)
	_update_buttons()


## What the groups above this one impose on it: whether it is hidden inside a
## collapsed ancestor, which box its members park on, and how much tint is
## already painted underneath it.
##
## Pure -- it reads the forest and writes nothing -- which is what lets the whole
## pass run before any frame is touched.
func _frame_context(group: BlendTreeGroup, contexts: Dictionary) -> Dictionary:
	var parent := _data.parent_of(group, _index)
	var above: Dictionary = contexts.get(parent.id, {}) if parent != null else {}

	# A collapsed group's own frame stays visible: it is the box you click to
	# get back. Everything inside it goes.
	var frame_hidden: bool = parent != null \
		and (parent.collapsed or bool(above.get("frame_hidden", false)))

	# Members park on the outermost collapsed box, so a two-deep collapse
	# converges every wire on the one rectangle still on screen. Its id travels
	# with the anchor because the wires have to name the box they hang off.
	var has_anchor: bool = bool(above.get("has_anchor", false))
	var anchor: Vector2 = above.get("anchor", Vector2.ZERO)
	var anchor_id: String = above.get("anchor_id", "")
	if not has_anchor and group.collapsed:
		has_anchor = true
		anchor = group.collapsed_position * EditorInterface.get_editor_scale()
		anchor_id = group.id

	# Nested frames are siblings that paint over one another. Solve each frame
	# against the rendered colour underneath it, so an ancestor's hue cannot
	# filter the child. The graph panel is the flat colour beneath the root.
	var backdrop: Color = above.get("render", _graph_background)
	var stored_tint: Color = group.tint
	if _is_selected(group):
		stored_tint = LAYOUT.selected_tint(stored_tint, SELECTED_TINT_BOOST, SELECTED_TINT_CEILING)
	var desired: Color = LAYOUT.composite_over(stored_tint, _graph_background)
	var fill: Color = LAYOUT.solve_over(desired, backdrop, MIN_TINT_ALPHA)
	var border_desired: Color = LAYOUT.composite_over(
		stored_tint.lightened(BORDER_LIGHTEN), _graph_background)
	var border: Color = LAYOUT.solve_over(border_desired, backdrop, MIN_TINT_ALPHA)
	var render: Color = LAYOUT.composite_over(fill, backdrop)

	return {
		"frame_hidden": frame_hidden,
		"has_anchor": has_anchor,
		"anchor": anchor,
		"anchor_id": anchor_id,
		"tint": stored_tint,
		"fill": fill,
		"border": border,
		"render": render,
	}


## Which members this group takes off the screen, and onto which box.
##
## Same test _apply_members uses, run ahead of it so the wire plan knows what is
## hidden before any frame is written. Members the tree no longer has are
## harmless here: no GraphNode, no connection, nothing to plan.
func _note_hidden(group: BlendTreeGroup, context: Dictionary, hidden_now: Dictionary) -> void:
	if not (context["frame_hidden"] or group.collapsed):
		return
	var box_id: String = context["anchor_id"]
	for member in group.members:
		hidden_now[member] = box_id


## The frame for a group, created if it is not there yet. No configuration here:
## _rebuild calls this for every group before configuring any of them.
func _ensure_frame(group: BlendTreeGroup) -> GraphFrame:
	var frame_name := FRAME_PREFIX + group.id
	var frame := _graph.get_node_or_null(NodePath(frame_name)) as GraphFrame
	if frame == null:
		frame = GraphFrame.new()
		frame.name = frame_name
		_graph.add_child(frame)
	return frame


## One frame per group, reused by name.
##
## Reuse is the common path, not the fallback: the built-in editor's rebuild
## frees only GraphNode children, and a GraphFrame is not one, so the frames --
## and the chevron parented to one -- outlive it. Attachments to nodes that were
## freed go with them, which is why every member is re-attached here, but only
## where it is actually missing.
##
## Every write below is guarded. That is not tidiness: it makes an apply over
## unchanged state write nothing at all, so the loop is a fixpoint. Without it,
## re-attaching an already-attached element makes the graph emit
## child_order_changed a frame later, which queues the next apply, which
## re-attaches -- an endless rebuild loop that takes the editor down with it.
func _apply_frame(group: BlendTreeGroup, context: Dictionary, plan: Dictionary) -> void:
	var frame_name := FRAME_PREFIX + group.id
	var frame := _ensure_frame(group)
	var scale := EditorInterface.get_editor_scale()
	var frame_hidden: bool = context["frame_hidden"]

	if frame.title != group.title:
		frame.title = group.title
	if frame.visible == frame_hidden:
		frame.visible = not frame_hidden

	_apply_frame_style(frame, context["fill"], context["border"], _is_selected(group))

	# Inert on purpose. GraphEdit collects every selected GraphElement for
	# delete_nodes_request, and the built-in handler would then call remove_node()
	# on a frame name the blend tree has never heard of. A frame that cannot be
	# selected is never in that list; one that cannot be dragged can never move a
	# node without the resource hearing about it; and ignoring the mouse keeps its
	# interior from eating clicks meant for the nodes inside it. The chevron is
	# the one exception, and it opts back in for itself.
	if frame.selectable:
		frame.selectable = false
	if frame.draggable:
		frame.draggable = false
	if frame.resizable:
		frame.resizable = false
	if frame.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_apply_chevron(frame, group)
	_apply_frame_parent(frame, frame_name, group, frame_hidden)
	_apply_members(frame, frame_name, group, context, scale)


func _graph_background_colour() -> Color:
	if not is_instance_valid(_graph):
		return GRAPH_BG_FALLBACK
	var panel := _graph.get_theme_stylebox(&"panel", &"GraphEdit")
	if panel is StyleBoxFlat:
		var background: Color = (panel as StyleBoxFlat).bg_color
		return Color(background.r, background.g, background.b, 1.0)
	return GRAPH_BG_FALLBACK


func _apply_frame_style(frame: GraphFrame, fill: Color, border: Color, selected: bool) -> void:
	var theme := EditorInterface.get_editor_theme()
	var base := theme.get_stylebox(&"panel", &"GraphFrame") if theme != null else null
	if not base is StyleBoxFlat:
		if frame.has_theme_stylebox_override(&"panel"):
			frame.remove_theme_stylebox_override(&"panel")
		if not frame.tint_color_enabled:
			frame.tint_color_enabled = true
		if frame.tint_color != fill:
			frame.tint_color = fill
		return

	var selected_box := theme.get_stylebox(&"panel_selected", &"GraphFrame")
	var selected_border := (selected_box as StyleBoxFlat).border_color \
		if selected_box is StyleBoxFlat else (base as StyleBoxFlat).border_color
	var style: StyleBoxFlat = (base as StyleBoxFlat).duplicate()
	style.bg_color = fill
	style.border_color = selected_border if selected else border
	var selected_box_id := selected_box.get_instance_id() if selected_box != null else 0
	var stamp := "%s|%s|%d|%d|%d" % [fill, style.border_color,
		1 if selected else 0, base.get_instance_id(), selected_box_id]
	if String(frame.get_meta(STYLE_META, "")) == stamp \
			and frame.has_theme_stylebox_override(&"panel"):
		if frame.tint_color_enabled:
			frame.tint_color_enabled = false
		return
	frame.add_theme_stylebox_override(&"panel", style)
	frame.set_meta(STYLE_META, stamp)
	if frame.tint_color_enabled:
		frame.tint_color_enabled = false


## Where a collapsed group's box sits and how big it is.
##
## A whole pass of its own, run only once every frame has finished attaching and
## detaching, and that ordering is the entire point. GraphEdit's
## _update_graph_frame reads:
##
##     if (frame_attached_nodes.get(name).size() > 0) {
##         if (!p_frame->is_autoshrink_enabled()) {
##             min_point = min_point.min(old_offset);
##             max_point = max_point.max(old_offset + p_frame->get_size());
##         }
##         p_frame->set_position_offset(min_point);
##         p_frame->set_size(max_point - min_point);
##     }
##
## -- so switching autoshrink off does not stop the engine forcing a frame to
## enclose whatever is attached to it; it only stops it shrinking back, which
## makes an inflated box permanent. The one thing that does stop it is having
## nothing attached at all.
##
## Sizing inside _apply_frame looked right and was not: frames are applied
## parents-first, so a collapsed group's box was sized while its nested child
## frames were still attached to it, and the next draw blew it back up to wrap
## them. It only ever came right after a drag, which re-writes the rect once
## everything has detached. Headless never reproduced it because nothing draws.
func _apply_frame_geometry(group: BlendTreeGroup, context: Dictionary, plan: Dictionary) -> void:
	var frame := _graph.get_node_or_null(NodePath(FRAME_PREFIX + group.id)) as GraphFrame
	if frame == null:
		return
	var scale := EditorInterface.get_editor_scale()

	if not group.collapsed:
		if not frame.autoshrink_enabled:
			frame.autoshrink_enabled = true
		if frame.autoshrink_margin != group.autoshrink_margin:
			frame.autoshrink_margin = group.autoshrink_margin
		return

	# Autoshrink measures hidden members too, so it is switched off rather than
	# starved: a collapsed frame is sized by hand.
	if frame.autoshrink_enabled:
		frame.autoshrink_enabled = false
	var moved := false
	var collapsed_offset := group.collapsed_position * scale
	if not frame.position_offset.is_equal_approx(collapsed_offset):
		frame.position_offset = collapsed_offset
		moved = true
	# One row per wire crossing the boundary, so the stubs the wire layer draws
	# all land inside the box they hang off. Control clamps size up to its
	# combined minimum, so comparing against the raw wanted value would be an
	# unconditional write in disguise.
	var minimum := frame.get_combined_minimum_size()
	var collapsed_size: Vector2 = LAYOUT.collapsed_box_size(COLLAPSED_WIDTH * scale,
		minimum.y, LAYOUT.stub_rows(plan, group.id), STUB_STEP * scale).max(minimum)
	# Recorded so _on_frame_rect_changed can tell GraphEdit's re-shrink from our
	# own write without recomputing a plan it does not have.
	if frame.get_meta(SIZE_META, Vector2.ZERO) != collapsed_size:
		frame.set_meta(SIZE_META, collapsed_size)
	if not frame.size.is_equal_approx(collapsed_size):
		frame.size = collapsed_size
		moved = true
	if moved:
		_rewrap_ancestors(group)


## Tell GraphEdit that a collapsed box has moved or resized, so every frame
## around it wraps the new rect instead of the old one.
##
## Nothing else will. GraphEdit re-wraps a frame only from attach, detach, a user
## resize, an autoshrink toggle, add/remove_child, or _graph_node_rect_changed --
## and that last one is connected to item_rect_changed for GraphNode ONLY. A
## GraphFrame written from script emits position_offset_changed into
## _graph_element_moved, whose whole body is queue_redraw calls.
##
## So the ancestors keep bounds computed from the rect this box had before it
## collapsed. Worse, the detaches earlier in the same rebuild DO re-wrap them --
## _update_graph_frame recurses upward through linked_parent_map -- so they are
## actively refreshed from stale geometry. Measured on the real tree: collapsing
## Sword A left Sword 43px too wide, Sword B another 67px, Stinger left Specials
## 157px too tall, and it only came right when the root itself was collapsed and
## sized by hand.
##
## attach_graph_element_to_frame is idempotent for the attachment maps and ends
## in _update_graph_frame, which recurses all the way up, so one call fixes a
## nest of any depth. Guarded by the caller on the geometry actually having
## changed, so a steady apply still writes nothing and the loop stays a fixpoint.
func _rewrap_ancestors(group: BlendTreeGroup) -> void:
	var parent := _data.parent_of(group, _index)
	if parent == null:
		return
	var frame_name := FRAME_PREFIX + group.id
	var parent_name := FRAME_PREFIX + parent.id
	# Only while it is actually attached: a hidden frame is detached on purpose,
	# and re-attaching it here would put it straight back into its collapsed
	# ancestor's wrap.
	var current := _graph.get_element_frame(StringName(frame_name))
	if current == null or String(current.name) != parent_name:
		return
	_graph.attach_graph_element_to_frame(StringName(frame_name), StringName(parent_name))


## Put the frame inside its parent's frame, or take it out again.
##
## The detach is not hypothetical: ungrouping a middle group reparents its
## children while their frames are live.
func _apply_frame_parent(frame: GraphFrame, frame_name: String, group: BlendTreeGroup,
		frame_hidden: bool) -> void:
	var parent := _data.parent_of(group, _index)
	var wanted := ""
	# A hidden frame detaches for the same reason a hidden member does: an
	# attached child still drags its collapsed parent's rect around, margin and
	# all, however firmly the parent's autoshrink is switched off.
	var parent_frame := _graph.get_node_or_null(NodePath(FRAME_PREFIX + parent.id)) \
		if parent != null else null
	if not frame_hidden and parent_frame is GraphFrame:
		wanted = FRAME_PREFIX + parent.id

	var current := _graph.get_element_frame(StringName(frame_name))
	var current_name := "" if current == null else String(current.name)
	if current_name == wanted:
		return
	if current != null:
		_graph.detach_graph_element_from_frame(StringName(frame_name))
	if not wanted.is_empty():
		_graph.attach_graph_element_to_frame(StringName(frame_name), StringName(wanted))


func _apply_members(frame: GraphFrame, frame_name: String, group: BlendTreeGroup,
		context: Dictionary, scale: float) -> void:
	var hidden: bool = context["frame_hidden"] or group.collapsed
	for member in group.members:
		var node := _graph.get_node_or_null(NodePath(member)) as GraphNode
		if node == null:
			continue
		var attached := _graph.get_element_frame(StringName(member)) == frame

		if hidden:
			# Detach while hidden. An attached member still feeds the frame's
			# autoshrink even with the flag off -- measured: a collapsed box grew
			# straight back to 333x245, the wrap of the very stack it was hiding.
			if attached:
				_graph.detach_graph_element_from_frame(StringName(member))
			# Deselect first: GraphEdit hands every selected element to the
			# built-in delete handler, and a node you cannot see is one you
			# cannot knowingly delete.
			if node.selected:
				node.selected = false
			if node.visible:
				node.visible = false
			if context["has_anchor"]:
				var anchor: Vector2 = context["anchor"]
				if not node.position_offset.is_equal_approx(anchor):
					node.position_offset = anchor
			continue

		if not attached:
			_graph.attach_graph_element_to_frame(StringName(member), StringName(frame_name))
		if not node.visible:
			# Only on the flip, and always from the resource: the built-in editor
			# commits every drag through set_node_position, so the resource is
			# authoritative for anything that is not being dragged right now --
			# and a hidden node cannot be.
			node.visible = true
			var home := _blend_tree.get_node_position(StringName(member)) * scale
			if not node.position_offset.is_equal_approx(home):
				node.position_offset = home
		_repair_ports(node)


func _release_frame(frame: GraphFrame) -> void:
	if not is_instance_valid(frame) or not is_instance_valid(_graph):
		return
	# A frame the gesture is holding is about to stop existing.
	if _dragging:
		_cancel_drag()
	_release_chevron(frame)
	if _graph.get_element_frame(frame.name) != null:
		_graph.detach_graph_element_from_frame(frame.name)
	if _graph.has_method("get_attached_nodes_of_frame"):
		for attached in _graph.get_attached_nodes_of_frame(frame.name):
			_restore_element(String(attached))
			_graph.detach_graph_element_from_frame(StringName(attached))
	_graph.remove_child(frame)
	frame.queue_free()


## Hand a graph element back to the built-in editor the way it expects to find
## Every element the overlay has hidden, back where the built-in editor expects
## it. A collapsed frame detaches its members, so releasing frames is not enough
## to find them all again -- the graph itself is the only complete list.
func _restore_all_hidden() -> void:
	if not is_instance_valid(_graph):
		return
	for child in _graph.get_children():
		if child is GraphElement and not child.visible:
			_restore_element(String(child.name))


## it: visible, and where the resource says it is.
##
## Disabling the addon while a group is collapsed would otherwise leave those
## animation nodes invisible and stacked on one another in the built-in editor,
## with no addon left to undo it.
func _restore_element(element_name: String) -> void:
	var element := _graph.get_node_or_null(NodePath(element_name)) as GraphElement
	if element == null:
		return
	if not element.visible:
		element.visible = true
	var node := element as GraphNode
	if node == null or _blend_tree == null or not _blend_tree.has_node(StringName(element_name)):
		return
	_repair_ports(node)
	var home := _blend_tree.get_node_position(StringName(element_name)) \
		* EditorInterface.get_editor_scale()
	if not node.position_offset.is_equal_approx(home):
		node.position_offset = home


## Every frame this addon has ever added to the graph, bookkeeping or not.
func _clear_frames() -> void:
	if not is_instance_valid(_graph):
		return
	for child in _graph.get_children():
		if child is GraphFrame and String(child.name).begins_with(FRAME_PREFIX):
			_release_frame(child)


func _sync_node_positions() -> void:
	var scale := EditorInterface.get_editor_scale()
	for node_name in _blend_tree.get_node_list():
		var node := _graph.get_node_or_null(NodePath(String(node_name))) as GraphNode
		if node == null:
			continue
		var wanted := _blend_tree.get_node_position(node_name) * scale
		if node.position_offset != wanted:
			node.position_offset = wanted

#endregion


#region Wires of a collapsed group

## Every connection the graph is showing, plus the ones we have taken out of it.
##
## The blend tree resource cannot be asked: AnimationNodeBlendTree exposes only
## connect_node and disconnect_node to scripts, not a query. So the GraphEdit's
## own list is the source, and _suppressed is the part of it we are holding.
func _all_connections() -> Array:
	var found: Array = []
	if not is_instance_valid(_graph):
		return found
	found.append_array(_graph.get_connection_list())
	for key in _suppressed:
		found.append(_suppressed[key])
	return found


func _connection_key(connection: Dictionary) -> String:
	return "%s:%d>%s:%d" % [
		connection.get("from_node", ""), int(connection.get("from_port", 0)),
		connection.get("to_node", ""), int(connection.get("to_port", 0))]


## Take the wires of a collapsed group out of the GraphEdit, and put them back
## when it expands.
##
## This is why collapsing is worth doing at all. GraphEdit resolves a connection
## by asking both ends for their port positions, with no visibility test and no
## bounds test, and a hidden GraphNode's port cache is empty -- so every wire
## into a collapsed group used to print three errors per redraw and then draw
## itself from the box's top-left corner. Removing them is decoration, exactly
## like the frames: AnimationNodeBlendTreeEditor drives the graph from the
## resource and never reads the graph's connection list back.
##
## Every write is guarded, so a second apply over unchanged state writes nothing.
func _apply_connections(plan: Dictionary) -> void:
	if not is_instance_valid(_graph):
		return
	var wanted := {}
	for connection in plan["suppress"]:
		wanted[_connection_key(connection)] = connection

	for key in _suppressed.keys():
		if wanted.has(key):
			continue
		var connection: Dictionary = _suppressed[key]
		_suppressed.erase(key)
		# Only if both ends are still on screen. A node deleted while its group
		# was collapsed must not come back as a wire to nowhere.
		var from_node := String(connection["from_node"])
		var to_node := String(connection["to_node"])
		if _graph.get_node_or_null(NodePath(from_node)) is GraphNode \
				and _graph.get_node_or_null(NodePath(to_node)) is GraphNode:
			_graph.connect_node(StringName(from_node), int(connection["from_port"]),
				StringName(to_node), int(connection["to_port"]))

	for key in wanted:
		if _suppressed.has(key):
			continue
		var connection: Dictionary = wanted[key]
		var from_node := StringName(connection["from_node"])
		var to_node := StringName(connection["to_node"])
		var from_port := int(connection["from_port"])
		var to_port := int(connection["to_port"])
		if _graph.is_node_connected(from_node, from_port, to_node, to_port):
			_graph.disconnect_node(from_node, from_port, to_node, to_port)
		_suppressed[key] = connection


## Put every wire we are holding back, for a teardown.
func _restore_connections() -> void:
	if is_instance_valid(_graph):
		for key in _suppressed:
			var connection: Dictionary = _suppressed[key]
			var from_node := String(connection["from_node"])
			var to_node := String(connection["to_node"])
			if _graph.get_node_or_null(NodePath(from_node)) is GraphNode \
					and _graph.get_node_or_null(NodePath(to_node)) is GraphNode:
				_graph.connect_node(StringName(from_node), int(connection["from_port"]),
					StringName(to_node), int(connection["to_port"]))
	_suppressed.clear()


## Hand the crossing wires to the layer that draws them.
##
## Which wires exist changes only when a group is collapsed, expanded or edited;
## where they are drawn changes constantly, and the layer tracks that itself. So
## an apply over an unchanged plan does no work here at all -- the comparison is
## a couple of dozen dictionaries, against a colour lookup and a node lookup per
## wire if it went ahead.
func _apply_wires(plan: Dictionary) -> void:
	var wires: Array = plan["wires"]
	if wires.is_empty() and _wire_layer == null:
		return
	# Ahead of the unchanged-plan check, because _ensure_wire_layer also keeps the
	# draw order right, and GraphEdit reorders its children for reasons that have
	# nothing to do with which wires exist.
	var layer := _ensure_wire_layer()
	if layer == null:
		return
	if wires == _planned_wires:
		return
	_planned_wires = wires.duplicate(true)
	layer.set_wires(_decorate_wires(wires))


## Give each wire the colour of whichever end still has real ports on screen.
func _decorate_wires(wires: Array) -> Array:
	var decorated: Array = []
	for wire in wires:
		var spec: Dictionary = wire.duplicate()
		spec["color"] = _wire_color(wire)
		decorated.append(spec)
	return decorated


func _wire_color(wire: Dictionary) -> Color:
	var fallback := Color(0.85, 0.85, 0.9, 0.85)
	if String(wire["to_box"]).is_empty():
		var to_node := _graph.get_node_or_null(NodePath(String(wire["to_node"]))) as GraphNode
		if to_node != null and int(wire["to_port"]) < to_node.get_input_port_count():
			return to_node.get_input_port_color(int(wire["to_port"]))
	if String(wire["from_box"]).is_empty():
		var from_node := _graph.get_node_or_null(NodePath(String(wire["from_node"]))) as GraphNode
		if from_node != null and int(wire["from_port"]) < from_node.get_output_port_count():
			return from_node.get_output_port_color(int(wire["from_port"]))
	return fallback


func _ensure_wire_layer() -> Control:
	if is_instance_valid(_wire_layer):
		return _wire_layer
	if not is_instance_valid(_graph):
		return null
	var existing := _graph.get_node_or_null(NodePath(WIRE_LAYER_NAME)) as Control
	if existing != null:
		_wire_layer = existing
	else:
		_wire_layer = WIRE_LAYER.new()
		_wire_layer.name = WIRE_LAYER_NAME
		_graph.add_child(_wire_layer)
	_wire_layer.configure(_graph, FRAME_PREFIX, STUB_STEP, STUB_RADIUS)
	_place_wire_layer()
	return _wire_layer


## Put the wires in the band Godot draws its own in: after the frames, before the
## nodes.
##
## GraphEdit keeps its own children in that order -- every GraphFrame first, then
## _connection_layer holding a Line2D per connection, then every GraphNode -- and
## a child added afterwards lands at the very end, on top of the nodes. z_index
## cannot fix that: anything below the nodes' 0 is also below GraphEdit's own
## background, which is opaque.
##
## The anchor is the first GraphNode, not the connection layer, and that choice
## is what keeps this from oscillating. Moving to just before the first node
## leaves the layer at that index while the node it displaced moves to the next
## one, so the following pass finds nothing to do. Targeting the connection layer
## instead would swap the two back and forth forever -- GraphEdit re-asserts its
## own position for that layer on a deferred call -- and every move_child emits
## child_order_changed straight back into the apply loop.
func _place_wire_layer() -> void:
	if not is_instance_valid(_wire_layer) or _wire_layer.get_parent() != _graph:
		return
	var first_node := -1
	for i in _graph.get_child_count():
		if _graph.get_child(i) is GraphNode:
			first_node = i
			break
	# No nodes yet is not a problem to solve now: the next apply has them.
	if first_node < 0 or _wire_layer.get_index() <= first_node:
		return
	_graph.move_child(_wire_layer, first_node)


func _release_wire_layer() -> void:
	if not is_instance_valid(_wire_layer):
		_wire_layer = null
		return
	if is_instance_valid(_graph) and _wire_layer.get_parent() == _graph:
		_graph.remove_child(_wire_layer)
	_wire_layer.queue_free()
	_wire_layer = null
	_planned_wires.clear()


## Rebuild a port cache that was computed while the node was hidden.
##
## GraphNode fills its port caches only from children that are visible in tree,
## so hiding a node and then asking it for a port leaves both caches empty -- and
## nothing outside the set_slot* setters ever sets port_pos_dirty again, so the
## empty cache survives the node being shown. A member is never the output node,
## so it always has exactly one output port: a count of zero means stale.
##
## The setter early-returns on an unchanged value, so it takes a real toggle to
## mark the cache dirty. Writes only when the cache is actually broken, so an
## apply over healthy state still writes nothing.
func _repair_ports(node: GraphNode) -> void:
	# Asking a node in a hidden panel would compute the empty cache ourselves.
	if not _graph.is_visible_in_tree() or not node.is_visible_in_tree():
		return
	if node.get_output_port_count() > 0:
		return
	var was := node.is_slot_enabled_left(0)
	node.set_slot_enabled_left(0, not was)
	node.set_slot_enabled_left(0, was)

#endregion


#region The chevron

## The collapse toggle, and the only thing on a frame that is not inert.
##
## It has to live on the frame: once a group is collapsed its members are hidden,
## so a toolbar button driven by the selection could never expand it again.
func _apply_chevron(frame: GraphFrame, group: BlendTreeGroup) -> void:
	if not frame.has_method("get_titlebar_hbox"):
		return
	var bar: HBoxContainer = frame.get_titlebar_hbox()
	if bar == null:
		return
	# PASS, not STOP: the bar must be the mouse-focus holder so a drag keeps
	# receiving motion once the pointer leaves it, but anything the drag does not
	# accept_event() has to reach GraphEdit, or middle-drag panning and the
	# right-click menu would die over every title strip. mouse_filter is per
	# control, not inherited, so the chevron below is still hit first.
	if bar.mouse_filter != Control.MOUSE_FILTER_PASS:
		bar.mouse_filter = Control.MOUSE_FILTER_PASS
	_apply_titlebar_drag(bar, group)

	var button := bar.get_node_or_null(NodePath(CHEVRON_NAME)) as Button
	if button == null:
		button = Button.new()
		button.name = CHEVRON_NAME
		button.flat = true
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_filter = Control.MOUSE_FILTER_STOP
		# Bind the id, never the resource: a reloaded sidecar hands out new
		# BlendTreeGroup objects, and a button holding one would edit a ghost.
		button.pressed.connect(_on_chevron_pressed.bind(group.id))
		bar.add_child(button)
		bar.move_child(button, 0)

	var icon := _editor_icon("GuiTreeArrowRight" if group.collapsed else "GuiTreeArrowDown")
	if icon != null:
		if button.icon != icon:
			button.icon = icon
		if not button.text.is_empty():
			button.text = ""
	else:
		var glyph := "▸" if group.collapsed else "▾"
		if button.text != glyph:
			button.text = glyph
	var tip := "Expand this group." if group.collapsed else "Collapse this group."
	if button.tooltip_text != tip:
		button.tooltip_text = tip


## Make the title strip a drag handle: everything on it except the chevron stops
## taking the mouse, and the bar's own gui_input comes here.
##
## Connected once per bar, tracked with a meta flag rather than is_connected,
## because the connection carries a bound argument and Callable equality across
## binds is not something to rest a guarded write on.
func _apply_titlebar_drag(bar: HBoxContainer, group: BlendTreeGroup) -> void:
	for child in bar.get_children():
		var control := child as Control
		if control == null or String(control.name) == CHEVRON_NAME:
			continue
		# The title label especially: left as it is, the grabbable strip would be
		# only whatever is left over to the right of the text.
		if control.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			control.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if bar.has_meta(DRAG_META):
		return
	bar.set_meta(DRAG_META, group.id)
	bar.gui_input.connect(_on_titlebar_input.bind(group.id))


func _release_chevron(frame: GraphFrame) -> void:
	if not frame.has_method("get_titlebar_hbox"):
		return
	var bar: HBoxContainer = frame.get_titlebar_hbox()
	if bar == null:
		return
	# The bar is engine-owned and may carry connections that are not ours.
	for connection in bar.gui_input.get_connections():
		if connection["callable"].get_object() == self:
			bar.gui_input.disconnect(connection["callable"])
	bar.remove_meta(DRAG_META)

	var button := bar.get_node_or_null(NodePath(CHEVRON_NAME)) as Button
	if button == null:
		return
	# Disconnect rather than rely on the free: a queued press must not fire into
	# a half-torn-down overlay during teardown().
	for connection in button.pressed.get_connections():
		button.pressed.disconnect(connection["callable"])
	bar.remove_child(button)
	button.queue_free()


func _editor_icon(icon_name: String) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	return null


func _on_chevron_pressed(group_id: String) -> void:
	if _data == null or _sidecar_path.is_empty():
		return
	var group := _data.group_with_id(group_id)
	if group == null or group.tree_key != _tree_key:
		return

	if not group.collapsed:
		# Snapshot where the group actually is at the moment it collapses, so the
		# box lands on the footprint it replaces.
		var frame := _graph.get_node_or_null(NodePath(FRAME_PREFIX + group.id)) as GraphFrame
		var scale := EditorInterface.get_editor_scale()
		if frame != null and scale > 0.0:
			group.collapsed_position = frame.position_offset / scale
	group.collapsed = not group.collapsed
	_queue_save()
	_queue_apply()

#endregion


#region Resolving the displayed tree

## Which blend tree the graph is showing.
##
## Run on every apply rather than only when the selection changes: the panel's
## breadcrumb walks into nested resources without the plugin being told.
func _resolve_blend_tree() -> bool:
	var visible := _visible_node_names()
	if visible.is_empty():
		return false

	# The graph almost always still shows the tree it showed last apply, and
	# _candidate_trees walks and allocates over every nested tree in the scene.
	# Confirming the incumbent is a dictionary lookup per node.
	if _blend_tree != null and is_instance_valid(_blend_tree) and _data != null \
			and _names_match(_blend_tree, visible):
		return true

	for entry in _candidate_trees():
		var tree: AnimationNodeBlendTree = entry[1]
		if _names_match(tree, visible):
			_adopt(tree, String(entry[0]))
			return true

	if not _warned_tree:
		_warned_tree = true
		push_warning("Animation Group: could not tell which blend tree the editor is showing; "
			+ "groups are left as they are.")
	return false


## The names the graph is showing, as a set. A set rather than a list because
## _names_match runs it against every candidate tree on every apply, and 63 nodes
## through PackedStringArray.has() is four thousand string compares a time.
func _visible_node_names() -> Dictionary:
	var names := {}
	for child in _graph.get_children():
		if child is GraphNode:
			names[String(child.name)] = true
	return names


func _names_match(tree: AnimationNodeBlendTree, visible: Dictionary) -> bool:
	var listed := tree.get_node_list()
	if listed.size() != visible.size():
		return false
	for node_name in listed:
		if not visible.has(String(node_name)):
			return false
	return true


func _candidate_trees() -> Array:
	var found: Array = []
	if _animation_tree != null and is_instance_valid(_animation_tree):
		_collect_trees(_animation_tree.tree_root, "", found, 0)
	if not found.is_empty():
		return found

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null:
		for node in _animation_trees_in(scene_root):
			_collect_trees(node.tree_root, "", found, 0)
	return found


func _collect_trees(node: AnimationNode, key: String, found: Array, depth: int) -> void:
	if node == null or depth > MAX_TREE_DEPTH:
		return
	if node is AnimationNodeBlendTree:
		var tree := node as AnimationNodeBlendTree
		found.append([key, tree])
		for child_name in tree.get_node_list():
			_collect_trees(tree.get_node(child_name), _join(key, String(child_name)), found, depth + 1)
	elif node is AnimationNodeStateMachine:
		var machine := node as AnimationNodeStateMachine
		for state in machine.get_node_list():
			_collect_trees(machine.get_node(state), _join(key, String(state)), found, depth + 1)
	elif node is AnimationNodeBlendSpace1D:
		var space_1d := node as AnimationNodeBlendSpace1D
		for i in space_1d.get_blend_point_count():
			_collect_trees(space_1d.get_blend_point_node(i), _join(key, str(i)), found, depth + 1)
	elif node is AnimationNodeBlendSpace2D:
		var space_2d := node as AnimationNodeBlendSpace2D
		for i in space_2d.get_blend_point_count():
			_collect_trees(space_2d.get_blend_point_node(i), _join(key, str(i)), found, depth + 1)


func _animation_trees_in(root: Node) -> Array:
	var trees: Array = []
	if root is AnimationTree:
		trees.append(root)
	for node in root.find_children("*", "AnimationTree", true, false):
		trees.append(node)
	return trees


func _adopt(tree: AnimationNodeBlendTree, key: String) -> void:
	var path := ""
	var tree_key := key

	# A blend tree saved as its own file owns its sidecar outright; that is the
	# ordinary case. Anything nested hangs off the file that does own it, keyed by
	# where it sits, so two nested trees cannot collide.
	var own_path := tree.resource_path
	if not own_path.is_empty() and not own_path.contains("::"):
		path = BlendTreeGroupData.sidecar_path_for(own_path)
		tree_key = ""
	else:
		var context := _owner_context()
		if not String(context[0]).is_empty():
			path = BlendTreeGroupData.sidecar_path_for(String(context[0]))
			tree_key = _join(String(context[1]), key)

	if tree == _blend_tree and path == _sidecar_path and tree_key == _tree_key and _data != null:
		return
	# A different tree on screen means the picked ids name nothing here.
	_selected_group_ids.clear()
	_editing_group_id = ""
	_blend_tree = tree
	_sidecar_path = path
	_tree_key = tree_key
	_data = _load_data(path)


## The file a nested tree's sidecar hangs off, and the key prefix it needs.
func _owner_context() -> Array:
	if _animation_tree != null and is_instance_valid(_animation_tree):
		var root := _animation_tree.tree_root
		if root != null and not root.resource_path.is_empty() and not root.resource_path.contains("::"):
			return [root.resource_path, ""]
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null and not scene_root.scene_file_path.is_empty():
		var prefix := ""
		if _animation_tree != null and is_instance_valid(_animation_tree) \
				and scene_root.is_ancestor_of(_animation_tree):
			prefix = String(scene_root.get_path_to(_animation_tree))
		return [scene_root.scene_file_path, prefix]
	return ["", ""]


func _join(prefix: String, suffix: String) -> String:
	if prefix.is_empty():
		return suffix
	if suffix.is_empty():
		return prefix
	return "%s/%s" % [prefix, suffix]

#endregion


#region Sidecar

func _load_data(path: String) -> BlendTreeGroupData:
	if not path.is_empty() and ResourceLoader.exists(path):
		var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
		if loaded is BlendTreeGroupData:
			# A hand-edited or older sidecar can name a parent that is gone, or
			# close a loop. Repairing on load means every walk below can trust
			# the forest, and it doubles as the format 1 -> 2 upgrade.
			(loaded as BlendTreeGroupData).repair_parents()
			return loaded
		push_warning("Animation Group: %s is not group data; ignoring it." % path)
	return BlendTreeGroupData.new()


## Save on the next idle frame.
##
## The chevron is a click target people drum on, and every save is a
## ResourceSaver.save plus a filesystem rescan. The five toolbar commands call
## _save() directly; they cannot be spammed the same way.
func _queue_save() -> void:
	if _save_queued:
		return
	_save_queued = true
	_deferred_save.call_deferred()


func _deferred_save() -> void:
	_save_queued = false
	_save()


func _save() -> void:
	if _data == null or _sidecar_path.is_empty():
		return
	_data.format_version = BlendTreeGroupData.FORMAT_VERSION
	var error := ResourceSaver.save(_data, _sidecar_path)
	if error != OK:
		push_warning("Animation Group: could not write %s (error %d)." % [_sidecar_path, error])
		return
	_data.take_over_path(_sidecar_path)
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem != null:
		filesystem.update_file(_sidecar_path)

#endregion


#region Commands

func _on_command(id: StringName) -> void:
	if _blend_tree == null or _data == null or _sidecar_path.is_empty():
		return
	match id:
		&"group":
			_group_selection()
		&"ungroup":
			_ungroup_selection()
		&"edit":
			_edit_selection()
		&"tidy":
			_tidy_selection()


## Group the selection, nesting it when the selection is already inside a group.
##
## There is no nest button: selecting nodes that all sit in one group and
## pressing Group puts a group inside that one, and any other selection makes a
## top-level group exactly as it always did. add_group() does the rest -- the new
## child takes the nodes out of the parent, and the parent keeps whatever was not
## selected.
func _group_selection() -> void:
	# A picked group wins: it is the only way to reach a collapsed one, whose
	# members are hidden and so invisible to the node selection.
	var picked := _selected_groups()
	if not picked.is_empty():
		_wrap_groups(picked)
		return

	var names := _selected_names()
	if names.is_empty():
		return
	var parent := _enclosing_group(names)
	if parent != null and _data.depth_of(parent) + 1 >= BlendTreeGroupData.MAX_DEPTH:
		push_warning("Animation Group: groups are already nested %d deep; not nesting further."
			% BlendTreeGroupData.MAX_DEPTH)
		return

	var group := BlendTreeGroup.make(_default_title(names), names, _next_tint(parent), _tree_key)
	if parent != null:
		group.parent_id = parent.id
	_data.add_group(group)
	_data.repair_parents()
	_save()
	_queue_apply()



## Put a new group around the ones that are selected.
##
## The wrapper joins the parent they already share, so wrapping Sword A and
## Sword B leaves both inside Sword; a selection spanning different parents has
## no shared home, and the wrapper goes to the top level.
func _wrap_groups(picked: Array[BlendTreeGroup]) -> void:
	var index := _data.build_index(_tree_key)

	# Wrapping pushes the whole subtree down a level, so the group that decides
	# whether it fits is the innermost descendant, not the one that was clicked.
	var deepest := -1
	for group in picked:
		deepest = maxi(deepest, _data.deepest_depth_of(group, index))
	if deepest + 1 >= BlendTreeGroupData.MAX_DEPTH:
		push_warning("Animation Group: groups are already nested %d deep; not wrapping further."
			% BlendTreeGroupData.MAX_DEPTH)
		return

	var parent_ids := PackedStringArray()
	var titles := PackedStringArray()
	for group in picked:
		var parent := _data.parent_of(group, index)
		parent_ids.append("" if parent == null else parent.id)
		titles.append(group.title)
	var parent_id: String = LAYOUT.shared_parent(parent_ids)
	var shared: BlendTreeGroup = _data.group_with_id(parent_id)

	var wrapper := BlendTreeGroup.make(
		LAYOUT.wrapper_title(titles), PackedStringArray(), _next_tint(shared), _tree_key)
	wrapper.parent_id = parent_id
	# Appended directly rather than through add_group(), which ends in
	# _drop_empty() -- and a wrapper with no members and, for one more line, no
	# children is exactly what that discards.
	_data.groups.append(wrapper)
	for group in picked:
		_data.set_parent(group, wrapper)
	_data.repair_parents()

	# The new group is what you just made, so it is what stays selected.
	_selected_group_ids = PackedStringArray([wrapper.id])
	_save()
	_queue_apply()


## The one group every selected node already belongs to, or null.
func _enclosing_group(names: PackedStringArray) -> BlendTreeGroup:
	var groups := _groups_of(names)
	if groups.size() != 1:
		return null
	# _groups_of skips names that belong to nothing, so an ungrouped node in the
	# selection has to be caught here or it would nest by accident.
	for node_name in names:
		if _data.group_containing(_tree_key, node_name) == null:
			return null
	return groups[0]


func _ungroup_selection() -> void:
	var groups := _selected_groups()
	if groups.is_empty():
		groups = _groups_of(_selected_names())
	else:
		_selected_group_ids.clear()
	if groups.is_empty():
		return
	# Deepest first, so an inner group merges into its parent before that parent
	# is itself considered. Any other order answers differently when the
	# selection straddles a group and its child.
	groups.sort_custom(func(a, b): return _data.depth_of(a) > _data.depth_of(b))
	for group in groups:
		_data.remove_group(group)
	_data.repair_parents()
	_save()
	_queue_apply()


func _edit_selection() -> void:
	var group := _single_group()
	if group == null:
		return
	# Remembered, because the dialog is modal and _on_edit_applied used to work
	# the selection out again after it closed -- which quietly renamed nothing if
	# anything had moved the selection in between.
	_editing_group_id = group.id
	_dialog.popup(group.title, group.tint)


func _on_edit_applied(title: String, tint: Color) -> void:
	var group := _data.group_with_id(_editing_group_id) if _data != null else null
	if group != null and group.tree_key != _tree_key:
		group = null
	if group == null:
		group = _single_group()
	if group == null:
		return
	if not title.is_empty():
		group.title = title
	group.tint = tint
	_save()
	_queue_apply()


## Lay a group's members out where they already are, only in order.
##
## The column is used whenever the whole group feeds one transition, which is
## every attack band: the transition lays its ports out top to bottom in input
## order, so a monotonic column keeps every edge horizontal and traceable. The
## grid is for groups with no ports to stay level with.
func _tidy_selection() -> void:
	var group := _single_group()
	if group == null:
		return

	var members := PackedStringArray()
	for member in group.members:
		if _blend_tree.has_node(StringName(member)):
			members.append(member)
	if members.size() < 2:
		return

	var current := {}
	for member in members:
		current[member] = _blend_tree.get_node_position(StringName(member))
	var origin: Vector2 = LAYOUT.bounding_origin(current)

	# A group that holds child groups does not own the rectangle they sit in, so
	# its own column goes beside them rather than straight through them.
	var occupied := _descendant_member_positions(group)
	if not occupied.is_empty():
		origin = LAYOUT.place_beside(LAYOUT.bounding_rect(occupied), NESTED_TIDY_GAP)

	var positions := {}
	var transition: AnimationNodeTransition = LAYOUT.owning_transition(members, _blend_tree)
	if transition != null:
		var ordered: PackedStringArray = LAYOUT.sorted_by_order(
			members, LAYOUT.transition_order(members, transition))
		positions = LAYOUT.tidy_column(ordered, origin, _row_step(members))
	else:
		positions = LAYOUT.tidy_grid(
			members, origin, LAYOUT.default_columns(members.size()), _cell(members))

	# The same call the built-in editor makes when a node is dragged: same undo
	# manager, same bound method, same custom context, so a tidy persists and
	# undoes exactly like a drag does.
	var undo := _plugin.get_undo_redo()
	undo.create_action("Tidy animation group", UndoRedo.MERGE_DISABLE, _blend_tree)
	for member in positions:
		undo.add_do_method(_blend_tree, "set_node_position", StringName(member), positions[member])
		undo.add_undo_method(_blend_tree, "set_node_position", StringName(member), current[member])

	# set_node_position emits nothing at all -- not changed, not tree_changed --
	# so neither editor notices the move on its own, and EditorUndoRedoManager's
	# version_changed does not fire either. The refresh is therefore part of the
	# action: it runs on the do, the undo and the redo, and since it only queues a
	# deferred apply it lands after the positions have been written either way.
	undo.add_do_method(_plugin, "refresh_group_positions")
	undo.add_undo_method(_plugin, "refresh_group_positions")
	undo.commit_action()


## Where every node inside this group's child groups currently sits.
func _descendant_member_positions(group: BlendTreeGroup) -> Dictionary:
	var positions := {}
	for descendant in _data.descendants_of(group):
		for member in descendant.members:
			if _blend_tree.has_node(StringName(member)):
				positions[member] = _blend_tree.get_node_position(StringName(member))
	return positions


#endregion


#region Group selection

## Pick a group by clicking its title bar.
##
## The only way to reach a collapsed group at all: everything inside it is
## hidden, so _selected_names() -- which walks GraphNodes -- can never see it,
## and Rename and Group were unreachable for exactly the groups most in need of
## them.
func _select_group(group_id: String, additive: bool) -> void:
	if _data == null or group_id.is_empty():
		return
	var group := _data.group_with_id(group_id)
	if group == null or group.tree_key != _tree_key:
		return

	var was := _selected_group_ids.duplicate()
	var index := _selected_group_ids.find(group_id)
	if additive:
		if index == -1:
			_selected_group_ids.append(group_id)
		else:
			_selected_group_ids.remove_at(index)
	elif _selected_group_ids.size() == 1 and index == 0:
		# Clicking the one selected group again lets go of it, so there is a way
		# back to an empty selection without hunting for blank canvas.
		_selected_group_ids.clear()
	else:
		_selected_group_ids = PackedStringArray([group_id])

	# One selection model live at a time, or the toolbar could not say what it
	# would act on.
	if not _selected_group_ids.is_empty():
		_deselect_nodes()
	if was != _selected_group_ids:
		_queue_apply()
	_update_buttons()


func _deselect_nodes() -> void:
	if not is_instance_valid(_graph):
		return
	for child in _graph.get_children():
		if child is GraphNode and (child as GraphNode).selected:
			(child as GraphNode).selected = false


## Drop the group selection, and say whether it held anything.
func _clear_group_selection() -> bool:
	if _selected_group_ids.is_empty():
		return false
	_selected_group_ids.clear()
	_queue_apply()
	return true


## The selected groups that still exist in the tree on screen.
##
## Ids that name nothing are dropped as they are found, which is what keeps a
## selection from surviving an Ungroup or a reload of the sidecar.
func _selected_groups() -> Array[BlendTreeGroup]:
	var found: Array[BlendTreeGroup] = []
	if _data == null:
		return found
	var alive := PackedStringArray()
	for id in _selected_group_ids:
		var group := _data.group_with_id(id)
		if group != null and group.tree_key == _tree_key:
			found.append(group)
			alive.append(id)
	if alive != _selected_group_ids:
		_selected_group_ids = alive
	return found


func _is_selected(group: BlendTreeGroup) -> bool:
	return group != null and _selected_group_ids.has(group.id)

#endregion


#region Selection helpers

func _selected_names() -> PackedStringArray:
	var names := PackedStringArray()
	if not is_instance_valid(_graph) or _blend_tree == null:
		return names
	var valid := _blend_tree.get_node_list()
	for child in _graph.get_children():
		if child is GraphNode and (child as GraphNode).selected:
			var node_name := String(child.name)
			if node_name != OUTPUT_NODE and valid.has(node_name):
				names.append(node_name)
	return names


func _groups_of(names: PackedStringArray) -> Array[BlendTreeGroup]:
	var groups: Array[BlendTreeGroup] = []
	if _data == null:
		return groups
	for node_name in names:
		var group := _data.group_containing(_tree_key, node_name)
		if group != null and not groups.has(group):
			groups.append(group)
	return groups


## The one group a command should act on.
##
## An explicitly picked group wins over whatever the node selection implies, so
## Rename and Tidy follow the title bar you clicked. Falling through to the node
## selection is what keeps every existing gesture working unchanged.
func _single_group() -> BlendTreeGroup:
	var picked := _selected_groups()
	if picked.size() == 1:
		return picked[0]
	if not picked.is_empty():
		return null
	var groups := _groups_of(_selected_names())
	return groups[0] if groups.size() == 1 else null


func _group_titled(title: String) -> BlendTreeGroup:
	# Root groups only: a nested group that happens to share a band title must
	# not absorb a root group and stay nested.
	for group in _data.root_groups(_tree_key):
		if group.title == title:
			return group
	return null


## A title from whatever the selected names have in common, so the usual case
## needs no rename at all.
func _default_title(names: PackedStringArray) -> String:
	var prefix := names[0].get_slice("_", 0)
	for node_name in names:
		if node_name.get_slice("_", 0) != prefix:
			return "Group"
	return prefix.capitalize()


## The tint a new group should take. Scan rather than indexing by group count so
## a nested group cannot inherit its parent's exact colour after reordering or
## palette wraparound. Existing hand-picked colours remain unchanged.
func _next_tint(parent: BlendTreeGroup = null) -> Color:
	var used: Array[Color] = []
	for group in _data.groups_for(_tree_key):
		if parent != null and group.parent_id != parent.id:
			continue
		used.append(group.tint)
	var start := used.size() % PALETTE.size()
	for offset in PALETTE.size():
		var candidate: Color = PALETTE[(start + offset) % PALETTE.size()]
		var taken := false
		for tint in used:
			if candidate.is_equal_approx(tint):
				taken = true
				break
		if not taken and (parent == null or not candidate.is_equal_approx(parent.tint)):
			return candidate
	return PALETTE[start]


func _row_step(members: PackedStringArray) -> float:
	return maxf(MIN_ROW_STEP, _member_extent(members).y + ROW_PADDING)


func _cell(members: PackedStringArray) -> Vector2:
	return _member_extent(members) + CELL_PADDING


## The largest member's size in blend tree units.
##
## GraphNode sizes come from the editor theme, so they carry the editor scale;
## node positions in the resource do not. Dividing here is what keeps a tidy from
## spacing nodes out further on a HiDPI display than on a 100% one.
func _member_extent(members: PackedStringArray) -> Vector2:
	var extent := Vector2.ZERO
	for member in members:
		var node := _graph.get_node_or_null(NodePath(member)) as GraphNode
		if node != null:
			extent = extent.max(node.size)
	var scale := EditorInterface.get_editor_scale()
	if scale > 0.0:
		extent /= scale
	return extent


func _update_buttons() -> void:
	if _toolbar == null or not _toolbar.has_buttons():
		return
	var has_target := _blend_tree != null and not _sidecar_path.is_empty()
	var tip := "" if has_target else NO_TARGET_TIP
	var selection := _selected_names()
	var picked := _selected_groups() if has_target else ([] as Array[BlendTreeGroup])
	var groups := picked if not picked.is_empty() else _groups_of(selection)
	var single := has_target and _single_group() != null

	# Whether Group would nest, and how deep that would land. A picked group is
	# wrapped, which pushes its deepest descendant down; a node selection nests
	# inside the group that holds it.
	var deepest := -1
	var can_group := false
	if has_target and not picked.is_empty():
		var index := _data.build_index(_tree_key)
		for group in picked:
			deepest = maxi(deepest, _data.deepest_depth_of(group, index))
		can_group = true
	elif has_target and not selection.is_empty():
		var parent := _enclosing_group(selection)
		deepest = -1 if parent == null else _data.depth_of(parent)
		can_group = true
	var too_deep := deepest + 1 >= BlendTreeGroupData.MAX_DEPTH
	var group_tip := tip
	if has_target and too_deep:
		group_tip = "Groups are already nested as deep as they go."

	_toolbar.set_enabled(&"group", can_group and not too_deep, group_tip)
	_toolbar.set_enabled(&"ungroup", has_target and not groups.is_empty(), tip)
	_toolbar.set_enabled(&"edit", single, tip)
	_toolbar.set_enabled(&"tidy", single, tip)

#endregion


#region Moving a group

## The title bar is the handle: press it and the whole group follows the mouse.
##
## The drag is implemented here rather than by re-enabling GraphFrame.draggable
## because an element GraphEdit can drag is an element GraphEdit can select, and
## a selected frame goes to the built-in delete handler, which would call
## remove_node() on a name the blend tree has never heard of. Doing it by hand
## also keeps the frame's interior free for box-selecting the nodes inside it.
func _on_titlebar_input(event: InputEvent, group_id: String) -> void:
	var bar := _titlebar_of(group_id)
	if bar == null:
		return

	var press := event as InputEventMouseButton
	if press != null and press.button_index == MOUSE_BUTTON_LEFT:
		if press.pressed:
			# Read the modifiers at press time: the release event that decides a
			# click has its own, and a user who lets go of Ctrl first would
			# otherwise have their multi-select turn into a plain one.
			_drag_additive = press.ctrl_pressed or press.shift_pressed
			if _begin_drag(group_id, press.global_position):
				bar.accept_event()
		elif _dragging:
			_drive_drag(press.global_position)
			_finish_drag()
			bar.accept_event()
		return

	var motion := event as InputEventMouseMotion
	if motion != null and _dragging:
		# The release can be lost -- a focus change, the mouse leaving the
		# window. A motion with the button no longer held says so from the event
		# alone, which is why nothing here asks the Input singleton: it would
		# also make the whole path untestable, since push_input does not update
		# it.
		_drive_drag(motion.global_position)
		if (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_finish_drag()
		bar.accept_event()
		return

	# Right-click puts it back. Escape cannot be caught here: a title bar never
	# holds keyboard focus, so key events do not reach its gui_input.
	if _dragging and press != null and press.pressed and press.button_index == MOUSE_BUTTON_RIGHT:
		_cancel_drag()
		bar.accept_event()


func _titlebar_of(group_id: String) -> HBoxContainer:
	if not is_instance_valid(_graph):
		return null
	var frame := _graph.get_node_or_null(NodePath(FRAME_PREFIX + group_id)) as GraphFrame
	if frame == null or not frame.has_method("get_titlebar_hbox"):
		return null
	return frame.get_titlebar_hbox()


## Graph-offset coordinate of a point given in viewport-global pixels.
##
## Taken from the event rather than from get_local_mouse_position(), so the whole
## gesture is a pure function of the events it received.
func _graph_offset_of(global_point: Vector2) -> Vector2:
	var local: Vector2 = _graph.get_global_transform().affine_inverse() * global_point
	return LAYOUT.graph_offset_of(local, _graph.scroll_offset, _graph.zoom)


func _graph_local_of(global_point: Vector2) -> Vector2:
	return _graph.get_global_transform().affine_inverse() * global_point


## Snapshot everything the gesture may move. Refuses, leaving the press to
## GraphEdit, on the same grounds _on_chevron_pressed refuses.
func _begin_drag(group_id: String, global_point: Vector2) -> bool:
	if _dragging or _blend_tree == null or _data == null or _sidecar_path.is_empty():
		return false
	var group := _data.group_with_id(group_id)
	if group == null or group.tree_key != _tree_key:
		return false
	var frame := _graph.get_node_or_null(NodePath(FRAME_PREFIX + group_id)) as GraphFrame
	if frame == null or not frame.visible:
		return false

	_drag_group_id = group_id
	_drag_delta = Vector2.ZERO
	_drag_moved = false
	_drag_press_local = _graph_local_of(global_point)
	_drag_origin = _graph_offset_of(global_point)
	_drag_member_offsets.clear()
	_drag_member_positions.clear()
	_drag_box_offsets.clear()
	_drag_box_positions.clear()

	# The whole subtree: a group holds its nested groups' nodes as surely as its
	# own, and a member hidden inside a collapsed child moves with everything
	# else so expanding it later shows the group where it was put.
	for member in _data.subtree_members(group):
		if not _blend_tree.has_node(StringName(member)):
			continue
		_drag_member_positions[member] = _blend_tree.get_node_position(StringName(member))
		var node := _graph.get_node_or_null(NodePath(member)) as GraphNode
		if node != null:
			_drag_member_offsets[member] = node.position_offset

	for inside in _data.subtree_of(group):
		if not inside.collapsed:
			continue
		_drag_box_positions[inside.id] = inside.collapsed_position
		var box := _graph.get_node_or_null(NodePath(FRAME_PREFIX + inside.id)) as GraphFrame
		if box != null:
			_drag_box_offsets[inside.id] = box.position_offset

	_dragging = true
	return true


func _drive_drag(global_point: Vector2) -> void:
	if not _dragging or not is_instance_valid(_graph):
		return
	var local := _graph_local_of(global_point)
	if not _drag_moved and LAYOUT.is_drag(_drag_press_local, local, DRAG_THRESHOLD):
		_drag_moved = true

	var raw := _graph_offset_of(global_point) - _drag_origin
	var delta := LAYOUT.snapped_delta(raw, _graph.snapping_enabled,
		float(_graph.snapping_distance))
	if delta.is_equal_approx(_drag_delta):
		return
	_drag_delta = delta
	_update_drag()


## Put every moving element at snapshot + delta.
##
## Uniform over visible and hidden members on purpose: a member parked on a
## collapsed ancestor's box was snapshotted at that anchor, and the anchor moves
## by the same delta, so the wires stay converged on the box for the whole
## gesture rather than trailing behind it.
func _update_drag() -> void:
	for member in _drag_member_offsets:
		var node := _graph.get_node_or_null(NodePath(String(member))) as GraphNode
		if node == null:
			continue
		var wanted: Vector2 = _drag_member_offsets[member] + _drag_delta
		if not node.position_offset.is_equal_approx(wanted):
			node.position_offset = wanted

	var scale := EditorInterface.get_editor_scale()
	var moved_boxes: Array[BlendTreeGroup] = []
	for id in _drag_box_offsets:
		var box := _graph.get_node_or_null(NodePath(FRAME_PREFIX + String(id))) as GraphFrame
		if box == null:
			continue
		var wanted_box: Vector2 = _drag_box_offsets[id] + _drag_delta
		var group := _data.group_with_id(String(id))
		if not box.position_offset.is_equal_approx(wanted_box):
			box.position_offset = wanted_box
			if group != null:
				moved_boxes.append(group)
		# Kept in step live, so _apply_frame's collapsed branch and
		# _on_frame_rect_changed both find the box already where they want it.
		if group != null and scale > 0.0:
			group.collapsed_position = wanted_box / scale

	# A moved box tells nobody, so the groups around it are told here.
	#
	# The same hole _rewrap_ancestors exists for: item_rect_changed is wired to
	# _graph_node_rect_changed for GraphNode only, so dragging a member re-wraps
	# every frame around it and dragging a collapsed box re-wraps nothing at all.
	# Measured: dragging collapsed Sword A left Sword 161px too tall, and a
	# three-deep Stinger ended up drawn outside Specials entirely.
	#
	# After the loop rather than inside it: _update_graph_frame recomputes a frame
	# from every element attached to it, so one pass over the final positions is
	# both cheaper and more correct than one per box.
	for group in moved_boxes:
		_rewrap_ancestors(group)


func _finish_drag() -> void:
	if not _dragging:
		return
	# A press that never travelled, or one dragged out and back to zero, writes
	# nothing at all: no undo action, no sidecar save, no resource touch.
	if _drag_moved and _drag_delta != Vector2.ZERO:
		_commit_drag()
	else:
		# A press that never travelled is a click on the title bar, and the only
		# way to reach a collapsed group: its members are hidden, so there is
		# nothing for the node based selection to get hold of.
		_restore_drag()
		_select_group(_drag_group_id, _drag_additive)
	_end_drag()


func _cancel_drag() -> void:
	if not _dragging:
		return
	_restore_drag()
	_end_drag()


func _restore_drag() -> void:
	_drag_delta = Vector2.ZERO
	_update_drag()
	if _data == null:
		return
	for id in _drag_box_positions:
		var group := _data.group_with_id(String(id))
		if group != null:
			group.collapsed_position = _drag_box_positions[id]


func _end_drag() -> void:
	_dragging = false
	_drag_group_id = ""
	_drag_delta = Vector2.ZERO
	_drag_moved = false
	_drag_member_offsets.clear()
	_drag_member_positions.clear()
	_drag_box_offsets.clear()
	_drag_box_positions.clear()
	# Every apply the gesture asked for, folded into one.
	if _apply_after_drag:
		_apply_after_drag = false
		_queue_apply()


## One undo action for the whole gesture, built exactly as _tidy_selection's is:
## same manager, same MERGE_DISABLE, same _blend_tree context, so a move sits in
## the blend tree's history and reverses like a node drag.
func _commit_drag() -> void:
	var delta: Vector2 = LAYOUT.to_resource_delta(_drag_delta, EditorInterface.get_editor_scale())
	var undo := _plugin.get_undo_redo()
	undo.create_action("Move animation group", UndoRedo.MERGE_DISABLE, _blend_tree)
	for member in _drag_member_positions:
		if not _blend_tree.has_node(StringName(member)):
			continue
		var was: Vector2 = _drag_member_positions[member]
		undo.add_do_method(_blend_tree, "set_node_position", StringName(member), was + delta)
		undo.add_undo_method(_blend_tree, "set_node_position", StringName(member), was)

	# The boxes go with the nodes. Collapse, title and tint stay outside the undo
	# history because nothing in the blend tree depends on them -- but a move
	# writes node positions, so Ctrl+Z has to reverse all of it, or undoing a
	# dragged collapsed group would leave its box adrift from the members it is
	# hiding and look like it had done nothing at all.
	if not _drag_box_positions.is_empty():
		undo.add_do_method(_plugin, "set_group_collapsed_positions",
			LAYOUT.shifted(_drag_box_positions, delta))
		undo.add_undo_method(_plugin, "set_group_collapsed_positions",
			_drag_box_positions.duplicate())

	# set_node_position emits nothing at all, so the refresh is part of the
	# action -- the same reason it is part of the tidy's.
	undo.add_do_method(_plugin, "refresh_group_positions")
	undo.add_undo_method(_plugin, "refresh_group_positions")
	undo.commit_action()
	_queue_save()


## Called from the move undo action. Writes only collapsed_position, only for
## groups of the tree on screen, and only where it differs -- so the do pass at
## commit time, which the live drag has already applied, costs nothing.
func apply_collapsed_positions(positions: Dictionary) -> void:
	if _data == null:
		return
	var changed := false
	for id in positions:
		var group := _data.group_with_id(String(id))
		if group == null or group.tree_key != _tree_key:
			continue
		if group.collapsed_position.is_equal_approx(positions[id]):
			continue
		group.collapsed_position = positions[id]
		changed = true
	if changed:
		_queue_save()
		_queue_apply()

#endregion
