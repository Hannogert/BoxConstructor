@tool
extends StaticBody3D
class_name CubeGrid3D
var grid_scale: float = 1:
	set(value):
		grid_scale = value
		_update_material()
		emit_signal("grid_created", grid_scale)


var mesh_instance: MeshInstance3D
var grid_material: ShaderMaterial
var voxel_root: CSGCombiner3D
signal grid_created(scale: float)

func _enter_tree() -> void:
	if Engine.is_editor_hint():
		set_meta("_edit_lock_", true)

	# Check if the CubeGridMesh3D already exists
	mesh_instance = get_node_or_null("CubeGridMesh3D")
	if not mesh_instance:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "CubeGridMesh3D"
		mesh_instance.set_meta("_edit_lock_", true)
		var plane_mesh = PlaneMesh.new()
		plane_mesh.size = Vector2(1, 1)
		mesh_instance.mesh = plane_mesh
		mesh_instance.scale = Vector3(4000, 0.001, 4000)
		add_child(mesh_instance)
		if Engine.is_editor_hint():
			mesh_instance.owner = null

	# Check if the CSGCombiner3D already exists
	voxel_root = self.get_node_or_null("CSGCombiner3D")
	if not voxel_root:
		voxel_root = CSGCombiner3D.new()
		voxel_root.name = "CSGCombiner3D"
		voxel_root.use_collision = true
		add_child(voxel_root)
		if Engine.is_editor_hint():
			voxel_root.owner = get_tree().edited_scene_root

	# Check if the CubeGridCollisionShape3D already exists
	var collision_shape = get_node_or_null("CubeGridCollisionShape3D")
	if not collision_shape:
		collision_shape = CollisionShape3D.new()
		var box_shape = BoxShape3D.new()
		box_shape.size = Vector3(4000, 0.001, 4000)
		collision_shape.shape = box_shape
		collision_shape.name = "CubeGridCollisionShape3D"
		add_child(collision_shape)
		if Engine.is_editor_hint():
			collision_shape.owner = null

	_setup_shader()
	emit_signal("grid_created", grid_scale)

func _setup_shader() -> void:
	if not mesh_instance:
		mesh_instance = get_node_or_null("CubeGridMesh3D")
	if not mesh_instance:
		push_error("Grid mesh instance not found!")
		return
	
	if not grid_material:
		var base_material = preload("res://addons/boxconstructor/textures/cube_grid.tres")
		grid_material = base_material.duplicate()
		mesh_instance.material_override = grid_material
		grid_material.set_shader_parameter("grid_scale", grid_scale)

func _update_material() -> void:
		grid_material.set_shader_parameter("grid_scale", grid_scale)

