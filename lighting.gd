@tool
extends Node3D

#var rd : RenderingDevice
#func _init():
	#rd = RenderingServer.get_rendering_device()
	#rd.buffer_get_data()

@export var speed := 1.0
var rot := -2.35
func _process( delta : float ):
	if true:
		rot += delta * speed
		if rot >= 2.0*PI:
			rot -= 2 * PI
		elif rot < 0.0:
			rot += 2 * PI
	else:
		rot = -2.35
	transform.basis = Basis.from_euler( Vector3( 0, rot, 0 ) )

	#var tex = get_viewport().get_viewport_rid()
