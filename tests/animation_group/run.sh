#!/usr/bin/env bash
# Run editor interaction tests without opening or changing the game project.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
godot_bin="${GODOT_BIN:-godot}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/animation-group-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/addons" "$test_dir/tests/animation_group"
cp -R "$repo_root/addons/animation_group" "$test_dir/addons/"
cp "$repo_root/tests/animation_group/editor_regression.gd" "$test_dir/tests/animation_group/"
cat > "$test_dir/project.godot" <<'EOF'
config_version=5
[application]
config/name="Animation Group Regression"
[rendering]
renderer/rendering_method="gl_compatibility"
EOF
export XDG_CONFIG_HOME="$test_dir/config"
export XDG_DATA_HOME="$test_dir/data"
"$godot_bin" --headless --editor --path "$test_dir" --import
"$godot_bin" --headless --editor --path "$test_dir" --script res://tests/animation_group/editor_regression.gd
