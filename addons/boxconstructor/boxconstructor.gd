@tool
extends EditorPlugin

# === Constants ===
enum BuildMode {
	DISABLE,
	SELECT,
	ADD
}


const GRID_SCALE_1 = 0.01
const GRID_SCALE_2 = 0.1
const GRID_SCALE_3 = 0.25
const GRID_SCALE_4 = 0.5
const GRID_SCALE_5 = 0.75
const GRID_SCALE_6 = 1
const GRID_SCALE_7 = 2
const GRID_SCALE_8 = 5
const GRID_SCALE_9 = 10
const BASE_PREVIEW_THICKNESS = 0.05

# === Editor properties ===
var current_mode: BuildMode = BuildMode.SELECT
var toolbar: PanelContainer
var editor_viewport = get_editor_interface().get_editor_viewport_3d()
var camera = editor_viewport.get_camera_3d()

# === Grid and CSG properties ===
var csg_root: CSGCombiner3D
var selected_grid: CubeGrid3D
var csg_mesh: MeshInstance3D = null

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
var extrude_line_normal: Vector3

# === Highlight properties ===
var hover_preview: MeshInstance3D = null
var hover_point: Vector3 = Vector3.ZERO

# === Edge Movement properties ===
var edge_preview: MeshInstance3D = null
var current_edge: Array = []
var is_dragging_edge: bool = false
var dragged_mesh: CSGMesh3D = null
var drag_start_position: Vector3
var drag_plane: Plane
var drag_start_offset: Vector3
var is_mouse_in_viewport: bool = false

var undo_redo
var drag_start_vertices: PackedVector3Array
var drag_start_indices: PackedInt32Array

func _update_mesh_arrays(mesh_node: CSGMesh3D, vertices: PackedVector3Array, indices: PackedInt32Array) -> void:
	var arr_mesh = mesh_node.mesh as ArrayMesh
	if arr_mesh:
		var arrays = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_INDEX] = indices
		arr_mesh.clear_surfaces()
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

# === Lifecycle Methods ===
func _enter_tree() -> void:
	get_editor_interface().get_selection().selection_changed.connect(_on_selection_changed)
	editor_viewport = get_editor_interface().get_editor_viewport_3d()
	undo_redo = get_undo_redo()
	toolbar = preload("res://addons/boxconstructor/scripts/toolbar.gd").new(self) # Create the toolbar
	var viewport_base = editor_viewport.get_parent().get_parent()
	viewport_base.add_child(toolbar)
	toolbar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, 0, 10)

	toolbar.hide() # Hide toolbar by default
	_connect_toolbar_signals() # Connect signals


func _exit_tree() -> void:
	if toolbar:
		toolbar.queue_free() # Remove the toolbar

	if get_editor_interface().get_selection().selection_changed.is_connected(_on_selection_changed):
		get_editor_interface().get_selection().selection_changed.disconnect(_on_selection_changed) # Disconnect signals


# This section handles all of the inputs
func _input(event: InputEvent) -> void:
	if not selected_grid or not selected_grid.is_inside_tree():
		return

	# Pressing the X key will move the grid to mouse position
	if event is InputEventKey and event.pressed and event.keycode == KEY_X:
		if not camera or not selected_grid:
			return
		# Cast a ray and get the hit position
		var from = camera.project_ray_origin(editor_viewport.get_mouse_position())
		var to = from + camera.project_ray_normal(editor_viewport.get_mouse_position()) * 5000
		var ray_query = PhysicsRayQueryParameters3D.new()
		ray_query.from = from
		ray_query.to = to
		var hit = get_editor_interface().get_edited_scene_root().get_world_3d().direct_space_state.intersect_ray(ray_query)
		if hit:
			var snapped_pos = _snap_to_grid(hit.position)
			# Move the Grid to the hit position
			_align_grid_to_surface(hit.normal, snapped_pos)

	# Pressing Z resets the grid to the 0,0,0 position
	if event is InputEventKey  and event.pressed and event.keycode == KEY_Z:
		_reset_grid_transform()
		
	# Edge movement logic
	if current_mode == BuildMode.SELECT:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				if not is_dragging_edge:
					if edge_preview and edge_preview.visible:
						for child in csg_root.get_children():
							if child is CSGBox3D or child is CSGMesh3D:
								# Get all of the edges of CSGBox3D or CSGMesh3D
								var edges = _get_edges(child)
								for edge in edges:

									# Check if the currently hovered edge is the same as the one we are dragging
									if edge[0].is_equal_approx(current_edge[0]) and edge[1].is_equal_approx(current_edge[1]):
										var from = camera.project_ray_origin(event.position)
										var dir = camera.project_ray_normal(event.position)

										# Create a plane for the edge to drag along
										var edge_dir = (edge[1] - edge[0]).normalized()
										drag_plane = Plane(edge_dir, edge[0].dot(edge_dir))
										
										# Get the intersection point of the ray and the plane
										var intersection = drag_plane.intersects_ray(from, dir)
										if intersection:
											# We turn the CSGBox3D into a custom mesh that allows use to move the vertecies
											if child is CSGBox3D:
												dragged_mesh = _convert_box_to_CSGMesh(child)

											else:
												dragged_mesh = child

											var arr_mesh = dragged_mesh.mesh as ArrayMesh
											if arr_mesh:
												var arrays = arr_mesh.surface_get_arrays(0)
												drag_start_vertices = arrays[Mesh.ARRAY_VERTEX].duplicate()
												drag_start_indices = arrays[Mesh.ARRAY_INDEX].duplicate()
											is_dragging_edge = true # Set dragging to true
											current_edge = edge		# Set the current edge to the one we are dragging
											drag_start_offset = _snap_to_grid(intersection) # Starting position of edge drag
										break
				else:
					if is_dragging_edge and dragged_mesh:
						var arr_mesh = dragged_mesh.mesh as ArrayMesh
						if arr_mesh:
							var final_arrays = arr_mesh.surface_get_arrays(0)
							undo_redo.create_action("Move Edge")
							
							# Store the current state
							var current_mesh = arr_mesh.duplicate(true)
							
							# Create original mesh
							var original_mesh = ArrayMesh.new()
							var arrays = []
							arrays.resize(Mesh.ARRAY_MAX)
							arrays[Mesh.ARRAY_VERTEX] = drag_start_vertices
							arrays[Mesh.ARRAY_INDEX] = drag_start_indices
							original_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
							
							undo_redo.add_do_property(dragged_mesh, "mesh", current_mesh)
							undo_redo.add_undo_property(dragged_mesh, "mesh", original_mesh)
							undo_redo.commit_action()
						
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
					# Snapped position on the grid
					var snapped_pos = _snap_to_grid(intersection)
					# Offset from the start position
					var offset = snapped_pos - drag_start_offset
					
					var arr_mesh = dragged_mesh.mesh as ArrayMesh
					if arr_mesh:
						var arrays = arr_mesh.surface_get_arrays(0)
						var vertices = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array

						# Get the edge points in local space
						var local_edge = [
							dragged_mesh.to_local(current_edge[0]),
							dragged_mesh.to_local(current_edge[1])
						]
						# Calculate the new offset
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
			
			# Highlight the closest edge
			elif not is_dragging_edge:
				if not camera or not csg_root:
					if edge_preview:
						edge_preview.hide()
					return
				
				# Get the closest node 
				var mouse_pos = editor_viewport.get_mouse_position()
				var closest_node = null
				var closest_distance = INF
				
				for child in csg_root.get_children():
					if not (child is CSGBox3D or child is CSGMesh3D):
						continue
					
					var node_center = child.global_position
					var screen_pos = camera.unproject_position(node_center) # Takes the position in 3D converts it to 2D
					var distance = screen_pos.distance_to(mouse_pos)
					
					if distance < closest_distance:
						closest_node = child
						closest_distance = distance
				
				if closest_distance:
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

			# If clicked inside toolbar ignore
			if toolbar and toolbar.get_global_rect().has_point(event.position):
				return

			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					if not camera: return
					
					# Extruson end
					if is_extruding and has_started_extrusion:
						# Create the box when clicking during extrusion
						_create_CSGBox3D()
						is_drawing = false
						is_extruding = false 
						has_started_extrusion = false
						if draw_preview:
							draw_preview.queue_free()
							draw_preview = null
						return
					
					# Start dragging the base rectangle
					var ray_query = PhysicsRayQueryParameters3D.new()
					ray_query.from = camera.project_ray_origin(editor_viewport.get_mouse_position())
					ray_query.to = ray_query.from + camera.project_ray_normal(editor_viewport.get_mouse_position()) * 1000
					
					var hit = get_editor_interface().get_edited_scene_root().get_world_3d().direct_space_state.intersect_ray(ray_query)
					if hit:
						is_drawing = true
						draw_normal = hit.normal
						draw_start = _snap_to_grid(hit.position)
						draw_end = draw_start
						draw_plane = Plane(draw_normal, hit.position.dot(draw_normal))
						create_rectangle_preview()
						
				else:
					# End dragging and start extrusion if we were drawing
					if is_drawing and not is_extruding:
						is_extruding = true
						has_started_extrusion = false
						extrude_distance = 0.0
						
						var from = camera.project_ray_origin(editor_viewport.get_mouse_position())
						var dir = camera.project_ray_normal(editor_viewport.get_mouse_position())
						var intersection = draw_plane.intersects_ray(from, dir)
						
						if intersection:
							initial_extrude_point = _snap_to_grid(intersection)
							extrude_line_normal = draw_normal
							_update_rectangle_preview()

		elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			is_drawing = false
			is_extruding = false
			has_started_extrusion = false
			if draw_preview:
				draw_preview.queue_free()
				draw_preview = null
				
			get_viewport().set_input_as_handled()

		# Update section		
		elif event is InputEventMouseMotion:
			if current_mode == BuildMode.ADD:
				if not is_drawing:
					if not camera: return
					
					var ray_query = PhysicsRayQueryParameters3D.new()
					ray_query.from = camera.project_ray_origin(editor_viewport.get_mouse_position())
					ray_query.to = ray_query.from + camera.project_ray_normal(editor_viewport.get_mouse_position()) * 1000
					ray_query.collide_with_bodies = true
					
					var hit = get_editor_interface().get_edited_scene_root().get_world_3d().direct_space_state.intersect_ray(ray_query)
					if hit:
						hover_point = _snap_to_grid(hit.position)
						if not hover_preview:
							_create_hover_preview()
						_update_hover_preview()
					elif hover_preview:
						hover_preview.queue_free()

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
					var grid_unit = selected_grid.grid_scale
					var e_line1 = initial_extrude_point - extrude_line_normal * 5000
					var e_line2 = initial_extrude_point + extrude_line_normal * 5000
					var m_line1 = from 
					var m_line2 = from + dir * 5000
					var closest_point = Geometry3D.get_closest_points_between_segments(e_line1, e_line2, m_line1, m_line2)
					var mouse_on_exturde_line = closest_point[0]
					var distance_vec =  mouse_on_exturde_line - initial_extrude_point
					var distance = distance_vec.length() * distance_vec.normalized().dot(extrude_line_normal)
				
					var new_distance = round(distance / grid_unit) * grid_unit
					#print(new_distance)
					if not is_equal_approx(extrude_distance, new_distance):
						extrude_distance = new_distance
						_update_rectangle_preview()


# === Grid Methods ===
# Changes the grid size based on the input from the toolbar
func _on_grid_size_changed(size: float) -> void:
	if selected_grid and selected_grid.grid_material:
		selected_grid.grid_scale = size
		selected_grid.grid_material.set_shader_parameter("grid_scale", size)

		# Destroy the hover preview so it gets updated
		if hover_preview:
			hover_preview.queue_free()
			hover_preview = null


# Snaps the position to the grid size
func _snap_to_grid(pos: Vector3) -> Vector3:
	if not selected_grid:
		return pos

	# Get the grid size of the selected grid
	var grid_unit = selected_grid.grid_scale
	
	# Divide the coordinates of the given position by the grid scale, to get how far it is from the origin
	# and round it to the nearest integer
	return Vector3(
		round(pos.x / grid_unit) * grid_unit,
		round(pos.y / grid_unit) * grid_unit,
		round(pos.z / grid_unit) * grid_unit
	)


func _align_grid_to_surface(normal: Vector3, hit_position: Vector3) -> void:
	if not selected_grid:
		return

	var mesh = selected_grid.get_node_or_null("CubeGridMesh3D")
	var collision = selected_grid.get_node_or_null("CubeGridCollisionShape3D")

	var mesh_size = mesh.scale
	var collision_size = collision.scale

	if not mesh or not collision:
		return

	# Normalize the normal vector
	normal = normal.normalized()

	var up = normal
	var right = up.cross(Vector3.FORWARD).normalized()
	if right.length() < 0.1:  
		right = up.cross(Vector3.RIGHT).normalized()
	var forward = right.cross(up)

	# Create the Basis and Transform3D
	var basis = Basis(right, up, forward)
	var transform = Transform3D(basis, hit_position + up * 0.01)

	# Apply the transform
	mesh.transform = transform
	collision.transform = transform

	# Restore correct scale
	mesh.scale = mesh_size
	collision.scale = collision_size

	# Update the material
	selected_grid._update_material()


func _reset_grid_transform() -> void:
	if not selected_grid:
		return
		
	var mesh = selected_grid.get_node_or_null("CubeGridMesh3D")
	var collision = selected_grid.get_node_or_null("CubeGridCollisionShape3D")
	
	if not mesh or not collision:
		return

	# Get the current mesh and collision scale	
	var mesh_scale = mesh.scale
	var collision_scale = collision.scale
	
	# Reset the transform
	mesh.transform = Transform3D()
	collision.transform = Transform3D()
	
	# Restore the scale
	mesh.scale = mesh_scale
	collision.scale = collision_scale
	
	# Update the shader
	selected_grid._update_material()


# === Drawing Methods ===
# Creates a MeshInstance3D shpere at the current hovered location when in ADD mode
func _create_hover_preview() -> void:
	# Clear the existing preview
	if hover_preview:
		hover_preview.queue_free()

	# Create new hover preview 
	hover_preview = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	var scale = selected_grid.grid_scale * BASE_PREVIEW_THICKNESS
	sphere.radius = scale
	sphere.height = scale * 2
	hover_preview.mesh = sphere

	# Create the material for the hover preview
	var material = StandardMaterial3D.new()
	material.albedo_color = Color.RED
	material.no_depth_test = true # Always visible Renders ontop of other objects
	hover_preview.material_override = material

	# Add it to the scene
	if csg_root:
		csg_root.add_child(hover_preview)
		hover_preview.position = hover_point
	# Do not add owner 
		
	
# Changes the position of the hover preview
func _update_hover_preview() -> void:
	if not hover_preview:
		return
	hover_preview.global_position = hover_point


func _calculate_base_rect_points() -> void:
	if not selected_grid:
		return
		
	var grid_unit = selected_grid.grid_scale

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
	material.albedo_color = Color.RED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	draw_preview.material_override = material
	
	if csg_root:
		csg_root.add_child(draw_preview)
		draw_preview.owner = get_editor_interface().get_edited_scene_root()


func _update_rectangle_preview() -> void:
	if not draw_preview: return
	var immediate_mesh = draw_preview.mesh as ImmediateMesh
	immediate_mesh.clear_surfaces()
	
	var base_thickness = BASE_PREVIEW_THICKNESS * selected_grid.grid_scale
	var thickness = base_thickness
	var grid_unit = selected_grid.grid_scale
	var material = draw_preview.material_override as StandardMaterial3D

	if is_extruding:
		material.albedo_color = Color.GREEN if extrude_distance >= 0 else Color.RED
	var preview_offset = draw_normal * (grid_unit * 0.000001)
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

	# Find a perpendicular vector to the line
	var perpendicular = Vector3.UP.cross(direction).normalized()
	if perpendicular.length() < 0.1:
		perpendicular = Vector3.RIGHT.cross(direction).normalized()

	# Calculate the four corners of the line
	var offset = perpendicular * thickness
	var v1 = start + offset
	var v2 = start - offset
	var v3 = end + offset
	var v4 = end - offset

	# Add the two faces to the line
	create_rectangle(immediate_mesh, v1, v2, v3, v4)


# Creates a rectangle using the given vertecies out of two triangles
func create_rectangle(immediate_mesh: ImmediateMesh, v1: Vector3, v2: Vector3, v3: Vector3, v4: Vector3) -> void:
	# Add two triangles to form a rectangle
	immediate_mesh.surface_add_vertex(v1)
	immediate_mesh.surface_add_vertex(v2)
	immediate_mesh.surface_add_vertex(v3)

	immediate_mesh.surface_add_vertex(v2)
	immediate_mesh.surface_add_vertex(v4)
	immediate_mesh.surface_add_vertex(v3)


# === CSG Management Methods ===
func _create_CSGBox3D() -> void:
	var new_box = CSGBox3D.new()
	new_box.use_collision = true
	new_box.set_meta("_edit_lock_", true)
	new_box.set_meta("_edit_group_", true)
	

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

	if size.x < 0.0001 or size.y < 0.0001 or size.z < 0.0001:
		return

	new_box.size = size
	new_box.position = center

	# Depending on the extrusion distance set the operation
	if extrude_distance < 0:
		new_box.operation = CSGShape3D.OPERATION_SUBTRACTION

	undo_redo.create_action("Create CSGBox3D")
	undo_redo.add_do_method(csg_root, "add_child", new_box)
	undo_redo.add_do_method(new_box, "set_owner", get_editor_interface().get_edited_scene_root())
	undo_redo.add_undo_method(csg_root, "remove_child", new_box)
	undo_redo.commit_action()
	_update_toolbar_states()
	

func _on_merge_mesh() -> void:
	if not csg_root or csg_root.get_child_count() == 0:
		return
	# Dont allow to merge an already merged mesh
	if csg_root.has_node("CSGMesh"):
		push_warning("Already merged!")
		return
	
	if edge_preview:
		edge_preview.queue_free()
		edge_preview = null

	current_edge = []
	is_dragging_edge = false

	var nodes_to_keep = []
	# Go over all of the children of the csg root and check if they are CSGBox3D or CSGMesh3D
	for node in csg_root.get_children():
		if node is MeshInstance3D:
			continue
		
		# For subtraction operations, check if it actually cuts something
		if node.operation == CSGShape3D.OPERATION_SUBTRACTION:
			var cuts_something = false
			for other_node in csg_root.get_children():
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
						# Check if the bounding boxes intersect if does keep it
						if node_bounds.intersects(other_bounds):
							cuts_something = true
							break
					else:
						cuts_something = false
						break
			# Only keep if it actually cuts something
			if cuts_something:
				nodes_to_keep.append(node)
		else:
			nodes_to_keep.append(node)

	var nodes_data = []
	for node in nodes_to_keep:
		nodes_data.append(_store_mesh_data(node))
	
	var meshes = csg_root.get_meshes()
	if meshes.size() > 1:
		if not csg_mesh:
			csg_mesh = MeshInstance3D.new()
			csg_mesh.name = "CSGMesh"
			csg_root.add_child(csg_mesh)
			csg_mesh.owner = get_editor_interface().get_edited_scene_root()

		csg_mesh.mesh = meshes[1]
		csg_mesh.set_meta("csg_data", {
			"nodes": nodes_data
		})
		
		for child in csg_root.get_children():
			if child != csg_mesh:
				child.queue_free()
				
		_update_toolbar_states()
		_change_mode(BuildMode.DISABLE)


func _on_edit_mesh() -> void:
	if not csg_root:
		push_warning("No Mesh root found!")
		return
		
	if not csg_root.has_node("CSGMesh"):
		push_warning("No CSGMesh to edit!")
		return

	csg_mesh = csg_root.get_node("CSGMesh")
	var data = csg_mesh.get_meta("csg_data")
	if not data:
		push_warning("No CSG data found in mesh!")
		return
	# Deconstruct the mesh into CSGBox3D or CSGMesh3D
	_convert_to_boxes()

# Stores the information about the CSGBox3D or CSGMesh3D
func _store_mesh_data(node: Node) -> Dictionary:
	# Create a dictionary to store information
	var data = {
		"position": node.position,
		"operation": node.operation,
		"use_collision": node.use_collision,
		"type": "box" if node is CSGBox3D else "mesh"
	}
	# Store the size of the CSGBox3D or the vertices and indices of the CSGMesh3D
	if node is CSGBox3D:
		data["size"] = node.size
	# Store vertices and indices of the CSGMesh3D
	elif node is CSGMesh3D:
		var mesh = node.mesh as ArrayMesh
		if mesh:
			data["vertices"] = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			data["indices"] = mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	
	return data


# Recreates the CSGBox3D or CSGMesh3D from the stored metadata
func _convert_to_boxes() -> void:

	csg_mesh = csg_root.get_node("CSGMesh")
	if not csg_mesh:
		push_warning("No CSGMesh node found!")
		return
	var data = csg_mesh.get_meta("csg_data")
	if not data:
		push_warning("No CSG data found in mesh!")
		return
	
	# Go through all of the nodes and recreate them
	for node_info in data["nodes"]:
		var new_node
		
		# Based on the type, recreate CSGBox3D or CSGMesh3D
		if node_info["type"] == "box":
			new_node = CSGBox3D.new()		  # Create a new CSGBox3D
			new_node.size = node_info["size"] # Set the size of the box by getting the size from the metadata
		else:
			new_node = CSGMesh3D.new() 		  # Create a new CSGMesh3D
			var arr_mesh = ArrayMesh.new()	  # Create a new ArrayMesh
			var arrays = []
			arrays.resize(Mesh.ARRAY_MAX)	 
			
			arrays[Mesh.ARRAY_VERTEX] = node_info["vertices"]
			arrays[Mesh.ARRAY_INDEX] = node_info["indices"]
			arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays) # Add the surface to the ArrayMesh
			new_node.mesh = arr_mesh

		new_node.position = node_info["position"] # Set the position
		new_node.operation = node_info["operation"]
		new_node.use_collision = node_info["use_collision"]
		
		new_node.set_meta("_edit_lock_", true)
		new_node.set_meta("_edit_group_", true)
		
		csg_root.add_child(new_node)
		new_node.owner = get_editor_interface().get_edited_scene_root()

	# Remove the CSGMesh
	csg_mesh.queue_free()
	csg_mesh = null

	toolbar.update_button_states(false)
	_change_mode(BuildMode.DISABLE)


# === UI Management Methods ===
func _connect_toolbar_signals() -> void:
	toolbar.select_button_pressed.connect(func(): _change_mode(BuildMode.SELECT))
	toolbar.add_button_pressed.connect(func(): _change_mode(BuildMode.ADD))
	toolbar.disable_button_pressed.connect(func(): _change_mode(BuildMode.DISABLE))
	toolbar.grid_size_changed.connect(_on_grid_size_changed)
	toolbar.reset_grid_pressed.connect(_reset_grid_transform)
	toolbar.merge_mesh.connect(_on_merge_mesh)
	toolbar.edit_mesh.connect(_on_edit_mesh)


func _update_toolbar_states() -> void:
	if not csg_root:
		return
		
	var has_csg_mesh = csg_root.has_node("CSGMesh")
	var has_csg_boxes = false
	
	for child in csg_root.get_children():
		if child is CSGBox3D or child is CSGMesh3D:
			has_csg_boxes = true
			break
			
	if has_csg_mesh:
		toolbar.update_button_states(true)
	else:
		toolbar.update_button_states(false)
	
	toolbar.set_merge_button_enabled(has_csg_boxes)
	toolbar.set_select_button_enabled(has_csg_boxes)
	toolbar.set_edit_button_enabled(has_csg_mesh)


func _on_selection_changed() -> void:
	var selected = get_editor_interface().get_selection().get_selected_nodes()
	if selected.size() == 1 and selected[0] is CubeGrid3D:
		selected_grid = selected[0]
		csg_root = selected_grid.get_node("CSGCombiner3D")
		toolbar.show()
		toolbar.connect_to_grid(selected_grid)
		_update_toolbar_states()

		var root := EditorInterface.get_base_control()
		var toolbar = root.find_children("", "Node3DEditor", true, false)[0].get_child(0).find_children("", "HBoxContainer", true, false)[0]
		var btn = toolbar.get_child(2)
		btn.pressed.emit()
		if hover_preview:
			hover_preview.queue_free()
			hover_preview = null
	else:
		_change_mode(BuildMode.DISABLE)
		if hover_preview:
			hover_preview.queue_free()
			hover_preview = null
		selected_grid = null
		csg_root = null
		toolbar.hide()


func _change_mode(new_mode: BuildMode) -> void:
	if new_mode == BuildMode.ADD and csg_root and csg_root.has_node("CSGMesh"):
		push_warning("Can't switch to ADD mode while CSGMesh exists. Use Edit to modify.")
		toolbar.set_active_mode(current_mode)
		return

	current_mode = new_mode
	toolbar.set_active_mode(current_mode)

	if edge_preview:
		edge_preview.queue_free()
		edge_preview = null
	current_edge = []
	is_dragging_edge = false

	if csg_root:
		csg_root.set_meta("_edit_lock_", current_mode != BuildMode.SELECT)


# === Edge Movement Methods ===
func _get_edges(node: Node) -> Array:
	var edges = []
	
	if node is CSGBox3D:
		var aabb = AABB(
			node.global_position - (node.size * 0.5),
			node.size
		)
		# Corners of the CSGBox3D
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
		# Edges of the CSGBox3D
		var edge_indices = [
			[0, 1], [1, 2], [2, 3], [3, 0],
			[4, 5], [5, 6], [6, 7], [7, 4],
			[0, 4], [1, 5], [2, 6], [3, 7]
		]
		# Create edges by taking pairs of corners
		for pair in edge_indices:
			edges.append([corners[pair[0]], corners[pair[1]]])
	# CSGMesh3D get edges by getting the verticies and indicies		
	elif node is CSGMesh3D:
		var arr_mesh = node.mesh as ArrayMesh
		if not arr_mesh:
			return edges
		
		# Arraymesh
		var arrays = arr_mesh.surface_get_arrays(0)
		# Get the vertices and indices
		var vertices = arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var indices = arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		# Create a set to store edges
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
				var idx2 = tri_indices[(j + 1) % 3] # Get the next 2 indicies
				
				var edge_key = str(min(idx1, idx2)) + "_" + str(max(idx1, idx2))
				if not edge_set.has(edge_key):
					edge_set[edge_key] = true
					var vert1 = node.global_transform * vertices[idx1]
					var vert2 = node.global_transform * vertices[idx2]
					edges.append([vert1, vert2])
	
	return edges


# Finds the closest edge to the mouse
func _find_closest_edge(node: Node, mouse_pos: Vector2) -> Array:
	if not camera:
		return []

	# Get all of the edges
	var edges = _get_edges(node)
	# Intialize closest edge
	var closest_edge = []
	# Set the distance to infinity
	var min_distance = INF
	
	# Cast ray from the camera to the mouse position
	var from = camera.project_ray_origin(mouse_pos)
	var dir = camera.project_ray_normal(mouse_pos)
	var m_line1 = from
	var m_line2 = from + dir * 5000 

	# Go over all of the edges
	for edge in edges:
		# Take the two first endpoints of the edge
		var e_line1 = edge[0]
		var e_line2 = edge[1]

		# Get the closest points between the edge and the ray
		var closest_points = Geometry3D.get_closest_points_between_segments(e_line1, e_line2, m_line1, m_line2)
		# Return the closest edge
		var point_on_edge = closest_points[0]
		var point_on_ray = closest_points[1]

		# Calculate the distance between the two points
		var distance_vec = point_on_ray - point_on_edge
		var distance = distance_vec.length()

		# If the distance is smaller than the current minimum, update the closest edge
		if distance < min_distance:
			min_distance = distance
			closest_edge = edge

	return closest_edge


# Method that draws a line on the currently hovered edge
func _create_edge_preview(edge: Array) -> void:

	if edge.is_empty():
		if edge_preview:
			edge_preview.hide()
		return

	# Create the edge preview material
	if not edge_preview:
		edge_preview = MeshInstance3D.new()
		var immediate_mesh = ImmediateMesh.new()
		edge_preview.mesh = immediate_mesh
		
		var material = StandardMaterial3D.new()
		material.albedo_color = Color.RED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.no_depth_test = true
		edge_preview.material_override = material
		
		if csg_root:
			csg_root.add_child(edge_preview)
	
	edge_preview.show()
	var immediate_mesh = edge_preview.mesh as ImmediateMesh
	immediate_mesh.clear_surfaces()
	
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var thickness = selected_grid.grid_scale * BASE_PREVIEW_THICKNESS # Scale the thickness based on grid size
	add_thick_line(immediate_mesh, edge[0], edge[1], thickness) # Use the add_thick_line methdod to create the line
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
	
	csg_root.add_child(csg_mesh)
	csg_mesh.owner = get_editor_interface().get_edited_scene_root()
	
	box.queue_free()
	
	return csg_mesh
