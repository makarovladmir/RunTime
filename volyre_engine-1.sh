#!/usr/bin/env bash
# Volyre AC Engine v2 - one-file installer / updater.
#
#   SDK repo  (RunTime; has src/graphics/vulkan/command_processor.cpp)   -> bash volyre_engine.sh
#   Game repo (AC2-Android-Recomp; has ac2mobile_manifest.toml)          -> bash volyre_engine.sh
#
# Works on a fresh tree (v1+v2) and on a tree that already has v1; running it twice does nothing.
#
# v2, from your logs and video of the previous build:
#   * the governor reached level 5 although the frame was CPU-bound (guest threads at 100 %, GPU wait ~0),
#     which deleted most geometry (sky-only frames, grey scene, black slats). Now it sheds work ONLY while the
#     command-processor thread is actually waiting on the GPU (volyre_gpu_bound_only = true).
#   * default is preset 2 "performance" = levels 0-3 (particles -> small props -> shadows/z-prepass).
#     Levels 4-5 (whole meshes disappear) and forced 1x MSAA (suspected cause of the stripes: games tile EDRAM
#     around MSAA) are now only in preset 3 "extreme".
#   * texture re-upload throttle is a flat 2 frames (it no longer scales with the level).
#   * native_2x_msaa is back to true so real 2x MSAA is used when MSAA is not forced off.
#
# Presets (extra ini box or AC2Recomp.ini):  volyre_preset = 0 custom | 1 balanced | 2 performance | 3 extreme
#   0 uses volyre_min_level / volyre_max_level (0-5). Other keys: volyre_enable, volyre_target_fps,
#   volyre_adaptive, volyre_gpu_bound_only, volyre_force_msaa_1x, volyre_texture_refresh_frames.
#
# The GPU code lives in the SDK plugin: after running this in the SDK repo, commit, push and run its
# "Build Android ARM64" workflow, then build the game with sdk_url pointing at the new release asset.
set -euo pipefail

P1="$(mktemp)"; P2="$(mktemp)"
trap 'rm -f "$P1" "$P2"' EXIT
cat > "$P1" <<'VOLYRE_P1_EOF'
diff --git a/include/rex/graphics/pipeline/texture/cache.h b/include/rex/graphics/pipeline/texture/cache.h
index d26cd4f..446613b 100644
--- a/include/rex/graphics/pipeline/texture/cache.h
+++ b/include/rex/graphics/pipeline/texture/cache.h
@@ -228,6 +228,12 @@ class TextureCache {
     }
     void MakeUpToDateAndWatch(const std::unique_lock<std::recursive_mutex>& global_lock);
 
+    // Volyre: re-upload throttling of textures whose guest memory the CPU rewrote.
+    bool volyre_loaded_once() const { return volyre_loaded_once_; }
+    bool volyre_gpu_dirty() const { return volyre_gpu_dirty_; }
+    uint64_t volyre_last_load_frame() const { return volyre_last_load_frame_; }
+    void VolyreMarkGpuDirty() { volyre_gpu_dirty_ = true; }
+
     void WatchCallback(const std::unique_lock<std::recursive_mutex>& global_lock, bool is_mip);
 
     // For LRU caching - updates the last usage frame and moves the texture to
@@ -262,6 +268,9 @@ class TextureCache {
     Texture* used_next_;
     bool in_usage_list_;
     bool force_load_3d_tiling_ = false;
+    bool volyre_loaded_once_ = false;
+    bool volyre_gpu_dirty_ = false;
+    uint64_t volyre_last_load_frame_ = 0;
 
     // These are to be accessed within the global critical region to synchronize
     // with shared memory.
@@ -614,6 +623,7 @@ class TextureCache {
   // so need to recheck if textures aren't outdated, disregarding whether fetch
   // constants have been changed.
   std::atomic<bool> texture_became_outdated_{false};
+  uint64_t volyre_frame_counter_ = 0;
 
   std::array<TextureBinding, xenos::kTextureFetchConstantCount> texture_bindings_;
   // Bit vector with bits reset on fetch constant writes to avoid parsing fetch
diff --git a/include/rex/graphics/volyre.h b/include/rex/graphics/volyre.h
new file mode 100644
index 0000000..188497d
--- /dev/null
+++ b/include/rex/graphics/volyre.h
@@ -0,0 +1,46 @@
+/**
+ * Volyre AC Engine - adaptive performance governor for the Xenos GPU backend.
+ *
+ * Everything here is optional and driven by cvars (all named volyre_*). The governor runs on the
+ * GPU command-processor thread: OnFrameSwap() is called once per guest swap, ShouldSkipDraw() once
+ * per draw.
+ */
+#pragma once
+
+#include <cstdint>
+
+namespace rex::graphics::volyre {
+
+// Cached cvar reads (cheap enough for the register-write hot path).
+bool Enabled();
+bool ForceMsaa1x();
+uint32_t TextureRefreshFrames();  // 0 = never throttle texture re-uploads
+
+// Current load-shedding level, 0 (full quality) .. volyre_max_level (<= 5).
+uint32_t Level();
+
+// Called once per guest swap (frame boundary).
+void OnFrameSwap();
+
+// Called for each frame the texture cache starts (counts re-uploads that were deferred).
+void NoteTextureRefreshDeferred();
+void NoteTextureRefreshDone();
+
+struct DrawInfo {
+  uint32_t index_count = 0;
+  bool is_rect_list = false;   // clears / resolves / full-screen passes are drawn as rect lists
+  bool memexport = false;      // vertex/pixel shader writes guest memory: never skip
+  bool color_written = false;  // any color render target is written
+  bool depth_test = false;
+  bool depth_write = false;
+  bool blended = false;        // render target 0 blends with the destination
+  bool kcolor_depth_mode = false;
+};
+
+// true = drop this draw (do not record it).
+bool ShouldSkipDraw(const DrawInfo& d);
+
+// true = skip this EDRAM resolve (only ever a depth resolve that does not clear the surface).
+bool ShouldSkipResolve(bool is_depth_source, bool clears_surface);
+
+}  // namespace rex::graphics::volyre
diff --git a/src/graphics/CMakeLists.txt b/src/graphics/CMakeLists.txt
index ce67073..46e271e 100644
--- a/src/graphics/CMakeLists.txt
+++ b/src/graphics/CMakeLists.txt
@@ -9,6 +9,7 @@ set(REXGPU_XENOS_SOURCES
 
     # Core GPU types
     flags.cpp
+    volyre.cpp
     register_file.cpp
     registers.cpp
     pipeline/shader/shader.cpp
diff --git a/src/graphics/command_processor.cpp b/src/graphics/command_processor.cpp
index d0b0028..e5ec5d8 100644
--- a/src/graphics/command_processor.cpp
+++ b/src/graphics/command_processor.cpp
@@ -25,6 +25,7 @@
 #include <rex/graphics/command_processor.h>
 #include <rex/graphics/flags.h>
 #include <rex/graphics/graphics_system.h>
+#include <rex/graphics/volyre.h>
 #include <rex/graphics/pipeline/texture/info.h>
 #include <rex/graphics/sampler_info.h>
 #include <rex/graphics/xenos.h>
@@ -379,6 +380,11 @@ uint32_t CommandProcessor::ReadRegisterValue(uint32_t index) const {
 }
 
 void CommandProcessor::WriteRegister(uint32_t index, uint32_t value) {
+  // Volyre: never let the guest enable MSAA. 2x/4x guest MSAA makes every host render target 2-4x
+  // bigger and is the largest single GPU cost on a tiler. RB_SURFACE_INFO.msaa_samples = bits 16-17.
+  if (index == XE_GPU_REG_RB_SURFACE_INFO && volyre::ForceMsaa1x()) {
+    value &= ~(UINT32_C(3) << 16);
+  }
   pm4_plume_transpiler_.ObserveRegisterWrite(index, value);
   RegisterFile& regs = *register_file_;
   if (index >= RegisterFile::kRegisterCount) {
diff --git a/src/graphics/pipeline/texture/cache.cpp b/src/graphics/pipeline/texture/cache.cpp
index ca45c25..6e9545c 100644
--- a/src/graphics/pipeline/texture/cache.cpp
+++ b/src/graphics/pipeline/texture/cache.cpp
@@ -22,6 +22,7 @@
 #include <rex/graphics/pipeline/texture/info.h>
 #include <rex/graphics/pipeline/texture/util.h>
 #include <rex/graphics/register_file.h>
+#include <rex/graphics/volyre.h>
 #include <rex/graphics/xenos.h>
 #include <rex/logging.h>
 #include <rex/math.h>
@@ -324,6 +325,7 @@ void TextureCache::BeginSubmission(uint64_t new_submission_index) {
 }
 
 void TextureCache::BeginFrame() {
+  ++volyre_frame_counter_;
   // In case there was a failure to create something in the previous frame, make
   // sure bindings are reset so a new attempt will surely be made if the texture
   // is requested again.
@@ -401,6 +403,19 @@ bool TextureCache::PrepareTextureLoad(Texture& texture, PendingTextureLoad& pend
     return false;
   }
 
+  // Volyre: a texture that was already uploaded once and was invalidated by a CPU write is refreshed at
+  // most every N frames. Every upload mid-frame ends the current render pass (a full tile flush on
+  // Adreno), and the log showed 50-100 such uploads per frame. GPU-written (resolved) textures are
+  // never throttled. Bindings are reset every frame, so the refresh is retried automatically.
+  if (texture.volyre_loaded_once() && !texture.volyre_gpu_dirty()) {
+    const uint32_t volyre_refresh_frames = volyre::TextureRefreshFrames();
+    if (volyre_refresh_frames &&
+        (volyre_frame_counter_ - texture.volyre_last_load_frame()) < volyre_refresh_frames) {
+      volyre::NoteTextureRefreshDeferred();
+      return false;
+    }
+  }
+
   pending_load_out.texture = &texture;
   pending_load_out.load_base = base_outdated;
   pending_load_out.load_mips = mips_outdated;
@@ -457,6 +472,7 @@ bool TextureCache::CommitPreparedTextureLoad(const PendingTextureLoad& pending_l
   // regular texture or a vertex buffer, and thus the scaled resolve version is
   // not up to date anymore.
   texture.MakeUpToDateAndWatch(global_critical_region_.Acquire());
+  volyre::NoteTextureRefreshDone();
   texture.LogAction("Loaded");
 
   return true;
@@ -715,6 +731,9 @@ void TextureCache::Texture::MakeUpToDateAndWatch(
         key().mip_page << 12, GetGuestMipsSize(), TextureCache::WatchCallback, this, nullptr, 1);
     outdated_mask_.fetch_and(~kOutdatedBitMips, std::memory_order_release);
   }
+  volyre_loaded_once_ = true;
+  volyre_gpu_dirty_ = false;
+  volyre_last_load_frame_ = texture_cache_.volyre_frame_counter_;
 }
 
 void TextureCache::Texture::MarkAsUsed() {
@@ -763,6 +782,9 @@ void TextureCache::WatchCallback(const std::unique_lock<std::recursive_mutex>& g
                                  void* context, void* data, uint64_t argument,
                                  bool invalidated_by_gpu) {
   Texture& texture = *static_cast<Texture*>(context);
+  if (invalidated_by_gpu) {
+    texture.VolyreMarkGpuDirty();
+  }
   texture.WatchCallback(global_lock, argument != 0);
   texture.texture_cache().texture_became_outdated_.store(true, std::memory_order_release);
 }
diff --git a/src/graphics/volyre.cpp b/src/graphics/volyre.cpp
new file mode 100644
index 0000000..82dd7eb
--- /dev/null
+++ b/src/graphics/volyre.cpp
@@ -0,0 +1,179 @@
+/**
+ * Volyre AC Engine - adaptive performance governor (see include/rex/graphics/volyre.h).
+ *
+ * A level is raised while frames miss volyre_target_fps and lowered again after a few seconds of
+ * meeting it (never below volyre_min_level / above volyre_max_level). Levels are cumulative:
+ *   1  half of the blended, depth-tested, non-depth-writing draws (particles, glass, decals) dropped
+ *   2  all of those, plus opaque draws with <= 36 indices (small props)
+ *   3  depth-only draws (shadow maps, z pre-pass) and depth resolves; opaque <= 180 indices,
+ *      <= 720 indices every other draw
+ *   4  opaque <= 720 indices, <= 2400 indices every other draw
+ *   5  opaque <= 2400 indices plus every third bigger draw
+ * Draws without depth test (HUD, menus, post-processing), memexport draws and rect lists (clears,
+ * full-screen passes) are never dropped at any level.
+ */
+
+#include <rex/graphics/volyre.h>
+
+#include <algorithm>
+#include <atomic>
+#include <chrono>
+
+#include <rex/cvar.h>
+#include <rex/logging.h>
+
+REXCVAR_DEFINE_BOOL(volyre_enable, true, "Volyre", "Master switch for the Volyre performance engine");
+REXCVAR_DEFINE_BOOL(volyre_force_msaa_1x, true, "Volyre",
+                    "Ignore guest MSAA (render at 1x): removes the 2x/4x render target cost");
+REXCVAR_DEFINE_INT32(volyre_texture_refresh_frames, 4, "Volyre",
+                     "A texture whose guest memory was rewritten by the CPU is re-uploaded at most "
+                     "once per this many frames (0 = always)");
+REXCVAR_DEFINE_BOOL(volyre_adaptive, true, "Volyre",
+                    "Raise the load-shedding level automatically while the frame rate is below target");
+REXCVAR_DEFINE_INT32(volyre_target_fps, 60, "Volyre", "Frame rate the governor tries to hold");
+REXCVAR_DEFINE_INT32(volyre_min_level, 0, "Volyre", "Lowest load-shedding level (0-5)");
+REXCVAR_DEFINE_INT32(volyre_max_level, 5, "Volyre", "Highest load-shedding level (0-5)");
+
+namespace rex::graphics::volyre {
+namespace {
+
+std::atomic<uint32_t> g_level{0};
+std::atomic<uint32_t> g_deferred_refresh{0};
+std::atomic<uint32_t> g_done_refresh{0};
+
+int64_t NowNs() {
+  return std::chrono::duration_cast<std::chrono::nanoseconds>(
+             std::chrono::steady_clock::now().time_since_epoch())
+      .count();
+}
+
+struct GovernorState {
+  int64_t last_swap_ns = 0;
+  uint32_t miss_run = 0;
+  uint32_t ok_run = 0;
+  uint32_t frames_since_change = 0;
+  uint64_t frame = 0;
+  int64_t window_start_ns = 0;
+  uint32_t window_frames = 0;
+};
+GovernorState g_state;
+uint32_t g_draw_counter = 0;
+
+uint32_t ClampLevel(int32_t v) { return uint32_t(std::clamp(v, 0, 5)); }
+
+}  // namespace
+
+bool Enabled() { return REXCVAR_GET(volyre_enable); }
+bool ForceMsaa1x() { return REXCVAR_GET(volyre_enable) && REXCVAR_GET(volyre_force_msaa_1x); }
+
+uint32_t TextureRefreshFrames() {
+  if (!REXCVAR_GET(volyre_enable)) return 0;
+  uint32_t base = uint32_t(std::max(0, REXCVAR_GET(volyre_texture_refresh_frames)));
+  if (!base) return 0;
+  // Under load, refresh textures less often.
+  return base * (1u + std::min<uint32_t>(g_level.load(std::memory_order_relaxed), 3u));
+}
+
+uint32_t Level() { return g_level.load(std::memory_order_relaxed); }
+
+void NoteTextureRefreshDeferred() { g_deferred_refresh.fetch_add(1, std::memory_order_relaxed); }
+void NoteTextureRefreshDone() { g_done_refresh.fetch_add(1, std::memory_order_relaxed); }
+
+void OnFrameSwap() {
+  if (!REXCVAR_GET(volyre_enable)) {
+    g_level.store(0, std::memory_order_relaxed);
+    return;
+  }
+  GovernorState& s = g_state;
+  const int64_t now = NowNs();
+  ++s.frame;
+  const uint32_t min_level = ClampLevel(REXCVAR_GET(volyre_min_level));
+  const uint32_t max_level = std::max(min_level, ClampLevel(REXCVAR_GET(volyre_max_level)));
+  uint32_t level = g_level.load(std::memory_order_relaxed);
+  level = std::clamp(level, min_level, max_level);
+
+  if (s.last_swap_ns && REXCVAR_GET(volyre_adaptive)) {
+    const int64_t period = now - s.last_swap_ns;
+    const int32_t fps = std::clamp(REXCVAR_GET(volyre_target_fps), 20, 120);
+    const int64_t target = 1000000000ll / fps;
+    ++s.frames_since_change;
+    if (period > target + target / 8 && period < 1500000000ll) {
+      ++s.miss_run;
+      s.ok_run = 0;
+      if (s.miss_run >= 3 && s.frames_since_change >= 4 && level < max_level) {
+        ++level;
+        s.frames_since_change = 0;
+        s.miss_run = 0;
+      }
+    } else if (period <= target + target / 8) {
+      s.miss_run = 0;
+      ++s.ok_run;
+      if (s.ok_run >= 240 && level > min_level) {
+        --level;
+        s.ok_run = 0;
+        s.frames_since_change = 0;
+      }
+    }
+  }
+  s.last_swap_ns = now;
+
+  if (level != g_level.load(std::memory_order_relaxed)) {
+    REXGPU_INFO("Volyre: load level -> {}", level);
+  }
+  g_level.store(level, std::memory_order_relaxed);
+
+  // One summary line every ~5 s.
+  ++s.window_frames;
+  if (!s.window_start_ns) s.window_start_ns = now;
+  if (now - s.window_start_ns >= 5000000000ll) {
+    const double secs = double(now - s.window_start_ns) / 1e9;
+    REXGPU_INFO(
+        "Volyre[5s]: {:.1f} fps, level {}, texture refresh done/deferred {}/{}",
+        double(s.window_frames) / secs, level, g_done_refresh.exchange(0), g_deferred_refresh.exchange(0));
+    s.window_start_ns = now;
+    s.window_frames = 0;
+  }
+}
+
+bool ShouldSkipDraw(const DrawInfo& d) {
+  const uint32_t level = g_level.load(std::memory_order_relaxed);
+  if (!level || !REXCVAR_GET(volyre_enable)) return false;
+  if (d.memexport || d.is_rect_list || !d.kcolor_depth_mode) return false;
+
+  // Depth-only draws (shadow maps / z pre-pass).
+  if (!d.color_written) {
+    return level >= 3 && (d.depth_write || d.depth_test);
+  }
+  // Draws that write color: anything without depth test is HUD / menus / post-processing.
+  if (!d.depth_test) return false;
+
+  ++g_draw_counter;
+  const uint32_t n = g_draw_counter;
+  if (d.blended && !d.depth_write) {
+    // particles, glass, decals, fog cards
+    return level >= 2 || (n & 1u) != 0;
+  }
+  // Opaque / depth-writing geometry: shed the small stuff first, then progressively bigger meshes.
+  const uint32_t idx = d.index_count;
+  switch (level) {
+    case 1:
+      return false;
+    case 2:
+      return idx <= 36;
+    case 3:
+      return idx <= 180 || (idx <= 720 && (n & 1u) != 0);
+    case 4:
+      return idx <= 720 || (idx <= 2400 && (n & 1u) != 0);
+    default:  // 5
+      return idx <= 2400 || (n % 3u) == 0;
+  }
+}
+
+bool ShouldSkipResolve(bool is_depth_source, bool clears_surface) {
+  if (!REXCVAR_GET(volyre_enable)) return false;
+  // A depth resolve without a clear only feeds shadow maps / soft-particle effects, which are
+  // already dropped at these levels.
+  return g_level.load(std::memory_order_relaxed) >= 3 && is_depth_source && !clears_surface;
+}
+
+}  // namespace rex::graphics::volyre
diff --git a/src/graphics/vulkan/command_processor.cpp b/src/graphics/vulkan/command_processor.cpp
index 3830bcd..1816917 100644
--- a/src/graphics/vulkan/command_processor.cpp
+++ b/src/graphics/vulkan/command_processor.cpp
@@ -34,6 +34,7 @@
 #include <rex/logging.h>
 #include <rex/math.h>
 #include <rex/graphics/util/draw.h>
+#include <rex/graphics/volyre.h>
 #include <rex/graphics/flags.h>
 #include <rex/graphics/pipeline/shader/shader.h>
 #include <rex/graphics/pipeline/shader/spirv_translator.h>
@@ -2288,6 +2289,7 @@ void VulkanCommandProcessor::OnGammaRampPWLValueWritten() {
 void VulkanCommandProcessor::IssueSwap(uint32_t frontbuffer_ptr, uint32_t frontbuffer_width,
                                        uint32_t frontbuffer_height) {
   SCOPE_profile_cpu_f("gpu");
+  volyre::OnFrameSwap();
   struct ScopedSwapCpuTimer {
     GpuTelemetryStats& stats;
     std::chrono::steady_clock::time_point start;
@@ -3925,6 +3927,27 @@ bool VulkanCommandProcessor::IssueDraw(xenos::PrimitiveType prim_type, uint32_t
   }
   reg::RB_DEPTHCONTROL normalized_depth_control = draw_util::GetNormalizedDepthControl(regs);
 
+  // Volyre adaptive load shedding: drop draws that cost GPU time but are not essential.
+  if (volyre::Level()) {
+    volyre::DrawInfo volyre_draw;
+    volyre_draw.index_count = index_count;
+    volyre_draw.is_rect_list = prim_type == xenos::PrimitiveType::kRectangleList;
+    volyre_draw.memexport = memexport_used_vertex || memexport_used_pixel;
+    volyre_draw.kcolor_depth_mode = edram_mode == xenos::EdramMode::kColorDepth;
+    volyre_draw.color_written =
+        pixel_shader && draw_util::GetNormalizedColorMask(regs, pixel_shader->writes_color_targets()) != 0;
+    volyre_draw.depth_test = normalized_depth_control.z_enable != 0;
+    volyre_draw.depth_write = normalized_depth_control.z_write_enable != 0;
+    auto volyre_blend = regs.Get<reg::RB_BLENDCONTROL>();
+    volyre_draw.blended = volyre_blend.color_srcblend != xenos::BlendFactor::kOne ||
+                          volyre_blend.color_destblend != xenos::BlendFactor::kZero ||
+                          volyre_blend.alpha_srcblend != xenos::BlendFactor::kOne ||
+                          volyre_blend.alpha_destblend != xenos::BlendFactor::kZero;
+    if (volyre::ShouldSkipDraw(volyre_draw)) {
+      return true;
+    }
+  }
+
   uint32_t ps_param_gen_pos = UINT32_MAX;
   uint32_t interpolator_mask =
       pixel_shader ? (vertex_shader->writes_interpolators() &
@@ -4659,6 +4682,15 @@ bool VulkanCommandProcessor::IssueCopy() {
   SCOPE_profile_cpu_f("gpu");
 #endif  // XE_GPU_FINE_GRAINED_DRAW_SCOPES
 
+  if (volyre::Level() >= 3) {
+    const auto volyre_copy_control = register_file_->Get<reg::RB_COPY_CONTROL>();
+    if (volyre::ShouldSkipResolve(volyre_copy_control.copy_src_select >= xenos::kMaxColorRenderTargets,
+                                  volyre_copy_control.color_clear_enable ||
+                                      volyre_copy_control.depth_clear_enable)) {
+      return true;
+    }
+  }
+
   ++telemetry_current_frame_.resolves;
   struct ScopedCopyCpuTimer {
     GpuTelemetryStats& stats;
diff --git a/src/graphics_plume/CMakeLists.txt b/src/graphics_plume/CMakeLists.txt
index f2788fc..5cbad29 100644
--- a/src/graphics_plume/CMakeLists.txt
+++ b/src/graphics_plume/CMakeLists.txt
@@ -7,6 +7,7 @@ set(REXGPU_PLUME_SOURCES
     plugin_main.cpp
     plume_graphics_system.cpp
     plume_command_processor.cpp
+  ../graphics/volyre.cpp
     plume_texture_cache.cpp
     plume_render_target_cache.cpp
     plume_texture_uploader.cpp
@@ -15,6 +16,7 @@ set(REXGPU_PLUME_SOURCES
     ${REXGLUE_ROOT}/src/graphics/pipeline/render_target/cache.cpp
     ${REXGLUE_ROOT}/src/graphics/pipeline/texture/util.cpp
     ${REXGLUE_ROOT}/src/graphics/command_processor.cpp
+  ../graphics/volyre.cpp
     ${REXGLUE_ROOT}/src/graphics/pm4_plume_transpiler.cpp
     ${REXGLUE_ROOT}/src/graphics/graphics_system.cpp
     ${REXGLUE_ROOT}/src/graphics/register_file.cpp
VOLYRE_P1_EOF
cat > "$P2" <<'VOLYRE_P2_EOF'
diff --git a/include/rex/graphics/volyre.h b/include/rex/graphics/volyre.h
index 188497d..f6200a4 100644
--- a/include/rex/graphics/volyre.h
+++ b/include/rex/graphics/volyre.h
@@ -19,8 +19,9 @@ uint32_t TextureRefreshFrames();  // 0 = never throttle texture re-uploads
 // Current load-shedding level, 0 (full quality) .. volyre_max_level (<= 5).
 uint32_t Level();
 
-// Called once per guest swap (frame boundary).
-void OnFrameSwap();
+// Called once per guest swap (frame boundary). fence_wait_ns = time this frame's command-processor
+// thread spent blocked on GPU fences (used to tell GPU-bound from CPU-bound frames).
+void OnFrameSwap(uint64_t fence_wait_ns);
 
 // Called for each frame the texture cache starts (counts re-uploads that were deferred).
 void NoteTextureRefreshDeferred();
diff --git a/src/graphics/volyre.cpp b/src/graphics/volyre.cpp
index 82dd7eb..a0309d0 100644
--- a/src/graphics/volyre.cpp
+++ b/src/graphics/volyre.cpp
@@ -1,16 +1,22 @@
 /**
- * Volyre AC Engine - adaptive performance governor (see include/rex/graphics/volyre.h).
+ * Volyre AC Engine v2 - adaptive performance governor (see include/rex/graphics/volyre.h).
  *
- * A level is raised while frames miss volyre_target_fps and lowered again after a few seconds of
- * meeting it (never below volyre_min_level / above volyre_max_level). Levels are cumulative:
- *   1  half of the blended, depth-tested, non-depth-writing draws (particles, glass, decals) dropped
+ * The governor only sheds work while the frame is GPU-bound (the command-processor thread spends a
+ * large part of the frame waiting on GPU fences). When the frame is CPU-bound, dropping draws does
+ * not help and only damages the picture, so the level is left alone / decays.
+ *
+ * Levels are cumulative:
+ *   1  half of the blended, depth-tested, non-depth-writing draws (particles, glass, decals)
  *   2  all of those, plus opaque draws with <= 36 indices (small props)
  *   3  depth-only draws (shadow maps, z pre-pass) and depth resolves; opaque <= 180 indices,
  *      <= 720 indices every other draw
- *   4  opaque <= 720 indices, <= 2400 indices every other draw
- *   5  opaque <= 2400 indices plus every third bigger draw
+ *   4  opaque <= 720 indices, <= 2400 indices every other draw          (opt-in: preset 3)
+ *   5  opaque <= 2400 indices plus every third bigger draw              (opt-in: preset 3)
  * Draws without depth test (HUD, menus, post-processing), memexport draws and rect lists (clears,
  * full-screen passes) are never dropped at any level.
+ *
+ * volyre_preset: 0 = use volyre_min_level / volyre_max_level, 1 = balanced (levels 0-2),
+ *                2 = performance (levels 0-3), 3 = extreme (levels 3-5, guest MSAA forced to 1x).
  */
 
 #include <rex/graphics/volyre.h>
@@ -23,16 +29,21 @@
 #include <rex/logging.h>
 
 REXCVAR_DEFINE_BOOL(volyre_enable, true, "Volyre", "Master switch for the Volyre performance engine");
-REXCVAR_DEFINE_BOOL(volyre_force_msaa_1x, true, "Volyre",
-                    "Ignore guest MSAA (render at 1x): removes the 2x/4x render target cost");
-REXCVAR_DEFINE_INT32(volyre_texture_refresh_frames, 4, "Volyre",
+REXCVAR_DEFINE_BOOL(volyre_force_msaa_1x, false, "Volyre",
+                    "Ignore guest MSAA (render at 1x). Cheaper, but can leave stripes on games that "
+                    "tile their EDRAM use around MSAA; preset 3 turns it on");
+REXCVAR_DEFINE_INT32(volyre_preset, 2, "Volyre",
+                     "0 custom (min/max level cvars), 1 balanced, 2 performance, 3 extreme");
+REXCVAR_DEFINE_INT32(volyre_texture_refresh_frames, 2, "Volyre",
                      "A texture whose guest memory was rewritten by the CPU is re-uploaded at most "
                      "once per this many frames (0 = always)");
+REXCVAR_DEFINE_BOOL(volyre_gpu_bound_only, true, "Volyre",
+                    "Shed work only while the frame is GPU-bound (recommended)");
 REXCVAR_DEFINE_BOOL(volyre_adaptive, true, "Volyre",
                     "Raise the load-shedding level automatically while the frame rate is below target");
 REXCVAR_DEFINE_INT32(volyre_target_fps, 60, "Volyre", "Frame rate the governor tries to hold");
 REXCVAR_DEFINE_INT32(volyre_min_level, 0, "Volyre", "Lowest load-shedding level (0-5)");
-REXCVAR_DEFINE_INT32(volyre_max_level, 5, "Volyre", "Highest load-shedding level (0-5)");
+REXCVAR_DEFINE_INT32(volyre_max_level, 3, "Volyre", "Highest load-shedding level (0-5)");
 
 namespace rex::graphics::volyre {
 namespace {
@@ -55,23 +66,36 @@ struct GovernorState {
   uint64_t frame = 0;
   int64_t window_start_ns = 0;
   uint32_t window_frames = 0;
+  double gpu_wait_frac = 0.0;  // smoothed fence-wait share of the frame
 };
 GovernorState g_state;
 uint32_t g_draw_counter = 0;
 
 uint32_t ClampLevel(int32_t v) { return uint32_t(std::clamp(v, 0, 5)); }
 
+void GetLevelRange(uint32_t& min_level, uint32_t& max_level) {
+  switch (REXCVAR_GET(volyre_preset)) {
+    case 1: min_level = 0; max_level = 2; break;
+    case 2: min_level = 0; max_level = 3; break;
+    case 3: min_level = 3; max_level = 5; break;
+    default:
+      min_level = ClampLevel(REXCVAR_GET(volyre_min_level));
+      max_level = std::max(min_level, ClampLevel(REXCVAR_GET(volyre_max_level)));
+      break;
+  }
+}
+
 }  // namespace
 
 bool Enabled() { return REXCVAR_GET(volyre_enable); }
-bool ForceMsaa1x() { return REXCVAR_GET(volyre_enable) && REXCVAR_GET(volyre_force_msaa_1x); }
+bool ForceMsaa1x() {
+  return REXCVAR_GET(volyre_enable) &&
+         (REXCVAR_GET(volyre_force_msaa_1x) || REXCVAR_GET(volyre_preset) == 3);
+}
 
 uint32_t TextureRefreshFrames() {
   if (!REXCVAR_GET(volyre_enable)) return 0;
-  uint32_t base = uint32_t(std::max(0, REXCVAR_GET(volyre_texture_refresh_frames)));
-  if (!base) return 0;
-  // Under load, refresh textures less often.
-  return base * (1u + std::min<uint32_t>(g_level.load(std::memory_order_relaxed), 3u));
+  return uint32_t(std::max(0, REXCVAR_GET(volyre_texture_refresh_frames)));
 }
 
 uint32_t Level() { return g_level.load(std::memory_order_relaxed); }
@@ -79,7 +103,7 @@ uint32_t Level() { return g_level.load(std::memory_order_relaxed); }
 void NoteTextureRefreshDeferred() { g_deferred_refresh.fetch_add(1, std::memory_order_relaxed); }
 void NoteTextureRefreshDone() { g_done_refresh.fetch_add(1, std::memory_order_relaxed); }
 
-void OnFrameSwap() {
+void OnFrameSwap(uint64_t fence_wait_ns) {
   if (!REXCVAR_GET(volyre_enable)) {
     g_level.store(0, std::memory_order_relaxed);
     return;
@@ -87,8 +111,8 @@ void OnFrameSwap() {
   GovernorState& s = g_state;
   const int64_t now = NowNs();
   ++s.frame;
-  const uint32_t min_level = ClampLevel(REXCVAR_GET(volyre_min_level));
-  const uint32_t max_level = std::max(min_level, ClampLevel(REXCVAR_GET(volyre_max_level)));
+  uint32_t min_level, max_level;
+  GetLevelRange(min_level, max_level);
   uint32_t level = g_level.load(std::memory_order_relaxed);
   level = std::clamp(level, min_level, max_level);
 
@@ -97,7 +121,13 @@ void OnFrameSwap() {
     const int32_t fps = std::clamp(REXCVAR_GET(volyre_target_fps), 20, 120);
     const int64_t target = 1000000000ll / fps;
     ++s.frames_since_change;
-    if (period > target + target / 8 && period < 1500000000ll) {
+    if (period > 0 && period < 1500000000ll) {
+      const double frac = std::min(1.0, double(fence_wait_ns) / double(period));
+      s.gpu_wait_frac += (frac - s.gpu_wait_frac) * 0.15;
+    }
+    const bool gpu_bound = !REXCVAR_GET(volyre_gpu_bound_only) || s.gpu_wait_frac > 0.20;
+    const bool missed = period > target + target / 8 && period < 1500000000ll;
+    if (missed && gpu_bound) {
       ++s.miss_run;
       s.ok_run = 0;
       if (s.miss_run >= 3 && s.frames_since_change >= 4 && level < max_level) {
@@ -105,10 +135,11 @@ void OnFrameSwap() {
         s.frames_since_change = 0;
         s.miss_run = 0;
       }
-    } else if (period <= target + target / 8) {
+    } else {
+      // Meeting the target, or missing it for a reason shedding cannot fix (CPU-bound).
       s.miss_run = 0;
       ++s.ok_run;
-      if (s.ok_run >= 240 && level > min_level) {
+      if (s.ok_run >= 180 && level > min_level) {
         --level;
         s.ok_run = 0;
         s.frames_since_change = 0;
@@ -118,7 +149,7 @@ void OnFrameSwap() {
   s.last_swap_ns = now;
 
   if (level != g_level.load(std::memory_order_relaxed)) {
-    REXGPU_INFO("Volyre: load level -> {}", level);
+    REXGPU_INFO("Volyre: load level -> {} (gpu wait {:.0f}%)", level, s.gpu_wait_frac * 100.0);
   }
   g_level.store(level, std::memory_order_relaxed);
 
@@ -128,8 +159,9 @@ void OnFrameSwap() {
   if (now - s.window_start_ns >= 5000000000ll) {
     const double secs = double(now - s.window_start_ns) / 1e9;
     REXGPU_INFO(
-        "Volyre[5s]: {:.1f} fps, level {}, texture refresh done/deferred {}/{}",
-        double(s.window_frames) / secs, level, g_done_refresh.exchange(0), g_deferred_refresh.exchange(0));
+        "Volyre[5s]: {:.1f} fps, level {}, gpu wait {:.0f}%, texture refresh done/deferred {}/{}",
+        double(s.window_frames) / secs, level, s.gpu_wait_frac * 100.0, g_done_refresh.exchange(0),
+        g_deferred_refresh.exchange(0));
     s.window_start_ns = now;
     s.window_frames = 0;
   }
diff --git a/src/graphics/vulkan/command_processor.cpp b/src/graphics/vulkan/command_processor.cpp
index 1816917..a31c7b0 100644
--- a/src/graphics/vulkan/command_processor.cpp
+++ b/src/graphics/vulkan/command_processor.cpp
@@ -2289,7 +2289,7 @@ void VulkanCommandProcessor::OnGammaRampPWLValueWritten() {
 void VulkanCommandProcessor::IssueSwap(uint32_t frontbuffer_ptr, uint32_t frontbuffer_width,
                                        uint32_t frontbuffer_height) {
   SCOPE_profile_cpu_f("gpu");
-  volyre::OnFrameSwap();
+  volyre::OnFrameSwap(telemetry_current_frame_.fence_wait_ns);
   struct ScopedSwapCpuTimer {
     GpuTelemetryStats& stats;
     std::chrono::steady_clock::time_point start;
VOLYRE_P2_EOF

apply_patch() {
  if git rev-parse --git-dir >/dev/null 2>&1 && git apply --check "$1" 2>/dev/null; then git apply "$1"
  elif patch -p1 --dry-run < "$1" >/dev/null 2>&1; then patch -p1 < "$1" >/dev/null
  else echo "[volyre] patch does not apply to this SDK version: $2"; exit 1; fi
}

if [ -f src/graphics/vulkan/command_processor.cpp ] && [ -f include/rex/graphics/xenos.h ]; then
  echo "[volyre] SDK repo detected"
  if [ ! -f include/rex/graphics/volyre.h ]; then
    apply_patch "$P1" "v1"; echo "[volyre] applied v1 (governor, MSAA hook, texture throttle, Plume fix)"
  fi
  if grep -q volyre_preset src/graphics/volyre.cpp; then
    echo "[volyre] v2 already present, nothing to do"; exit 0
  fi
  apply_patch "$P2" "v2"; echo "[volyre] applied v2 (GPU-bound-only governor, presets, safer defaults)"
  echo "[volyre] SDK patched. Commit + push, run the SDK 'Build Android ARM64' workflow, then rebuild the game."
  exit 0
fi

[ -f ac2mobile_manifest.toml ] || { echo "Run from the SDK repo root or the game repo root"; exit 1; }
echo "[volyre] game repo detected"
J=android/app/src/main/java/com/ac2/recomp
for f in $J/GameSettings.java AC2Recomp.ini; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
BK=.volyre_bak_$(date +%Y%m%d_%H%M%S); mkdir -p "$BK/$J"
cp $J/GameSettings.java "$BK/$J/"; cp AC2Recomp.ini "$BK/"
mkdir -p patches
# keep the SDK patch for the CI "source" SDK mode (v1 then v2; the names sort in that order)
cp "$P1" patches/rexglue-sdk-volyre.patch
cp "$P2" patches/rexglue-sdk-volyre.v2.patch

python3 - "$J/GameSettings.java" AC2Recomp.ini <<'PY'
import re, sys
gs, ini = sys.argv[1], sys.argv[2]
s = open(gs, encoding='utf-8').read()

# 60 fps cap
if 'append(60)  // Volyre' not in s:
    old = '.append("\\nac2_fps_limit = ").append(fpsLimit)'
    if s.count(old) == 1:
        s = s.replace(old, '.append("\\nac2_fps_limit = ").append(60)  // Volyre: 60 fps target')

VALUES = [("volyre_enable", "true"), ("volyre_preset", "2"), ("volyre_force_msaa_1x", "false"),
          ("volyre_texture_refresh_frames", "2"), ("volyre_adaptive", "true"),
          ("volyre_gpu_bound_only", "true"), ("volyre_target_fps", "60"),
          ("volyre_min_level", "0"), ("volyre_max_level", "3")]
block = '        putDefault(sb, "native_2x_msaa", "true");  // real 2x MSAA unless the extreme preset forces 1x\n' + \
        ''.join('        putDefault(sb, "%s", "%s");\n' % kv for kv in VALUES)

# remove every earlier Volyre / native_2x_msaa putDefault line, then insert the fresh block once
lines = s.split('\n')
out, idx = [], None
for ln in lines:
    if re.search(r'putDefault\(sb, "(volyre_[a-z0-9_]+|native_2x_msaa)"', ln):
        if idx is None: idx = len(out)
        continue
    out.append(ln)
if idx is None:
    anchor = [i for i, l in enumerate(out) if 'vulkan_submit_on_primary_buffer_end' in l and 'putDefault' in l]
    assert anchor, "anchor for settings block not found"
    idx = anchor[0] + 1
out[idx:idx] = block.rstrip('\n').split('\n')
open(gs, 'w', encoding='utf-8').write('\n'.join(out))

# ini template
t = open(ini, encoding='utf-8').read()
t = re.sub(r'(?m)^ac2_fps_limit\s*=.*$', 'ac2_fps_limit = 60', t)
t = re.sub(r'(?m)^native_2x_msaa\s*=.*$', 'native_2x_msaa = true', t)
t = re.sub(r'(?m)^(volyre_[a-z0-9_]+)\s*=.*\n?', '', t)
t = re.sub(r'(?m)^\[Volyre\]\s*\n?', '', t)
t = t.rstrip('\n') + '\n\n[Volyre]\n' + ''.join('%s = %s\n' % kv for kv in VALUES)
open(ini, 'w', encoding='utf-8').write(t)
PY
echo "[volyre] game updated (backup in $BK). Settings: preset 2, MSAA not forced, texture throttle 2, 60 fps cap."
echo "[volyre] Next: build the SDK repo, then build the game with sdk_url set to the new SDK release asset."
