// BF_GPU_Mesh/Mod.odin
//
// Extension that registers the meshlet (task + mesh shader) pipeline
// with BF_GPU's Renderer_Extension_Point. Loaded only when the project
// enables the BF_GPU_Meshlet extension in [[extensions]] AND the GPU
// supports VK_EXT_mesh_shader; otherwise it stays unloaded and the
// renderer falls back to the traditional vertex pipeline.
//
// The meshlet shaders and meshlet asset baker live here, not in
// BF_GPU, so the BF_GPU module compiles cleanly on hardware that
// doesn't support mesh shaders.
//
// Dependencies:
//   BF_GPU    - the renderer that owns the extension point
//
// This module is loaded AFTER BF_GPU. Its module_register calls
// service_find("Renderer.ExtensionPoint") and registers the meshlet
// pass + meshlet pipeline with it.

package BF_GPU_Mesh

import "core:log"
import "../../Core"
import GPU "../../Modules/BF_GPU"

// === MODULE_IDENTITY (parsed by rbs) ===
IDENTITY :: Core.Lib_Descriptor {
	api_version      = Core.LIB_API_VERSION,
	name             = "BF_GPU_Mesh",
	version          = Core.Version{0, 0, 1},
	author           = "armscream",
	description      = "Optional meshlet (task + mesh shader) pipeline extension for BF_GPU.",
	component_kind   = .Extension,
	type             = .Renderer_Extension,
	flags            = {.Runtime},
	capabilities     = {.Renderer},
	dependencies     = {
		{
			name = "BF_GPU",
			min_version = Core.Version{0, 0, 1},
			max_version = Core.Version{9, 9, 9},
			has_max_version = true,
			has_min_version = true,
			optional = false,
		},
	},
	dependency_count = 1,
}
// === END MODULE_IDENTITY ===

MODULE_API := Core.LIB_API {
	descriptor = IDENTITY,
	load       = module_load,
	register   = module_register,
	activate   = module_activate,
	deactivate = module_deactivate,
	unload     = module_unload,
}

when #config(BUILDING_BF_GPU_MESHLET_DLL, false) {
	@(export)
	bifrost_lib_get_api :: proc() -> ^Core.LIB_API {
		return &MODULE_API
	}
}

// ---------------------------------------------------------------------------
// State. Tracks whether the extension successfully registered with the
// renderer; module_activate queries VK_EXT_mesh_shader support before
// committing to attach.
// ---------------------------------------------------------------------------

@(private)
MODULE_STATE :: struct {
	attached:   bool,
	ep:         ^GPU.Renderer_Extension_Point,
}

@(private)
MODULE_STATE_VALUE := MODULE_STATE{}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

module_load :: proc(ctx: ^Core.Lib_Context) -> bool {
	_ = ctx
	log.info("[BF_GPU_Meshlet] loaded")
	return true
}

module_register :: proc(ctx: ^Core.Lib_Context) -> bool {
	// Look up the renderer's extension point.
	if reg := core_service_registry(ctx); reg != nil {
		handle, found := Core.service_find(reg, GPU.RENDERER_EXTENSION_POINT_SERVICE_NAME)
		if !found {
			log.warn("[BF_GPU_Meshlet] Renderer.ExtensionPoint service not found; extension will be a no-op")
			return true
		}
		raw := Core.service_get(reg, handle)
		MODULE_STATE_VALUE.ep = cast(^GPU.Renderer_Extension_Point)raw
	}
	if MODULE_STATE_VALUE.ep == nil {
		log.warn("[BF_GPU_Meshlet] no extension point; extension will be a no-op")
		return true
	}

	MODULE_STATE_VALUE.ep.attach(MODULE_STATE_VALUE.ep, "BF_GPU_Meshlet")
	MODULE_STATE_VALUE.attached = true

	// Register the meshlet pass + pipeline descriptors. The actual
	// SPIR-V / shader paths are deferred to the backend; the extension
	// just hands the renderer a structured descriptor.
	register_meshlet_contributions(MODULE_STATE_VALUE.ep)

	log.info("[BF_GPU_Meshlet] attached and registered with BF_GPU")
	return true
}

module_activate :: proc(ctx: ^Core.Lib_Context) -> bool {
	_ = ctx
	// Activation checks hardware support. Until the Vulkan backend
	// exists, this is a no-op; the renderer logs which extensions
	// were activated.
	if !MODULE_STATE_VALUE.attached {
		log.warn("[BF_GPU_Meshlet] not attached; activate is a no-op")
	}
	return true
}

module_deactivate :: proc(ctx: ^Core.Lib_Context) {
	_ = ctx
}

module_unload :: proc(ctx: ^Core.Lib_Context) {
	_ = ctx
	if MODULE_STATE_VALUE.attached && MODULE_STATE_VALUE.ep != nil {
		MODULE_STATE_VALUE.ep.detach(MODULE_STATE_VALUE.ep, "BF_GPU_Meshlet")
		MODULE_STATE_VALUE.attached = false
	}
	log.info("[BF_GPU_Meshlet] unloaded")
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private = "file")
register_meshlet_contributions :: proc(ep: ^GPU.Renderer_Extension_Point) {
	// Graphics pass: Meshlet.task + Meshlet.mesh, fills visibility
	// buffer for the Mesh/* geometry buckets.
	graphics_desc := GPU.Graphics_Pass_Descriptor {
		name              = "Shading.Meshlet",
		vertex_shader     = "Engine/src/Extensions/BF_GPU_Mesh/Shaders/Passes/Shading/Common/Meshlet.task",
		mesh_shader       = "Engine/src/Extensions/BF_GPU_Mesh/Shaders/Passes/Shading/Common/Meshlet.mesh",
		indirect_buffer   = .Global_Indirect_Command, // slot 4-7 meshlet region
		slot_count        = 4,
		write_target      = .Visibility_Buffer,
	}
	ep.register_graphics_pass(ep, "Shading.Meshlet", cast(rawptr)&graphics_desc)

	// Meshlet pipeline registration: this is the extension's identity
	// contribution. The renderer recognises "BF_GPU_Meshlet.Pipeline"
	// as the source of the Meshlet task+mesh pair. The task/mesh
	// sources live with the extension (Engine/src/Extensions/BF_GPU_Mesh/Shaders/),
	// not with BF_GPU, so the renderer compiles them only when this
	// extension is attached.
	pipeline_desc := GPU.Meshlet_Pipeline_Descriptor {
		name        = "BF_GPU_Meshlet.Pipeline",
		task_shader = "Engine/src/Extensions/BF_GPU_Mesh/Shaders/Passes/Shading/Common/Meshlet.task",
		mesh_shader = "Engine/src/Extensions/BF_GPU_Mesh/Shaders/Passes/Shading/Common/Meshlet.mesh",
		max_meshlets_per_wg = 32,
		supports_cull       = true,
	}
	ep.register_meshlet_pipeline(ep, "BF_GPU_Meshlet.Pipeline", cast(rawptr)&pipeline_desc)
}

@(private = "file")
core_service_registry :: proc(ctx: ^Core.Lib_Context) -> ^Core.Service_Registry {
	if ctx == nil do return nil
	raw := Core.lib_context_query(
		ctx,
		Core.CORE_LIB_INTERFACE_SERVICE_REGISTRY,
		Core.SERVICE_REGISTRY_API_VERSION,
	)
	if raw == nil do return nil
	return cast(^Core.Service_Registry)raw
}
