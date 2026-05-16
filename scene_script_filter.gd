@tool
extends EditorPlugin

## Matches "t:MyScript" or "type: MyScript" (case-insensitive, optional spaces)
const FILTER_REGEX := "^(?:t|type):\\s*(.+)$"

var _regex: RegEx
var _filter_input: LineEdit
var _scene_tree: Tree
var _pending_query: String = ""


func _enter_tree() -> void:
	_regex = RegEx.new()
	_regex.compile(FILTER_REGEX)

	_setup_ui_references()

	if _filter_input:
		_filter_input.text_changed.connect(_on_filter_text_changed)
	else:
		push_warning("SceneScriptFilter: filter LineEdit not found, plugin inactive")


func _exit_tree() -> void:
	if _filter_input and _filter_input.text_changed.is_connected(_on_filter_text_changed):
		_filter_input.text_changed.disconnect(_on_filter_text_changed)

	# Reset visibility when the plugin is disabled
	_restore_all_visible()


## Finds the SceneTreeDock and resolves the filter LineEdit (a direct
## descendant of the dock, NOT of the SceneTreeEditor) and the Tree widget
## (inside the SceneTreeEditor).
func _setup_ui_references() -> void:
	var base := EditorInterface.get_base_control()

	var dock := _find_node_by_class(base, "SceneTreeDock")
	if not dock:
		push_warning("SceneScriptFilter: SceneTreeDock not found")
		return

	# The filter LineEdit lives directly under SceneTreeDock (in a HBox),
	# while the Tree lives inside the SceneTreeEditor child.
	_filter_input = _find_node_by_class(dock, "LineEdit") as LineEdit

	var editor := _find_node_by_class(dock, "SceneTreeEditor")
	if editor:
		_scene_tree = _find_node_by_class(editor, "Tree") as Tree
	else:
		push_warning("SceneScriptFilter: SceneTreeEditor not found")


## Recursive class-name search (internal nodes have no unique names)
func _find_node_by_class(node: Node, p_class: String) -> Node:
	if node.get_class() == p_class:
		return node
	for child in node.get_children():
		var found := _find_node_by_class(child, p_class)
		if found:
			return found
	return null


func _on_filter_text_changed(new_text: String) -> void:
	var result := _regex.search(new_text)
	if result:
		var query := result.get_string(1).strip_edges()
		if not query.is_empty():
			_pending_query = query
			# Wait a full process frame so Godot's built-in `t:` filter
			# (which only matches via `contains` and therefore hides items
			# whose class_name does not contain the query verbatim) finishes
			# its synchronous visibility pass before we override it.
			_schedule_apply()
			return

	_pending_query = ""
	# Normal text → let Godot's built-in filter handle everything


func _schedule_apply() -> void:
	var captured_query := _pending_query
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		await (loop as SceneTree).process_frame
	# If the user kept typing while we were waiting, abort: a newer
	# scheduling call will handle the latest query.
	if _pending_query != captured_query:
		return
	_apply_filter()


func _apply_filter() -> void:
	if _pending_query.is_empty() or not _scene_tree or not _filter_input:
		return

	# Safety check: abort if the user already changed the text
	var result := _regex.search(_filter_input.text)
	if not result or result.get_string(1).strip_edges() != _pending_query:
		return

	var edited_scene := EditorInterface.get_edited_scene_root()
	if not edited_scene:
		return

	var root := _scene_tree.get_root()
	if not root:
		return

	var query := _pending_query.to_lower()
	var matched_items: Array[TreeItem] = []

	# --- Pass 1: collect items whose node has a matching script ---
	var item := root
	while item:
		var node := _resolve_node_from_item(item, edited_scene)
		if node and _node_matches_script(node, query):
			matched_items.append(item)
		item = item.get_next_in_tree()

	# --- Pass 2: hide everything ---
	item = root
	while item:
		item.set_visible(false)
		item = item.get_next_in_tree()

	# --- Pass 3: show matches + every ancestor so the path is visible ---
	for matched in matched_items:
		var curr := matched
		while curr:
			curr.set_visible(true)
			curr = curr.get_parent()

	# Always keep the scene root visible
	root.set_visible(true)


## TreeItem metadata(0) stores a NodePath (or sometimes the Node itself)
func _resolve_node_from_item(item: TreeItem, edited_scene: Node) -> Node:
	var meta := item.get_metadata(0)
	if meta == null:
		return null

	if meta is Node:
		return meta as Node

	if meta is NodePath:
		var np := meta as NodePath

		# Most common: path relative to the edited scene root
		var n := edited_scene.get_node_or_null(np)
		if n:
			return n

		# Fallback: absolute path from the tree root
		var tree := edited_scene.get_tree()
		if tree and tree.root:
			n = tree.root.get_node_or_null(np)
			if n:
				return n

	return null


## Checks the node's script and its entire inheritance chain.
## Matching is case-insensitive and underscore-insensitive, so a query like
## "my_script" matches a script with `class_name MyScript` (or a file named
## `my_script.gd`), and vice-versa.
func _node_matches_script(node: Node, query: String) -> bool:
	var script := node.get_script() as Script
	if not script:
		return false

	var query_norm := _normalize_name(query)
	if query_norm.is_empty():
		return false

	var curr := script
	while curr:
		var path := curr.resource_path
		if not path.is_empty():
			var base_name := path.get_file().get_basename()
			if _normalize_name(base_name) == query_norm:
				return true

		var global_name := curr.get_global_name()
		if not global_name.is_empty():
			if _normalize_name(global_name) == query_norm:
				return true

		curr = curr.get_base_script()

	return false


## Normalizes a script identifier so that "MyScript", "my_script",
## "My_Script" and "myscript" all compare as equal.
static func _normalize_name(s: String) -> String:
	return s.to_lower().replace("_", "")


func _restore_all_visible() -> void:
	if not _scene_tree:
		return
	var root := _scene_tree.get_root()
	if not root:
		return
	var item := root
	while item:
		item.set_visible(true)
		item = item.get_next_in_tree()
