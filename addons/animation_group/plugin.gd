@tool
extends EditorPlugin

## Visual-only groups for the AnimationNodeBlendTree editor.
##
## The plugin itself is just lifecycle: it owns one overlay, hands it the
## AnimationTree the editor is on, and tears everything down again. All the work
## is in group_overlay.gd.
##
## _handles() is additive in Godot -- every plugin that claims an object is told
## about it -- so claiming AnimationTree here does not displace the built-in
## animation tree editor. No main screen and no dock are registered, so nothing
## of this plugin is visible except the buttons it adds to the blend tree
## editor's own toolbar.

const OVERLAY := preload("res://addons/animation_group_manual/group_overlay.gd")

var _overlay


func _enter_tree() -> void:
	_overlay = OVERLAY.new()
	_overlay.setup(self)


func _exit_tree() -> void:
	if _overlay != null:
		_overlay.teardown()
	_overlay = null


func _handles(object: Object) -> bool:
	return object is AnimationTree


func _edit(object: Object) -> void:
	if _overlay != null:
		_overlay.set_animation_tree(object as AnimationTree)


func _make_visible(visible: bool) -> void:
	if visible and _overlay != null:
		_overlay.notify_visible()


## Called by the tidy undo action so the graph follows the resource.
##
## It lives on the plugin rather than on the overlay because the undo history
## holds the object it calls: an EditorPlugin is a Node the editor keeps alive
## for exactly as long as the addon is enabled.
func refresh_group_positions() -> void:
	if _overlay != null:
		_overlay.refresh_positions()


## Called by the move undo action, for the same reason refresh_group_positions
## is: the undo history holds the object it calls, and an EditorPlugin is a Node
## the editor keeps alive for exactly as long as the addon is enabled.
func set_group_collapsed_positions(positions: Dictionary) -> void:
	if _overlay != null:
		_overlay.apply_collapsed_positions(positions)
