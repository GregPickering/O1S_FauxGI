#@tool
extends Label

@export var update_s := 0.25

# cascaded exponential filter
var gain : float = 1
var filt_delta_1 : float = 1
var filt_delta_2 : float = 1
var filt_delta_3 : float = 1
var filt_delta_4 : float = 1

var accum := 0.0
func _process( delta : float ):
	# do the math every time
	filt_delta_1 = lerpf( filt_delta_1, delta, gain )
	filt_delta_2 = lerpf( filt_delta_2, filt_delta_1, gain )
	filt_delta_3 = lerpf( filt_delta_3, filt_delta_2, gain )
	filt_delta_4 = lerpf( filt_delta_4, filt_delta_3, gain )
	
	# update the text periodically
	accum += delta
	if accum >= update_s:
		accum -= update_s
		var fps : float = 1.0 / max( filt_delta_4, 1e-5 )
		if fps >= 1000.0:
			text = "%1.0f fps" % fps
		elif fps >= 100.0:
			text = "%1.1f fps" % fps
		elif fps >= 10.0:
			text = "%1.2f fps" % fps
		else:
			text = "%1.3f fps" % fps
		# adjust the gain so we filter over ~ 1s
		gain = clampf( filt_delta_4 * 4.0, 1e-5, 1.0 )
