@tool
extends RefCounted

## Finds Godot's built-in blend tree editor and the GraphEdit inside it.
##
## AnimationNodeBlendTreeEditor is an internal C++ editor class with no
## scripting API, so there is no supported handle on it: the only way in is to
## walk the editor's own control tree and match on get_class(). That is the one
## brittle assumption in this addon, and everything here is written so that a
## future Godot moving it costs one warning and nothing else.

const EDITOR_CLASS := "AnimationNodeBlendTreeEditor"

## Ceiling on nodes visited, so a search can never stall the editor.
const VISIT_BUDGET := 40000

## The GraphEdit sits directly under the editor; a couple of levels of slack
## covers a future container without turning this into a whole-tree search.
const GRAPH_DEPTH := 3


## The built-in editor, or null. It is created once at editor startup and only
## hidden when another bottom panel is shown, so one successful find holds for
## the session.
static func find_editor() -> Control:
	var base := EditorInterface.get_base_control()
	if base == null:
		return null

	var stack: Array[Node] = [base]
	var visited := 0
	while not stack.is_empty() and visited < VISIT_BUDGET:
		var node: Node = stack.pop_back()
		visited += 1
		if node.get_class() == EDITOR_CLASS:
			return node as Control
		for child in node.get_children(true):
			stack.push_back(child)
	return null


static func find_graph_edit(editor: Node) -> GraphEdit:
	if editor == null:
		return null
	var frontier: Array[Node] = [editor]
	for _depth in GRAPH_DEPTH:
		var next: Array[Node] = []
		for node in frontier:
			for child in node.get_children(true):
				if child is GraphEdit:
					return child as GraphEdit
				next.append(child)
		frontier = next
	return null
