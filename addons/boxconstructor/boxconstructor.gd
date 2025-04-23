@tool
extends EditorPlugin

# === Constants ===
enum BuildMode {
	DISABLE,
	SELECT,
	ADD
}

const DISTANCE_THRESHOLD_SMALL = 50.0
const DISTANCE_THRESHOLD_MEDIUM = 500.0
#const DISTANCE_THRESHOLD_LARGE = 5000.0
const GRID_SCALE_SMALL = 10.0
const GRID_SCALE_MEDIUM = 100.0
#const GRID_SCALE_LARGE = 1000.0
const BASE_PREVIEW_THICKNESS = 0.02

# === Editor properties ===
var current_mode: BuildMode = BuildMode.SELECT
var toolbar: PanelContainer
var editor_viewport = get_editor_interface().get_editor_viewport_3d()
var camera = editor_viewport.get_camera_3d()

# === Grid and Voxel properties ===
var voxel_root: CSGCombiner3D
var selected_grid: CubeGrid3D
var voxel_mesh: MeshInstance3D = null

# === Rectangle drawing properties ===
var is_drawing: bool = false
var draw_normal: Vector3 = Vector3.UP
var draw_start: Vector3 = Vector3()
var draw_end: Vector3 = Vector3()
var draw_preview: MeshInstance3D = null
var draw_plane: Plane
var base_rect_points: Array = []

# === Extrusion properties ===
var is_extruding: bool = false
var has_started_extrusion: bool = false
var extrude_distance: float = 0.0
var initial_extrude_point: Vector3
var extrude_line_start: Vector3
var extrude_line_end: Vector3

# === Edge Movement properties ===
var edge_preview: MeshInstance3D = null
var current_edge: Array = []
var is_dragging_edge: bool = false
var dragged_mesh: CSGMesh3D = null
var drag_start_position: Vector3
var drag_plane: Plane
var drag_start_offset: Vector3


# === Lifecycle Methods ===
func _enter_tree() -> void:
	get_editor_interface().get_selection().selection_changed.connect(_on_selection_changed)
	editor_viewport = get_editor_interface().get_editor_viewport_3d()

	# Create the toolbar
	toolbar = preload("res://addons/boxconstructor/scripts/toolbar.gd").new(self)
	var viewport_base = editor_viewport.get_parent().get_parent()
	viewport_base.add_child(toolbar)
	toolbar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, 0, 10)
	# Hide toolbar by default
	toolbar.hide()
	# Connect signals
	_connect_toolbar_signals()

func _exit_tree() -> void:
	# Remove the toolbar
	if toolbar:
		toolbar.queue_free()
	# Disconnect signals
	if get_editor_interface().get_selection().selection_changed.is_connected(_on_selection_changed):
		get_editor_interface().get_selection().selection_changed.disconnect(_on_selection_changed)

func _process(_delta: float) -> void:
	# Here we change the grid scale based on the distance to the camera (y-axis)
	if selected_grid:
		if camera and selected_grid.grid_material:
			if selected_grid.grid_scale == 0:
				var distance = abs(camera.global_position.y - selected_grid.global_position.y)
				selected_grid.grid_material.set_shader_parameter("camera_distance", distance)
				# Set the grid scale based on the distance
				#if distance > DISTANCE_THRESHOLD_LARGE:
				#	selected_grid.grid_material.set_shader_parameter("grid_scale", GRID_SCALE_LARGE)
				if distance > DISTANCE_THRESHOLD_MEDIUM:
					selected_grid.grid_material.set_shader_parameter("grid_scale", GRID_SCALE_MEDIUM)
				elif distance > DISTANCE_THRESHOLD_SMALL:
					selected_grid.grid_material.set_shader_parameter("grid_scale", GRID_SCALE_SMALL)
				else:
					selected_grid.grid_material.set_shader_parameter("grid_scale", 1.0)

func _input(event: InputEvent) -> void:
	if not selected_grid or not selected_grid.is_inside_tree():
		return
	# Handles all the input events for the plugin
	if event is InputEventKey and event.pressed and event.keycode == KEY_X:
		if not camera or not selected_grid:
			return
		var ray_query = PhysicsRayQueryParameters3D.new()
		ray_query.from = camera.project_ray_origin(editor_viewport.get_mouse_position())
		ray_query.to = ray_query.from + camera.project_ray_normal(editor_viewport.get_mouse_position()) * 1000
		ray_query.collide_with_bodies = true
		var hit = get_editor_interface().get_edited_scene_root().get_world_3d().direct_space_state.intersect_ray(ray_query)
		if hit:
			#print("Hit position: ", hit.position)
			var snapped_pos = _snap_to_grid(hit.position)
			_align_grid_to_normal(hit.normal, snapped_pos)
	if event is InputEventKey  and event.pressed and event.keycode == KEY_Z:
		_reset_grid_transform()
	# Handle Edge Movement Logic
	if current_mode == BuildMode.SELECT:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				if not is_dragging_edge:
					if edge_preview and edge_preview.visible:
						for child in voxel_root.get_children():
							if child is CSGBox3D or child is CSGMesh3D:
								var edges = _get_edges(child)
								for edge in edges:
									if edge[0].is_equal_approx(current_edge[0]) and edge[1].is_equal_approx(current_edge[1]):
										var from = camera.project_ray_origin(event.position)
										var dir = camera.project_ray_normal(event.position)

										# Create a plane for the edge to drag along
										var edge_dir = (edge[1] - edge[0]).normalized()
										drag_plane = Plane(edge_dir, edge[0].dot(edge_dir))
										
										var intersection = drag_plane.intersects_ray(from, dir)
										if intersection:
											# We turn the CSGBox3D into a custom mesh that allows use to move the vertecies
											if child is CSGBox3D:
												dragged_mesh = _convert_box_to_CSGMesh(child)
											else:
												dragged_mesh = child
											is_dragging_edge = true
											current_edge = edge
											drag_start_offset = _snap_to_grid(intersection)
										break
				else:
					is_dragging_edge = false
					dragged_mesh = null
					edge_preview.hide()
					
		if event is InputEventMouseMotion:
			if is_dragging_edge and dragged_mesh:
				edge_preview.hide()
				var from = camera.project_ray_origin(event.position)
				var dir = camera.project_ray_normal(event.position)
				
				# Project mouse position onto drag plane
				var intersection = drag_plane.intersects_ray(from, dir)
				if intersection:
					# Calculate new position with grid snapping
					var snapped_pos = _snap_to_grid(intersection)
					var offset = snapped_pos - drag_start_offset
					
					var arr_mesh = dragged_mesh.mesh as ArrayMesh
					if arr_mesh:
						var arrays = arr_mesh.surface_get_arrays(0)
						var vertices = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
				
						var local_edge = [
							dragged_mesh.to_local(current_edge[0]),
    						dragged_mesh.to_local(current_edge[1])
						]
						var local_offset = dragged_mesh.global_transform.basis.inverse() * offset
						var new_vertices = PackedVector3Array()
						new_vertices.resize(vertices.size())
						
						# Move vertices that match the edge points
						for i in range(vertices.size()):
							var vertex = vertices[i]
							if vertex.is_equal_approx(local_edge[0]) or vertex.is_equal_approx(local_edge[1]):
								new_vertices[i] = vertex + local_offset
							else:
								new_vertices[i] = vertex
						
						# Update the mesh
						var new_arrays = []
						new_arrays.resize(Mesh.ARRAY_MAX)
						new_arrays[Mesh.ARRAY_VERTEX] = new_vertices
						new_arrays[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
						
						arr_mesh.clear_surfaces()
						arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, new_arrays)
					
						current_edge = [
							dragged_mesh.global_transform * (local_edge[0] + local_offset),
							dragged_mesh.global_transform * (local_edge[1] + local_offset)
						]
						drag_start_offset = snapped_pos
			
            
			
			# Highlight the Edge
			elif not is_dragging_edge:
				if not camera or not voxel_root:
					if edge_preview:
						edge_preview.hide()
					return
				
				var mouse_pos = editor_viewport.get_mouse_position()
				var closest_node = null
				var closest_distance = INF
				
				for child in voxel_root.get_children():
					if not (child is CSGBox3D or child is CSGMesh3D):
						continue
					
					var node_center = child.global_position
					var screen_pos = camera.unproject_position(node_center)
					var distance = screen_pos.distance_to(mouse_pos)
					
					if distance < closest_distance:
						closest_node = child
						closest_distance = distance
				
				if closest_node and closest_distance < 1000:
					var closest_edge = _find_closest_edge(closest_node, mouse_pos)
					current_edge = closest_edge
					_create_edge_preview(closest_edge)
				else:
					current_edge = []
					if edge_preview:
						edge_preview.hide()
				
	# Handle Rectangle Drawing and Extrusion Logic
	if current_mode == BuildMode.ADD:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				if not camera: return

				# Draw the base rectangle
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

				# Start extruding the rectangle
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

				# Create the new box
				else:
					_create_CSGBox3D()
					is_drawing = false
					is_extruding = false
					has_started_extrusion = false
					if draw_preview:
						draw_preview.queue_free()
						draw_preview = null

			# Cancel the drawing
			elif event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
				is_drawing = false
				is_extruding = false
				has_started_extrusion = false
				if draw_preview:
					draw_preview.queue_free()
					draw_preview = null

		# Update section		
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
				
				if has_started_extrusion:
					var mouse_point = from + dir * camera.position.distance_to(initial_extrude_point)
					var line_dir = (extrude_line_end - extrude_line_start).normalized()
					var to_point = mouse_point - extrude_line_start
					var projected_dist = to_point.dot(line_dir)
					var projected_point = extrude_line_start + line_dir * projected_dist
					var raw_distance = (projected_point - initial_extrude_point).dot(draw_normal)
					
					var grid_unit = 1.0
					if selected_grid.grid_scale > 0:
						grid_unit = selected_grid.grid_scale
					else:
						if camera:
							var distance = camera.global_position.distance_to(initial_extrude_point)
							if distance > DISTANCE_THRESHOLD_SMALL:
								grid_unit = GRID_SCALE_SMALL
							if distance > DISTANCE_THRESHOLD_MEDIUM:
								grid_unit = GRID_SCALE_MEDIUM
							#if distance > DISTANCE_THRESHOLD_LARGE:
							#	grid_unit = GRID_SCALE_LARGE
					
					var new_distance = round(raw_distance / grid_unit) * grid_unit
					
					if not is_equal_approx(extrude_distance, new_distance):
						extrude_distance = new_distance
						_update_rectangle_preview()


# === Grid Methods ===
func _on_grid_size_changed(size: int) -> void:
	# Update the grid material
	var selected = get_editor_interface().get_selection().get_selected_nodes()
	if selected.size() > 0 and selected[0] is CubeGrid3D:
		selected[0].grid_scale = size
		selected[0]._update_material()
	
func _snap_to_grid(pos: Vector3) -> Vector3:
	if not selected_grid:
		return pos

	# Default smallest unit
	var grid_unit = 1.0

	# If we have set our own grid scale use that for snapping
	if selected_grid.grid_scale > 0:
		grid_unit = selected_grid.grid_scale
	else:
		# Dynamically set the snap
		if camera:
			var distance = camera.global_position.distance_to(pos)
			if distance > DISTANCE_THRESHOLD_SMALL:
				grid_unit = GRID_SCALE_SMALL
			if distance > DISTANCE_THRESHOLD_MEDIUM:
				grid_unit = GRID_SCALE_MEDIUM
			#if distance > DISTANCE_THRESHOLD_LARGE:
			#	grid_unit = GRID_SCALE_LARGE
	
	return Vector3(
		round(pos.x / grid_unit) * grid_unit,
		round(pos.y / grid_unit) * grid_unit,
		round(pos.z / grid_unit) * grid_unit
	)

func _align_grid_to_normal(normal: Vector3, hit_position: Vector3) -> void:
	if not selected_grid:
		return
	
	var mesh = selected_grid.get_node_or_null("CubeGridMesh3D")
	var collision = selected_grid.get_node_or_null("CubeGridCollisionShape3D")
	
	if not mesh or not collision:
		return
	# Store scales to reset later
	var mesh_scale = mesh.scale
	var collision_scale = collision.scale

	# Align the grid to the normal
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
	
	# Apply the transform and restore the scale
	mesh.transform = transform
	collision.transform = transform
	mesh.scale = mesh_scale
	collision.scale = collision_scale
	
	# Update the shader
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
	
	# Reset the transform
	mesh.transform = Transform3D()
	collision.transform = Transform3D()
	
	mesh.scale = mesh_scale
	collision.scale = collision_scale
	
	if selected_grid.grid_material:
		selected_grid.grid_material.set_shader_parameter("up_vector", Vector3.UP)
		selected_grid._update_material()

# === Drawing Methods ===
func _calculate_base_rect_points() -> void:
	if not selected_grid:
		return
		
	# Get the grid unit size	
	var grid_unit = 1.0 
	if selected_grid.grid_scale != 0:
		grid_unit = selected_grid.grid_scale
		if grid_unit == 1.0:
			grid_unit = 0.1
	else:
		if camera:
			var distance = camera.global_position.distance_to(draw_start)
			if distance > DISTANCE_THRESHOLD_SMALL:
				grid_unit = GRID_SCALE_SMALL
			if distance > DISTANCE_THRESHOLD_MEDIUM:
				grid_unit = GRID_SCALE_MEDIUM
			#if distance > DISTANCE_THRESHOLD_LARGE:
			#	grid_unit = GRID_SCALE_LARGE
	
	# Calculate the base rectangle points
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
	# Clear the previous preview
	if draw_preview:
		draw_preview.queue_free()
	
	# Create a new preview 
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
	
	# Scale the thickness of the lines based on the distance of the camera
	if camera:
		var distance = camera.global_position.distance_to(draw_start)
		if distance > DISTANCE_THRESHOLD_SMALL:
			thickness = base_thickness * 10.0
			grid_unit = GRID_SCALE_SMALL
		if distance > DISTANCE_THRESHOLD_MEDIUM:
			thickness = base_thickness * 20.0
			grid_unit = GRID_SCALE_MEDIUM
		#if distance > DISTANCE_THRESHOLD_LARGE:
		#	thickness = base_thickness * 30.0
		#	grid_unit = GRID_SCALE_LARGE
			
	var preview_offset = draw_normal * (grid_unit * 0.01)
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var preview_points = []
	for point in base_rect_points:
		preview_points.append(point + preview_offset)

	# Rectangle base lines
	for i in range(preview_points.size()):
		add_thick_line(
			immediate_mesh,
			preview_points[i],
			preview_points[(i + 1) % preview_points.size()],
			thickness
		)
	# Extrusion lines
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


# === Voxel Management Methods ===
func _create_CSGBox3D() -> void:
	var new_voxel = CSGBox3D.new()
	new_voxel.use_collision = true
	new_voxel.set_meta("_edit_lock_", true)
	new_voxel.set_meta("_edit_group_", true)
	

	var min_point = base_rect_points[0]
	var max_point = base_rect_points[0]
	
	# Minimum and maximum points of the base rectangle
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

	# Initial size and center of the box
	var size = (max_point - min_point)
	var center = (max_point + min_point) * 0.5
	
	# Adjust size and center based on the extrusion
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

	# Depending on the extrusion distance set the operation
	if extrude_distance < 0:
		new_voxel.operation = CSGShape3D.OPERATION_SUBTRACTION

	voxel_root.add_child(new_voxel)
	new_voxel.owner = get_editor_interface().get_edited_scene_root()

func _on_merge_mesh() -> void:
	if not voxel_root or voxel_root.get_child_count() == 0:
		return
	# Dont allow to merge an already merged mesh
	if voxel_root.has_node("VoxelMesh"):
		push_warning("Already merged!")
		return
	
	if edge_preview:
		edge_preview.queue_free()
		edge_preview = null
	current_edge = []
	is_dragging_edge = false

	var nodes_to_keep = []
	for node in voxel_root.get_children():
		if not (node is CSGBox3D or node is CSGMesh3D):
			continue
			
		if node.operation == CSGShape3D.OPERATION_SUBTRACTION:
			var cuts_something = false
			for other_node in voxel_root.get_children():
				if other_node.operation == CSGShape3D.OPERATION_UNION:
					if node is CSGBox3D and other_node is CSGBox3D:
						var node_bounds = AABB(
							node.position - (node.size * 0.5),
							node.size
						)
						var other_bounds = AABB(
							other_node.position - (other_node.size * 0.5),
							other_node.size
						)
						if node_bounds.intersects(other_bounds):
							cuts_something = true
							break
					else:
						cuts_something = true
						break
			# Only keep if it actually cuts something
			if cuts_something:
				nodes_to_keep.append(node)
		else:
			nodes_to_keep.append(node)

	var nodes_data = []
	for node in nodes_to_keep:
		nodes_data.append(_store_voxel_data(node))
	
	var meshes = voxel_root.get_meshes()
	if meshes.size() > 1:
		if not voxel_mesh:
			voxel_mesh = MeshInstance3D.new()
			voxel_mesh.name = "VoxelMesh"
			voxel_root.add_child(voxel_mesh)
			voxel_mesh.owner = get_editor_interface().get_edited_scene_root()

		voxel_mesh.mesh = meshes[1]
		voxel_mesh.set_meta("voxel_data", {
			"nodes": nodes_data
		})
		
		for child in voxel_root.get_children():
			if child != voxel_mesh:
				child.queue_free()
				
		_update_toolbar_states()
		_change_mode(BuildMode.DISABLE)
		
func _on_edit_mesh() -> void:
	if not voxel_root:
		push_warning("No voxel root found!")
		return
		
	if not voxel_root.has_node("VoxelMesh"):
		push_warning("No VoxelMesh to edit!")
		return

	# Get info from the metadata
	voxel_mesh = voxel_root.get_node("VoxelMesh")
	var data = voxel_mesh.get_meta("voxel_data")
	if not data:
		push_warning("No voxel data found in mesh!")
		return
		
	_convert_to_voxels()

func _store_voxel_data(node: Node) -> Dictionary:
	var data = {
		"position": node.position,
		"basis": node.transform.basis,
		"operation": node.operation,
		"use_collision": node.use_collision,
		"type": "box" if node is CSGBox3D else "mesh"
	}
	
	if node is CSGBox3D:
		data["size"] = node.size
	elif node is CSGMesh3D:
		var mesh = node.mesh as ArrayMesh
		if mesh:
			# Store vertices in local space
			data["vertices"] = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			data["indices"] = mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	
	return data


func _convert_to_voxels() -> void:
	voxel_mesh = voxel_root.get_node("VoxelMesh")
	if not voxel_mesh:
		push_warning("No VoxelMesh node found!")
		return
	
	var data = voxel_mesh.get_meta("voxel_data")
	if not data:
		push_warning("No voxel data found in mesh!")
		return
	
	for node_info in data["nodes"]:
		var new_node
		
		# Based on the type, recreate CSGBox3D or CSGMesh3D
		if node_info["type"] == "box":
			new_node = CSGBox3D.new()
			new_node.size = node_info["size"]
		else:
			new_node = CSGMesh3D.new()
			var arr_mesh = ArrayMesh.new()
			var arrays = []
			arrays.resize(Mesh.ARRAY_MAX)
			
			arrays[Mesh.ARRAY_VERTEX] = node_info["vertices"]
			arrays[Mesh.ARRAY_INDEX] = node_info["indices"]
			arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			new_node.mesh = arr_mesh

		new_node.transform = Transform3D(node_info["basis"], node_info["position"])
		new_node.operation = node_info["operation"]
		new_node.use_collision = node_info["use_collision"]
		
		new_node.set_meta("_edit_lock_", true)
		new_node.set_meta("_edit_group_", true)
		
		voxel_root.add_child(new_node)
		new_node.owner = get_editor_interface().get_edited_scene_root()

	# Remove the VoxelMesh
	voxel_mesh.queue_free()
	voxel_mesh = null

	toolbar.update_button_states(false)
	_change_mode(BuildMode.DISABLE)


# === UI Management Methods ===
func _connect_toolbar_signals() -> void:
	toolbar.select_button_pressed.connect(func(): _change_mode(BuildMode.SELECT))
	toolbar.add_button_pressed.connect(func(): _change_mode(BuildMode.ADD))
	toolbar.disable_button_pressed.connect(func(): _change_mode(BuildMode.DISABLE))  # Add this line
	toolbar.grid_size_changed.connect(_on_grid_size_changed)
	toolbar.reset_grid_pressed.connect(_reset_grid_transform)
	toolbar.merge_mesh.connect(_on_merge_mesh)
	toolbar.edit_mesh.connect(_on_edit_mesh)

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

func _on_selection_changed() -> void:
	var selected = get_editor_interface().get_selection().get_selected_nodes()
	if selected.size() == 1 and selected[0] is CubeGrid3D:
		selected_grid = selected[0]
		voxel_root = selected_grid.get_node("CSGCombiner3D")
		toolbar.show()
		_update_toolbar_states()
	else:
		selected_grid = null
		voxel_root = null
		toolbar.hide()

func _change_mode(new_mode: BuildMode) -> void:
	if new_mode == BuildMode.ADD and voxel_root and voxel_root.has_node("VoxelMesh"):
		push_warning("Can't switch to ADD mode while VoxelMesh exists. Use Edit to modify.")
		toolbar.set_active_mode(current_mode)
		return

	current_mode = new_mode
	toolbar.set_active_mode(current_mode)

	if edge_preview:
		edge_preview.queue_free()
		edge_preview = null
	current_edge = []
	is_dragging_edge = false

	if voxel_root:
		voxel_root.set_meta("_edit_lock_", current_mode != BuildMode.SELECT)

# === Edge Movement Methods ===
func _get_edges(node: Node) -> Array:
	var edges = []
	
	if node is CSGBox3D:
		var aabb = AABB(
			node.global_position - (node.size * 0.5),
			node.size
		)
		# Create the corners of the AABB
		var corners = [
			Vector3(aabb.position.x, aabb.position.y, aabb.position.z),
			Vector3(aabb.end.x, aabb.position.y, aabb.position.z),
			Vector3(aabb.end.x, aabb.end.y, aabb.position.z),
			Vector3(aabb.position.x, aabb.end.y, aabb.position.z),
			Vector3(aabb.position.x, aabb.position.y, aabb.end.z),
			Vector3(aabb.end.x, aabb.position.y, aabb.end.z),
			Vector3(aabb.end.x, aabb.end.y, aabb.end.z),
			Vector3(aabb.position.x, aabb.end.y, aabb.end.z)
		]
		# Create the edges of the AABB
		var edge_indices = [
			[0, 1], [1, 2], [2, 3], [3, 0],
			[4, 5], [5, 6], [6, 7], [7, 4],
			[0, 4], [1, 5], [2, 6], [3, 7]
		]
		# Create edges from the corner pairs
		for pair in edge_indices:
			edges.append([corners[pair[0]], corners[pair[1]]])
			
	elif node is CSGMesh3D:
		var arr_mesh = node.mesh as ArrayMesh
		if not arr_mesh:
			return edges
			
		var arrays = arr_mesh.surface_get_arrays(0)
		var vertices = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var indices = arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		var edge_set = {}
		
		# Go through the indicies and create an edgemap
		for i in range(0, indices.size(), 3):
			var tri_indices = [
				indices[i],
				indices[i + 1],
				indices[i + 2]
			]
			
			for j in range(3):
				var idx1 = tri_indices[j]
				var idx2 = tri_indices[(j + 1) % 3]
				
				var edge_key = str(min(idx1, idx2)) + "_" + str(max(idx1, idx2))
				if not edge_set.has(edge_key):
					edge_set[edge_key] = true
					var v1 = node.global_transform * vertices[idx1]
					var v2 = node.global_transform * vertices[idx2]
					edges.append([v1, v2])
	
	return edges


func _find_closest_edge(node: Node, mouse_pos: Vector2) -> Array:
	if not camera:
		return []
		
	var edges = _get_edges(node)
	var closest_edge = []
	var min_distance = 25.0
	
	var from = camera.project_ray_origin(mouse_pos)
	var dir = camera.project_ray_normal(mouse_pos)
	
	for edge in edges:
		var start = edge[0]
		var end = edge[1]
		
		var result = Geometry3D.get_closest_points_between_segments(from, from + dir * 1000, start, end)
		var point_on_edge = result[1]
		var screen_point = camera.unproject_position(point_on_edge)
		
		var distance = screen_point.distance_to(mouse_pos)
		var depth = camera.global_position.distance_to(point_on_edge)
		
		if distance < min_distance:
			min_distance = distance
			var min_depth = depth
			closest_edge = edge
	
	return closest_edge

func _create_edge_preview(edge: Array) -> void:
	if edge.is_empty():
		if edge_preview:
			edge_preview.hide()
		return
		
	if not edge_preview:
		edge_preview = MeshInstance3D.new()
		var immediate_mesh = ImmediateMesh.new()
		edge_preview.mesh = immediate_mesh
		
		var material = StandardMaterial3D.new()
		material.albedo_color = Color(1.0, 0.0, 0.0, 1.0)
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		edge_preview.material_override = material
		
		if voxel_root:
			voxel_root.add_child(edge_preview)
			edge_preview.owner = get_editor_interface().get_edited_scene_root()
	
	edge_preview.show()
	var immediate_mesh = edge_preview.mesh as ImmediateMesh
	immediate_mesh.clear_surfaces()
	
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	immediate_mesh.surface_add_vertex(edge[0])
	immediate_mesh.surface_add_vertex(edge[1])
	immediate_mesh.surface_end()


func _convert_box_to_CSGMesh(box: CSGBox3D) -> CSGMesh3D:
	var csg_mesh = CSGMesh3D.new()
	var arr_mesh = ArrayMesh.new()
	var vertices = PackedVector3Array()
	var indices = PackedInt32Array()
	var half_size = box.size * 0.5
	
	var local_verts = [
		Vector3(-half_size.x, -half_size.y, -half_size.z),  # 0
		Vector3(half_size.x, -half_size.y, -half_size.z),   # 1
		Vector3(half_size.x, half_size.y, -half_size.z),    # 2
		Vector3(-half_size.x, half_size.y, -half_size.z),   # 3
		Vector3(-half_size.x, -half_size.y, half_size.z),   # 4
		Vector3(half_size.x, -half_size.y, half_size.z),    # 5
		Vector3(half_size.x, half_size.y, half_size.z),     # 6
		Vector3(-half_size.x, half_size.y, half_size.z)     # 7
	]
	
	vertices.append_array(local_verts)
	
	var faces = [
		[0, 1, 2, 2, 3, 0],  # Front
		[1, 5, 6, 6, 2, 1],  # Right
		[5, 4, 7, 7, 6, 5],  # Back
		[4, 0, 3, 3, 7, 4],  # Left
		[3, 2, 6, 6, 7, 3],  # Top
		[4, 5, 1, 1, 0, 4]   # Bottom
	]
	
	for face in faces:
		indices.append_array(face)
	
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	csg_mesh.mesh = arr_mesh
	csg_mesh.transform = box.transform
	csg_mesh.operation = box.operation
	csg_mesh.use_collision = box.use_collision
	
	voxel_root.add_child(csg_mesh)
	csg_mesh.owner = get_editor_interface().get_edited_scene_root()
	
	box.queue_free()
	
	return csg_mesh