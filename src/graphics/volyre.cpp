/**
 * Volyre AC Engine - adaptive performance governor (see include/rex/graphics/volyre.h).
 *
 * A level is raised while frames miss volyre_target_fps and lowered again after a few seconds of
 * meeting it (never below volyre_min_level / above volyre_max_level). Levels are cumulative:
 *   1  half of the blended, depth-tested, non-depth-writing draws (particles, glass, decals) dropped
 *   2  all of those, plus opaque draws with <= 36 indices (small props)
 *   3  depth-only draws (shadow maps, z pre-pass) and depth resolves; opaque <= 180 indices,
 *      <= 720 indices every other draw
 *   4  opaque <= 720 indices, <= 2400 indices every other draw
 *   5  opaque <= 2400 indices plus every third bigger draw
 * Draws without depth test (HUD, menus, post-processing), memexport draws and rect lists (clears,
 * full-screen passes) are never dropped at any level.
 */

#include <rex/graphics/volyre.h>

#include <algorithm>
#include <atomic>
#include <chrono>

#include <rex/cvar.h>
#include <rex/logging.h>

REXCVAR_DEFINE_BOOL(volyre_enable, true, "Volyre", "Master switch for the Volyre performance engine");
REXCVAR_DEFINE_BOOL(volyre_force_msaa_1x, true, "Volyre",
                    "Ignore guest MSAA (render at 1x): removes the 2x/4x render target cost");
REXCVAR_DEFINE_INT32(volyre_texture_refresh_frames, 4, "Volyre",
                     "A texture whose guest memory was rewritten by the CPU is re-uploaded at most "
                     "once per this many frames (0 = always)");
REXCVAR_DEFINE_BOOL(volyre_adaptive, true, "Volyre",
                    "Raise the load-shedding level automatically while the frame rate is below target");
REXCVAR_DEFINE_INT32(volyre_target_fps, 60, "Volyre", "Frame rate the governor tries to hold");
REXCVAR_DEFINE_INT32(volyre_min_level, 0, "Volyre", "Lowest load-shedding level (0-5)");
REXCVAR_DEFINE_INT32(volyre_max_level, 5, "Volyre", "Highest load-shedding level (0-5)");

namespace rex::graphics::volyre {
namespace {

std::atomic<uint32_t> g_level{0};
std::atomic<uint32_t> g_deferred_refresh{0};
std::atomic<uint32_t> g_done_refresh{0};

int64_t NowNs() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

struct GovernorState {
  int64_t last_swap_ns = 0;
  uint32_t miss_run = 0;
  uint32_t ok_run = 0;
  uint32_t frames_since_change = 0;
  uint64_t frame = 0;
  int64_t window_start_ns = 0;
  uint32_t window_frames = 0;
};
GovernorState g_state;
uint32_t g_draw_counter = 0;

uint32_t ClampLevel(int32_t v) { return uint32_t(std::clamp(v, 0, 5)); }

}  // namespace

bool Enabled() { return REXCVAR_GET(volyre_enable); }
bool ForceMsaa1x() { return REXCVAR_GET(volyre_enable) && REXCVAR_GET(volyre_force_msaa_1x); }

uint32_t TextureRefreshFrames() {
  if (!REXCVAR_GET(volyre_enable)) return 0;
  uint32_t base = uint32_t(std::max(0, REXCVAR_GET(volyre_texture_refresh_frames)));
  if (!base) return 0;
  // Under load, refresh textures less often.
  return base * (1u + std::min<uint32_t>(g_level.load(std::memory_order_relaxed), 3u));
}

uint32_t Level() { return g_level.load(std::memory_order_relaxed); }

void NoteTextureRefreshDeferred() { g_deferred_refresh.fetch_add(1, std::memory_order_relaxed); }
void NoteTextureRefreshDone() { g_done_refresh.fetch_add(1, std::memory_order_relaxed); }

void OnFrameSwap() {
  if (!REXCVAR_GET(volyre_enable)) {
    g_level.store(0, std::memory_order_relaxed);
    return;
  }
  GovernorState& s = g_state;
  const int64_t now = NowNs();
  ++s.frame;
  const uint32_t min_level = ClampLevel(REXCVAR_GET(volyre_min_level));
  const uint32_t max_level = std::max(min_level, ClampLevel(REXCVAR_GET(volyre_max_level)));
  uint32_t level = g_level.load(std::memory_order_relaxed);
  level = std::clamp(level, min_level, max_level);

  if (s.last_swap_ns && REXCVAR_GET(volyre_adaptive)) {
    const int64_t period = now - s.last_swap_ns;
    const int32_t fps = std::clamp(REXCVAR_GET(volyre_target_fps), 20, 120);
    const int64_t target = 1000000000ll / fps;
    ++s.frames_since_change;
    if (period > target + target / 8 && period < 1500000000ll) {
      ++s.miss_run;
      s.ok_run = 0;
      if (s.miss_run >= 3 && s.frames_since_change >= 4 && level < max_level) {
        ++level;
        s.frames_since_change = 0;
        s.miss_run = 0;
      }
    } else if (period <= target + target / 8) {
      s.miss_run = 0;
      ++s.ok_run;
      if (s.ok_run >= 240 && level > min_level) {
        --level;
        s.ok_run = 0;
        s.frames_since_change = 0;
      }
    }
  }
  s.last_swap_ns = now;

  if (level != g_level.load(std::memory_order_relaxed)) {
    REXGPU_INFO("Volyre: load level -> {}", level);
  }
  g_level.store(level, std::memory_order_relaxed);

  // One summary line every ~5 s.
  ++s.window_frames;
  if (!s.window_start_ns) s.window_start_ns = now;
  if (now - s.window_start_ns >= 5000000000ll) {
    const double secs = double(now - s.window_start_ns) / 1e9;
    REXGPU_INFO(
        "Volyre[5s]: {:.1f} fps, level {}, texture refresh done/deferred {}/{}",
        double(s.window_frames) / secs, level, g_done_refresh.exchange(0), g_deferred_refresh.exchange(0));
    s.window_start_ns = now;
    s.window_frames = 0;
  }
}

bool ShouldSkipDraw(const DrawInfo& d) {
  const uint32_t level = g_level.load(std::memory_order_relaxed);
  if (!level || !REXCVAR_GET(volyre_enable)) return false;
  if (d.memexport || d.is_rect_list || !d.kcolor_depth_mode) return false;

  // Depth-only draws (shadow maps / z pre-pass).
  if (!d.color_written) {
    return level >= 3 && (d.depth_write || d.depth_test);
  }
  // Draws that write color: anything without depth test is HUD / menus / post-processing.
  if (!d.depth_test) return false;

  ++g_draw_counter;
  const uint32_t n = g_draw_counter;
  if (d.blended && !d.depth_write) {
    // particles, glass, decals, fog cards
    return level >= 2 || (n & 1u) != 0;
  }
  // Opaque / depth-writing geometry: shed the small stuff first, then progressively bigger meshes.
  const uint32_t idx = d.index_count;
  switch (level) {
    case 1:
      return false;
    case 2:
      return idx <= 36;
    case 3:
      return idx <= 180 || (idx <= 720 && (n & 1u) != 0);
    case 4:
      return idx <= 720 || (idx <= 2400 && (n & 1u) != 0);
    default:  // 5
      return idx <= 2400 || (n % 3u) == 0;
  }
}

bool ShouldSkipResolve(bool is_depth_source, bool clears_surface) {
  if (!REXCVAR_GET(volyre_enable)) return false;
  // A depth resolve without a clear only feeds shadow maps / soft-particle effects, which are
  // already dropped at these levels.
  return g_level.load(std::memory_order_relaxed) >= 3 && is_depth_source && !clears_surface;
}

}  // namespace rex::graphics::volyre
