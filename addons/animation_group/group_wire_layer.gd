@tool
extends Control

## Draws the wires a collapsed group swallowed.
##
## Collapsing takes every connection with a hidden end out of the GraphEdit --
## see _apply_connections in group_overlay.gd for why it has to. The ones that
## crossed the group's boundary are still true, though, so they are drawn here
## instead: from a stub on the box's right edge for a wire leaving the group, to
## a stub on its left edge for one arriving.
##
## Deliberately not a GraphElement. GraphEdit only transforms, selects, deletes
## and reorders those, so a plain Control sits still at the top-left of the graph
## and applies the same transform by hand.
##
## z_index stays at 0. A negative z_index sorts a CanvasItem behind its own
## parent's drawing, and GraphEdit paints an opaque panel there -- so z_index -1
## drew all of this perfectly, underneath the background, where nobody could see
## it. Draw order is settled by tree position instead, in _place_wire_layer.

const LAYOUT := preload("res://addons/animation_group/group_layout.gd")

## The specs handed over by the overlay. Positions are resolved live rather than
## stored, so a pan, a zoom, a node drag and a group drag all track without the
## overlay having to re-apply.
var _wires: Array = []
var _graph: GraphEdit
var _frame_prefix := ""
var _stub_step := 22.0
var _stub_radius := 4.0

## Last frame's resolved geometry, in screen pixels. Comparing against it is what
## keeps an idle editor from redrawing.
var _lines: Array = []
var _nubs: Array = []

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_process(true)


func configure(graph: GraphEdit, frame_prefix: String, stub_step: float,
		stub_radius: float) -> void:
	_graph = graph
	_frame_prefix = frame_prefix
	_stub_step = stub_step
	_stub_radius = stub_radius


func set_wires(wires: Array) -> void:
	_wires = wires
	_refresh()

func wire_count() -> int:
	return _wires.size()


## Re-resolve, and redraw only if anything actually moved.
##
## Polling rather than a signal: scroll_offset_changed fires only for user
## scrolls, there is no zoom signal at all, and the far end of a wire moves
## whenever someone drags an ordinary node. The work is a couple of dozen node
## lookups, and it stops at the comparison when nothing has changed.
func _process(_delta: float) -> void:
	if _wires.is_empty() or not is_visible_in_tree():
		return
	_refresh()


func _refresh() -> void:
	var lines: Array = []
	var nubs: Array = []
	if is_instance_valid(_graph):
		var zoom: float = _graph.zoom
		var scroll: Vector2 = _graph.scroll_offset
		for wire in _wires:
			var from_point := _end_point(wire, true)
			var to_point := _end_point(wire, false)
			if from_point == null or to_point == null:
				continue
			var from_screen: Vector2 = (from_point as Vector2) * zoom - scroll
			var to_screen: Vector2 = (to_point as Vector2) * zoom - scroll
			lines.append([_graph.get_connection_line(from_screen, to_screen), wire["color"]])
			if not String(wire["from_box"]).is_empty():
				nubs.append([from_screen, wire["color"]])
			if not String(wire["to_box"]).is_empty():
				nubs.append([to_screen, wire["color"]])

	if lines == _lines and nubs == _nubs:
		return
	_lines = lines
	_nubs = nubs
	queue_redraw()


## Where one end of a wire sits, in the unzoomed graph space position_offset uses.
##
## Null when the element is gone -- a node freed underneath us drops its wire for
## the frame rather than drawing it to the origin, which is the very bug this
## whole layer exists to fix.
func _end_point(wire: Dictionary, from_side: bool) -> Variant:
	var box_id := String(wire["from_box"] if from_side else wire["to_box"])
	if box_id.is_empty():
		var node_name := String(wire["from_node"] if from_side else wire["to_node"])
		var node := _graph.get_node_or_null(NodePath(node_name)) as GraphNode
		if node == null or not node.visible:
			return null
		# The same expression GraphEdit resolves its own connections with, so our
		# wires land on the pixels the native ones would have.
		var port := int(wire["from_port"] if from_side else wire["to_port"])
		if from_side:
			if port >= node.get_output_port_count():
				return null
			return node.position_offset + node.get_output_port_position(port)
		if port >= node.get_input_port_count():
			return null
		return node.position_offset + node.get_input_port_position(port)

	var frame := _graph.get_node_or_null(NodePath(_frame_prefix + box_id)) as GraphFrame
	if frame == null or not frame.visible:
		return null
	# The same helper _apply_frame sizes the box with, so the bottom stub is
	# guaranteed to land inside it.
	return LAYOUT.stub_point(frame.position_offset, frame.size,
		frame.get_combined_minimum_size().y, int(wire["from_stub"] if from_side else wire["to_stub"]),
		_stub_step * EditorInterface.get_editor_scale(), from_side)


func _draw() -> void:
	if not is_instance_valid(_graph):
		return
	var zoom: float = _graph.zoom
	var width: float = _graph.connection_lines_thickness * zoom
	var antialiased: bool = _graph.connection_lines_antialiased
	for line in _lines:
		var points: PackedVector2Array = line[0]
		if points.size() > 1:
			draw_polyline(points, line[1], width, antialiased)
	for nub in _nubs:
		draw_circle(nub[0], _stub_radius * zoom, nub[1], true, -1.0, antialiased)
