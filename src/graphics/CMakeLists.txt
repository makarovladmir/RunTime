# rexgpu-xenos: Xenos GPU emulation plugin (ported from Xenia)
# Namespace: rex::graphics
#
# Runtime-loaded via rex::system::LoadGpuPlugin; consumers never link this
# target. The Xenos format layer is compiled into rexcore.

set(REXGPU_XENOS_SOURCES
    plugin_main.cpp

    # Core GPU types
    flags.cpp
    volyre.cpp
    register_file.cpp
    registers.cpp
    pipeline/shader/shader.cpp
    format/ucode.cpp
    sampler_info.cpp

    # GPU system
    graphics_system.cpp
    command_processor.cpp
    pm4_plume_transpiler.cpp
    util/draw_extent_estimator.cpp
    util/draw.cpp
    packet_disassembler.cpp
    primitive_processor.cpp
    pipeline/render_target/cache.cpp
    shared_memory.cpp
    pipeline/texture/cache.cpp
    pipeline/shader/interpreter.cpp
    pipeline/shader/prebaked_shader_cache.cpp
    pipeline/shader/translator.cpp
    pipeline/shader/translator_disasm.cpp
)

# SPIR-V shader translation
set(REXGPU_XENOS_SPIRV_SOURCES
    pipeline/shader/spirv_builder.cpp
    pipeline/shader/spirv.cpp
    pipeline/shader/spirv_translator.cpp
    pipeline/shader/spirv_translator_alu.cpp
    pipeline/shader/spirv_translator_fetch.cpp
    pipeline/shader/spirv_translator_memexport.cpp
    pipeline/shader/spirv_translator_rb.cpp
)

# Vulkan backend
set(REXGPU_XENOS_VULKAN_SOURCES
    vulkan/graphics_system.cpp
    vulkan/deferred_command_buffer.cpp
    vulkan/command_processor.cpp
    vulkan/pipeline_cache.cpp
    vulkan/primitive_processor.cpp
    vulkan/render_target_cache.cpp
    vulkan/shader.cpp
    vulkan/shared_memory.cpp
    vulkan/texture_cache.cpp
)

list(APPEND REXGPU_XENOS_SOURCES ${REXGPU_XENOS_SPIRV_SOURCES} ${REXGPU_XENOS_VULKAN_SOURCES})

add_library(rexgpu-xenos SHARED ${REXGPU_XENOS_SOURCES})
add_library(rex::gpu-xenos ALIAS rexgpu-xenos)

set_target_properties(rexgpu-xenos PROPERTIES
    EXPORT_NAME gpu-xenos
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

target_include_directories(rexgpu-xenos PRIVATE
    ${REXGLUE_ROOT}/thirdparty/renderdoc
)

target_compile_options(rexgpu-xenos PRIVATE -Wno-unused-variable)

rex_target_pch(rexgpu-xenos
    <mutex>
    <unordered_map>
    <rex/math.h>
    <rex/memory.h>
    <rex/thread/mutex.h>
    <rex/system/xmemory.h>
    <rex/graphics/xenos.h>
    <rex/graphics/registers.h>
    <rex/graphics/format/ucode.h>
    <rex/graphics/pipeline/shader/shader.h>
)

# Everything PRIVATE: the plugin has no consumers. Never link the OBJECT
# libraries (rexcore/rexui) here; rexruntime already contains those objects
# and relinking them would duplicate global state.
target_link_libraries(rexgpu-xenos PRIVATE
    rexruntime
    xxHash::xxhash
    Vulkan::Headers
    glslang::SPIRV
    GPUOpen::VulkanMemoryAllocator
    glslang
    MachineIndependent
    GenericCodeGen
    OSDependent
    OGLCompiler
)
