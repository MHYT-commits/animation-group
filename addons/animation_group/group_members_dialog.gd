@tool
extends RefCounted

## Edits direct membership using existing blend-tree nodes only.
signal applied(members: PackedStringArray)

var _dialog: ConfirmationDialog
var _search: LineEdit
var _list: Tree
var _summary: Label
var _entries: Array[Dictionary] = []
var _checked := PackedStringArray()
var _rebuilding := false


func popup(title: String, entries: Array[Dictionary], members: PackedStringArray) -> void:
	_ensure_built()
	if not is_instance_valid(_dialog):
		return
	_entries = entries
	_checked = members.duplicate()
	_dialog.title = "Members of %s" % title
	_search.clear()
	_rebuild()
	_dialog.popup_centered(Vector2i(660, 520) * EditorInterface.get_editor_scale())
	_search.grab_focus()


func teardown() -> void:
	if is_instance_valid(_dialog):
		_dialog.get_parent().remove_child(_dialog)
		_dialog.queue_free()
	_dialog = null
	_entries.clear()
	_checked.clear()


func _ensure_built() -> void:
	if is_instance_valid(_dialog):
		return
	var base := EditorInterface.get_base_control()
	if base == null:
		return
	_dialog = ConfirmationDialog.new()
	_dialog.ok_button_text = "Apply Members"
	var rows := VBoxContainer.new()
	_dialog.add_child(rows)
	var help := Label.new()
	help.text = "Group any node: Animation, OneShot, Blend2, BlendSpace, and more.\nCheck to add; uncheck to remove. Nodes from another group move here."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(help)
	_search = LineEdit.new()
	_search.placeholder_text = "Search node names, types, animation clips, or groups…"
	_search.text_changed.connect(func(_text: String) -> void: _rebuild())
	rows.add_child(_search)
	_list = Tree.new()
	_list.columns = 3
	_list.column_titles_visible = true
	_list.set_column_title(0, "Node")
	_list.set_column_title(1, "Animation / Type")
	_list.set_column_title(2, "Current Group")
	_list.hide_root = true
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(600, 320) * EditorInterface.get_editor_scale()
	_list.item_edited.connect(_on_item_edited)
	rows.add_child(_list)
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(_summary)
	_dialog.confirmed.connect(_on_confirmed)
	base.add_child(_dialog)


func _rebuild() -> void:
	_rebuilding = true
	_list.clear()
	var root := _list.create_item()
	var query := _search.text.strip_edges()
	for entry in _entries:
		var search_text := "%s %s %s" % [entry["name"], entry["detail"], entry["owner"]]
		if not query.is_empty() and not search_text.containsn(query):
			continue
		var item := _list.create_item(root)
		var locked: bool = entry["nested"]
		item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		item.set_text(0, entry["name"])
		item.set_metadata(0, entry["name"])
		item.set_checked(0, locked or _checked.has(entry["name"]))
		item.set_editable(0, not locked)
		item.set_text(1, entry["detail"])
		item.set_text(2, entry["owner"])
		item.set_tooltip_text(1, entry["detail"])
		item.set_tooltip_text(2, entry["owner"])
		if locked:
			item.set_tooltip_text(0, "Edit this node's nested group to change its membership.")
	_rebuilding = false
	_update_summary()


func _on_item_edited() -> void:
	if _rebuilding:
		return
	var item := _list.get_edited()
	if item == null:
		return
	var node_name: String = item.get_metadata(0)
	if item.is_checked(0):
		if not _checked.has(node_name):
			_checked.append(node_name)
	else:
		var index := _checked.find(node_name)
		if index != -1:
			_checked.remove_at(index)
	_update_summary()


func _update_summary() -> void:
	_summary.text = "%d direct member(s). Removing all members of a group without children removes its frame." % _checked.size()


func _on_confirmed() -> void:
	_dialog.hide()
	applied.emit(_checked.duplicate())
