@tool
extends RefCounted

## Title and tint for one group, in a dialog built in code.
##
## No .tscn: the whole thing is two rows, and a scene file would be one more
## piece of the addon to keep in step with the script that drives it.

signal applied(title: String, tint: Color)

var _dialog: ConfirmationDialog
var _title_edit: LineEdit
var _tint_picker: ColorPickerButton


func popup(title: String, tint: Color) -> void:
	_ensure_built()
	if _dialog == null:
		return
	_title_edit.text = title
	_tint_picker.color = tint
	_dialog.popup_centered(Vector2i(360, 150))
	_title_edit.grab_focus()
	_title_edit.select_all()


func teardown() -> void:
	if is_instance_valid(_dialog):
		if _dialog.get_parent() != null:
			_dialog.get_parent().remove_child(_dialog)
		_dialog.queue_free()
	_dialog = null
	_title_edit = null
	_tint_picker = null


func _ensure_built() -> void:
	if is_instance_valid(_dialog):
		return
	var base := EditorInterface.get_base_control()
	if base == null:
		return

	_dialog = ConfirmationDialog.new()
	_dialog.title = "Animation Group"
	_dialog.ok_button_text = "Apply"

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 8)
	_dialog.add_child(rows)

	var title_row := HBoxContainer.new()
	var title_label := Label.new()
	title_label.text = "Title"
	title_label.custom_minimum_size.x = 60
	_title_edit = LineEdit.new()
	_title_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_edit.text_submitted.connect(func(_text: String) -> void: _on_confirmed())
	title_row.add_child(title_label)
	title_row.add_child(_title_edit)
	rows.add_child(title_row)

	var tint_row := HBoxContainer.new()
	var tint_label := Label.new()
	tint_label.text = "Tint"
	tint_label.custom_minimum_size.x = 60
	_tint_picker = ColorPickerButton.new()
	_tint_picker.custom_minimum_size = Vector2(120, 0)
	_tint_picker.edit_alpha = true
	tint_row.add_child(tint_label)
	tint_row.add_child(_tint_picker)
	rows.add_child(tint_row)

	_dialog.confirmed.connect(_on_confirmed)
	base.add_child(_dialog)


func _on_confirmed() -> void:
	if not is_instance_valid(_dialog):
		return
	if _dialog.visible:
		_dialog.hide()
	applied.emit(_title_edit.text.strip_edges(), _tint_picker.color)
