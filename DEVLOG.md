# Dev Log

## 2026-02-15

### Lighting Mode Toggle (Verification)
- Switched active runtime mode to `vertical` in `src/constants.lua` (`Constants.LIGHTING.mode`) for regression verification of the vertical backend.

### Floodfill Lighting Rebuild (Clean Backend Rewrite)
- Replaced `src/world/lighting/FloodfillLighting.lua` with a clean, standalone floodfill backend implementation (same public API, rewritten internals).
- Rebuilt floodfill around an explicit two-phase queue model:
  - vertical column recompute queue (`skyColumnsQueue`) for baseline skylight values.
  - flood propagation queue (`skyFloodQueue`) using max-propagation (`candidate > neighbor`) with bounded per-frame budgets.
- Kept world/chunk integration compatible with existing systems:
  - `getSkyLight(...)`, `ensureSkyLightForChunk(...)`, `fillSkyLightHalo(...)`, `updateSkyLight(...)`, `pruneSkyLightChunks(...)`.
  - edit hooks: `onOpacityChanged(...)`, `onBulkOpacityChanged(...)`, `onPrepareChunk(...)`.
- Improved lighting-to-mesh correctness on chunk boundaries:
  - skylight voxel changes now mark dirty chunks and boundary-neighbor chunks when the changed voxel sits on a chunk edge.
- Rebuilt edit-driven relight behavior:
  - opacity edits schedule bounded local rebuild windows (`radius=15` blocks), clear stale skylight in-window, then recompute/flood.
  - immediate catch-up pass after edits still uses `editImmediateOps` / `editImmediateMillis`.
- Added bounded flood catch-up during halo generation:
  - `fillSkyLightHalo(...)` now runs a small synchronous lighting update budget (`meshImmediateOps` / `meshImmediateMillis`) before packing halo light data, reducing vertical-only snapshots in newly meshed chunks.

### Floodfill Lighting Follow-up (Behavior + Cost)
- Fixed floodfill seed generation during meshing prep in `src/world/ChunkWorld.lua`:
  - `ensureSkyLightForChunk(...)` and `fillSkyLightHalo(...)` now request flood seeding when `Constants.LIGHTING.mode == 'floodfill'`.
  - This prevents chunk halo prep from silently baking vertical-only light in floodfill mode.
- Added idle-stage flood kickoff after lazy column recompute:
  - `_recomputeSkyColumn(...)` now transitions to `flood` stage when it enqueues flood nodes while the stage is `idle`.
- Replaced movement-triggered full-region flood relight with incremental region delta queueing:
  - new `_queueSkyRegionDelta(...)` only enqueues newly entered active columns instead of clearing/rebuilding the whole active region every center-chunk move.
  - `pruneSkyLightChunks(...)` now uses this delta queue path for floodfill mode.
- Reduced floodfill thrash from vertical pass:
  - `updateSkyLight(...)` vertical stage now recomputes columns with `markDirty=false`; dirty marking is driven by actual flood propagation changes.
- Added stale queue guards:
  - vertical-stage queued columns are ignored if outside the active sky X/Z region.
  - flood propagation now early-outs for sources outside the active sky X/Z region.

### Floodfill Lighting Fix (Flood Stage Visibility)
- Reduced flood queue seed volume in `src/world/lighting/FloodfillLighting.lua`:
  - `_recomputeSkyColumn(...)` now seeds flood from the topmost and bottommost lit voxels (instead of every lit voxel).
  - flood propagation can now "walk down" columns on equal-light vertical steps, enabling sideways spread from lower heights without per-y seeding.
- Split dirty tracking between vertical and flood stages:
  - movement-driven region deltas keep vertical recompute non-dirty, but flood propagation marks affected chunks dirty so meshes can be rebuilt with updated light.

### Floodfill Edit Path Follow-up (No Full-Region Reset)
- Reworked floodfill edit scheduling in `src/world/ChunkWorld.lua` to avoid resetting to vertical across the entire active region on each opacity edit:
  - added `_scheduleSkyBoundsRebuild(...)` and `_scheduleSkyLocalRebuild(...)`.
  - `_onSkyOpacityChanged(...)` now queues a local rebuild window (`radius=15` blocks) instead of `_scheduleSkyRegionRebuild(true)`.
- Added bounded immediate floodfill catch-up after single opacity edits:
  - `_primeSkyLightAfterOpacityEdit(...)` runs a synchronous, bounded skylight update pass right after local edit relight scheduling.
  - supports optional `Constants.LIGHTING.editImmediateOps` / `editImmediateMillis` tuning (defaults now: `8192` ops, `0` ms budget for op-capped catch-up).
- Reduced flood queue bloat during vertical recompute:
  - `_recomputeSkyColumn(...)` now enqueues flood seeds only for skylight voxels that actually changed, instead of every lit voxel in the column.
  - this prevents long post-edit "vertical first, flood later" transitions caused by huge unchanged-seed queues.
- Reduced edit-induced visual fallback to vertical:
  - floodfill no longer calls `_markLightingDirtyRadius(...)` up-front during normal local edit relight scheduling.
  - vertical-stage dirty marking now follows `_skyTrackDirty` so edit-driven relights can mark changed chunks, while movement-driven region deltas stay non-dirty.
- Movement-driven delta queueing now stays non-dirty:
  - `_queueSkyRegionDelta(...)` now sets `_skyTrackDirty=false` to avoid unnecessary mesh churn while the player moves.
- Updated bulk-edit floodfill scheduling:
  - `applyEditsBulk(...)` now tracks opacity-change bounds and queues a bounded floodfill rebuild window (expanded by 15 blocks), instead of scheduling a full active-region rebuild.

### Floodfill Status Reset
- Default runtime mode remains `floodfill` in `src/constants.lua` (`Constants.LIGHTING.mode`).

### Lighting Backend Isolation Refactor
- Added isolated lighting backend modules:
  - `src/world/lighting/VerticalLighting.lua`
  - `src/world/lighting/FloodfillLighting.lua`
- Refactored `src/world/ChunkWorld.lua` to use a single active backend selected by `Constants.LIGHTING.mode`:
  - backend factory + initialization now lives in `_initLighting(...)`.
  - public skylight APIs now delegate to backend implementations:
    - `getSkyLight(...)`
    - `ensureSkyLightForChunk(...)`
    - `fillSkyLightHalo(...)`
    - `updateSkyLight(...)`
    - `pruneSkyLightChunks(...)`
  - opacity-change and chunk-prepare hooks now delegate through backend methods:
    - `_onSkyOpacityChanged(...)`
    - `applyEditsBulk(...)` opacity notifications
    - `prepareChunk(...)` column invalidation hook
- `FloodfillLighting` is now standalone and no longer delegates to vertical internals.

### Floodfill Backend Decoupling Pass
- Replaced `src/world/lighting/FloodfillLighting.lua` scaffold with a fully independent floodfill implementation:
  - owns its own skylight chunk cache, vertical/flood queues, active-region bounds, and update scheduling.
  - keeps floodfill-only edit hooks (`onOpacityChanged`, `onBulkOpacityChanged`, `onPrepareChunk`) isolated from vertical.
- Added floodfill queue dedupe + bounded rebuild clearing in the new backend:
  - flood queue now tracks `worldIndex` membership to avoid duplicate queue bloat.
  - edit-driven rebuild windows clear existing skylight values in-bounds before recompute to avoid stale carry-over.
- Removed legacy in-world floodfill internals from `src/world/ChunkWorld.lua`:
  - deleted old `_sky*` state fields and helper methods so `ChunkWorld` only routes through the selected lighting backend.
  - this eliminates mixed execution paths between vertical and floodfill logic.
- Switched `Constants.LIGHTING.mode` back to `floodfill` in `src/constants.lua` for direct in-game validation of the decoupled backend.

## 2026-02-14

### Alpha Skylight Lighting Pass
- Added configurable skylight settings in `src/constants.lua`:
  - new `Constants.LIGHTING` (`enabled`, `mode`, `leafOpacity`, flood update budgets, debug flags)
  - default mode is `vertical` for hitch-safe baseline; `floodfill` is available via config toggle
  - per-block `lightOpacity` values in `BLOCK_INFO` (leaf opacity is tunable via lighting config)
- Implemented chunked skylight storage and APIs in `src/world/ChunkWorld.lua`:
  - `getSkyLight(x, y, z)`
  - `fillSkyLightHalo(cx, cy, cz, out)` with `(chunkSize + 2)^3` layout matching block halos
  - `ensureSkyLightForChunk(cx, cy, cz)`
  - `updateSkyLight(maxOps, maxMillis)` for incremental flood-fill queue processing
  - `pruneSkyLightChunks(centerCx, centerCz, keepRadiusChunks)` tied to renderer keep radius
- Added vertical skylight scan (0..15) and flood-fill propagation mode:
  - vertical top-down attenuation uses per-block `lightOpacity` (including partial leaf attenuation)
  - flood-fill propagation runs in budgeted incremental steps with O(1) queue head/tail
  - block edits that change opacity now trigger skylight invalidation/rebuild scheduling and wider dirty marking in X/Z lighting influence range
- Wired renderer/mesher skylight data flow:
  - `ChunkRenderer` now builds a second skylight halo payload for both sync and threaded meshing paths
  - threaded jobs now support `skyHaloBlob` / `skyHalo` payloads in addition to block halos
  - `mesher_thread.lua` decodes block and sky halos into separate scratch buffers (prevents alias overwrite)
  - greedy meshing merge keys now include skylight (`blockId * 16 + sky`) to prevent light-smear quads
- Added `VertexLight` mesh attribute and new voxel shader:
  - vertex format extended to include per-face skylight scalar
  - new `src/render/VoxelShader.lua` applies classic alpha-style face shading + 16-step brightness LUT
  - shader supports day/night skylight subtraction via `uSkySubtract`
  - fixed shader input declaration for custom mesh attribute (`in float VertexLight;`) for LOVR custom-attribute binding
- Integrated lighting update and shader draw flow in `src/game/GameState.lua`:
  - `world:updateSkyLight(...)` now runs each frame before `renderer:rebuildDirty(...)`
  - voxel shader is applied for chunk rendering pass so both opaque and alpha chunk meshes use skylight + day/night modulation
  - HUD now shows lighting mode and shader runtime status (`On` with sky-subtract value, or shader compile error text when unavailable)
- Skylight cache pruning is now coordinated with mesh pruning:
  - `ChunkRenderer:setPriorityOriginWorld(...)` now calls `world:pruneSkyLightChunks(...)` with the current keep radius

### Audit Results #2 Follow-up
- Removed per-frame camera/view allocations:
  - `src/game/GameState.lua` now reuses a persistent `lovr.math.newVec3` (`self._cameraPosition`) for `pass:setViewPose(...)`.
  - `src/player.lua` now reuses cached quaternions in `Player:getCameraOrientation()` via in-place `:set(...)` + `:mul(...)` (no `newQuat` allocations, no `yaw * pitch` temporary).
- Added bulk save-load edit application:
  - new `ChunkWorld:applyEditsBulk(edits, count)` writes directly to sparse edit storage while preserving AIR overrides, dirty marking, and boundary-neighbor dirty propagation.
  - `SaveSystem:apply(...)` now prefers `world:applyEditsBulk(...)` when available, with fallback to the original per-edit `world:set(...)` path.
- Fullscreen local-dev artifact hygiene:
  - added `.fullscreen` to `.gitignore` so fullscreen toggle persistence does not create untracked repo noise.
- Synced control wording in docs:
  - updated `AGENTS.md` Escape behavior text to match runtime behavior and `README.md` (`Esc` unlocks mouse if locked, otherwise opens pause menu).
- Added third-party attribution/compliance docs:
  - new `THIRD_PARTY_NOTICES.md` includes upstream source URL, commit provenance, license type, and full MIT license text for vendored `lovr-mouse.lua`.
  - `README.md` now points to `THIRD_PARTY_NOTICES.md` in the relative mouse section.

### Codex Task Spec Refresh
- Replaced `Codex_Instructions` with a numeric chunk-key migration plan: remove comma-string chunk IDs and use numeric chunk keys end-to-end across world dirtying, streaming enqueue, renderer queues/cache, and threaded meshing key flow.

### Numeric Chunk Key Migration
- Added public chunk-key helpers in `src/world/ChunkWorld.lua`:
  - `ChunkWorld:chunkKey(cx, cy, cz)`
  - `ChunkWorld:decodeChunkKey(chunkKey)`
- Switched world dirty tracking to numeric keys:
  - `_markDirty(...)` now writes `self._dirty[chunkKey] = true` using `_chunkKey`.
  - `drainDirtyChunkKeys(...)` now emits numeric chunk keys.
- Switched streaming enqueue outputs to numeric keys:
  - `enqueueChunkSquare(...)` and `enqueueRingDelta(...)` now fill `outKeys` with `_chunkKey(...)` integers.
- Switched renderer key handling to numeric chunk keys:
  - removed string parsing helper (`parseKey`) and all `key:match` chunk-key parsing.
  - `_queueDirtyKeys(...)` now decodes coordinates via `world:decodeChunkKey(key)`.
  - `_rebuildChunk(...)` now keys build versions via `world:chunkKey(cx, cy, cz)`.
  - prune path no longer tries to recover missing coords by parsing string keys.
- Verified there are no remaining renderer/world chunk-key string concatenation/parsing paths (`.. ',' ..`, `parseKey`, `key:match`) in `src/world/ChunkWorld.lua` and `src/render/ChunkRenderer.lua`.
- Follow-up consistency cleanup in `src/world/ChunkWorld.lua`:
  - internal call sites now use public `chunkKey(...)` / `decodeChunkKey(...)` wrappers instead of calling `:_chunkKey(...)` / `:_decodeChunkKey(...)` directly.
  - private underscore helpers remain as canonical internal implementations behind those wrappers.

### Renderer Draw + Meshing Pipeline Updates
- Added rollout toggles in `src/constants.lua`:
  - `Constants.RENDER = { cullOpaque = true, cullAlpha = false }`
  - `Constants.MESH.indexed = false` (default-off indexed quad path)
  - `Constants.THREAD_MESH = { enabled = false, maxInFlight = 2, maxApplyMillis = 1.0 }`
- Updated `src/render/ChunkRenderer.lua` draw path:
  - opaque meshes now draw front-to-back (distance-sorted) with reusable `_opaqueScratch`
  - alpha meshes remain back-to-front with existing `_alphaScratch`
  - two-pass cull state: opaque uses back-face culling by default, alpha stays unculled by default
- Corrected face winding for +/-Y and +/-Z in both naive and greedy mesh builders so back-face culling keeps outward faces visible.
- Added optional indexed quad emission (4 vertices + 6 indices) for both naive and greedy build paths:
  - added pooled index buffers (`_indexPoolOpaque`, `_indexPoolAlpha`) with trailing trim
  - when indexed mode is enabled, chunk meshes call `mesh:setIndices(...)`
- Added threaded meshing pipeline with safe fallback:
  - new `src/render/MeshWorker.lua` thread/channel wrapper
  - new `src/render/mesher_thread.lua` worker mesher (table payload phase)
  - main thread now supports versioned meshing jobs, stale-result rejection, in-flight caps, and bounded per-frame apply budget
  - all graphics object creation (`newMesh`, `setIndices`) remains on the main thread
  - if worker startup/runtime fails, renderer falls back to synchronous rebuild path
- Added renderer worker cleanup on session teardown (`GameState:_teardownSession` calls `renderer:shutdown()` when available).
- Correctness risk notes:
  - culling correctness is sensitive to winding; winding was aligned explicitly per face direction for both sync and worker meshing paths.
  - runtime visual/perf verification is still required with the A/B toggle matrix (culling/indexed/threaded on/off).

### Thread Payload Optimization (Phase A)
- Added threaded halo payload toggle in `Constants.THREAD_MESH`:
  - `haloBlob = true` (uses Blob halo payload when available, falls back to table payload automatically).
- Updated `ChunkRenderer` threaded enqueue path to attempt Blob packing for halo data:
  - packs `(chunkSize + 2)^3` halo block IDs into a byte string in bounded chunks and builds a `Blob` via `lovr.data.newBlob(...)`.
  - sends `job.haloBlob` when packing succeeds; otherwise keeps existing `job.halo` table payload.
- Updated worker (`src/render/mesher_thread.lua`) to accept both payload formats:
  - decodes `job.haloBlob` via `Blob:getString(...)` into a reusable scratch table.
  - falls back to `job.halo` when blob decode is unavailable.
- Safety behavior:
  - if blob decode fails and no table fallback exists, worker returns an explicit error (`missing_halo_payload`) and renderer falls back to synchronous rebuild (existing worker-failure fallback path).

### Thread Payload Optimization (Phase B)
- Added threaded result payload toggle in `Constants.THREAD_MESH`:
  - `resultBlob = true` (worker attempts Blob result payloads for vertices/indices; falls back to table result payloads if packing is unavailable).
- Updated worker result packaging (`src/render/mesher_thread.lua`):
  - when enabled and supported (`ffi` + `lovr.data.newBlob`), packs vertex data into float blobs and index data into `u16`/`u32` blobs.
  - index blob packing converts renderer 1-based indices to raw 0-based index values for Blob index buffers.
  - emits index element type metadata (`indicesOpaqueType` / `indicesAlphaType`) so main-thread `mesh:setIndices(blob, type)` uses the correct integer width.
- Updated renderer threaded apply path (`src/render/ChunkRenderer.lua`) to consume blob or table result payloads:
  - accepts blob vertex payloads in `lovr.graphics.newMesh(...)`.
  - accepts blob index payloads via `mesh:setIndices(blob, indexType)`.
  - preserves fallback behavior: if blob mesh/index apply fails on the main thread, renderer disables worker threading and rebuilds synchronously for correctness.

### Thread Payload Optimization (Phase C)
- Promoted threaded meshing defaults in `Constants.THREAD_MESH`:
  - `enabled = true` (with `haloBlob = true` and `resultBlob = true` retained).
- Added main-thread halo table pooling in `src/render/ChunkRenderer.lua`:
  - reusable halo table pool (`_threadHaloTablePool`) with acquire/release helpers.
  - threaded enqueue now reuses halo tables instead of allocating a fresh Lua table per queued build.
  - table-payload fallback now keeps halo tables in-flight until the matching worker result arrives before returning them to the pool.
- Added worker-side pack buffer reuse in `src/render/mesher_thread.lua`:
  - persistent FFI buffers for vertex pack (`float`) and index pack (`u16` / `u32`) paths, grown-on-demand and reused across jobs.
  - reused greedy meshing mask scratch table (`greedyMaskScratch`) to avoid per-job mask table allocation.
- Net effect:
  - reduced transient allocation churn during threaded streaming/rebuild bursts while preserving existing fallback behavior.

### Phase C Hotfix
- Fixed Lua unpack compatibility in `src/render/ChunkRenderer.lua` halo blob packing:
  - replaced direct `table.unpack(...)` calls with a LuaJIT-safe fallback (`table.unpack or unpack`).
  - if no unpack function is available, halo blob packing now safely skips and falls back to table payloads (no startup crash).
- Fixed worker bootstrap compatibility in `src/render/mesher_thread.lua`:
  - worker no longer assumes global `lovr` exists in thread context.
  - thread/data APIs are resolved via `rawget(_G, 'lovr')` with `require('lovr.thread')` / `require('lovr.data')` fallback.
  - worker bootstrap now exits cleanly if thread channels are unavailable (avoids fatal top-level thread errors and preserves main-thread fallback behavior).
  - worker job receive path now supports runtimes without `Channel:demand()` by falling back to `Channel:pop()` polling with a tiny sleep.

## 2026-02-13

### Meshing Hot-Path Optimizations
- Added `ChunkWorld:_getByChunkKey(chunkKey, localIndex, x, y, z)` to mirror `get(...)` lookup semantics (bounds, edits, features, base) without chunk-coordinate floor/mod work.
- Added `ChunkWorld:fillBlockHalo(cx, cy, cz, out)` to fill a reusable `(chunkSize + 2)^3` halo buffer (x-fast indexing) for meshing neighbor reads, with out-of-world/out-of-range samples forced to AIR.
- Refactored `ChunkRenderer:_buildChunkNaive(...)` and `ChunkRenderer:_buildChunkGreedy(...)` to read block + neighbor IDs from the halo cache, removing `world:get(...)` calls from meshing inner loops.
- Reworked vertex emission in `ChunkRenderer` to pooled table writes (`_vertexPoolOpaque` / `_vertexPoolAlpha`) with per-rebuild count tracking and trailing-slot trim, eliminating per-vertex table allocation churn after pool warm-up.
- Kept existing feature-prep behavior (`prepareChunk` for the target chunk column only), which remains correct with current tree edge margins.

## 2026-02-12

### Streaming + Frame-Pacing Fixes
- Replaced per-boundary full-radius dirty reseeding in `src/game/GameState.lua` with chunk-ring enqueueing:
  - movement now uses `ChunkWorld:enqueueRingDelta(...)`
  - initial session boot uses a one-time square seed (`ChunkWorld:enqueueChunkSquare(...)`)
- Added `ChunkWorld:getActiveChunkYRange()` with conservative precomputed generation/feature bounds, and limited startup + movement enqueue work to that Y chunk range (skips guaranteed-empty upper layers).
- Added renderer missing-mesh enqueue path in `src/render/ChunkRenderer.lua`:
  - `enqueueMissingKeys(...)` only queues chunks without cached meshes
  - explicit world dirties (edits/boundary neighbors) still force rebuilds through the dirty path
- Switched rebuild pacing from chunk-count-only to millisecond budgeting:
  - new `Constants.REBUILD.maxMillisPerFrame`
  - `ChunkRenderer:rebuildDirty(maxPerFrame, maxMillisPerFrame)` now stops on time budget and still respects a hard chunk cap safety guard
- Added transient streaming metric in HUD:
  - `GameState` tracks last chunk-crossing enqueue count
  - `HUD` shows `Stream: Enqueued N` for `Constants.PERF.enqueuedShowSeconds` (default `0.5s`)
- Added tree bound tuning fields in `Constants.GEN` (`treeTrunkMin`, `treeTrunkMax`, `treeLeafPad`) and aligned feature height usage so active Y-range estimation stays conservative/deterministic.

### Rebuild Queue Spike Mitigation + Diagnostics
- Updated `ChunkRenderer` priority handling to avoid O(queue) rebucketing spikes on chunk crossings:
  - added `_priorityVersion` stamping for dirty entries
  - added lazy stale-entry requeue on pop when priority changed
  - full `_rebucketDirtyEntries()` now runs only when backlog is small (`Constants.REBUILD.rebucketFullThreshold`)
  - stale requeue work per rebuild call is capped (`Constants.REBUILD.staleRequeueCap`) to guarantee forward progress
- Added renderer rebuild diagnostics captured each frame:
  - dirty intake drained count from `world:drainDirtyChunkKeys`
  - newly queued dirty count from that drain
  - rebuild time spent in `rebuildDirty` (ms)
  - active rebuild budget (ms, or off)
- Extended `GameState` HUD payload and `HUD` perf lines:
  - `Rebuild: <spent> / <budget> ms`
  - `DirtyIn: <drained>  Queued: <queued>`
  - existing transient `Stream: Enqueued N` retained
- Reduced greedy meshing allocation churn by reusing a persistent 2D mask array (`ChunkRenderer._greedyMask`) instead of allocating a new mask table per chunk rebuild.

### Clear Done Line: Incremental Mesh Pruning
- Removed chunk-crossing full-cache prune spikes by replacing immediate `_pruneChunkMeshes()` scans with incremental pruning in `src/render/ChunkRenderer.lua`.
- `setPriorityOriginWorld(...)` now only schedules prune work (`_prunePending`, cursor reset, cached keep radius) and no longer performs O(meshCache) maintenance directly.
- Added bounded per-frame prune stepping:
  - new `ChunkRenderer:_pruneChunkMeshesStep(maxChecks, maxMillis)` uses a safe `next(...)` cursor and supports deletion while iterating
  - default per-frame caps added in `Constants.REBUILD`:
    - `pruneMaxChecksPerFrame = 128`
    - `pruneMaxMillisPerFrame = 0.25`
- Pruning now runs each frame from `rebuildDirty(...)` under its own small budget, so mesh cache convergence is amortized.
- Added prune diagnostics to renderer/HUD:
  - `Prune: scanned <n>  removed <m>  pending <yes/no>`
  - useful for confirming bounded prune work and pending-state drain.

## 2026-02-11

### Large-World Procedural Terrain Refactor
- Replaced eager per-chunk base voxel storage in `src/world/ChunkWorld.lua` with layered lookup:
  - procedural base terrain (`_getBaseBlock`)
  - deterministic feature overrides (lazy trees in `_featureChunks`)
  - sparse persisted edit overrides (`_editChunks`, including carved air `0`)
- `ChunkWorld:generate()` is now O(1) and no longer scans/fills the entire world volume.
- Added numeric-key chunk/local indexing helpers (`_chunkKey`, `_localIndex`) to keep `world:get()` allocation-free in meshing hot paths.
- Refactored edit persistence APIs:
  - `getEditCount()` now reflects sparse edit entries
  - `collectEdits(out)` now decodes numeric chunk/index storage back to world coordinates
- Added deterministic lazy tree preparation:
  - `prepareChunk(cx, cy, cz)` seeds per-column feature generation once
  - per-column RNG is derived from `(WORLD_SEED, cx, cz)` so results are generation-order independent
  - tree placement uses a safe chunk-edge margin and keeps writes within a single chunk
- Added dirty seeding for lazy meshing with `ChunkWorld:markDirtyRadius(centerCx, centerCz, radiusChunks)`.
- Updated `GameState` dirty/meshing flow:
  - seeds dirty chunks around the spawn/player chunk on session start
  - reseeds when the player crosses chunk boundaries so newly visible chunks queue for rebuild
- Updated `ChunkRenderer` integration:
  - calls `world:prepareChunk` once before chunk rebuilds
  - prunes far chunk meshes when priority chunk changes to keep mesh memory bounded
  - mesh cache retention radius now uses `drawRadius + alwaysVisiblePadding + meshCachePadding`
- Increased finite world X/Z dimensions to `1280 x 1280` (`WORLD_SIZE_Y` remains `64`) and added `Constants.CULL.meshCachePaddingChunks`.
- Note: existing saves from smaller world dimensions will fail compatibility checks (header world-size validation).
- Updated `README.md` feature bullets to match the new world scale/storage model.

### Save V2 + Autosave + Menu Metadata
- Upgraded save serialization in `src/save/SaveSystem.lua` to always write `MC_SAVE_V2` at `saves/world_v1.txt`.
- Added backward-compatible load support for both `MC_SAVE_V1` and `MC_SAVE_V2`.
- Extended save payload to include:
  - `savedAt` unix timestamp
  - `time` (`Sky.timeOfDay`)
  - `inv` + `slot` entries for hotbar/inventory state
  - existing player transform and diff-based edits (`BEGIN_EDITS` marker layout)
- Added `SaveSystem:peek(constants)` metadata parsing for main-menu save health/details without building edit tables.
- Added inventory serialization APIs in `src/inventory.lua`:
  - `Inventory:getState(out)` for reusable export tables
  - `Inventory:applyState(state)` with validation/clamping and empty-slot normalization
- Updated session boot flow in `src/game/GameState.lua` so Continue restores inventory/hotbar selection and time-of-day.
- Added autosave support in `src/game/GameState.lua` using new `Constants.SAVE` config:
  - `enabled`
  - `autosaveIntervalSeconds`
  - `autosaveShowHudSeconds`
- Added shared save-status messaging used by autosave + manual save:
  - HUD transient status text (`Saving...`, `Autosaving...`, `Autosaved`, failures)
  - pause menu status line integration
- Added main-menu save metadata rendering in `src/ui/MainMenu.lua`:
  - availability/corrupt/incompatible state
  - version info
  - last saved timestamp (when available)
  - edit count
- Added New Game overwrite confirmation when any save file exists:
  - first Enter arms confirmation
  - second Enter emits `new_game_confirmed`
  - navigation/Esc cancels

### World Gen Tuning
- Reduced `Constants.TREE_DENSITY` by ~50% to lower average foliage density (less overdraw + simpler sightlines).
- Increased baseline strata depth so bedrock is reached after ~15 blocks of digging (with an approximate 2/3 dirt, 1/3 stone split).

### Persistence + Menu Foundation
- Added world edit diff tracking in `src/world/ChunkWorld.lua` (`_editOriginal/_editValues`) so only block edits are persisted.
- Added `ChunkWorld:getEditCount()` and `ChunkWorld:collectEdits(out)` for save serialization.
- Added `src/save/SaveSystem.lua` with single-slot save support at `saves/world_v1.txt` using `lovr.filesystem` and versioned header validation.
- Added `src/ui/MainMenu.lua` with startup/pause modes, keyboard navigation, and delete-save confirmation flow.
- Refactored `src/game/GameState.lua` to support `menu` vs `game` modes, session start/teardown, and menu intent handling.
- Updated `src/input/Input.lua` so `Esc` opens pause menu when mouse is already unlocked (while preserving unlock behavior when captured).
- Added `lovr.quit` hook in `main.lua` to save diffs on window close/Alt+F4.
- Added explicit in-game `Save` action in the pause menu with on-screen save status feedback.
- Changed pause menu `Quit` behavior to save and return to the main menu instead of exiting the app.
- Hardened save detection/parse flow for save availability checks in main menu.
- Updated save behavior so an explicit save creates a valid save file even with zero world edits (Continue now registers reliably).
- Extended save format to persist player position and look direction; Continue now restores player state with safe spawn fallback if invalid/colliding.
- Updated `README.md` controls and feature list for menu/save behavior.

## 2026-02-10

### Git / Version Control Setup
- Detected an incomplete/broken `.git` folder that prevented normal git usage; preserved it as `.git_incomplete_backup_2026-02-10/`.
- Initialized a fresh git repository on `main` and added a `.gitignore` for local artifacts/backups.
- Created the initial commit and pushed `main` to GitHub (`tristonkautz-kautzperformance/MC-GAME`).

### Renderer Polish + HUD GC Smoothing
- Reduced per-frame allocations in `ChunkRenderer:draw()` by reusing a scratch forward vector and doing a single visibility pass.
- Alpha chunk meshes are now drawn back-to-front (chunk-distance sorted) to reduce translucent blending artifacts.
- Reduced HUD per-frame allocations by caching the HUD text and updating it at a configurable interval (`Constants.PERF.hudUpdateInterval`), and by reusing scratch vectors/line buffers.
- Precomputed constant HUD help/tip strings to avoid per-frame concatenation.
- Fixed LOVR runtime error "Attempt to use a temporary vector from a previous frame" by switching cached vectors to `lovr.math.newVec3`.

### Inventory-Full Break Safety
- Added `Inventory:canAdd(block, amount)` in `src/inventory.lua` to support a no-allocation capacity check for stacking/existing-empty-slot acceptance.
- Updated `Interaction:tryBreak()` in `src/interaction/Interaction.lua` to check `inventory:canAdd` before removing a world block.
- Breaking a block now leaves the block intact when the inventory cannot accept it, preventing item loss/disappearing blocks.

### Docs
- Updated `README.md` to describe the current `F3` performance overlay (frame/chunk stats) instead of “pass stats”.
- Updated `AGENTS.md` to reference `Codex_Instructions` (removed stale `CODEX_*.txt` references).

## 2026-02-09

### Rebuild Scheduling + Perf HUD
- Added rebuild/perf configuration tables in `src/constants.lua`:
  - `Constants.REBUILD` for rebuild budget and priority behavior.
  - `Constants.PERF` for perf HUD/pass stats/timing defaults.
- Replaced FIFO dirty chunk rebuild scheduling in `src/render/ChunkRenderer.lua` with distance-bucket prioritization.
- Added renderer priority-origin API (`setPriorityOriginWorld`) and automatic queued dirty-chunk re-bucketing when the player changes chunk.
- Wired player camera position into rebuild prioritization each update in `src/game/GameState.lua`.
- Made rebuild budget configurable from constants (`Constants.REBUILD.maxPerFrame`).
- Added optional timing enable on load via `Constants.PERF.enableTiming` with API guard.
- Added runtime perf HUD toggle on `F3` in `src/input/Input.lua`.
- Expanded HUD debug output in `src/ui/HUD.lua`:
  - FPS via `lovr.timer.getFPS()`.
  - Visible chunk count and rebuilds-per-frame.
  - Guarded `pass:getStats()` fields (draws/computes/drawsCulled/cpu memory, plus optional timing fields).
- Fixed perf stats sampling order so `pass:getStats()` is captured after draw calls and displayed from the previous frame (prevents persistent zero draw/CPU values).
- Timing fields are now shown only when `Constants.PERF.enableTiming` is enabled.
- Disabled VSync in `conf.lua` using `t.graphics.vsync = false` to allow uncapped FPS during performance testing.
- Improved pass-stats capture path to sample after world draw commands on the active pass for more reliable counters.
- Simplified perf HUD to focused runtime metrics: FPS, frame time, worst frame in the last second, visible chunks, rebuilds, and dirty queue depth.
- Removed pass-stat/timing overlays from runtime HUD flow to avoid noisy or misleading zero-value readouts on some platforms.
- Refactored base terrain generation in `ChunkWorld:generate()` to write directly into chunk storage instead of calling `set()` for every voxel.
- Updated chunk storage semantics so AIR writes clear block slots (`nil`) to keep chunk data sparse and reduce memory bloat from block breaking.
- Preserved sparse tree placement via existing `set()` path and kept final "mark all chunks dirty once" generation behavior.
- Added low-allocation dirty drain path (`ChunkWorld:drainDirtyChunkKeys(out)`) with an empty fast path.
- Added a compatibility fast path in `ChunkWorld:getDirtyChunkKeys()` to return a shared empty array when no dirty chunks exist.
- Updated renderer dirty intake to use a reusable scratch table and explicit count (`_queueDirtyKeys(dirtyKeys, count)`), avoiding per-frame dirty list allocations in the idle case.
- Updated `README.md` controls to document the new `F3` perf toggle.

## 2026-02-08

### Prototype + Performance Passes
- Built a playable voxel sandbox prototype in LOVR with Lua.
- Added static world dimensions (`32 x 32 x 64`).
- Implemented block types: grass, dirt, stone, bedrock, wood, leaf.
- Implemented FPS movement, jump, gravity, and collision.
- Added break/place interactions and an 8-slot inventory/hotbar.
- Added day/night cycle and in-world HUD.
- Added pointer-lock flow with click-to-capture, `Tab` toggle, and `Esc` unlock.
- Integrated `lovr-mouse.lua` for proper relative mouse mode on LOVR `0.18`.
- Refactored into modules (GameState, input, UI, sky, interaction).
- Implemented chunked world storage (`16 x 16 x 16`) and mesh-based rendering.
- Added conservative chunk culling and visible-chunk caching.
- Added internal face culling (including internal leaf culling).

### Recovery Note
- Reconstructed project files after an accidental workspace wipe (docs folder remained).

### Audit Fixes
- Fixed input key state handling by adding key-release plumbing (`lovr.keyreleased` -> `GameState` -> `Input`) to prevent sticky WASD movement.
- On focus loss, input now clears held keys and one-shot intents (jump/break/place/help/quit) to avoid stale movement/actions after alt-tabbing.
- Fixed dirty chunk rebuild scheduling to queue dirty keys across frames so rebuild budget limits no longer drop pending chunk updates.
- Enforced finite player world bounds in collision checks so the player cannot move outside the playable volume.
- Corrected `lovr-mouse.lua` GLFW FFI signatures for `glfwGetInputMode` and `glfwSetScrollCallback`.
- Fixed HUD help text newline rendering (actual line break instead of literal `\n`).

### Input/UI/Window Cleanup
- Fixed pointer-lock integration regression by assigning `lovr.mouse = require('lovr-mouse')` during game init.
- Added `F11` fullscreen toggle with restart-based apply and persisted state via `.fullscreen`.
- Updated desktop config for non-VR module usage (`t.modules.headset = false`) and explicit window settings.
- Reworked HUD layout/scales to prevent overlapping giant text and added chunk/relative-mouse status lines.
- Set help overlay to hidden by default (`F1` still toggles it).

### Culling Fix Pass
- Reworked chunk visibility from center-only FOV tests to conservative sphere-aware FOV culling.
- Added horizontal chunk radius metadata and FOV padding (`fovPaddingDegrees`) to reduce edge popping.
- Updated draw-radius culling to account for chunk radius so near-edge chunks are not culled early.

### Performance Fix
- Optimized dirty chunk rebuild queue to avoid `table.remove(..., 1)` (O(n)) and use an O(1) head-index queue.
- Corrected queue bookkeeping to explicit head/tail indices (without `#` on sparse tables) to prevent dropped or stalled dirty chunk rebuilds.

### Greedy Meshing
- Added chunk meshing mode toggle via `Constants.MESH.greedy` (greedy on by default, naive fallback retained).
- Implemented 6-direction greedy meshing in `ChunkRenderer` using a per-slice 2D face mask and rectangle merge.
- Preserved existing face visibility rules by reusing `_shouldDrawFace` for opaque/translucent behavior.
- Removed per-face color table allocations in meshing by passing RGBA scalars directly into quad emission.
- Added HUD mesh mode indicator (`Mesh: Greedy` / `Mesh: Naive`) for quick runtime verification.
