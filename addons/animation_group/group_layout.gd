extends RefCounted

## Pure layout maths for the Tidy command.
##
## No editor types are referenced here, so this file loads and runs in a
## headless test run -- which is what makes the one rule that matters testable
## (see tidy_column below).


## Rows in a single column, y strictly increasing in the order given.
##
## This is the shape a transition-driven group should keep. GraphEdit draws connections
## underneath nodes, so a second column's edges pass behind the first column and
## stop being traceable; vertical transition order is load-bearing. Tidy compacts
## the column instead of breaking it without relying on project-specific gaps.
static func tidy_column(ordered: PackedStringArray, origin: Vector2, row_step: float) -> Dictionary:
	var positions := {}
	for i in ordered.size():
		positions[ordered[i]] = Vector2(origin.x, origin.y + i * row_step)
	return positions


## Row-major grid. For groups whose members do not all feed one transition, so
## there are no ports to stay level with.
static func tidy_grid(ordered: PackedStringArray, origin: Vector2, columns: int,
		cell: Vector2) -> Dictionary:
	var positions := {}
	var column_count := maxi(1, columns)
	for i in ordered.size():
		var column := i % column_count
		var row := i / column_count
		positions[ordered[i]] = origin + Vector2(column * cell.x, row * cell.y)
	return positions


## As square as the count allows: 24 clips -> 5 columns.
static func default_columns(count: int) -> int:
	if count <= 1:
		return 1
	return maxi(1, int(ceil(sqrt(float(count)))))


## Input index on the transition for each member, -1 when it is not an input.
static func transition_order(members: PackedStringArray,
		transition: AnimationNodeTransition) -> Dictionary:
	var order := {}
	for member in members:
		order[member] = -1
	if transition == null:
		return order
	for i in transition.get_input_count():
		var input_name := String(transition.get_input_name(i))
		if order.has(input_name):
			order[input_name] = i
	return order


## Members in input order. Anything that is not an input keeps its relative
## order and goes last, so a stray member cannot reshuffle the ports.
static func sorted_by_order(members: PackedStringArray, order: Dictionary) -> PackedStringArray:
	var indexed: Array = []
	var trailing := PackedStringArray()
	for member in members:
		var index: int = order.get(member, -1)
		if index < 0:
			trailing.append(member)
		else:
			indexed.append([index, member])
	indexed.sort_custom(func(a, b): return a[0] < b[0])

	var sorted := PackedStringArray()
	for entry in indexed:
		sorted.append(entry[1])
	sorted.append_array(trailing)
	return sorted


## Top-left corner of a set of positions, so a tidy compacts in place instead of
## teleporting the group somewhere else on the canvas.
static func bounding_origin(positions: Dictionary) -> Vector2:
	var origin := Vector2.ZERO
	var first := true
	for key in positions:
		var position: Vector2 = positions[key]
		if first:
			origin = position
			first = false
		else:
			origin.x = minf(origin.x, position.x)
			origin.y = minf(origin.y, position.y)
	return origin


## Every AnimationNodeTransition in a blend tree, node name -> node.
##
## Tidy picks the column layout only when a whole group feeds one of these, so
## it needs to see all of them rather than assume the one named "Attacks".
static func transitions_of(blend_tree: AnimationNodeBlendTree) -> Dictionary:
	var found := {}
	if blend_tree == null:
		return found
	for node_name in blend_tree.get_node_list():
		var node := blend_tree.get_node(node_name)
		if node is AnimationNodeTransition:
			found[String(node_name)] = node
	return found


## The transition a whole group feeds, or null when its members are spread
## across several -- or across none, which is the ordinary case for the
## structural blend nodes.
static func owning_transition(members: PackedStringArray,
		blend_tree: AnimationNodeBlendTree) -> AnimationNodeTransition:
	if members.is_empty():
		return null
	var transitions := transitions_of(blend_tree)
	for node_name in transitions:
		var transition: AnimationNodeTransition = transitions[node_name]
		var order := transition_order(members, transition)
		var complete := true
		for member in members:
			if int(order.get(member, -1)) < 0:
				complete = false
				break
		if complete:
			return transition
	return null


## Bounding box of a set of positions. bounding_origin is its top-left corner,
## and the two must always agree -- a test pins that.
static func bounding_rect(positions: Dictionary) -> Rect2:
	if positions.is_empty():
		return Rect2()
	var origin := bounding_origin(positions)
	var far := origin
	for key in positions:
		var position: Vector2 = positions[key]
		far.x = maxf(far.x, position.x)
		far.y = maxf(far.y, position.y)
	return Rect2(origin, far - origin)


## Where to start a column that must not run through an occupied rectangle.
static func place_beside(rect: Rect2, gap: float) -> Vector2:
	return Vector2(rect.end.x + gap, rect.position.y)


## The opaque RGB result of top composited over bottom.
##
## The animation-group backdrop is the opaque GraphEdit panel colour. Keeping
## this helper's contract opaque avoids pretending that a translucent backdrop
## has a defined RGB result without also carrying the colour beneath it.
static func composite_over(top: Color, bottom: Color) -> Color:
	var alpha := clampf(top.a, 0.0, 1.0)
	return Color(
		top.r * alpha + bottom.r * (1.0 - alpha),
		top.g * alpha + bottom.g * (1.0 - alpha),
		top.b * alpha + bottom.b * (1.0 - alpha),
		1.0)


## Minimum opacity needed for one channel to reach desired over backdrop.
static func channel_alpha(desired: float, backdrop: float) -> float:
	var difference := desired - backdrop
	if is_zero_approx(difference):
		return 0.0
	if difference < 0.0:
		return clampf(-difference / maxf(backdrop, 0.000001), 0.0, 1.0)
	return clampf(difference / maxf(1.0 - backdrop, 0.000001), 0.0, 1.0)


## Minimum opacity needed for all RGB channels to reach desired over backdrop.
static func min_alpha_for(desired: Color, backdrop: Color) -> float:
	return maxf(channel_alpha(desired.r, backdrop.r),
		maxf(channel_alpha(desired.g, backdrop.g), channel_alpha(desired.b, backdrop.b)))


## Solve the flat colour to draw over an opaque backdrop.
##
## The smallest useful opacity is selected, then RGB is re-derived from that
## actual opacity. This matters when a caller supplies a floor: using the
## minimum channel's RGB at the floored alpha would overshoot the target.
static func solve_over(desired: Color, backdrop: Color, floor_alpha: float = 0.0) -> Color:
	var alpha := maxf(min_alpha_for(desired, backdrop), clampf(floor_alpha, 0.0, 1.0))
	if alpha < 0.000001:
		return Color(desired.r, desired.g, desired.b, 0.0)
	var red := clampf((desired.r - (1.0 - alpha) * backdrop.r) / alpha, 0.0, 1.0)
	var green := clampf((desired.g - (1.0 - alpha) * backdrop.g) / alpha, 0.0, 1.0)
	var blue := clampf((desired.b - (1.0 - alpha) * backdrop.b) / alpha, 0.0, 1.0)
	return Color(red, green, blue, alpha)


## Graph-space coordinate of a point given in GraphEdit-local pixels.
##
## Inverts GraphEdit's own child transform (position = offset * zoom -
## scroll_offset). Tracking a drag through this is invariant under a zoom or a
## pan that happens mid-gesture, and accumulates no error over a long drag the
## way summing InputEventMouseMotion.relative does -- and relative is a trap
## besides: the viewport has already divided it by the element's zoom scale, so
## dividing again would be right only at zoom 1.0.
static func graph_offset_of(local_point: Vector2, scroll_offset: Vector2, zoom: float) -> Vector2:
	if zoom <= 0.0:
		return local_point + scroll_offset
	return (local_point + scroll_offset) / zoom


## The delta a drag commits, snapped as one vector.
##
## Snapping the delta rather than each node is what preserves the group's
## internal layout: a tidied column keeps its exact row step, which snapping
## every member separately would quantise away.
static func snapped_delta(delta: Vector2, enabled: bool, distance: float) -> Vector2:
	if not enabled or distance <= 0.0:
		return delta
	return delta.snapped(Vector2(distance, distance))


## Graph-offset units -> blend tree units. Same division as _member_extent, and
## for the same reason: GraphEdit offsets carry the editor scale, resource
## positions do not.
static func to_resource_delta(delta: Vector2, editor_scale: float) -> Vector2:
	if editor_scale <= 0.0:
		return delta
	return delta / editor_scale


## Every position in a set, shifted by one delta.
static func shifted(positions: Dictionary, delta: Vector2) -> Dictionary:
	var moved := {}
	for key in positions:
		moved[key] = positions[key] + delta
	return moved


## Whether a press has travelled far enough to be a drag rather than a click.
static func is_drag(press_point: Vector2, point: Vector2, threshold: float) -> bool:
	return press_point.distance_squared_to(point) > threshold * threshold


## What a collapse does to the graph's wires.
##
## GraphEdit queries a node's ports for every connection it holds, with no
## visibility test and no bounds test, and a hidden GraphNode's port cache is
## empty -- GraphNode builds it only from children that are visible in tree. So
## every wire touching a hidden member both spams
## "right_port_cache.size() = 0" and, because the failed lookup returns
## Vector2(), draws from the node's own top-left corner instead of its port.
##
## The answer is to take those wires out of the GraphEdit and draw the ones that
## cross a group's boundary ourselves, from the box's edge. This decides which is
## which. Pure: it is handed plain connection dictionaries and a map of
## member -> the id of the outermost collapsed group hiding it.
##
## Returns:
##   suppress   -- every connection with a hidden end, to remove from the GraphEdit
##   wires      -- the crossing subset, to draw by hand
##   out_stubs  -- box id -> how many wires leave its right edge
##   in_stubs   -- box id -> how many wires arrive on its left edge
static func wire_plan(connections: Array, hidden_by_box: Dictionary) -> Dictionary:
	var suppress: Array = []
	var crossing: Array = []

	for connection in connections:
		var from_node := String(connection.get("from_node", ""))
		var to_node := String(connection.get("to_node", ""))
		var from_box := String(hidden_by_box.get(from_node, ""))
		var to_box := String(hidden_by_box.get(to_node, ""))
		if from_box.is_empty() and to_box.is_empty():
			continue

		suppress.append(connection)
		# Both ends inside the same box is wiring the box exists to hide: it goes
		# and nothing replaces it. Two different boxes still deserve a wire --
		# that is one collapsed group feeding another.
		if from_box == to_box:
			continue
		var from_port := int(connection.get("from_port", 0))
		var to_port := int(connection.get("to_port", 0))
		var wire := {
			"from_box": from_box,
			"from_node": from_node,
			"from_port": from_port,
			"from_stub": 0,
			"to_box": to_box,
			"to_node": to_node,
			"to_port": to_port,
			"to_stub": 0,
		}
		# Stub rows are dealt out in the order of the *far* end, so a group
		# feeding a transition comes off the box in input-port order and the fan
		# does not cross itself. The near end breaks ties, which only two
		# different boxes can produce, so the order is total. Sorting also makes
		# the plan independent of the order GraphEdit hands its list over in.
		#
		# The key is built once per wire rather than inside the comparator: a
		# sort asks a hundred questions of two dozen wires, and formatting four
		# strings for each of them was the single most expensive thing here.
		var far := "%s|%04d" % ([to_node, to_port] if to_box.is_empty() else [from_node, from_port])
		crossing.append(["%s|%s|%04d|%s|%04d" % [far, from_node, from_port, to_node, to_port], wire])

	crossing.sort_custom(func(a, b): return a[0] < b[0])
	var out_stubs := {}
	var in_stubs := {}
	var wires: Array = []
	for entry in crossing:
		var wire: Dictionary = entry[1]
		wires.append(wire)
		if not String(wire["from_box"]).is_empty():
			var out_box: String = wire["from_box"]
			wire["from_stub"] = int(out_stubs.get(out_box, 0))
			out_stubs[out_box] = wire["from_stub"] + 1
		if not String(wire["to_box"]).is_empty():
			var in_box: String = wire["to_box"]
			wire["to_stub"] = int(in_stubs.get(in_box, 0))
			in_stubs[in_box] = wire["to_stub"] + 1

	return {
		"suppress": suppress,
		"wires": wires,
		"out_stubs": out_stubs,
		"in_stubs": in_stubs,
	}


## How many stub rows a collapsed box has to be tall enough for.
static func stub_rows(plan: Dictionary, box_id: String) -> int:
	var out_stubs: Dictionary = plan.get("out_stubs", {})
	var in_stubs: Dictionary = plan.get("in_stubs", {})
	return maxi(int(out_stubs.get(box_id, 0)), int(in_stubs.get(box_id, 0)))


## Where one stub sits, in the same unzoomed graph space as position_offset.
##
## Row 0 starts below the title bar, so the stubs read as ports on the box rather
## than as marks on its heading.
static func stub_point(origin: Vector2, size: Vector2, title_h: float, row: int,
		step: float, right_side: bool) -> Vector2:
	var x: float = origin.x + size.x if right_side else origin.x
	return Vector2(x, origin.y + title_h + (float(row) + 0.5) * step)


## A collapsed box: fixed width, and tall enough for its stubs.
##
## With no stubs it is exactly the title bar, which is what a collapsed group
## looked like before wires were drawn at all.
static func collapsed_box_size(width: float, title_h: float, rows: int, step: float) -> Vector2:
	return Vector2(width, title_h + maxf(0.0, float(rows)) * step)


## The parent a new wrapper group should take.
##
## Wrapping two groups that already sit in the same band should leave them in it,
## so the wrapper joins them there; a selection spanning different parents has no
## shared home and the wrapper goes to the top level. "" means top level, and is
## also what an empty selection gets.
static func shared_parent(parent_ids: PackedStringArray) -> String:
	if parent_ids.is_empty():
		return ""
	var first := parent_ids[0]
	for id in parent_ids:
		if id != first:
			return ""
	return first


## A selected group reads brighter without changing what its tint means.
##
## The boost is added to alpha rather than multiplied, so a nearly transparent
## nested frame gains as much as a solid one; the ceiling keeps a group that is
## already opaque from becoming indistinguishable from the selection outline.
static func selected_tint(base: Color, boost: float, ceiling: float) -> Color:
	return Color(base.r, base.g, base.b, minf(base.a + boost, ceiling))


## A title for a group wrapping others: what their titles have in common, else a
## plain "Group", the same rule the node-name version follows.
static func wrapper_title(titles: PackedStringArray) -> String:
	if titles.is_empty():
		return "Group"
	var prefix := String(titles[0]).get_slice(" ", 0)
	for title in titles:
		if String(title).get_slice(" ", 0) != prefix:
			return "Group"
	return prefix
