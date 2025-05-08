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
## Do we want to spawn VPLs for source lights which don't cast shadows?
const include_shadowless : bool = false
## use real random vectors instead of a repeatable pattern (requires heavy temporal filtering)
const real_random_jitter : bool = false
## scales all light power
const scale_all_light_energy : float = 0.25

@export_category( "Scene Integration" )
## The node containing all the lights we wish to GI-ify
@export var top_node : Node3D = null
## Maximum number of point sources we can add to the scene to simulate GI
@export_range( 1, 1024 ) var max_points : int = 32
## Maximum number of directional sources we can add to the scene to simulate GI
@export_range( 1, 32 ) var max_directionals : int = 8
## What fraction of energy is preserved each bounce
@export_range( 0.0, 1.0, 0.01 ) var bounce_gain : float = 0.25
## Visualize the raycasts?
@export var show_raycasts : bool = false

@export_category( "Spot & Omni Lights" )
## How many VPLs to generate per source SpotLight3D, 1+
@export_range( 1, 8 ) var per_spot : int = 1:
		set( value ):
			per_spot = value
			light_data_stale = true
## How many VPLs to generate per source OmniLight3D, 1+ (>= 4 looks good)
@export_range( 1, 32 ) var per_omni : int = 4:
		set( value ):
			per_omni = value
			light_data_stale = true
## How many raycasts per VPL per _physics_process, 0+
@export_range( 0, 100 ) var oversample : int = 8
## Filter the VPLs over time (0=never update/infinite filtering, 1=instant update/no filtering)
@export_range( 0.01, 1.0, 0.01 ) var temporal_filter : float = 0.25
## place the VPL (0=at light origin, 1=at intersection)
@export_range( 0.0, 1.1, 0.01 ) var placement_fraction : float = 0.5

@export_category( "Directional Lights" )
## Generate a grid of NxN VPLs to approximate all DirectionalLight3D's.  A value
## of 0 will use Virtual Directional Lights instead (which is a horrible
## approximation for indoors)
@export_range( 0, 16 ) var dir_NxN : int = 0
## Max distance for the placement of directional light bounces
@export var directional_proximity : float = 5.0
## Max distance to check for directional light being intercepted
@export var thickness : float = 10.0
enum DirCastPlane { NONE, X, Y, Z, ADAPT }
## Cast all directional sample points into a plane
@export var cast_plane : DirCastPlane = DirCastPlane.ADAPT

# original light sources in the scene
var light_sources : Array[ Light3D ] = []
# keep data per light for temporal smoothing (cascaded exponential filter)
var light_filter : Dictionary[ Light3D, Dictionary ]
var light_data : Dictionary[ Light3D, Dictionary ]
# do we need to start fresh with the temporal data?
var light_data_stale : bool = true
# put all directional lights into a grid
var light_dir_grid : Array[ Dictionary ]

# keep a pool of our Virtual Points Lights
var VPL_inst : Array[ RID ] = []
var VPL_light : Array[ RID ] = []
var last_active_VPLs : int = 0
var active_VPLs : int = 0

# keep a pool of our Virtual Directional Lights
var VDL_inst : Array[ RID ] = []
var VDL_light : Array[ RID ] = []
var last_active_VDLs : int = 0
var active_VDLs : int = 0

# know where the camera is
var _camera : Camera3D = null

# physics stuff
var query := PhysicsRayQueryParameters3D.new()
var space_state : PhysicsDirectSpaceState3D = null
enum ray_storage { energy, pos, norm, rad, color, dist_frac }

# debug raycasts
var raycast_hits : PackedVector3Array = []
var raycast_misses : PackedVector3Array = []
@onready var draw_rays : ImmediateMesh = $RaycastDebug.mesh

# I need to raycast, which happens here in the physics process
func _physics_process( _delta ):
	active_VPLs = 0
	active_VDLs = 0
	allocate_VPLs( max_points )
	allocate_VDLs( max_directionals )
	raycast_hits.clear()
	raycast_misses.clear()
	if bounce_gain >= 0.01:
		light_dir_grid.clear()
		if dir_NxN > 0:
			light_dir_grid.resize( dir_NxN * dir_NxN )
		# to I need to refresh all light data?
		if light_data_stale:
			light_filter.clear()
			light_data.clear()
			light_data_stale = false
		# now run through all active light sources in the scene
		for light in light_sources:
			if light.is_visible_in_tree():
				light_filter.get_or_add( light, {} )
				light_data.get_or_add( light, {} )
				match light.get_class():
					"DirectionalLight3D": process_dirl( light )
					"OmniLight3D": process_omni( light )
					"SpotLight3D": process_spot( light )
			else:
				light_filter.erase( light )
				light_data.erase( light )
		# Gather all active VPLs into a convenient array
		var preVPLs : Array[ Dictionary ] = []
		for light in light_data:
			for idx in light_data[ light ]:
				if light_data[ light ][ idx ][ ray_storage.energy ] > 0.0:
					preVPLs.push_back( light_data[ light ][ idx ] )
					preVPLs.back()[ ray_storage.color ] = light.light_color;
		if light_dir_grid:
			for lg in light_dir_grid:
				if lg:
					preVPLs.push_back( lg )
		# Do we need a second pass to filter out the top N VPLs?
		if preVPLs.size() > max_points:
			# sort most to least energetic
			preVPLs.sort_custom( func(a, b): return a[ ray_storage.energy ] > b[ ray_storage.energy ] )
			# do I want to average all the lights that will get cut?
			if true:
				var avg_VPL : Dictionary = preVPLs[ 0 ]
				for key in avg_VPL:
					avg_VPL[ key ] *= 0.0
				var sum_energy : float = 0.0
				for idx in range( max_points - 1, preVPLs.size() ):
					var e : float = preVPLs[ idx ][ ray_storage.energy ]
					sum_energy += e;
					for key in preVPLs[ idx ]:
						avg_VPL[ key ] += preVPLs[ idx ][ key ] * e
				var gain : float = 1.0 / sum_energy
				for key in avg_VPL:
					avg_VPL[ key ] *= gain
				avg_VPL[ ray_storage.energy ] = sum_energy
			# just throw away the rest
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
		light_filter.clear()
		light_data.clear()
	# done with raycasts
	draw_rays.clear_surfaces()
	if show_raycasts:
		if not raycast_hits.is_empty():
			draw_rays.surface_begin( Mesh.PRIMITIVE_LINES )
			for rce in raycast_hits:
				draw_rays.surface_add_vertex( rce )
			draw_rays.surface_set_color( Color.WHITE )
			draw_rays.surface_end()
		if not raycast_misses.is_empty():
			draw_rays.surface_begin( Mesh.PRIMITIVE_LINES )
			for rce in raycast_misses:
				draw_rays.surface_add_vertex( rce )
			draw_rays.surface_set_color( Color.BLACK )
			draw_rays.surface_end()
	# deactivate any VPLs that need it
	if active_VPLs < last_active_VPLs:
		for idx in range( active_VPLs, last_active_VPLs ):
			disable_VPL( idx )
	if last_active_VPLs != active_VPLs:
		last_active_VPLs = active_VPLs
		print( last_active_VPLs, " active VPLs" )
	# same for VDLs
	if active_VDLs < last_active_VDLs:
		for idx in range( active_VDLs, last_active_VDLs ):
			disable_VDL( idx )
	if last_active_VDLs != active_VDLs:
		last_active_VDLs = active_VDLs
		print( last_active_VDLs, " active VDLs" )

func process_ray_dummy( from : Vector3, to : Vector3, done_frac : float = 0.5 ) -> Dictionary:
	# This function is only called if Oversample is 0, i.e. no raycasts
	var res_light : Dictionary
	var total_d : float = from.distance_to( to )
	var done_d : float = total_d * done_frac
	res_light[ ray_storage.pos ] = lerp( from, to, done_frac * placement_fraction )
	res_light[ ray_storage.norm ] = to.direction_to( from ) # just say the normal is back along this ray
	res_light[ ray_storage.rad ] = (total_d - 0.5 * done_d) * 1.25
	res_light[ ray_storage.energy ] = sqrt( 1.0 - done_frac )
	return res_light

var collisions : Dictionary = {}
func raycast( from : Vector3, to : Vector3 ) -> Dictionary:
	# do the ray cast
	query.from = from
	query.to = to
	var res_ray := space_state.intersect_ray( query )
	# what did we hit?
	#if res_ray:
		## save based on some collision ID
		#var cid = res_ray.face_index
		#if not collisions.has( cid ):
			#collisions[ cid ] = true
			## and what did we hit?
			#printt( "Entry " + str( collisions.size() ),
					#res_ray.collider, res_ray.collider_id, 
					#res_ray.face_index, res_ray.rid, res_ray.shape )
	# draw it?
	if show_raycasts:
		if res_ray:
			raycast_hits.push_back( to_local( from ) )
			raycast_hits.push_back( to_local( res_ray.position ) )
		else:
			raycast_misses.push_back( to_local( from ) )
			raycast_misses.push_back( to_local( to ) )
	return res_ray
	
func process_ray( from : Vector3, to : Vector3 ) -> Dictionary:
	#
	var res_light : Dictionary
	var res_ray := raycast( from, to )
	if res_ray:
		var total_d : float = from.distance_to( to )
		var done_d : float = from.distance_to( res_ray.position )
		var done_frac : float = done_d / maxf( total_d, 1e-6 )
		res_light[ ray_storage.pos ] = lerp( from, to, done_frac * placement_fraction )
		res_light[ ray_storage.norm ] = res_ray.normal
		res_light[ ray_storage.rad ] = (total_d - 0.5 * done_d) * 1.25
		res_light[ ray_storage.energy ] = sqrt( 1.0 - done_frac ) \
					* absf( res_ray.normal.dot( from.direction_to( to ) ) )
	return res_light

func process_rays( from : Vector3, rays : Array[ Vector3 ] ) -> Dictionary:
	var avg_ray_res : Dictionary
	var sum_energy : float = 0.0
	for ray in rays:
		var ray_res := process_ray( from, from + ray )
		if ray_res:
			# weight by energy
			var e = ray_res[ ray_storage.energy ]
			if e > 0.0:
				sum_energy += e
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
		var gain = 1.0 / sum_energy
		avg_ray_res[ ray_storage.pos ] *= gain
		avg_ray_res[ ray_storage.norm ] *= gain
		avg_ray_res[ ray_storage.rad ] *= gain
		# and the energy itself is scaled by the number of samples
		avg_ray_res[ ray_storage.energy ] = sum_energy / rays.size()
	return avg_ray_res

func jitter_ray_angle(	ray : Vector3, N : int, deg : float, 
						true_rnd : bool = real_random_jitter ) -> Array[ Vector3 ]:
	# always start with the original?
	var rays : Array[ Vector3 ] = [] # [ ray ]
	# now add others
	if N > 0:
		var length : float = -ray.length()
		var xform := Quaternion( Vector3(0,0,-1), ray )
		for samp in range( 0, N ):
			var samp_2d : Vector2
			if true_rnd:
				samp_2d = Vector2( randf_range(-0.5, 0.5), randf_range(-0.5, 0.5) ) * (deg / 120.0) + Vector2(0.5,0.5)
			else:
				samp_2d = qrnd_distrib( samp, deg / 120.0 )
			var sample_vec := Vector3.octahedron_decode( samp_2d )
			rays.push_back( (xform * sample_vec) * length )
	return rays

func process_rays_angle( from : Vector3, to : Vector3, N : int, deg : float ) -> Dictionary:
	if N > 0:
		var rays := jitter_ray_angle( to - from, N, deg )
		return process_rays( from, rays )
	else:
		return process_ray_dummy( from, to, 0.5 )

# Do I want cascaded exponential filtering?

func update_light_data( light : Light3D, idx : int, data : Dictionary, modulate : float ):
	if light and data:
		# scale in the actual light energy here
		data[ ray_storage.energy ] *= modulate * light.light_indirect_energy
		if light_data[ light ].has( idx ):
			for key in data:
				# Cascaded exponential filter
				light_filter[ light ][ idx ][ key ] = lerp( 
						light_filter[ light ][ idx ][ key ],
						data[ key ], temporal_filter )
				light_data[ light ][ idx ][ key ] = lerp( 
						light_data[ light ][ idx ][ key ],
						light_filter[ light ][ idx ][ key ], temporal_filter )
				#light_data[ light ][ idx ][ key ] = lerp( 
						#light_data[ light ][ idx ][ key ],
						#data[ key ], temporal_filter )
		else:
			light_filter[ light ][ idx ] = data#.duplicate()
			light_data[ light ][ idx ] = data#.duplicate()
			# do I want the amplitude to fade in?
			#light_data[ light ][ idx ][ ray_storage.energy ] *= temporal_filter
	else:
		light_filter[ light ].erase( idx )
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
		else:
			light_filter[ light ].erase( ray_idx )
			light_data[ light ].erase( ray_idx )

func process_dirl( light : Light3D ):
	var light_dir : Vector3 = light.global_basis.z * -thickness
	var e : float = (light.light_energy * light.light_indirect_energy * 
				scale_all_light_energy * bounce_gain)
	if dir_NxN < 1:
		# directly place a Virtual Directional Light, instead of VPLs
		config_VDL( active_VDLs, light.global_basis.z, light.light_color, e )
		active_VDLs += 1
	else:
		e /= dir_NxN * dir_NxN
		var offset : float = (dir_NxN - 1.0) * 0.5
		var center : Vector3 = _camera.global_position - _camera.global_basis.z * directional_proximity * 0.35
		var sample_basis := Basis()
		match cast_plane:
			DirCastPlane.X:
				sample_basis = Basis( Quaternion( _camera.global_basis.y, Vector3(1,0,0) ) )
			DirCastPlane.Y:
				sample_basis = Basis( Quaternion( _camera.global_basis.y, Vector3(0,1,0) ) )
			DirCastPlane.Z:
				sample_basis = Basis( Quaternion( _camera.global_basis.y, Vector3(0,0,0) ) )
			DirCastPlane.ADAPT:
				sample_basis = Basis( Quaternion( _camera.global_basis.y, light.global_basis.z ) )
		sample_basis *= _camera.global_basis
		var stride : float = directional_proximity / dir_NxN
		var stride_i = sample_basis * Vector3( -0.7071, 0, +0.7071 ) * stride
		var stride_j = sample_basis * Vector3( +0.7071, 0, +0.7071 ) * stride
		var idx : int = 0
		for j in dir_NxN:
			var pt_row : Vector3 = center + (j - offset) * stride_j
			for i in dir_NxN:
				var pt : Vector3 = pt_row + (i - offset) * stride_i
				var res_ray := raycast( pt - light_dir, pt + light_dir )
				if res_ray:
					if res_ray.normal.dot( res_ray.position - _camera.global_position ) < 0.0:
						var vpl : Dictionary = {}
						vpl[ ray_storage.color ] = light.light_color
						vpl[ ray_storage.pos ] = res_ray.position
						vpl[ ray_storage.rad ] = directional_proximity # 2 * stride
						vpl[ ray_storage.energy ] = e * 10
						if light_dir_grid[ idx ]:
							light_dir_grid[ idx ] = vpl
						else:
							light_dir_grid[ idx ] = vpl
				idx += 1

func process_spot( light : Light3D ):
	var compensate_N_pts : float = 1.0 / per_spot
	# these rays never use real random jitter
	var rays := jitter_ray_angle( -light.spot_range * light.global_basis.z, 
									per_spot, light.spot_angle, false )
	process_light_rays( light, rays, light.spot_angle * sqrt( compensate_N_pts ), 
		light.light_energy * bounce_gain * scale_all_light_energy * compensate_N_pts )

func process_omni( light : Light3D ):
	# where do I want to cast rays
	var rays : Array[ Vector3 ] = []
	match abs( per_omni ):
		0:	# do nothing
			return
		1:	# this is a single point
			rays.append( Vector3.DOWN )
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
	var angle_deg : float = sqrt( 14400.0 * compensate_N_pts )
	process_light_rays( light, rays, angle_deg, 
			light.light_energy * bounce_gain * scale_all_light_energy * compensate_N_pts )

func _ready():
	# grab the camera
	if Engine.is_editor_hint():
		# Get EditorInterface this way because it does not exist in a build
		var editor_interface := Engine.get_singleton( "EditorInterface" )
		_camera = editor_interface.get_editor_viewport_3d().get_camera_3d()
	else:
		_camera = get_viewport().get_camera_3d()
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
			# create and attach the light (each light needs different parameters, 
			# so we can't just share a single light across multiple instances)
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

func disable_VPL( index : int ):
	if index < VPL_inst.size():
		RenderingServer.instance_set_visible( VPL_inst[ index ] , false )

func config_VPL(	index : int,
					pos : Vector3,
					color : Color,
					energy : float,
					dist : float ):
	if index < min( VPL_inst.size(), VPL_light.size() ):
		# instance parameters
		var inst : RID = VPL_inst[ index ]
		RenderingServer.instance_set_visible( inst , true )
		RenderingServer.instance_set_transform( inst, Transform3D( Basis.IDENTITY, pos ) )
		# light parameters
		var light : RID = VPL_light[ index ]
		RenderingServer.light_set_color( light, color )
		RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_ENERGY, energy )
		RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_RANGE, dist )

func allocate_VDLs( N : int ):
	if N != VDL_inst.size():
		# safety first
		N = max( 0, min( max_directionals, N ) )
		print( "VDL count ", VDL_inst.size(), " -> ", N )
		# do we need to remove some RIDs?
		while VDL_inst.size() > N:
			RenderingServer.free_rid( VDL_inst.pop_back() )
		while VDL_light.size() > N:
			RenderingServer.free_rid( VDL_light.pop_back() )
		# do we need to add some RIDs?
		var scenario = get_world_3d().scenario
		while VDL_inst.size() < N:
			# each light needs an instance, attached to the scenario
			var instance : RID = RenderingServer.instance_create()
			RenderingServer.instance_set_scenario( instance, scenario )
			# create and attach the light (each light needs different parameters, 
			# so we can't just share a single light across multiple instances)
			var light : RID = RenderingServer.directional_light_create()
			RenderingServer.instance_set_base( instance, light )
			# configure any constant parameters here
			RenderingServer.instance_set_visible( instance , false )
			RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_SPECULAR, 0.0 )
			# keep a copy around
			VDL_inst.append( instance )
			VDL_light.append( light )

func disable_VDL( index : int ):
	if index < VDL_inst.size():
		RenderingServer.instance_set_visible( VDL_inst[ index ] , false )

func config_VDL(	index : int,
					direction : Vector3,
					color : Color,
					energy : float ):
	if index < min( VDL_inst.size(), VDL_light.size() ):
		# instance parameters
		var inst : RID = VDL_inst[ index ]
		RenderingServer.instance_set_visible( inst , true )
		RenderingServer.instance_set_transform( inst, 
				Transform3D( Quaternion( Vector3(0,0,-1), direction ), Vector3.ZERO ) )
		# light parameters
		var light : RID = VDL_light[ index ]
		RenderingServer.light_set_color( light, color )
		RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_ENERGY, energy )
