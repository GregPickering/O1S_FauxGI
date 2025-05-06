extends Label
@onready var faux_gi = $"../../FauxGI"

func _process( _delta ):
	if faux_gi.bounce_gain >= 0.01:
		text = str( faux_gi.active_VPLs ) + " VPLs, gain = " + str( faux_gi.bounce_gain )
	else:
		text = "FauxGI Disabled"
