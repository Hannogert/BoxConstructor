@tool
extends PanelContainer

signal disable_button_pressed
signal select_button_pressed
signal add_button_pressed
signal remove_button_pressed
signal edit_mesh
signal grid_size_changed(size: float)
signal reset_grid_pressed
signal merge_mesh

var disable_button: Button
var merge_button: Button
var edit_button: Button
var tooltip_button: Button
var plugin: EditorPlugin
var toolbar_buttons: HBoxContainer
var select_button: Button
var add_button: Button
var active_button_stylebox: StyleBoxFlat
var grid_sizes = [0.01, 0.1, 0.25, 0.5, 0.75, 1, 2, 5, 10]

func _init(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin

func _ready() -> void:
	_configure_style()
	_create_containers()
	_create_active_button_style()
	_create_all_buttons()

func _create_all_buttons() -> void:
	disable_button = _create_mode_button("Disable", "GuiClose", "_on_disable_pressed")
	select_button = _create_mode_button("Select Edge", "ToolSelect", "_on_select_button_pressed")
	add_button = _create_mode_button("Add Primitive", "Add", "_on_add_button_pressed")
	_create_button("Reset Grid", "Reload", "_on_reset_button_pressed")
	_create_grid_size_selector()
	merge_button = _create_button("Merge Mesh", "BoxMesh", "_on_merge_mesh_pressed")
	edit_button = _create_button("Edit Mesh", "Edit", "_on_edit_pressed")
	tooltip_button = _create_button("", "Help", "pass")

func _configure_style() -> void:
	var stylebox = StyleBoxFlat.new()
	stylebox.bg_color = Color(0.211, 0.239, 0.290)
	stylebox.set_corner_radius_all(20)
	add_theme_stylebox_override("panel", stylebox)

	add_theme_constant_override("margin_left", 20)
	add_theme_constant_override("margin_right", 20)
	add_theme_constant_override("margin_top", 10)
	add_theme_constant_override("margin_bottom", 10)

func _create_containers() -> void:
	var margin_container = MarginContainer.new()
	margin_container.add_theme_constant_override("margin_left", 6)
	margin_container.add_theme_constant_override("margin_right", 6)
	margin_container.add_theme_constant_override("margin_top", 6)
	margin_container.add_theme_constant_override("margin_bottom", 6)
	add_child(margin_container)
	
	toolbar_buttons = HBoxContainer.new()
	toolbar_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	toolbar_buttons.add_theme_constant_override("separation", 8)
	margin_container.add_child(toolbar_buttons)

func _create_active_button_style() -> void:
	active_button_stylebox = _create_button_stylebox()
	active_button_stylebox.bg_color = Color(0.3, 0.5, 0.7)
	active_button_stylebox.border_color = Color.WHITE

func _create_buttons() -> void:
	disable_button = _create_mode_button("Disable", "GuiVisibilityHidden", "_on_disable_pressed")
	select_button = _create_mode_button("Select Edge", "ToolSelect", "_on_select_button_pressed")
	add_button = _create_mode_button("Add Primitive", "Add", "_on_add_button_pressed")
	_create_button("Reset Grid", "Reload", "_on_reset_button_pressed")

func set_edit_button_enabled(enabled: bool) -> void:
	if edit_button:
		edit_button.disabled = not enabled

func set_merge_button_enabled(enabled: bool) -> void:
	if merge_button:
		merge_button.disabled = not enabled

func set_select_button_enabled(enabled: bool) -> void:
	if select_button:
		select_button.disabled = not enabled
		
func update_button_states(is_merged: bool) -> void:
	
	if select_button:
		select_button.visible = !is_merged
	if add_button:
		add_button.visible = !is_merged
	if merge_button:
		merge_button.visible = !is_merged
	if edit_button:
		edit_button.visible = is_merged
	
	if add_button:
		add_button.queue_redraw()
	if merge_button:
		merge_button.queue_redraw()
	if edit_button:
		edit_button.queue_redraw()

	toolbar_buttons.custom_minimum_size = Vector2.ZERO
	toolbar_buttons.reset_size()
	custom_minimum_size = Vector2.ZERO
	reset_size()

	var viewport_base = get_parent()
	if viewport_base:
		position.x = (viewport_base.size.x - size.x) * 0.5 

func _create_mode_button(text: String, icon_name: String, callback: String) -> Button:
	var button = Button.new()
	button.text = text
	button.toggle_mode = true
	button.icon = plugin.get_editor_interface().get_base_control().get_theme_icon(icon_name, "EditorIcons")
	button.connect("pressed", Callable(self, callback))
	
	var normal_style = _create_button_stylebox()
	var hover_style = _create_button_stylebox(true)
	
	button.tooltip_text = _get_tooltip_text(button.text)
	button.add_theme_stylebox_override("normal", normal_style)
	button.add_theme_stylebox_override("hover", hover_style)
	button.add_theme_stylebox_override("pressed", active_button_stylebox)
	button.add_theme_stylebox_override("disabled", normal_style)
	button.add_theme_stylebox_override("focus", normal_style)
	
	toolbar_buttons.add_child(button)
	return button

func _create_button(text: String, icon_name: String, callback: String) -> Button:
	var button = Button.new()
	button.text = text
	button.icon = plugin.get_editor_interface().get_base_control().get_theme_icon(icon_name, "EditorIcons")
	button.connect("pressed", Callable(self, callback))
	
	var normal_style = _create_button_stylebox()
	var hover_style = _create_button_stylebox(true)
	
	button.tooltip_text = _get_tooltip_text(button.text)
	button.add_theme_stylebox_override("normal", normal_style)
	button.add_theme_stylebox_override("hover", hover_style)
	button.add_theme_stylebox_override("pressed", hover_style)
	button.add_theme_stylebox_override("disabled", normal_style)
	button.add_theme_stylebox_override("focus", normal_style)
	
	toolbar_buttons.add_child(button)
	return button

func _create_button_stylebox(is_hover: bool = false) -> StyleBoxFlat:
	var stylebox = StyleBoxFlat.new()
	stylebox.bg_color = Color(0.15, 0.17, 0.20) if not is_hover else Color(0.25, 0.27, 0.30)
	stylebox.set_corner_radius_all(20)
	
	stylebox.content_margin_left = 8
	stylebox.content_margin_right = 8
	stylebox.content_margin_top = 4
	stylebox.content_margin_bottom = 4
	
	stylebox.border_width_bottom = 0
	stylebox.border_width_left = 0
	stylebox.border_width_right = 0
	stylebox.border_width_top = 0
	
	return stylebox

func _create_grid_size_selector() -> void:
	var grid_size_button = OptionButton.new()
	grid_size_button.name = "Grid Size"
	
	grid_size_button.add_item("0.01", 0)
	grid_size_button.add_item("0.1", 1)
	grid_size_button.add_item("0.25", 2)
	grid_size_button.add_item("0.5", 3)
	grid_size_button.add_item("0.75", 4)
	grid_size_button.add_item("1", 5)
	grid_size_button.add_item("2", 6)
	grid_size_button.add_item("5", 7)
	grid_size_button.add_item("10", 8)

	grid_size_button.select(5)

	grid_size_button.connect("item_selected", Callable(self, "_on_grid_size_selected"))
	grid_size_button.add_theme_stylebox_override("normal", _create_button_stylebox())
	grid_size_button.add_theme_stylebox_override("hover", _create_button_stylebox(true))

	toolbar_buttons.add_child(grid_size_button)

func set_active_mode(mode: int) -> void:
	disable_button.button_pressed = (mode == 0) # DISABLE mode
	select_button.button_pressed = (mode == 1) # SELECT mode
	add_button.button_pressed = (mode == 2) # ADD mode

func connect_to_grid(grid: CubeGrid3D) -> void:
	var grid_size_button = toolbar_buttons.get_node("Grid Size") as OptionButton
	if not grid_size_button:
		return
		
	var grid_sizes = [0.01, 0.1, 0.25, 0.5, 0.75, 1, 2, 5, 10]
	var index = grid_sizes.find(grid.grid_scale)
	if index != -1:
		grid_size_button.select(index)

func _on_grid_created(initial_scale: float) -> void:
	var grid_size_button = toolbar_buttons.get_node("Grid Size") as OptionButton
	if not grid_size_button:
		return
		
	var index = grid_sizes.find(initial_scale)
	if index != -1:
		grid_size_button.select(index)

func _on_disable_pressed() -> void:
	emit_signal("disable_button_pressed")

func _on_select_button_pressed() -> void:
	emit_signal("select_button_pressed")

func _on_add_button_pressed() -> void:
	emit_signal("add_button_pressed")

func _on_remove_button_pressed() -> void:
	emit_signal("remove_button_pressed")

func _on_grid_size_selected(index: int) -> void:
	var selected_size = grid_sizes[index]
	emit_signal("grid_size_changed", selected_size)

func _on_reset_button_pressed() -> void:
	emit_signal("reset_grid_pressed")

func _on_merge_mesh_pressed() -> void:
	emit_signal("merge_mesh")

func _on_edit_pressed() -> void:
	update_button_states(false)
	emit_signal("edit_mesh")

func _get_tooltip_text(button_name: String) -> String:
	match button_name:
		"Disable":
			return "Disable\n Disables mouse input for Constructor."
		"Select Edge":
			return "Select Edge\n Allows you to select an edge to move it."
		"Add Primitive":
			return "Add Primitive\n Allows you to add or remove a box by drawing a rectangle and extruding it."
		"Reset Grid":
			return "Reset\n Resets the grid to its original state."
		"Grid Size":
			return "Grid Size\n Sets the size of the grid."
		"Merge Mesh":
			return "Merge Mesh\n Merges all the cubes into a single MeshInstance3D."
		"Edit Mesh":
			return "Edit Mesh\n Breaks the mesh into its original cubes."
		"":
			return """Box Constructor Help:
		
		Keyboard Shortcuts:
		- Press X to move the drawing plane.
		- Press Z key to reset the drawing plane.
		- Middle mouse will cancel the current operation for extrudsion and drawing.

		Tips:
		- You can use the edge select to move edges, but only use them to create ramps
		(Creating other shapes may result in CSG operations not working correctly).
		- The drawing does not work on slanted surfaces, only flat surfaces.
		"""
		_:
			return ""
