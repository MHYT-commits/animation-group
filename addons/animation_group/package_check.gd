@tool
extends SceneTree

## Lightweight checks for keeping the distributed addon project-independent.
## Run from the project root with Godot's script runner when packaging.

const PACKAGE := "res://addons/animation_group_manual"
const FORBIDDEN := [
	"ATTACK_GROUPS",
	"attack_group_seed",
	"build_blend_tree",
	"res://Player/",
	"res://tools/",
	"Auto-group",
]


func _init() -> void:
	run()
	quit()

static func run() -> void:
	var files := _script_files(PACKAGE)
	for path in files:
		var source := FileAccess.get_file_as_string(path)
		for token in FORBIDDEN:
			assert(not source.contains(token), "%s contains portable-package dependency %s" % [path, token])
	assert(FileAccess.file_exists(PACKAGE + "/plugin.cfg"))
	assert(FileAccess.file_exists(PACKAGE + "/plugin.gd"))
	assert(FileAccess.file_exists(PACKAGE + "/README.md"))


static func _script_files(directory: String) -> PackedStringArray:
	var result := PackedStringArray()
	var dir := DirAccess.open(directory)
	if dir == null:
		return result
	for name in dir.get_files():
		if name.ends_with(".gd") and name != "package_check.gd":
			result.append(directory + "/" + name)
	return result
