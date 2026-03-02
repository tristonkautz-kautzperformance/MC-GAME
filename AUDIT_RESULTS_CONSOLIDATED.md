# Consolidated Performance Audit Results

**Project:** LOVR Voxel Clone (MC Clone)  
**Audits Conducted:** February 9-23, 2026  
**Consolidated By:** OpenAI Codex 5.3

---

## Executive Summary

This document consolidates three performance audits conducted over a two-week period during active development. The audits tracked the evolution of a Minecraft-style voxel engine from initial implementation through survival-feature completion.

| Audit | Date | Scope | Status |
|-------|------|-------|--------|
| Audit #1 | Feb 9, 2026 (updated Feb 14) | Core loop, meshing, chunk keys | ✅ Mostly Resolved |
| Audit #2 | Feb 14, 2026 | Project-wide correctness & GC | ✅ All Items Resolved |
| Audit #3 | Feb 23, 2026 | Read-only performance analysis | 📋 Recommendations Pending |

---

## Audit #1: Core Loop & Threaded Meshing (Feb 9-14)

### Critical Findings (Initially)

#### 1. Meshing GC Pressure
- **Issue:** Heavy per-rebuild allocations (vertex/index buffers, greedy mask/scratch)
- **Location:** `src/render/ChunkRenderer.lua:500,563`, `src/render/mesher_thread.lua`
- **Impact:** Worker-side GC and result-application cost could hitch under high rebuild throughput

#### 2. Alpha Sorting Scaling
- **Issue:** Alpha chunk sorting is O(n log n) in visible alpha chunks
- **Location:** `src/render/ChunkRenderer.lua:1749`
- **Impact:** Potential issues if leaf-heavy scenes grow significantly

#### 3. Stale Mesh Risk
- **Issue:** Non-edit block changes without proper dirtying could create stale meshes
- **Mitigation:** Current system correctly dirties via `ChunkWorld:set()` and `_markNeighborsIfBoundary`

### Resolved Issues (By Feb 14)

| Issue | Solution | Commit |
|-------|----------|--------|
| Git initialization | New repo initialized, old preserved as backup | `f7c90d3` |
| O(1) terrain generation | `ChunkWorld:generate()` no longer allocates per-voxel | `d1e46a2` |
| AIR storage bloat | Writing AIR clears chunk slots (sparse storage) | `9552327` |
| Per-frame dirty-key allocations | Added `drainDirtyChunkKeys()` with fast path | `2f7de7e` |
| String chunk keys | Unified to numeric keys end-to-end | `2f7de7e` |
| Renderer double-iteration | Single visibility pass, alpha back-to-front | `9552327` |
| Vector crash risk | Persistent `lovr.math.newVec3` cached | `9552327` |
| HUD GC | Scratch vectors/buffers, fixed-interval rebuild | `9552327` |
| Inventory-full break | Block no longer removes if inventory full | `9552327` |
| Streaming spikes | Ring-delta streaming with ms budget | `03639d5` |
| Threaded meshing | Worker thread with blob packing, versioning, fallback | `4cf6066` |

### Recommendations (Carried Forward)
1. Keep threaded meshing on "blob path" for low-GC transfers
2. Optimize alpha sorting only if it appears in profiling
3. Add assertions for chunk-key type validation (guard against string key regressions)

---

## Audit #2: Project-Wide Correctness & GC (Feb 14)

### High-Priority Findings

#### 1. Per-Frame Camera Allocations ⚠️ RESOLVED
- **Issue:** `GameState:draw` created temporary vec3 each frame via `lovr.math.vec3()`
- **Risk:** Reintroduces "temporary vector from previous frame" crashes
- **Location:** `src/game/GameState.lua:702`
- **Resolution:** Use persistent camera position vec3 with `:set()` each frame
- **Status:** ✅ Fixed Feb 14

#### 2. Player Quaternion Allocations ⚠️ RESOLVED
- **Issue:** `Player:getCameraOrientation()` allocated new quats every call
- **Impact:** GC spikes during heavy meshing/rebuild periods
- **Location:** `src/player.lua:57`
- **Resolution:** Reuse cached quaternions with in-place `:set()` + `:mul()`
- **Status:** ✅ Fixed Feb 14

#### 3. Fullscreen Persistence Robustness ⚠️ RESOLVED
- **Issue:** `.fullscreen` file assumes writable project root; fails if CWD differs or directory read-only
- **Also:** Not in `.gitignore`, creates untracked noise
- **Location:** `conf.lua:4`, `src/game/GameState.lua:20,31`
- **Resolution:** Added to `.gitignore`; treated as local-dev artifact
- **Status:** ✅ Fixed Feb 14

#### 4. Documentation Mismatch ⚠️ RESOLVED
- **Issue:** `AGENTS.md` said "Esc quits if unlocked" but actual behavior opens pause menu
- **Location:** `AGENTS.md:25` vs `README.md:42`
- **Resolution:** Updated `AGENTS.md` to match runtime behavior
- **Status:** ✅ Fixed Feb 14

#### 5. Third-Party License Compliance ⚠️ RESOLVED
- **Issue:** `lovr-mouse.lua` vendored without license/attribution in-repo
- **Resolution:** Added `THIRD_PARTY_NOTICES.md` with upstream URL, commit, and MIT license text
- **Status:** ✅ Fixed Feb 14

#### 6. Save/Load Scaling for Large Edits ⚠️ RESOLVED
- **Issue:** O(edits) with overhead from repeated dirty marking; inflates dirty queue before first frame
- **Location:** `src/save/SaveSystem.lua:656`
- **Resolution:** Added `ChunkWorld:applyEditsBulk()` for direct `_editChunks` writes; batched dirty marking
- **Status:** ✅ Fixed Feb 14

### Lower Priority / Cleanup

| Issue | Severity | Recommendation |
|-------|----------|----------------|
| Filename mismatch (world_v1.txt vs V2 magic) | Low | Rename or document for debugging clarity |
| Dead code: `src/world/Chunk.lua` unused | Low | Remove or wire up |
| Dead code: `Input.wantQuit` never set | Low | Remove or implement quit flow |
| Repo hygiene: nested `.git` folders | Low | Clean up when convenient |

### Follow-Up Verification (Feb 14)
All high-priority items verified implemented:
- ✅ Camera/view allocations eliminated
- ✅ Player quaternion reuse implemented
- ✅ `.fullscreen` gitignored
- ✅ Documentation synchronized
- ✅ Third-party compliance added
- ✅ Bulk edit apply implemented

---

## Audit #3: Read-Only Performance Analysis (Feb 23)

### High-Impact Findings (Active Recommendations)

#### 1. Main-Thread Meshing Prep Overhead 🔴
- **Issue:** Heavy prep on main thread before worker dispatch
- **Costs:** Chunk prep, light ensure, halo fill/pack
- **Locations:** 
  - `src/render/ChunkRenderer.lua:843` (dispatch)
  - `src/render/ChunkRenderer.lua:885,894,902` (prep steps)
- **Impact:** Chunk movement/edit bursts spike frametime despite worker threads
- **Recommendation:** Consider moving more prep off-thread or optimizing halo pack path

#### 2. Dirty-Queue Churn Under Budget Pressure 🔴
- **Issue:** Pop/defer/requeue cycles continue after prep caps hit
- **Locations:**
  - `src/render/ChunkRenderer.lua:2160`
  - `src/render/ChunkRenderer.lua:2204`
  - `src/render/ChunkRenderer.lua:2240`
- **Impact:** CPU cycles spent without visible progress
- **Recommendation:** Stop queue iteration once budget is saturated

#### 3. Expensive Geometry Generation/Upload 🔴
- **Issues:**
  - Lua table-per-vertex writes (`src/render/ChunkRenderer.lua:17`)
  - Indexed meshes disabled (`src/constants.lua:121`)
  - CPU mesh storage (`src/render/ChunkRenderer.lua:758`)
- **Impact:** Higher vertex count and upload overhead
- **Recommendation:** Enable indexed meshes; explore GPU storage; reduce table churn

#### 4. Render Traversal Scales with Total Mesh Count 🔴
- **Issues:**
  - Per-frame iteration over all chunk meshes (`src/render/ChunkRenderer.lua:2401`)
  - Per-chunk draw calls for opaque and alpha
- **Configuration:** Large default radius (`drawRadiusChunks = 16`)
- **Impact:** Render CPU cost increases sharply in dense regions
- **Recommendation:** Adaptive radius or stronger active-set pruning

### Medium-Impact Findings

#### 5. Duplicated Entity Raycast
- **Issue:** Entity raycast performed twice per frame (update + draw)
- **Locations:** 
  - `src/game/GameState.lua:1572` (update)
  - `src/game/GameState.lua:1853` (draw/HUD)
- **Impact:** O(entity_count) scan duplicated every frame
- **Recommendation:** Cache entity target from update, reuse in draw

#### 6. Ambient Item Spawn Spikes
- **Issue:** Chunk transition triggers neighborhood spawn with top-down world scan per candidate
- **Locations:**
  - `src/game/GameState.lua:1521` (trigger)
  - `src/items/ItemEntities.lua:583` (neighborhood spawn)
  - `src/items/ItemEntities.lua:516` (top-down scan)
- **Impact:** Transient CPU spikes on chunk crossings
- **Recommendation:** Pre-compute spawn positions or defer to background

#### 7. Item Rendering Overhead
- **Issue:** Per-entity draw calls with push/translate/cube/pop
- **Locations:** `src/items/ItemEntities.lua:394,413,416`
- **Configuration:** High entity cap (`maxActive = 384`)
- **Impact:** Many tiny draw calls reduce render throughput
- **Recommendation:** Batch or instance item entity draws

### Low-Impact Findings

#### 8. Inventory UI Allocations
- **Issue:** Layout and mouse candidate lists rebuilt every update while UI open
- **Locations:** `src/ui/InventoryMenu.lua:418,325,129,177`
- **Impact:** GC churn while inventory is open
- **Recommendation:** Cache layout when unchanged

---

## Recommended Optimization Priority (Consolidated)

### Immediate (High ROI)
1. **Stop dirty-queue churn** once threaded prep budget is saturated (Audit #3, Item 2)
2. **Cache entity target** from update and reuse in draw (Audit #3, Item 5)
3. **Enable indexed meshes** for GPU-friendlier data flow (Audit #3, Item 3)

### Short-Term (Medium ROI)
4. **Reduce per-frame chunk candidate pressure** via adaptive radius or active-set pruning (Audit #3, Item 4)
5. **Optimize or defer ambient item spawning** to avoid chunk-crossing spikes (Audit #3, Item 6)

### Longer-Term (Architectural)
6. **Move more meshing prep off-thread** or optimize halo pack path (Audit #3, Item 1)
7. **Batch or instance item entity draws** (Audit #3, Item 7)
8. **Cache inventory UI layout** when unchanged (Audit #3, Item 8)

---

## Performance Evolution Summary

| Metric | Audit #1 Baseline | Audit #2 | Audit #3 Current |
|--------|-------------------|----------|------------------|
| Threaded Meshing | ✅ Implemented | ✅ Stable | ✅ Active |
| Chunk Key Type | ✅ Numeric | ✅ Numeric | ✅ Numeric |
| Per-Frame Allocations | ⚠️ Moderate | ✅ Minimized | ✅ Minimized |
| Streaming Spikes | ⚠️ Addressed | ✅ Resolved | 🔍 Monitor |
| Render Scaling | N/A | N/A | 🔍 Optimize |

---

## Files by Audit Reference

### Audit #1 Key Files
- `src/render/ChunkRenderer.lua` - Meshing, threaded workers
- `src/render/mesher_thread.lua` - Worker implementation
- `src/world/ChunkWorld.lua` - Chunk keys, streaming
- `src/world/Chunk.lua` - (Note: unused per Audit #2)

### Audit #2 Key Files
- `src/game/GameState.lua` - Camera allocations
- `src/player.lua` - Quaternion allocations
- `conf.lua` - Fullscreen persistence
- `AGENTS.md` - Documentation
- `src/save/SaveSystem.lua` - Bulk load

### Audit #3 Key Files
- `src/render/ChunkRenderer.lua` - Prep overhead, queue churn, traversal
- `src/constants.lua` - Mesh configuration
- `src/game/GameState.lua` - Entity raycast duplication
- `src/items/ItemEntities.lua` - Spawn spikes, draw calls
- `src/ui/InventoryMenu.lua` - UI allocations

---

## Notes for Future Development

1. **Guard against string key regressions:** Add assertions where `type(key) ~= 'number'` in enqueue/dirty paths
2. **Alpha sorting:** Only optimize if profiling shows it as a hotspot
3. **Save format naming:** Consider aligning filename with version magic for clarity
4. **Dead code cleanup:** `Chunk.lua`, `Input.wantQuit` when convenient

---

*Document generated from consolidation of Audit Results #1, #2, and #3*  
*Date: 2026-03-01*
