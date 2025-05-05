extends CheckButton

func _on_toggled( toggled_on ):
	DisplayServer.window_set_vsync_mode( DisplayServer.VSYNC_ENABLED
			if toggled_on else DisplayServer.VSYNC_DISABLED )
