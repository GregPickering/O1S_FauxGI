@tool
extends Node3D
##	Faux Global Illumination
##[br][br]
##	O1S Gaming
##	Jonathan Dummer
##	(MIT License)
##
##	Using the existing lights and collision geometry, approximate GI by placing
##	Virtual Point Lights (VPL) as appropriate.  A primary goal is running on even the
##	Compatibilty renderer, so design around those limits.  (Each mesh can light
##	up to 8 Omnis + 8 Spots, with a max of 32 lights active in view.)  Don't use
##	shadows on the VPLs.
##
##	Minimal implementation, for each original...
##		SpotLight3D: itself, 1+ VPL
##		OmniLight3D: itself, 1+ VPL
##		DirectionalLight3D: itself, 1+ VPL
##
##	While the number of VPLs is limited, we can place and power them using an
##	average of multiple raycast samples, so the final results are representative
##	of more than a single sample.
##
##	Notes:
##		* we can approx an omni with a spot @ 180 deg
##			- this wouldn't work with shadows (~70 deg looks OK), but...
##			- so a mesh can have 16 VPLs
##			- still a dark spot, normal matters
##
##	for evenly distributing points in a 2D field see:
##		https://extremelearning.com.au/unreasonable-effectiveness-of-quasirandom-sequences/
##	and for going from 2D to 3D normal vectors see:
##		Vector3.octahedron_decode( uv: Vector2 )

## VPLs use omni *AND* spot (180 deg), Compatibility's per-mesh limit is "8 spot + 8 omni"
const VPLs_use_spots : bool = true
## How many VPLs to generate per source SpotLight3D, 1+
const per_spot : int = 1
## How many VPLs to generate per source OmniLight3D, 1+ (>= 4 looks good)
const per_omni : int = 4
## How many VPLs to generate per source DirectionalLight3D
const per_dirl : int = 16
## Do we want to spawn VPLs for source lights which don't cast shadows?
const include_shadowless : bool = false
## place the VPL (0=at light origin, 1=at intersection)
const placement_fraction : float = 0.5
## use real random vectors instead of a repeatable pattern (requires heavy temporal filtering)
const real_random_jitter : bool = false

## The node containing all the lights we wish to GI-ify
@export var top_node : Node3D = null
## Maximum number of point sources we can add to the scene to simulate GI
@export_range( 1, 1024 ) var max_points : int = 32
## What fraction of energy is preserved each bounce
@export_range( 0.0, 1.0 ) var bounce_gain : float = 0.25
## How many raycasts per VPL per _physics_process, 0+
@export_range( 0, 100 ) var oversample : int = 8
## Filter the VPLs over time (0=never update/infinite filtering, 1=instant update/no filtering)
@export_range( 0.01, 1.0 ) var temporal_filter : float = 0.25

# original light sources in the scene
var light_sources : Array[ Light3D ] = []
var light_data : Dictionary

# keep a pool of our Virtual Points Lights
var VPL_inst : Array[ RID ] = []
var VPL_light : Array[ RID ] = []
var last_active_VPLs : int = 0
var active_VPLs : int = 0

# physics stuff
var query := PhysicsRayQueryParameters3D.new()
var space_state : PhysicsDirectSpaceState3D = null
enum ray_storage { energy, pos, norm, rad, color }

# I need to raycast, which happens here in the physics process
func _physics_process( _delta ):
	active_VPLs = 0
	allocate_VPLs( max_points )
	if bounce_gain >= 0.01:
		# now run through all active light sources in the scene
		for light in light_sources:
			if light.is_visible_in_tree():
				light_data.get_or_add( light, {} )
				match light.get_class():
					"DirectionalLight3D": pass
					"OmniLight3D": process_omni( light )
					"SpotLight3D": process_spot( light )
			else:
				light_data.erase( light )
		# Gather all active VPLs into a convenient array
		var preVPLs : Array[ Dictionary ] = []
		for light in light_data:
			for idx in light_data[ light ]:
				if light_data[ light ][ idx ][ ray_storage.energy ] > 0.0:
					preVPLs.push_back( light_data[ light ][ idx ] )
					preVPLs.back()[ ray_storage.color ] = light.light_color;
		# Do we need a second pass to filter out the top N VPLs?
		if preVPLs.size() > max_points:
			# keep the most energetic
			preVPLs.sort_custom( func(a, b): return a[ ray_storage.energy ] > b[ ray_storage.energy ] )
			preVPLs.resize( max_points )
		# finally add the VPLs
		active_VPLs = 0
		for preVPL in preVPLs:
			config_VPL(	active_VPLs,
					preVPL[ ray_storage.pos ],
					preVPL[ ray_storage.color ], 
					preVPL[ ray_storage.energy ], 
					preVPL[ ray_storage.rad ] )
			active_VPLs += 1
	else:
		light_data.clear()
	# deactivate any VPLs that need it
	if active_VPLs < last_active_VPLs:
		for idx in range( active_VPLs, last_active_VPLs ):
			disable_VPL( idx )
	if last_active_VPLs != active_VPLs:
		last_active_VPLs = active_VPLs
		print( last_active_VPLs, " active VPLs" )

func process_ray_dummy( from : Vector3, to : Vector3, done_frac : float = 0.5 ) -> Dictionary:
	var res_light : Dictionary
	var total_d : float = from.distance_to( to )
	var done_d : float = total_d * done_frac
	res_light[ ray_storage.pos ] = lerp( from, to, done_frac * placement_fraction )
	res_light[ ray_storage.norm ] = to.direction_to( from ) # just say the normal is back along this ray
	res_light[ ray_storage.rad ] = (total_d - 0.5 * done_d) * 1.25
	res_light[ ray_storage.energy ] = sqrt( 1.0 - done_frac )
	return res_light
	
func process_ray( from : Vector3, to : Vector3 ) -> Dictionary:
	var res_light : Dictionary
	query.from = from
	query.to = to
	var res_ray := space_state.intersect_ray( query )
	if res_ray:
		var total_d : float = from.distance_to( to )
		var done_d : float = from.distance_to( res_ray.position )
		var done_frac : float = done_d / maxf( total_d, 1e-6 )
		res_light[ ray_storage.pos ] = lerp( from, to, done_frac * placement_fraction )
		res_light[ ray_storage.norm ] = res_ray.normal
		res_light[ ray_storage.rad ] = (total_d - 0.5 * done_d) * 1.25
		res_light[ ray_storage.energy ] = sqrt( 1.0 - done_frac )
					#* absf( res_ray.normal.dot( (to - from).normalized() ) )
	return res_light

func process_rays( from : Vector3, rays : Array[ Vector3 ] ) -> Dictionary:
	var avg_ray_res : Dictionary
	for ray in rays:
		var ray_res := process_ray( from, from + ray )
		if ray_res:
			# weight by energy
			var e = ray_res[ ray_storage.energy ]
			if e > 0.0:
				ray_res[ ray_storage.pos ] *= e
				ray_res[ ray_storage.norm ] *= e
				ray_res[ ray_storage.rad ] *= e
				if not avg_ray_res:
					avg_ray_res = ray_res
				else:
					for key in ray_res:
						avg_ray_res[ key ] += ray_res[ key ]
	if avg_ray_res:
		# divide by energy
		var gain = 1.0 / avg_ray_res[ ray_storage.energy ]
		avg_ray_res[ ray_storage.pos ] *= gain
		avg_ray_res[ ray_storage.norm ] *= gain
		avg_ray_res[ ray_storage.rad ] *= gain
		# and the energy itself is scaled by the number of samples
		avg_ray_res[ ray_storage.energy ] /= rays.size()
	return avg_ray_res

func jitter_ray_angle( ray : Vector3, N : int, deg : float, true_rnd : bool = real_random_jitter ) -> Array[ Vector3 ]:
	# always start with the original?
	var rays : Array[ Vector3 ] = [] # [ ray ]
	# now add others
	if N > 0:
		var length : float = -ray.length()
		var xform := Basis.looking_at( ray, 
			Vector3.UP if (1 != ray.abs().max_axis_index()) else Vector3.RIGHT )
		for samp in range( 0, N ):
			var samp_2d : Vector2
			if true_rnd:
				samp_2d = Vector2( randf_range(-0.5, 0.5), randf_range(-0.5, 0.5) ) * (deg / 180.0) + Vector2(0.5,0.5)
			else:
				samp_2d = qrnd_distrib( samp, deg / 180.0 )
			var sample_vec := Vector3.octahedron_decode( samp_2d )
			rays.push_back( (xform * sample_vec) * length )
	return rays

func process_rays_angle( from : Vector3, to : Vector3, N : int, deg : float ) -> Dictionary:
	if N > 0:
		var rays := jitter_ray_angle( to - from, N, deg )
		return process_rays( from, rays )
	else:
		return process_ray_dummy( from, to, 0.5 )

func update_light_data( light : Light3D, idx : int, data : Dictionary, modulate : float ):
	if light and data:
		# scale in the actual light energy here
		data[ ray_storage.energy ] *= modulate
		if light_data[ light ].has( idx ):
			for key in data:
				light_data[ light ][ idx ][ key ] = lerp( 
						light_data[ light ][ idx ][ key ],
						data[ key ], temporal_filter )
		else:
			light_data[ light ][ idx ] = data #.duplicate()
			# do I want the amplitude to fade in?
			#light_data[ light ][ idx ][ ray_storage.energy ] *= temporal_filter
	else:
		light_data[ light ].erase( idx )

func process_light_rays( light : Light3D, rays : Array[ Vector3 ], angle_deg : float, modulate : float ):
	for ray_idx in rays.size():
		var ray_res := process_rays_angle( 
						light.global_position, 
						light.global_position + rays[ ray_idx ],
						oversample, angle_deg )
		if ray_res:
			update_light_data( light, ray_idx, ray_res, modulate )
			active_VPLs += 1

func process_spot( light : Light3D ):
	var compensate_N_pts : float = 1.0 / per_spot
	# these rays never use real random jitter
	var rays := jitter_ray_angle( -light.spot_range * light.global_basis.z, 
									per_spot, light.spot_angle, false )
	process_light_rays( light, rays, light.spot_angle * sqrt( compensate_N_pts ), 
		light.light_energy * bounce_gain * 0.1 * compensate_N_pts )

func process_omni( light : Light3D ):
	# where do I want to cast rays
	var rays : Array[ Vector3 ] = []
	match abs( per_omni ):
		0:	# do nothing
			return
		1:	# this is a single point, but if oversample is set to 0, place it at the center
			rays.append( Vector3.UP )
		2:	# up and down
			const _two_dirs : Array[ Vector3 ] = [
					Vector3(0,+1,0), Vector3(0,-1,0) ]
			rays.append_array( _two_dirs )
		3: # 3 points in a plane (no up/down)
			const _three_dirs : Array[ Vector3 ] = [
					Vector3(1,0,0), Vector3(-0.6,0,0.8), Vector3(-0.6,0,-0.8) ]
			rays.append_array( _three_dirs )
		4, 5: # 4 faces of a tetrahedron, decent
			const _tds : float = 1.0 / sqrt( 3.0 )
			const _tet_dirs : Array[ Vector3 ] = [
					Vector3(1,1,-1) * _tds, Vector3(1,-1,1) * _tds,
					Vector3(-1,1,1) * _tds, Vector3(-1,-1,-1) * _tds ]
			rays.append_array( _tet_dirs )
		_:	# 6 faces of a cube (better), plus more if needed
			const _cube_dirs : Array[ Vector3 ] = [
					Vector3(0,0,+1), Vector3(0,0,-1),
					Vector3(0,+1,0), Vector3(0,-1,0),
					Vector3(+1,0,0), Vector3(-1,0,0) ]
			rays.append_array( _cube_dirs )
			if per_omni > 6:
				# add extras randomly
				for i in (per_omni - 6):
					rays.push_back( Vector3.octahedron_decode( 
							qrnd_distrib( i * 17 + 33 ) ) )
	# size the rays correctly
	for i in rays.size():
		rays[i] *= light.omni_range
	# do the ray casts
	var compensate_N_pts : float = 1.0 / rays.size()
	var angle_deg : float = 240.0 * compensate_N_pts
	process_light_rays( light, rays, angle_deg, 
			light.light_energy * bounce_gain * 0.1 * compensate_N_pts )

func _ready():
	# set up for raycasts (which are all in global space)
	space_state = get_world_3d().direct_space_state
	# find all possible source lights
	var source_nodes : Array[ Node ]
	if top_node:
		# the user told us where to look
		source_nodes = top_node.find_children("", "Light3D" )
	else:
		# no user direction, try the parent of the FauxGI node
		var parent = get_parent()
		if parent:
			source_nodes = parent.find_children("", "Light3D" )
	if source_nodes:
		# store all vetted light sources
		for sn_light : Light3D in source_nodes:
			# maybe only look at lights which cast shadows
			if sn_light.shadow_enabled or include_shadowless:
				light_sources.push_back( sn_light )
		# report
		print( "Source count is ", light_sources.size() )
		print( "VPL max count is ", VPL_light.size() )

func disable_VPL( index : int ):
	if index < VPL_inst.size():
		RenderingServer.instance_set_visible( VPL_inst[ index ] , false )

func config_VPL(	index : int,
				pos : Vector3,
				color : Color,
				energy : float,
				dist : float ):
	if index < VPL_inst.size():
		RenderingServer.instance_set_visible( VPL_inst[ index ] , true )
		RenderingServer.instance_set_transform( VPL_inst[ index ], Transform3D( Basis(), pos ) )
	if index < VPL_light.size():
		RenderingServer.light_set_color( VPL_light[ index ], color )
		RenderingServer.light_set_param( VPL_light[ index ], RenderingServer.LIGHT_PARAM_ENERGY, energy )
		RenderingServer.light_set_param( VPL_light[ index ], RenderingServer.LIGHT_PARAM_RANGE, dist )

func qrnd_distrib( index : int, scale_01 : float = 1.0 ) -> Vector2:
	const mid2d := Vector2.ONE * 0.5
	const golden_2d := 1.32471795724474602596
	const g2 := Vector2( 1.0 / golden_2d, 1.0 / golden_2d / golden_2d )
	return ( ( mid2d + g2 * index ).posmod( 1.0 ) - mid2d) * scale_01 + mid2d;

func _enter_tree():
	allocate_VPLs( max_points )

func _exit_tree():
	allocate_VPLs( 0 )

func allocate_VPLs( N : int ):
	if N != VPL_inst.size():
		# safety first
		N = max( 0, min( max_points, N ) )
		print( "VPL count ", VPL_inst.size(), " -> ", N )
		# do we need to remove some RIDs?
		while VPL_inst.size() > N:
			RenderingServer.free_rid( VPL_inst.pop_back() )
		while VPL_light.size() > N:
			RenderingServer.free_rid( VPL_light.pop_back() )
		# do we need to add some RIDs?
		var scenario = get_world_3d().scenario
		while VPL_inst.size() < N:
			# spot is slightly slower, but alternating lets the engine render 8 omni + 8 spot per mesh
			var spot_instead : bool = ((VPL_inst.size() & 1) == 1) and VPLs_use_spots
			# each light needs an instance, attached to the scenario
			var instance : RID = RenderingServer.instance_create()
			RenderingServer.instance_set_scenario( instance, scenario )
			# now create the light and attach it
			var light : RID
			if spot_instead:
				light = RenderingServer.spot_light_create()
			else:
				light = RenderingServer.omni_light_create()
			RenderingServer.instance_set_base( instance, light )
			# configure any constant parameters here
			RenderingServer.instance_set_visible( instance , false )
			RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_SPECULAR, 0.0 )
			if spot_instead:
				RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_SPOT_ANGLE, 180.0 )
			# keep a copy around
			VPL_inst.append( instance )
			VPL_light.append( light )
