/**
 * Volyre AC Engine v2 - adaptive performance governor (see include/rex/graphics/volyre.h).
 *
 * The governor only sheds work while the frame is GPU-bound (the command-processor thread spends a
 * large part of the frame waiting on GPU fences). When the frame is CPU-bound, dropping draws does
 * not help and only damages the picture, so the level is left alone / decays.
 *
 * Levels are cumulative:
 *   1  half of the blended, depth-tested, non-depth-writing draws (particles, glass, decals)
 *   2  all of those, plus opaque draws with <= 36 indices (small props)
 *   3  depth-only draws (shadow maps, z pre-pass) and depth resolves; opaque <= 180 indices,
 *      <= 720 indices every other draw
 *   4  opaque <= 720 indices, <= 2400 indices every other draw          (opt-in: preset 3)
 *   5  opaque <= 2400 indices plus every third bigger draw              (opt-in: preset 3)
 * Draws without depth test (HUD, menus, post-processing), memexport draws and rect lists (clears,
 * full-screen passes) are never dropped at any level.
 *
 * volyre_preset: 0 = use volyre_min_level / volyre_max_level, 1 = balanced (levels 0-2),
 *                2 = performance (levels 0-3), 3 = extreme (levels 3-5, guest MSAA forced to 1x).
 */

#include <rex/graphics/volyre.h>

#include <algorithm>
#include <atomic>
#include <chrono>

#include <rex/cvar.h>
#include <rex/logging.h>

REXCVAR_DEFINE_BOOL(volyre_enable, false, "Volyre",
                    "Master switch for the Volyre load shedding (VOLYRE_V3: off, it drops geometry)");
REXCVAR_DEFINE_BOOL(volyre_force_msaa_1x, false, "Volyre",
                    "Ignore guest MSAA (render at 1x). Cheaper, but can leave stripes on games that "
                    "tile their EDRAM use around MSAA; preset 3 turns it on");
REXCVAR_DEFINE_INT32(volyre_preset, 2, "Volyre",
                     "0 custom (min/max level cvars), 1 balanced, 2 performance, 3 extreme");
REXCVAR_DEFINE_INT32(volyre_texture_refresh_frames, 2, "Volyre",
                     "A texture whose guest memory was rewritten by the CPU is re-uploaded at most "
                     "once per this many frames (0 = always)");
REXCVAR_DEFINE_BOOL(volyre_gpu_bound_only, true, "Volyre",
                    "Shed work only while the frame is GPU-bound (recommended)");
REXCVAR_DEFINE_BOOL(volyre_adaptive, true, "Volyre",
                    "Raise the load-shedding level automatically while the frame rate is below target");
REXCVAR_DEFINE_INT32(volyre_target_fps, 60, "Volyre", "Frame rate the governor tries to hold");
REXCVAR_DEFINE_INT32(volyre_min_level, 0, "Volyre", "Lowest load-shedding level (0-5)");
REXCVAR_DEFINE_INT32(volyre_max_level, 3, "Volyre", "Highest load-shedding level (0-5)");

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
  double gpu_wait_frac = 0.0;  // smoothed fence-wait share of the frame
};
GovernorState g_state;
uint32_t g_draw_counter = 0;

uint32_t ClampLevel(int32_t v) { return uint32_t(std::clamp(v, 0, 5)); }

void GetLevelRange(uint32_t& min_level, uint32_t& max_level) {
  switch (REXCVAR_GET(volyre_preset)) {
    case 1: min_level = 0; max_level = 2; break;
    case 2: min_level = 0; max_level = 3; break;
    case 3: min_level = 3; max_level = 5; break;
    default:
      min_level = ClampLevel(REXCVAR_GET(volyre_min_level));
      max_level = std::max(min_level, ClampLevel(REXCVAR_GET(volyre_max_level)));
      break;
  }
}

}  // namespace

bool Enabled() { return REXCVAR_GET(volyre_enable); }
bool ForceMsaa1x() {
  return REXCVAR_GET(volyre_enable) &&
         (REXCVAR_GET(volyre_force_msaa_1x) || REXCVAR_GET(volyre_preset) == 3);
}

uint32_t TextureRefreshFrames() {
  if (!REXCVAR_GET(volyre_enable)) return 0;
  return uint32_t(std::max(0, REXCVAR_GET(volyre_texture_refresh_frames)));
}

uint32_t Level() { return g_level.load(std::memory_order_relaxed); }

void NoteTextureRefreshDeferred() { g_deferred_refresh.fetch_add(1, std::memory_order_relaxed); }
void NoteTextureRefreshDone() { g_done_refresh.fetch_add(1, std::memory_order_relaxed); }

void OnFrameSwap(uint64_t fence_wait_ns) {
  if (!REXCVAR_GET(volyre_enable)) {
    g_level.store(0, std::memory_order_relaxed);
    return;
  }
  GovernorState& s = g_state;
  const int64_t now = NowNs();
  ++s.frame;
  uint32_t min_level, max_level;
  GetLevelRange(min_level, max_level);
  uint32_t level = g_level.load(std::memory_order_relaxed);
  level = std::clamp(level, min_level, max_level);

  if (s.last_swap_ns && REXCVAR_GET(volyre_adaptive)) {
    const int64_t period = now - s.last_swap_ns;
    const int32_t fps = std::clamp(REXCVAR_GET(volyre_target_fps), 20, 120);
    const int64_t target = 1000000000ll / fps;
    ++s.frames_since_change;
    if (period > 0 && period < 1500000000ll) {
      const double frac = std::min(1.0, double(fence_wait_ns) / double(period));
      s.gpu_wait_frac += (frac - s.gpu_wait_frac) * 0.15;
    }
    const bool gpu_bound = !REXCVAR_GET(volyre_gpu_bound_only) || s.gpu_wait_frac > 0.20;
    const bool missed = period > target + target / 8 && period < 1500000000ll;
    if (missed && gpu_bound) {
      ++s.miss_run;
      s.ok_run = 0;
      if (s.miss_run >= 3 && s.frames_since_change >= 4 && level < max_level) {
        ++level;
        s.frames_since_change = 0;
        s.miss_run = 0;
      }
    } else {
      // Meeting the target, or missing it for a reason shedding cannot fix (CPU-bound).
      s.miss_run = 0;
      ++s.ok_run;
      if (s.ok_run >= 180 && level > min_level) {
        --level;
        s.ok_run = 0;
        s.frames_since_change = 0;
      }
    }
  }
  s.last_swap_ns = now;

  if (level != g_level.load(std::memory_order_relaxed)) {
    REXGPU_INFO("Volyre: load level -> {} (gpu wait {:.0f}%)", level, s.gpu_wait_frac * 100.0);
  }
  g_level.store(level, std::memory_order_relaxed);

  // One summary line every ~5 s.
  ++s.window_frames;
  if (!s.window_start_ns) s.window_start_ns = now;
  if (now - s.window_start_ns >= 5000000000ll) {
    const double secs = double(now - s.window_start_ns) / 1e9;
    REXGPU_INFO(
        "Volyre[5s]: {:.1f} fps, level {}, gpu wait {:.0f}%, texture refresh done/deferred {}/{}",
        double(s.window_frames) / secs, level, s.gpu_wait_frac * 100.0, g_done_refresh.exchange(0),
        g_deferred_refresh.exchange(0));
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
