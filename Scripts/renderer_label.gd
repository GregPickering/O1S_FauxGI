extends Label

func _ready():
	text = RenderingServer.get_current_rendering_method()
