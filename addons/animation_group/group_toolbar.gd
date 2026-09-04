@tool
extends RefCounted

## The buttons injected into the blend tree editor's own toolbar.
##
## GraphEdit.get_menu_hbox() is a public API, so this is the one part of the
## injection that rests on nothing internal. Every control created here is kept
## so remove() can put the toolbar back exactly as it was found.

signal command(id: StringName)

const MANUAL_BUTTONS := [
	{"id": &"group", "text": "Group", "icon": "Groups",
		"tip": "Frame the selected nodes as a group (visual only). A selection already inside one group nests inside it, and picked groups are wrapped in a new one."},
	{"id": &"ungroup", "text": "Ungroup", "icon": "Remove",
		"tip": "Delete the picked group, or the one holding the selected nodes, merging them back into the group around it. The nodes stay."},
	{"id": &"edit", "text": "Rename", "icon": "Edit",
		"tip": "Rename a group and pick its tint. Click a group's title bar to pick it, or select any node inside it."},
	{"id": &"tidy", "text": "Tidy", "icon": "AnimationTrackList",
		"tip": "Line the group's nodes up, in transition input order where there is one."},
]

var _owned: Array[Control] = []
var _buttons: Dictionary = {}


func inject(graph: GraphEdit) -> bool:
	remove()
	if graph == null or not graph.has_method("get_menu_hbox"):
		return false
	var box: HBoxContainer = graph.get_menu_hbox()
	if box == null:
		return false

	var separator := VSeparator.new()
	box.add_child(separator)
	_owned.append(separator)

	var entries: Array = MANUAL_BUTTONS.duplicate()
	for entry in entries:
		var button := Button.new()
		button.flat = true
		button.text = entry["text"]
		button.tooltip_text = entry["tip"]
		button.focus_mode = Control.FOCUS_NONE
		_apply_icon(button, entry["icon"])
		button.pressed.connect(_on_pressed.bind(entry["id"]))
		box.add_child(button)
		_owned.append(button)
		_buttons[entry["id"]] = button
	return true


func remove() -> void:
	for control in _owned:
		if is_instance_valid(control):
			if control.get_parent() != null:
				control.get_parent().remove_child(control)
			control.queue_free()
	_owned.clear()
	_buttons.clear()


func set_enabled(id: StringName, enabled: bool, disabled_tip: String = "") -> void:
	var button: Button = _buttons.get(id)
	if button == null or not is_instance_valid(button):
		return
	button.disabled = not enabled
	if not enabled and not disabled_tip.is_empty():
		button.tooltip_text = disabled_tip
	else:
		for entry in MANUAL_BUTTONS:
			if entry["id"] == id:
				button.tooltip_text = entry["tip"]


func has_buttons() -> bool:
	return not _buttons.is_empty()


## Icons are best effort: their names move between Godot versions, and a button
## with text and a tooltip reads fine without one.
func _apply_icon(button: Button, icon_name: String) -> void:
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon(icon_name, &"EditorIcons"):
		button.icon = theme.get_icon(icon_name, &"EditorIcons")


func _on_pressed(id: StringName) -> void:
	command.emit(id)
