/**
 * Volyre AC Engine - adaptive performance governor for the Xenos GPU backend.
 *
 * Everything here is optional and driven by cvars (all named volyre_*). The governor runs on the
 * GPU command-processor thread: OnFrameSwap() is called once per guest swap, ShouldSkipDraw() once
 * per draw.
 */
#pragma once

#include <cstdint>

namespace rex::graphics::volyre {

// Cached cvar reads (cheap enough for the register-write hot path).
bool Enabled();
bool ForceMsaa1x();
uint32_t TextureRefreshFrames();  // 0 = never throttle texture re-uploads

// Current load-shedding level, 0 (full quality) .. volyre_max_level (<= 5).
uint32_t Level();

// Called once per guest swap (frame boundary). fence_wait_ns = time this frame's command-processor
// thread spent blocked on GPU fences (used to tell GPU-bound from CPU-bound frames).
void OnFrameSwap(uint64_t fence_wait_ns);

// Called for each frame the texture cache starts (counts re-uploads that were deferred).
void NoteTextureRefreshDeferred();
void NoteTextureRefreshDone();

// PERF profiling (texture hash cost); TakeProfile() returns and resets the counters.
void NoteHash(uint64_t ns, uint64_t bytes);
void TakeProfile(uint64_t& hash_ns, uint64_t& hash_bytes, uint64_t& hash_calls, uint64_t& uploads,
                 uint64_t& deferred);

struct DrawInfo {
  uint32_t index_count = 0;
  bool is_rect_list = false;   // clears / resolves / full-screen passes are drawn as rect lists
  bool memexport = false;      // vertex/pixel shader writes guest memory: never skip
  bool color_written = false;  // any color render target is written
  bool depth_test = false;
  bool depth_write = false;
  bool blended = false;        // render target 0 blends with the destination
  bool kcolor_depth_mode = false;
};

// true = drop this draw (do not record it).
bool ShouldSkipDraw(const DrawInfo& d);

// true = skip this EDRAM resolve (only ever a depth resolve that does not clear the surface).
bool ShouldSkipResolve(bool is_depth_source, bool clears_surface);

}  // namespace rex::graphics::volyre
