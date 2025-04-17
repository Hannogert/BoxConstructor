@tool
extends EditorPlugin

# Constants
enum BuildMode {
	SELECT,
	ADD
}

const DISTANCE_THRESHOLD_SMALL := 50.0
const DISTANCE_THRESHOLD_MEDIUM := 500.0
const DISTANCE_THRESHOLD_LARGE := 5000.0

const GRID_SCALE_SMALL := 10.0
const GRID_SCALE_MEDIUM := 100.0
const GRID_SCALE_LARGE := 1000.0

const BASE_PREVIEW_THICKNESS := 0.02

# Core properties
var current_mode: BuildMode = BuildMode.SELECT
var voxel_root: CSGCombiner3D
var selected_grid: CubeGrid3D
var toolbar: PanelContainer
var editor_viewport = get_editor_interface().get_editor_viewport_3d()
var voxel_size
var voxel_mesh: MeshInstance3D = null
var camera = editor_viewport.get_camera_3d()

# Drawing properties
var is_drawing: bool = false
var draw_normal: Vector3 = Vector3.UP
var draw_start: Vector3 = Vector3()
var draw_end: Vector3 = Vector3()
var draw_plane: Plane
var is_extruding: bool = false
var draw_preview: MeshInstance3D = null
var has_started_extrusion: bool = false
var extrude_distance: float = 0.0
var initial_extrude_point: Vector3
var extrude_line_start: Vector3
var extrude_line_end: Vector3
var base_rect_points: Array = []

func _process(_delta: float) -> void:
	if selected_grid and editor_viewport:
		if camera and selected_grid.grid_material:
			if selected_grid.grid_scale == 0:
				var distance = camera.global_position.distance_to(selected_grid.global_position)
				selected_grid.grid_material.set_shader_parameter("camera_distance", distance)
				
				if distance > DISTANCE_THRESHOLD_LARGE:
					selected_grid.grid_material.set_shader_parameter("grid_scale", GRID_SCALE_LARGE)
				elif distance > DISTANCE_THRESHOLD_MEDIUM:
					selected_grid.grid_material.set_shader_parameter("grid_scale", GRID_SCALE_MEDIUM)
				elif distance > DISTANCE_THRESHOLD_SMALL:
					selected_grid.grid_material.set_shader_parameter("grid_scale", GRID_SCALE_SMALL)
				else:
					selected_grid.grid_material.set_shader_parameter("grid_scale", 1.0)

func _on_grid_size_changed(size: int) -> void:
	var selected = get_editor_interface().get_selection().get_selected_nodes()
	if selected.size() > 0 and selected[0] is CubeGrid3D:
		selected[0].grid_scale = size
		selected[0]._update_material()

func _enter_tree() -> void:
	get_editor_interface().get_selection().selection_changed.connect(_on_selection_changed)
	editor_viewport = get_editor_interface().get_editor_viewport_3d()

	toolbar = preload("res://addons/boxconstructor/scripts/toolbar.gd").new(self)
	var viewport_base = editor_viewport.get_parent().get_parent()
	viewport_base.add_child(toolbar)
	toolbar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, 0, 10)
	toolbar.hide()
	_connect_toolbar_signals()

func _exit_tree() -> void:
	if toolbar:
		toolbar.queue_free()
	if get_editor_interface().get_selection().selection_changed.is_connected(_on_selection_changed):
		get_editor_interface().get_selection().selection_changed.disconnect(_on_selection_changed)

func _on_selection_changed() -> void:
	var selected = get_editor_interface().get_selection().get_selected_nodes()
	if selected.size() == 1 and selected[0] is CubeGrid3D:
		selected_grid = selected[0]
		voxel_root = selected_grid.get_node("CSGCombiner3D")
		toolbar.show()
		# Update toolbar button states based on voxel_root content
		_update_toolbar_states()
	else:
		selected_grid = null
		voxel_root = null
		toolbar.hide()

func _update_toolbar_states() -> void:
	if not voxel_root:
		return
		
	var has_voxel_mesh = voxel_root.has_node("VoxelMesh")
	var has_csg_boxes = false
	
	for child in voxel_root.get_children():
		if child is CSGBox3D:
			has_csg_boxes = true
			break
			
	if has_voxel_mesh:
		toolbar.update_button_states(true) 
	else:
		toolbar.update_button_states(false)
	toolbar.set_edit_button_enabled(has_voxel_mesh)

func _connect_toolbar_signals() -> void:
	toolbar.select_button_pressed.connect(func(): _change_mode(BuildMode.SELECT))
	toolbar.add_button_pressed.connect(func(): _change_mode(BuildMode.ADD))
	toolbar.grid_size_changed.connect(_on_grid_size_changed)
	toolbar.reset_grid_pressed.connect(_reset_grid_transform)
	toolbar.merge_mesh.connect(_on_merge_mesh)
	toolbar.edit_mesh.connect(_on_edit_mesh)
	
func _change_mode(new_mode: BuildMode) -> void:
	if new_mode == BuildMode.ADD and voxel_root and voxel_root.has_node("VoxelMesh"):
		push_warning("Can't switch to ADD mode while VoxelMesh exists. Use Edit to modify.")
		toolbar.set_active_mode(current_mode)
		return

	current_mode = new_mode
	toolbar.set_active_mode(current_mode)
	
	if voxel_root:
		voxel_root.set_meta("_edit_lock_", current_mode != BuildMode.SELECT)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_X:
		if not camera or not selected_grid:
			return
		var ray_query = PhysicsRayQueryParameters3D.new()
		ray_query.from = camera.project_ray_origin(editor_viewport.get_mouse_position())
		ray_query.to = ray_query.from + camera.project_ray_normal(editor_viewport.get_mouse_position()) * 1000
		ray_query.collide_with_bodies = true
		var hit = get_editor_interface().get_edited_scene_root().get_world_3d().direct_space_state.intersect_ray(ray_query)
		if hit:
			print("Hit position: ", hit.position)
			_align_grid_to_normal(hit.normal, hit.position)
	if current_mode == BuildMode.ADD:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				if not camera: return
				
				if not is_drawing:
					var ray_query = PhysicsRayQueryParameters3D.new()
					ray_query.from = camera.project_ray_origin(editor_viewport.get_mouse_position())
					ray_query.to = ray_query.from + camera.project_ray_normal(editor_viewport.get_mouse_position()) * 1000
					ray_query.collide_with_bodies = true
					
					var hit = get_editor_interface().get_edited_scene_root().get_world_3d().direct_space_state.intersect_ray(ray_query)
					if hit:
						is_drawing = true
						draw_normal = hit.normal
						draw_start = _snap_to_grid(hit.position)
						draw_end = draw_start
						draw_plane = Plane(draw_normal, hit.position.dot(draw_normal))
						create_rectangle_preview()
						_calculate_base_rect_points()
						
				elif not is_extruding:
					is_extruding = true
					has_started_extrusion = false
					extrude_distance = 0.0
					
					var from = camera.project_ray_origin(editor_viewport.get_mouse_position())
					var dir = camera.project_ray_normal(editor_viewport.get_mouse_position())
					var intersection = draw_plane.intersects_ray(from, dir)
					
					if intersection:
						initial_extrude_point = _snap_to_grid(intersection)
						extrude_line_start = initial_extrude_point - draw_normal * 500.0
						extrude_line_end = initial_extrude_point + draw_normal * 500.0
						_update_rectangle_preview()
				
				else:
					_create_rectangle_voxels()
					is_drawing = false
					is_extruding = false
					has_started_extrusion = false
					if draw_preview:
						draw_preview.queue_free()
						draw_preview = null
			
			elif event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
				is_drawing = false
				is_extruding = false
				has_started_extrusion = false
				if draw_preview:
					draw_preview.queue_free()
					draw_preview = null
					
		elif event is InputEventMouseMotion:
			if is_drawing and not is_extruding:
				if not camera: return
				
				var from = camera.project_ray_origin(editor_viewport.get_mouse_position())
				var dir = camera.project_ray_normal(editor_viewport.get_mouse_position())
				
				var intersection = draw_plane.intersects_ray(from, dir)
				if intersection:
					draw_end = _snap_to_grid(intersection)
					_calculate_base_rect_points()
					_update_rectangle_preview()
			
			elif is_extruding:
				if not camera: return
				
				var from = camera.project_ray_origin(editor_viewport.get_mouse_position())
				var dir = camera.project_ray_normal(editor_viewport.get_mouse_position())
				
				if not has_started_extrusion:
					if event.relative.length() > 0.01:
						has_started_extrusion = true
						#print("Started extrusion")
				
				if has_started_extrusion:
					var mouse_point = from + dir * camera.position.distance_to(initial_extrude_point)
					var line_dir = (extrude_line_end - extrude_line_start).normalized()
					var to_point = mouse_point - extrude_line_start
					var projected_dist = to_point.dot(line_dir)
					var projected_point = extrude_line_start + line_dir * projected_dist
					var raw_distance = (projected_point - initial_extrude_point).dot(draw_normal)
					
					var grid_unit = 1.0
					if camera:
						var distance = camera.global_position.distance_to(initial_extrude_point)
						if distance > 50.0:
							grid_unit = 10.0
						if distance > 500.0:
							grid_unit = 100.0
						if distance > 5000.0:
							grid_unit = 1000.0
					
					var new_distance = round(raw_distance / grid_unit) * grid_unit
					
					if not is_equal_approx(extrude_distance, new_distance):
						extrude_distance = new_distance
						_update_rectangle_preview()

func _snap_to_grid(pos: Vector3) -> Vector3:
	if not selected_grid:
		return pos
	
	var grid_unit = 1.0

	if selected_grid.grid_scale != 0:
		grid_unit = selected_grid.grid_scale
	else:
		if camera:
			var distance = camera.global_position.distance_to(pos)
			if distance > 50.0:
				grid_unit = 10.0
			if distance > 500.0:
				grid_unit = 100.0
			if distance > 5000.0:
				grid_unit = 1000.0
	
	return Vector3(
		round(pos.x / grid_unit) * grid_unit,
		round(pos.y / grid_unit) * grid_unit,
		round(pos.z / grid_unit) * grid_unit
	)

func _calculate_base_rect_points() -> void:
	if not selected_grid:
		return
		
	var grid_unit = 1.0 

	if selected_grid.grid_scale != 0:
		grid_unit = selected_grid.grid_scale
		if grid_unit == 1.0:
			grid_unit = 0.1
	else:
		if camera:
			var distance = camera.global_position.distance_to(draw_start)
			if distance > 50.0:
				grid_unit = 10.0
			if distance > 500.0:
				grid_unit = 100.0
			if distance > 5000.0:
				grid_unit = 1000.0
	
	var min_x = floor(min(draw_start.x, draw_end.x) / grid_unit) * grid_unit
	var max_x = ceil(max(draw_start.x, draw_end.x) / grid_unit) * grid_unit
	var min_y = floor(min(draw_start.y, draw_end.y) / grid_unit) * grid_unit
	var max_y = ceil(max(draw_start.y, draw_end.y) / grid_unit) * grid_unit
	var min_z = floor(min(draw_start.z, draw_end.z) / grid_unit) * grid_unit
	var max_z = ceil(max(draw_start.z, draw_end.z) / grid_unit) * grid_unit
	
	if draw_normal.abs().is_equal_approx(Vector3.UP) or draw_normal.abs().is_equal_approx(Vector3.DOWN):
		base_rect_points = [
			Vector3(min_x, draw_start.y, min_z),
			Vector3(max_x, draw_start.y, min_z),
			Vector3(max_x, draw_start.y, max_z),
			Vector3(min_x, draw_start.y, max_z)
		]
	elif draw_normal.abs().is_equal_approx(Vector3.RIGHT) or draw_normal.abs().is_equal_approx(Vector3.LEFT):
		base_rect_points = [
			Vector3(draw_start.x, min_y, min_z),
			Vector3(draw_start.x, max_y, min_z),
			Vector3(draw_start.x, max_y, max_z),
			Vector3(draw_start.x, min_y, max_z)
		]
	else:
		base_rect_points = [
			Vector3(min_x, min_y, draw_start.z),
			Vector3(max_x, min_y, draw_start.z),
			Vector3(max_x, max_y, draw_start.z),
			Vector3(min_x, max_y, draw_start.z)
		]

func create_rectangle_preview() -> void:
	if draw_preview:
		draw_preview.queue_free()
	
	draw_preview = MeshInstance3D.new()
	var immediate_mesh = ImmediateMesh.new()
	draw_preview.mesh = immediate_mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.0, 0.0, 1.0)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	draw_preview.material_override = material
	
	if voxel_root:
		voxel_root.add_child(draw_preview)
		draw_preview.owner = get_editor_interface().get_edited_scene_root()

func _update_rectangle_preview() -> void:
	if not draw_preview: return
	var immediate_mesh = draw_preview.mesh as ImmediateMesh
	immediate_mesh.clear_surfaces()
	
	var base_thickness = BASE_PREVIEW_THICKNESS
	var thickness = base_thickness
	var grid_unit = 1.0
	
	if camera:
		var distance = camera.global_position.distance_to(draw_start)
		if distance > DISTANCE_THRESHOLD_SMALL:
			thickness = base_thickness * 10.0
			grid_unit = GRID_SCALE_SMALL
		if distance > DISTANCE_THRESHOLD_MEDIUM:
			thickness = base_thickness * 20.0
			grid_unit = GRID_SCALE_MEDIUM
		if distance > DISTANCE_THRESHOLD_LARGE:
			thickness = base_thickness * 30.0
			grid_unit = GRID_SCALE_LARGE
			
	var preview_offset = draw_normal * (grid_unit * 0.01)
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var preview_points = []
	for point in base_rect_points:
		preview_points.append(point + preview_offset)

	for i in range(preview_points.size()):
		add_thick_line(
			immediate_mesh,
			preview_points[i],
			preview_points[(i + 1) % preview_points.size()],
			thickness
		)
	
	if is_extruding:
		add_thick_line(immediate_mesh, 
			initial_extrude_point + preview_offset,
			initial_extrude_point + draw_normal * (extrude_distance + preview_offset.length()),
			thickness * 0.5)
		
		if has_started_extrusion:
			var extrude_offset = draw_normal * extrude_distance
			
			for i in range(preview_points.size()):
				var extruded_point = preview_points[i] + extrude_offset
				add_thick_line(immediate_mesh, 
					preview_points[i], 
					extruded_point, 
					thickness)
				add_thick_line(
					immediate_mesh,
					extruded_point,
					preview_points[(i + 1) % preview_points.size()] + extrude_offset,
					thickness
				)
	
	immediate_mesh.surface_end()

func add_thick_line(immediate_mesh: ImmediateMesh, start: Vector3, end: Vector3, thickness: float) -> void:
	var direction = (end - start).normalized()
	var perpendicular = direction.cross(Vector3.UP).normalized()
	if perpendicular.length() < 0.1:
		perpendicular = direction.cross(Vector3.RIGHT).normalized()
		
	var v1 = start + perpendicular * thickness
	var v2 = start - perpendicular * thickness
	var v3 = end + perpendicular * thickness
	var v4 = end - perpendicular * thickness
	
	immediate_mesh.surface_add_vertex(v1)
	immediate_mesh.surface_add_vertex(v2)
	immediate_mesh.surface_add_vertex(v3)
	immediate_mesh.surface_add_vertex(v2)
	immediate_mesh.surface_add_vertex(v4)
	immediate_mesh.surface_add_vertex(v3)
	
	immediate_mesh.surface_add_vertex(v1)
	immediate_mesh.surface_add_vertex(v3)
	immediate_mesh.surface_add_vertex(v2)
	immediate_mesh.surface_add_vertex(v2)
	immediate_mesh.surface_add_vertex(v3)
	immediate_mesh.surface_add_vertex(v4)
	
	var up = direction.cross(perpendicular).normalized() * thickness
	var v1_up = v1 + up
	var v2_up = v2 + up
	var v3_up = v3 + up
	var v4_up = v4 + up
	
	immediate_mesh.surface_add_vertex(v1)
	immediate_mesh.surface_add_vertex(v1_up)
	immediate_mesh.surface_add_vertex(v3)
	immediate_mesh.surface_add_vertex(v3)
	immediate_mesh.surface_add_vertex(v1_up)
	immediate_mesh.surface_add_vertex(v3_up)
	
	immediate_mesh.surface_add_vertex(v2)
	immediate_mesh.surface_add_vertex(v4)
	immediate_mesh.surface_add_vertex(v2_up)
	immediate_mesh.surface_add_vertex(v4)
	immediate_mesh.surface_add_vertex(v4_up)
	immediate_mesh.surface_add_vertex(v2_up)

func _create_rectangle_voxels() -> void:
	var new_voxel = CSGBox3D.new()
	new_voxel.use_collision = true
	new_voxel.set_meta("_edit_lock_", true)
	new_voxel.set_meta("_edit_group_", true)
	

	var min_point = base_rect_points[0]
	var max_point = base_rect_points[0]
	
	for point in base_rect_points:
		min_point = Vector3(
			min(min_point.x, point.x),
			min(min_point.y, point.y),
			min(min_point.z, point.z)
		)
		max_point = Vector3(
			max(max_point.x, point.x),
			max(max_point.y, point.y),
			max(max_point.z, point.z)
		)
	
	var size = (max_point - min_point)
	var center = (max_point + min_point) * 0.5
	
	if draw_normal.abs().is_equal_approx(Vector3.UP) or draw_normal.abs().is_equal_approx(Vector3.DOWN):
		size.y = abs(extrude_distance)
		center += draw_normal * (extrude_distance * 0.5)
	elif draw_normal.abs().is_equal_approx(Vector3.RIGHT) or draw_normal.abs().is_equal_approx(Vector3.LEFT):
		size.x = abs(extrude_distance)
		center += draw_normal * (extrude_distance * 0.5)
	else:
		size.z = abs(extrude_distance)
		center += draw_normal * (extrude_distance * 0.5)
		
	new_voxel.size = size
	new_voxel.position = center
	if extrude_distance < 0:
		new_voxel.operation = CSGShape3D.OPERATION_SUBTRACTION

	voxel_root.add_child(new_voxel)
	new_voxel.owner = get_editor_interface().get_edited_scene_root()

func _on_merge_mesh() -> void:
	if not voxel_root or voxel_root.get_child_count() == 0:
		return
	if voxel_root.has_node("VoxelMesh"):
		push_warning("There are no cubes to Merge!")
		return
	
	var voxels_to_keep = []
	for voxel in voxel_root.get_children():
		if not (voxel is CSGBox3D):
			continue
			
		var voxel_bounds = AABB(
			voxel.position - (voxel.size * 0.5), 
			voxel.size
		)
		if voxel.operation == CSGShape3D.OPERATION_SUBTRACTION:
			var cuts_something = false
			for other_voxel in voxel_root.get_children():
				if other_voxel is CSGBox3D and other_voxel.operation == CSGShape3D.OPERATION_UNION:
					var other_bounds = AABB(
						other_voxel.position - (other_voxel.size * 0.5),
						other_voxel.size
					)
					if voxel_bounds.intersects(other_bounds):
						cuts_something = true
						break
			if cuts_something:
				voxels_to_keep.append(voxel)
		else:
			voxels_to_keep.append(voxel)
	
	var voxels_data = []
	for voxel in voxels_to_keep:
		voxels_data.append(_store_voxel_data(voxel))
	
	var meshes = voxel_root.get_meshes()
	if meshes.size() > 1:
		if not voxel_mesh:
			voxel_mesh = MeshInstance3D.new()
			voxel_mesh.name = "VoxelMesh"
			voxel_root.add_child(voxel_mesh)
			voxel_mesh.owner = get_editor_interface().get_edited_scene_root()
		
		voxel_mesh.mesh = meshes[1]
		
		voxel_mesh.set_meta("voxel_data", {
			"voxels": voxels_data,
			"voxel_size": voxel_size
		})
		
		for child in voxel_root.get_children():
			if child != voxel_mesh:
				child.queue_free()
		_update_toolbar_states()
		
func _on_edit_mesh() -> void:
	if not voxel_root:
		push_warning("No voxel root found!")
		return
		
	if not voxel_root.has_node("VoxelMesh"):
		push_warning("No VoxelMesh to edit!")
		return
		
	voxel_mesh = voxel_root.get_node("VoxelMesh")
	var data = voxel_mesh.get_meta("voxel_data")
	if not data:
		push_warning("No voxel data found in mesh!")
		return
		
	_convert_to_voxels()

func _store_voxel_data(voxel: CSGBox3D) -> Dictionary:
	return {
		"position": voxel.position,
		"operation": voxel.operation,
		"size": voxel.size
	}

func _convert_to_voxels() -> void:
	voxel_mesh = voxel_root.get_node("VoxelMesh")
	if not voxel_mesh:
		push_warning("No VoxelMesh node found!")
		return
		
	var data = voxel_mesh.get_meta("voxel_data")
	if not data:
		push_warning("No voxel data found in mesh!")
		return
	
	voxel_size = data.voxel_size
	
	for voxel_info in data["voxels"]:
		var new_voxel = CSGBox3D.new()
		new_voxel.position = voxel_info["position"]
		new_voxel.size = voxel_info["size"]
		new_voxel.operation = voxel_info["operation"]
		new_voxel.use_collision = true
		
		new_voxel.set_meta("_edit_lock_", true)
		new_voxel.set_meta("_edit_group_", true)
		
		voxel_root.add_child(new_voxel)
		new_voxel.owner = get_editor_interface().get_edited_scene_root()

	voxel_mesh.queue_free()
	voxel_mesh = null

	toolbar.update_button_states(false)
	_change_mode(BuildMode.SELECT)

func _align_grid_to_normal(normal: Vector3, hit_position: Vector3) -> void:
	if not selected_grid:
		return
	
	var mesh = selected_grid.get_node_or_null("CubeGridMesh3D")
	var collision = selected_grid.get_node_or_null("CubeGridCollisionShape3D")
	
	if not mesh or not collision:
		return
		
	var mesh_scale = mesh.scale
	var collision_scale = collision.scale
	var normalized_normal = normal.normalized()
	var up = -normalized_normal
	var right = up.cross(Vector3.UP)
	if right.length() < 0.1:
		right = up.cross(Vector3.RIGHT)
	right = right.normalized()
	var forward = up.cross(right)
	var rotation = Transform3D(right, up, forward, Vector3.ZERO)
	var offset_position = hit_position + normalized_normal * 0.01
	var transform = Transform3D(rotation.basis, offset_position)
	
	mesh.transform = transform
	collision.transform = transform
	mesh.scale = mesh_scale
	collision.scale = collision_scale
	
	if selected_grid.grid_material:
		selected_grid.grid_material.set_shader_parameter("up_vector", normalized_normal)
		selected_grid._update_material()

func _reset_grid_transform() -> void:
	if not selected_grid:
		return
		
	var mesh = selected_grid.get_node_or_null("CubeGridMesh3D")
	var collision = selected_grid.get_node_or_null("CubeGridCollisionShape3D")
	
	if not mesh or not collision:
		return
		
	var mesh_scale = mesh.scale
	var collision_scale = collision.scale
	
	mesh.transform = Transform3D()
	collision.transform = Transform3D()
	
	mesh.scale = mesh_scale
	collision.scale = collision_scale
	
	if selected_grid.grid_material:
		selected_grid.grid_material.set_shader_parameter("up_vector", Vector3.UP)
		selected_grid._update_material()