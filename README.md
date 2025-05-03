O1S Faux Global Illumination

A lightweight approximation to global illumination for the Godot game engine.
Supports Compatibility / Mobile / Forward+ renderers.

The FauxGI node takes the principles of Godot's [Faking global illumination](https://docs.godotengine.org/en/stable/tutorials/3d/global_illumination/faking_global_illumination.html) page and automates them.  Simply add a FauxGI node to your scene.  All light sources in the scene are scanned on _ready(), and then Virtual Point Lights (VPL) are updated every _physics_process() by raycasting from the light sources to any physics objects in the scene.

Runtime configuration options control how many raycasts are used per VPL (oversample), and if there is smoothing in time (temporal_filter).

Compile time options control how many VPLs per light type (as low as 1 per SpotLight3D, and 4 in a tetrahedron around each OmniLight3D).

To get around the Compatibility light rendering limitations (each mesh can only support "8 Spot + 8 Omni"), FauxGI instances the Virtual Point Lights as a mixture of Omni and Spot lights with a 180 degree angle.  As the VPLs do not cast shadows, this essentially doubles the number of VPLs that can be rendered per mesh.  Directional lights are not yet supported.

![FGI_Demo_Image](https://github.com/user-attachments/assets/6cf08f9f-e85c-4453-b8b5-10bd06872867)
