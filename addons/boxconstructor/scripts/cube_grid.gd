@tool
extends StaticBody3D
class_name CubeGrid3D
@export var grid_scale: float = 0.0:
	set(value):
		grid_scale = value
		_update_material()


var mesh_instance: MeshInstance3D
var grid_material: ShaderMaterial
var voxel_root: CSGCombiner3D

func _enter_tree() -> void:
	if Engine.is_editor_hint():
		set_meta("_edit_lock_", true)

	if not has_node("CubeGridMesh3D"):
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "CubeGridMesh3D"
		mesh_instance.set_meta("_edit_lock_", true)
		var plane_mesh = PlaneMesh.new()
		plane_mesh.size = Vector2(1, 1)
		mesh_instance.mesh = plane_mesh
		mesh_instance.scale = Vector3(4000, 0.001, 4000)
		
		var collision_shape = CollisionShape3D.new()
		var box_shape = BoxShape3D.new()
		box_shape.size = Vector3(4000, 0.001, 4000)
		collision_shape.shape = box_shape
		collision_shape.name = "CubeGridCollisionShape3D"

		voxel_root = CSGCombiner3D.new()
		voxel_root.name = "CSGCombiner3D"
		voxel_root.use_collision = true
		
		add_child(mesh_instance)
		add_child(collision_shape)
		add_child(voxel_root)
		
		if Engine.is_editor_hint():
			mesh_instance.owner = get_tree().edited_scene_root
			collision_shape.owner = get_tree().edited_scene_root
			voxel_root.owner = get_tree().edited_scene_root
	
	else:
		mesh_instance = get_node_or_null("CubeGridMesh3D")
		voxel_root = get_node_or_null("CSGCombiner3D")
		
		if not voxel_root:
			voxel_root = CSGCombiner3D.new()
			voxel_root.name = "CSGCombiner3D"
			voxel_root.use_collision = true
			add_child(voxel_root)
			if Engine.is_editor_hint():
				voxel_root.owner = get_tree().edited_scene_root
	
	_setup_shader()

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
		
		grid_material.set_shader_parameter("grid_scale", 1000.0)
		if grid_scale == 0 and Engine.is_editor_hint():
			var editor_plugin = EditorPlugin.new()
			var editor_viewport = editor_plugin.get_editor_interface().get_editor_viewport_3d()
			if editor_viewport:
				var camera = editor_viewport.get_camera_3d()
				if camera:
					var y_distance = abs(camera.global_position.y - global_position.y)
					grid_material.set_shader_parameter("camera_distance", y_distance)

func _update_material() -> void:
	if grid_material:
		if grid_scale == 0:
			grid_material.set_shader_parameter("grid_scale", 5000.0)
		else:
			grid_material.set_shader_parameter("grid_scale", grid_scale)
			grid_material.set_shader_parameter("camera_distance", grid_scale)

