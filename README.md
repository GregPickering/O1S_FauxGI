# O1S Faux Global Illumination for Godot

## Summary
O1S_FauxGI is a lightweight approximation to global illumination for the Godot game engine.
It supports all three renderers (Compatibility / Mobile / Forward+), and is tested on the 
latest stable version of Godot (4.4.1).

## Getting Started
Using FauxGI is simple:
1. Copy the O1S_FauxGI folder into your own project
2. "Instantiate Child Scene.." under the top level Node, and select "faux_gi.tscn"
3. Make sure the scene's geometry has collision shapes

You can optionally play with the FauxGI settings while watching the results in the 3D preview window.

## Principles
The FauxGI node takes the principles of Godot's [Faking global illumination](https://docs.godotengine.org/en/stable/tutorials/3d/global_illumination/faking_global_illumination.html) page and automates them.
All light sources in the scene are scanned on _ready().  Then on every _physics_process(), each active light source in the scene can add a Virtual Point Light (VPL) to approximate indirect light.

Raycasts are used to determine where to place the VPLs, hence the need for collision shapes.  The number of raycasts per VPL is controlled with the `Oversample` setting (with 0 disabling the raycasts entirely, simply placing the VPL at a specific fraction of the way from the light's `Range`).  The more raycasts per VPL, the better they can adapt to the (possibly changing) geometry around them.

Spotlights can control more than one VPL, controlled with the `Per Spot` parameter.  The VPLs will all work the same way, all generated within the spotlight's cone.

Omnilights look best when using at least 4 VPLs, as the the VPLs can be near multiple surfaces.  If each Omnilight only has a single VPL it is much harder to get bounced light on the back of other objects in the space.  Omnilights are implemented by casting their VPLs as if there were `Per Omni` spotlights radiating outward.

Directional lights are handled as if the camera itself were an omnilight, finding where to place the `Per Directional` VPLs.  Those VPLs are then all checked to see if the directional lights can reach them, and if so the directional lights contribute the color and energy information to the VPLs.  Currently all directional lights will share the same VPLs, so the name `Per Directional` is no longer correct.

FauxGI keeps a pool of VPLs, added via the RenderingServer to minimize overhead (so they do not need to interact with the scene tree).

To get around the Compatibility light rendering limitations (each mesh can only support "8 Spot + 8 Omni"), FauxGI instances the Virtual Point Lights as a mixture of Omni and Spot lights with a 180 degree angle.  As the VPLs do not cast shadows, this essentially doubles the number of VPLs that can be rendered per mesh.

![FGI_Demo_Image](https://github.com/user-attachments/assets/6cf08f9f-e85c-4453-b8b5-10bd06872867)
