# Dev Log

## 2026-02-21

### Mountain Biome Terrain Pass
- Added mountain biome controls to `Constants.GEN` in `src/constants.lua`:
  - biome mask frequency/octaves/threshold
  - ridge noise frequency/octaves/persistence
  - mountain height boost/amplitude
  - mountain stone-cap start Y and transition band
- Updated terrain generation in `src/world/ChunkWorld.lua`:
  - `_computeTerrainColumnData(...)` now blends a sparse mountain biome mask into base terrain height and applies ridged elevation for mountain regions.
  - high-elevation mountain surfaces now transition into stone composition using a configurable Y threshold with a natural blend band.
  - mountain stone surfaces now use stone subsurface composition (no dirt layer under stone caps).
- Updated generation bounds estimation:
  - `_computeGenerationThresholds()` now accounts for possible mountain height raise when computing max active chunk Y range, keeping streaming/meshing ranges aligned with generated terrain.
- Retuned mountain defaults for stronger visibility with seed `1337`:
  - increased mountain biome coverage and lowered threshold.
  - increased mountain vertical boost/amplitude so mountains are encounterable near spawn and can reach stone-cap elevations.
- Follow-up tuning for much higher, true-mountain relief:
  - increased `WORLD_SIZE_Y` from `64` to `96` to add vertical headroom for tall peaks.
  - further increased mountain coverage/intensity (`mountainBiomeFrequency`, lower threshold, higher boost/amplitude).
  - raised mountain stone-cap profile (`mountainStoneStartY`, `mountainStoneTransition`) to fit the taller terrain scale.
  - note: save files from the previous world-size config are incompatible by design and will not load under the new world dimensions.

### Low-Cost World-Edge Fog
- Added simple edge fog config in `src/constants.lua` (`Constants.FOG`) with conservative defaults.
- Updated shader initialization in `src/game/GameState.lua` to pass constants into `VoxelShader`.
- Added lightweight fog blending in `src/render/VoxelShader.lua`:
  - fog distance derives from render radius (with optional overrides in config),
  - fog uses horizontal camera distance only for low cost,
  - fog color follows day/night sky colors to blend naturally at the render edge.

### Large Sun/Moon Sky Cycle (Low-Cost)
- Updated `src/sky/Sky.lua` to draw large Minecraft-style sky bodies:
  - sun and moon now orbit opposite each other around the camera with a configurable tilted orbit.
  - render path uses two camera-facing planes (fallback to spheres only if needed), keeping draw cost extremely low.
- Added tuning config in `src/constants.lua` as `Constants.SKY_BODIES`:
  - `distance`, `sunSize`, `moonSize`, `orbitTiltDegrees`, `moonAlpha`, `enabled`.
- Updated `src/game/GameState.lua` to pass camera position/orientation into `Sky:draw(...)` so sky bodies remain stable in view while moving through the world.

## 2026-02-20

### Floodfill Vertical Intermediate Regression Fix
- Fixed a floodfill readiness regression in `src/world/lighting/FloodfillLighting.lua` that could reintroduce temporary vertical-style shadowing.
- Updated `ensureSkyLightForChunk(...)` to require both:
  - local halo-column readiness, and
  - floodfill queue drain (`_hasSkyQueueWork() == false`)
  before reporting chunk lighting ready for meshing.
- Restored no-shadow mesh-prep fallback behavior in `fillSkyLightHalo(...)` while floodfill queues are still active (or local columns are not yet ready), preventing vertical intermediate lighting from being rendered.

### Frame-Time Spike Mitigation (Render Radius 16)
- Optimized alpha draw ordering in `src/render/ChunkRenderer.lua`:
  - removed per-frame `alphaScratch` build/sort in `draw`.
  - added persistent alpha order cache (`_alphaOrder`) sorted by camera position and rebuilt only when camera position changes or alpha mesh presence changes.
  - alpha pass now filters cached order by frame visibility tag (`_visibleFrame`) to avoid double culling.
  - follow-up spike fix: alpha list rebuild now happens only when alpha membership changes, and camera-position resort is throttled by movement step (`RENDER.alphaOrderResortStep`, default `1.0` block) to avoid resorting full alpha cache on tiny movement jitter.
  - exposed alpha resort step in `src/constants.lua` (`Constants.RENDER.alphaOrderResortStep`) for runtime tuning if needed.
  - draw path now skips alpha resort work when 0-1 alpha chunks are visible in the current frame.
- Optimized floodfill neighbor propagation in `src/world/lighting/FloodfillLighting.lua`:
  - unrolled six-neighbor propagation checks in `_propagateSkyDarkFrom` and `_propagateSkyFloodFrom`.
  - removed per-call `tryNeighbor` closure allocation while preserving bounds/propagation behavior.
- Optimized rebuild/apply hot paths in `src/render/ChunkRenderer.lua`:
  - `rebuildDirty` now reuses persistent deferred-entry storage (`_deferredEntries`) instead of allocating a new table each call.
  - removed per-call local helper closures in `rebuildDirty` and `_applyThreadedResults` by inlining logic / using a renderer method.
- Optimized dirty-drain path in `src/world/ChunkWorld.lua`:
  - `drainDirtyChunkKeys(out)` now clears `self._dirty` in place while draining keys.
  - removed per-call `self._dirty = {}` table swap allocation.

### Streaming Spike Budget Tuning
- Tuned streaming/dispatch budgets in `src/constants.lua` to reduce 30-50ms chunk-load spikes:
  - `Constants.THREAD_MESH.maxInFlight`: `4` -> `2`
  - `Constants.REBUILD.maxPerFrame`: `16` -> `10`
  - `Constants.REBUILD.maxMillisPerFrame`: `1.8` -> `1.2`
  - `Constants.LIGHTING.chunkEnsureOps`: `768` -> `384`

### Streaming Spike Guardrails + Thread Stage Telemetry
- Added per-frame threaded-dispatch guardrails in `src/render/ChunkRenderer.lua`:
  - caps costly pre-dispatch prep work via `THREAD_MESH.maxQueuePrepPerFrame` and `THREAD_MESH.maxQueuePrepMillis`.
  - caps threaded mesh-apply burst size via `THREAD_MESH.maxApplyResultsPerFrame`.
- Added thread-stage frame metrics in `ChunkRenderer` (`getThreadingFrameStats`):
  - prep attempts, prep ms, prep deferrals, apply count, apply ms.
- Wired new thread-stage perf telemetry into HUD via `src/game/GameState.lua` and `src/ui/HUD.lua`:
  - new perf line: `Thread: Prep ... | Apply ...`.
- Added default tuning fields in `src/constants.lua`:
  - `THREAD_MESH.maxQueuePrepPerFrame = 1`
  - `THREAD_MESH.maxQueuePrepMillis = 0.8`
  - `THREAD_MESH.maxApplyResultsPerFrame = 1`

### Stage Timing Instrumentation + One-Pass Skylight A/B
- Added update/draw stage timing instrumentation in `src/game/GameState.lua`:
  - update stages: `updateTotal`, `updateSim`, `updateLight`, `updateRebuild`.
  - draw stages: `drawWorld`, `drawRenderer`.
  - each stage now tracks current ms + `Worst(1s)` style rolling max.
- Added skyline pass telemetry:
  - `GameState` now tracks `skyLightPasses` used in the frame.
- Added HUD diagnostics in `src/ui/HUD.lua`:
  - `StageU` and `StageD` lines showing per-stage frame ms + `Worst(1s)` plus sky-light pass count.
- Added temporary A/B cap in `src/constants.lua`:
  - `Constants.LIGHTING.maxPassesPerFrame = 1` to force single-pass `updateSkyLight` per frame while profiling spike sources.

### Perf HUD Overflow/Layout Fix
- Updated perf/debug panel layout in `src/ui/HUD.lua` to keep diagnostics visible with expanded stage/thread metrics:
  - widened panel in perf mode and allowed slight extra width when line count is high.
  - switched perf text rendering to explicit newline-only layout (disabled auto wrap) so panel height matches actual displayed lines.
  - added dynamic text-scale/panel-height fitting with top anchor + bottom clamp so the panel stays on-screen.

### Pass 1: Lighting Queue Guardrails + Deep Spike Telemetry
- Added queue stale-scan guardrail in `src/world/lighting/FloodfillLighting.lua`:
  - new `Constants.LIGHTING.dequeueScanLimitPerCall` (default `512`) bounds dequeue scanning per call for sky column/dark/flood queues.
  - when a per-call scan cap is reached, `updateSkyLight` now exits the current pass early and continues in later frames.
- Tightened time-budget behavior for lighting loops:
  - `_processRegionTasks(...)` and `updateSkyLight(...)` now enforce time budget checks without requiring at least one processed op first.
- Added floodfill sub-stage perf counters in `FloodfillLighting`:
  - per-pass totals for `updateSkyLight` ms, region-strip ms, column/dark/flood op counts.
  - queue stale-skip counts and scan-cap-hit counts for column/dark/flood dequeues.
- Added threaded prep micro-breakdown telemetry in `src/render/ChunkRenderer.lua`:
  - per-frame prep slices: ensure lighting, block halo fill, skylight halo fill, halo blob pack, worker push.
- Wired new telemetry into HUD via `src/game/GameState.lua` and `src/ui/HUD.lua`:
  - `PrepMs: ...` line for threaded prep breakdown.
  - `LPerf: ...` and `LSkip: ...` lines for floodfill queue behavior and op distribution.

### Pass 2: Incremental Sky-Column Solve + Per-Op Max Timings
- Added incremental sky-column recompute path in `src/world/lighting/FloodfillLighting.lua`:
  - queued vertical sky-column work is now processed in slices (`columnRecomputeRowsPerSlice`, `columnRecomputeSliceMillis`) with continuation state per column.
  - partial columns are re-enqueued so one large column no longer needs to complete in a single light op.
- Added new tuning knobs in `src/constants.lua`:
  - `Constants.LIGHTING.columnRecomputeRowsPerSlice = 8`
  - `Constants.LIGHTING.columnRecomputeSliceMillis = 0.20`
- Added pass-level max-op timing telemetry for floodfill update:
  - max per-op ms for column/dark/flood propagation plus partial-column op count.
- Wired new metrics through `ChunkWorld` -> `GameState` -> HUD:
  - new HUD line `LMax: C ... D ... F ... Partial ...`.
- Added queue-progress hygiene:
  - column continuation state is now cleared when region/column readiness is invalidated (prepare/rebuild/prune/remove paths).

### Pass 3: Floodfill Worst(1s) Telemetry + Hard Flood Op Cap
- Added rolling `Worst(1s)` tracking in `src/world/lighting/FloodfillLighting.lua` for:
  - `LPerf` update/region ms.
  - `LMax` per-op max column/dark/flood ms.
  - partial-column op count.
- Added hard flood-op guardrail:
  - new `Constants.LIGHTING.floodOpsCapPerPass` (default `32`) caps flood propagation ops per `updateSkyLight` pass.
  - added `lightFloodCapHits` telemetry so HUD shows when this cap was the stopping reason.
- Wired new perf fields through `src/world/ChunkWorld.lua` and `src/game/GameState.lua` into `src/ui/HUD.lua`:
  - `LPerf` now shows current + `Worst(1s)` for update/region timings.
  - `LMax` now shows current + `Worst(1s)` and partial op worst.
  - `LSkip` now includes flood hard-cap hit count (`FCap`).
- Mild lighting spike-budget tuning in `src/constants.lua`:
  - `urgentMillisPerFrame`: `1.75` -> `1.50`
  - `startupWarmupMillisPerFrame`: `4.0` -> `3.0`

### Pass 4: Local-Ready Chunk Gating + Main-vs-Ensure Telemetry Split
- Reworked chunk-lighting readiness in `src/world/lighting/FloodfillLighting.lua`:
  - `ensureSkyLightForChunk(...)` now gates chunk meshing on local halo-column readiness (`_areSkyHaloColumnsReady`) instead of requiring all global sky queues to drain.
  - added bounded per-call local catch-up passes (`chunkEnsurePasses`) to prioritize near-player chunk readiness.
  - startup/warmup now bypasses chunk-ensure downscaling so initial visible chunks do not stall behind aggressive ensure throttling.
- Adjusted skylight halo fallback behavior in `fillSkyLightHalo(...)`:
  - fallback-to-full-light now triggers only when the local halo column is not ready (not on unrelated global queue backlog).
- Split floodfill telemetry sources:
  - `updateSkyLight(...)` now accepts a source tag and tracks main frame lighting (`main`) separately from mesh-prep/ensure calls (`ensure`).
  - `LPerf/LMax/LSkip` now represent the main update-stage lighting work, preventing ensure-time calls from masking stage spikes.
  - added ensure-side counters (`LEns`) for calls, ms, and op mix.
- Wired new metrics through `src/world/ChunkWorld.lua`, `src/game/GameState.lua`, and `src/ui/HUD.lua`.
- Tuned startup/backlog knobs in `src/constants.lua`:
  - `floodOpsCapPerPass`: `32` -> `192`
  - `maxPassesPerFrame`: `1` -> `2`
  - `chunkEnsureSpikeHardScale`: `0.2` -> `0.35`
  - `urgentMillisPerFrame`: `1.50` -> `1.75`
  - `startupWarmupMillisPerFrame`: `3.0` -> `4.0`
  - added `chunkEnsurePasses = 2`

### Temporarily Disabled Sheep/Ghost Gameplay Presence
- Updated `src/constants.lua` mob tuning so `Constants.MOBS.maxSheep` and `Constants.MOBS.maxGhosts` are both `0`.
- This prevents Sheep/Ghost from appearing in-game while keeping `src/mobs/MobSystem.lua` and related combat systems intact for future re-enable.
- Updated `README.md` feature/control text to reflect the temporary gameplay disablement.

## 2026-02-17

### Render Distance vs Simulation Distance Split
- Added explicit simulation-radius config field in `src/constants.lua` (`CULL.simulationRadiusChunks`).
- Kept simulation radius locked to 4 chunks in `src/game/GameState.lua` for now, independent from render-distance tuning.
- Stress-test preset: increased `CULL.drawRadiusChunks` from `4` to `16` while keeping simulation locked at `4`.
- Decoupled floodfill active-region pruning from render mesh-cache radius in `src/render/ChunkRenderer.lua`:
  - sky-light prune now uses simulation radius (`simulationRadiusChunks`) instead of mesh prune radius.
  - prevents floodfill active-region blowups when render radius is pushed very high.
- Added floodfill outside-region fast path in `src/world/lighting/FloodfillLighting.lua`:
  - chunks outside active simulation lighting region now solve halo columns without enqueueing flood/dark propagation.
  - avoids runaway urgent/region queue growth and late-session lighting degradation under high render-distance stress.
- Updated far-distance floodfill fallback in `src/world/lighting/FloodfillLighting.lua`:
  - chunks outside active simulation lighting region now skip sky-column solving entirely.
  - outside-sim chunk halos render with full skylight (no shadows) for a smoother visual transition into in-range floodfill lighting.
  - removes remaining far-region column-solve cost during high render-distance stress sessions.
- Prioritized floodfill stability over interim vertical fallback in `src/world/lighting/FloodfillLighting.lua`:
  - `ensureSkyLightForChunk(...)` now treats any pending sky queue work (columns/dark/flood) as not-ready and defers chunk meshing until queues drain.
  - `fillSkyLightHalo(...)` now uses temporary full-skylight fallback while sky queues are backlogged or halo columns are not ready, avoiding dark vertical-style pop-in.
- Added runtime lighting-priority throttling in `src/game/GameState.lua`:
  - when lighting backlog exists, game now runs an extra `updateSkyLight()` pass before meshing.
  - chunk rebuild budgets are temporarily reduced while backlog is present (stronger reduction for urgent lighting queues), so near-player lighting catch-up wins over mesh throughput.
- Added lighting-backlog introspection plumbing:
  - `ChunkWorld:hasUrgentSkyLightWork()` and `ChunkWorld:hasSkyLightWork()` wrappers.
  - `FloodfillLighting:hasUrgentSkyWork()` / `hasSkyWork()` implementations.
  - no-op compatibility stubs in `VerticalLighting`.
- Updated leaf visuals/material in `src/constants.lua`, `src/render/ChunkRenderer.lua`, and `src/render/mesher_thread.lua`:
  - leaves now render as fully opaque blocks (`opaque = true`, `alpha = 1`).
  - added deterministic per-block leaf tint variation during meshing (main-thread and threaded paths) so canopies are not flat single-color.
  - follow-up perf fix: leaf tint variation now uses coarse canopy cells (x/z quantized) to preserve greedy face merging and avoid heavy mesh-fragmentation spikes.
  - removed leaf tint variation entirely and restored uniform leaf coloring to keep canopy visuals consistent.
- Adjusted water lighting behavior in `src/constants.lua`:
  - water `lightOpacity` changed from `1` to `0` so water no longer attenuates skylight/casts terrain shadowing.
  - intended to remove inconsistent underwater dark patching on sand/terrain while floodfill is active.
- Wired simulation chunk window into mob ticking in `src/mobs/MobSystem.lua`:
  - `MobSystem:update(...)` now receives player chunk center + simulation radius.
  - mob AI/attacks/movement are processed only for mobs inside the simulation chunk window.
  - out-of-simulation mobs remain present but effectively frozen until they re-enter simulation range.
- Added HUD distance telemetry in `src/ui/HUD.lua` (`Distance: Render <n> | Sim <n>`) for quick runtime verification.

### Bag Menu + Inventory Flow Upgrade
- Expanded inventory model in `src/inventory.lua`:
  - split inventory capacity into hotbar + storage (`hotbarCount` + `slotCount`).
  - hotbar selection/cycling now stays constrained to hotbar slots.
  - added full-stack bag interactions (`interactSlot`) for pick/place/merge/swap behavior.
  - added held-stack handling (`getHeldStack`, `stowHeldStack`) so moving stacks is loss-safe when closing UI/saving.
- Added bag-mode input behavior in `src/input/Input.lua`:
  - `Tab` now toggles inventory bag mode instead of toggling mouse lock.
  - while bag is open, movement/look/break/place inputs are suspended.
  - added bag navigation + interaction intents (arrows/WASD + Enter/Space/left click).
- Wired bag runtime flow in `src/game/GameState.lua`:
  - explicit bag open/close state with cursor index tracking.
  - opening bag unlocks the mouse and routes input to inventory slot movement/interactions.
  - gameplay update loop pauses world/player interaction while bag is open.
  - save path now attempts to stow held stacks before serialization.
- Reworked HUD inventory rendering in `src/ui/HUD.lua`:
  - preserved existing gameplay hotbar presentation.
  - added a dedicated bag overlay showing storage grid + hotbar row with cursor highlight.
  - bag overlay supports full-stack pick/place feedback and held-stack text.
  - help/tip strings updated for bag controls.
- Updated docs and project notes:
  - control/feature updates in `README.md`.
  - pointer-lock/control note update in `AGENTS.md`.

### Perf Audit: Top 3 Hot-Path Fixes
- Optimized render culling/sorting path in `src/render/ChunkRenderer.lua`:
  - precomputes cull parameters once per draw call via a reusable cull-frame scratch table.
  - removes repeated per-entry cull config math and forward-vector normalization work.
  - unifies chunk sort key to one cached distance field.
  - adds `Constants.RENDER.sortOpaqueFrontToBack` (default `false`) to skip opaque sorting CPU cost unless explicitly enabled.
- Optimized thread halo payload packing/unpacking:
  - `ChunkRenderer:_packHaloBlob(...)` now uses an ffi `uint8_t` buffer + `ffi.string(...)` fast path before falling back to chunked `string.char(...)` packing.
  - `src/render/mesher_thread.lua` halo decode now first attempts direct blob pointer access (`getPointer` + ffi cast) to avoid per-byte Lua table decode when available.
- Reduced worker-side mesher allocations in `src/render/mesher_thread.lua`:
  - switched naive and greedy builders to reuse pooled vertex/index arrays across jobs.
  - removed inner emit closures in hot loops and inlined face emission branches.
  - trims pooled tails each build to keep returned counts and buffers accurate.

### Perf Audit: Items 4-8
- Optimized mob removal/census in `src/mobs/MobSystem.lua`:
  - replaced repeated `table.remove(...)` hot-loop paths with O(1) swap-remove helper (`_removeMobAt`).
  - added incremental sheep/ghost counters so spawn caps no longer require full list scans each AI step.
- Optimized mob simulation-window checks in `src/mobs/MobSystem.lua`:
  - precomputes simulation chunk/world bounds when the window updates.
  - runtime inside-window checks now use direct world-space bounds tests instead of per-mob chunk conversion math.
- Reduced per-frame HUD state allocation in `src/game/GameState.lua`:
  - draw path now reuses a persistent `_hudState` table instead of constructing a new large state table each frame.
  - added cached shader-status string builder (`_getShaderStatusText`) to avoid repeated format/allocation churn.
- Optimized raycast allocation path in `src/world/ChunkWorld.lua` and `src/interaction/Interaction.lua`:
  - moved ray `intBound` helper out of `ChunkWorld:raycast(...)` to avoid per-call closure creation.
  - `raycast` now supports writing into a caller-provided hit table; interaction system now reuses a persistent hit scratch table.
- Optimized player collision hot path in `src/player.lua`:
  - `Player:_collides(...)` now performs inline block-collidable checks (using cached block info/getter locals) instead of calling `world:isSolidAt(...)` for every sampled voxel.

### Perf Audit: Items 9-13
- Added mob ground-height caching with edit-aware invalidation in `src/mobs/MobSystem.lua` and `src/world/ChunkWorld.lua`:
  - mob ground probes now cache per world column.
  - cache invalidation keys off new monotonic `ChunkWorld` edit revision (`getEditRevision`), incremented on effective block changes.
- Optimized ghost AI math in `src/mobs/MobSystem.lua`:
  - hoisted player camera position fetch to once per AI step and passed it into ghost updates.
  - changed ghost attack range check from sqrt distance to squared-distance comparison.
- Added interior fast path for chunk halo fill in `src/world/ChunkWorld.lua`:
  - `fillBlockHalo(...)` now prefetches neighboring chunk edit/feature refs for non-boundary chunks.
  - avoids per-voxel boundary tests and reduces hot-loop lookup overhead on the common interior case.
- Reduced floodfill queue-clear spikes in `src/world/lighting/FloodfillLighting.lua`:
  - replaced large clear loops with table swaps for sky-column/flood/dark queues and set maps.
  - avoids O(n) key clearing passes during queue reset points.
- Optimized axis movement collision stepping in `src/player.lua`:
  - `_moveAxis(...)` now uses a coarser step pass with micro-step fallback only when blocked.
  - reduces collision-check count during free movement while preserving blocked-axis resolution behavior.

## 2026-02-16

### Frame Spike Tuning Pass (Thread/Apply/Rebuild Budgets)
- Tightened default streaming budgets in `src/constants.lua` to reduce rare long-frame spikes:
  - `THREAD_MESH.maxInFlight`: `0` (auto) -> `4`
  - `THREAD_MESH.maxApplyMillis`: `1.0` -> `0.6`
  - `REBUILD.maxPerFrame`: `24` -> `16`
  - `REBUILD.maxMillisPerFrame`: `2.5` -> `1.8`
- Goal: improve frame-time stability by reducing main-thread mesh-apply and rebuild burst size at the cost of slower dirty-queue drain during heavy streaming.

### Perf HUD Core Utilization Readout
- Added renderer threading perf stats in `src/render/ChunkRenderer.lua` (`getThreadingPerfStats`):
  - logical core count detected at runtime.
  - active mesh worker count and target worker count.
  - active meshing thread count (`workers + main thread`) and fallback/threaded state flag.
- Wired threading stats through `src/game/GameState.lua` into HUD draw state.
- Updated F3/perf text in `src/ui/HUD.lua`:
  - new line now shows `CPU: meshing threads <active>/<logical> logical` plus `Mesh workers <active>/<target>`.
  - appends `(fallback)` when threaded pool is not active.

### Mesh Worker Pool (Auto Core Scaling + Fallback)
- Upgraded meshing threading in `src/render/ChunkRenderer.lua` from a single worker to a worker pool:
  - selects active worker count automatically from logical CPU cores (`cores - 1`) with configurable cap.
  - dispatches mesh jobs round-robin across active workers.
  - drains results from all workers with existing main-thread apply time budget.
- Added graceful fallback behavior for limited hardware/runtime support:
  - if no background workers can be started (single-core auto mode, or thread API unavailable), threaded meshing is disabled cleanly and renderer uses synchronous rebuild path.
  - if worker startup/health fails at runtime, pool is torn down and renderer falls back to sync meshing safely.
- Added new thread-mesh tuning in `src/constants.lua`:
  - `THREAD_MESH.workerCount` (`0` = auto)
  - `THREAD_MESH.maxWorkers`
  - `THREAD_MESH.maxInFlight` (`0` = auto based on active worker count)
- Updated `README.md` feature list to document worker-pool scaling and fallback behavior.

### Mob Perf Guardrails + Autosave Disabled
- Tuned default mob pressure in `src/constants.lua`:
  - reduced `maxSheep`/`maxGhosts`.
  - slowed default sheep/ghost spawn intervals.
- Added fixed-tick mob AI in `src/mobs/MobSystem.lua`:
  - mob simulation now advances on `aiTickSeconds` (default `0.20`) instead of full per-frame updates.
  - capped catch-up work with `maxAiTicksPerFrame` to avoid AI bursts after long frames.
- Added chunk-backlog-aware mob throttling in `src/game/GameState.lua`:
  - reads renderer dirty queue size each frame.
  - temporarily skips mob AI updates when queue exceeds `Constants.MOBS.skipAiWhenDirtyQueueAbove`.
- Disabled autosave by default in `src/constants.lua` (`Constants.SAVE.enabled = false`) to remove periodic save spikes during current perf tuning.
- Updated `README.md` to reflect fixed-tick mob AI and autosave-disabled default state.

### Death + Respawn Loop (Health Zero Handling)
- Added death handling in `src/game/GameState.lua`:
  - when player health reaches `0`, gameplay immediately respawns player at world spawn.
  - player transform/velocity/look are reset for a stable respawn state.
  - if spawn position collides, respawn now probes upward for a safe standing height.
  - chunk-streaming hint state is reset so meshing priorities recover correctly after teleporting.
- Added respawn behavior in `src/player/PlayerStats.lua`:
  - new `isDead()` and `respawn()` helpers.
  - respawn restores full health and hunger.
  - added damage-immunity timer support in stats update/damage flow.
- Added post-respawn hostile cleanup in `src/mobs/MobSystem.lua`:
  - `onPlayerRespawn()` now clears active ghosts and resets ghost spawn timer.
  - prevents immediate re-death loops at spawn while preserving ambient sheep.
- Added new stats tuning in `src/constants.lua`:
  - `Constants.STATS.respawnInvulnerabilitySeconds` (default `2.0`).
- Updated `README.md` feature list to document death/respawn behavior and brief immunity window.

## 2026-02-15

### Mobs + Sword Combat Prototype
- Added lightweight mob system in `src/mobs/MobSystem.lua`:
  - passive `Sheep` spawning with simple wander behavior.
  - hostile `Ghost` spawning at night only, with chase + contact damage.
  - conservative spawn/despawn caps and distances for low baseline runtime cost.
- Wired mob runtime into `src/game/GameState.lua`:
  - mobs update every gameplay frame and draw in-world.
  - crosshair targeting now prefers mobs when in reach.
  - left-click now attacks targeted mobs before falling back to block breaking.
- Added starter combat/item constants in `src/constants.lua`:
  - `Constants.ITEM.SWORD` item id and metadata.
  - `Constants.COMBAT` damage values (hand vs sword).
  - `Constants.MOBS` spawn/AI tuning values.
- Updated `src/inventory.lua` defaults parsing so hotbar entries can set custom per-slot counts (used for one starter sword).
- Added damage/heal helpers in `src/player/PlayerStats.lua` and used them for ghost attacks.
- Updated docs in `README.md` for mob/combat controls and features.

### Survival Stats Scaffold (Health/Hunger + Persistence)
- Added `src/player/PlayerStats.lua`:
  - tracks `health`, `hunger`, `experience`, and `level` with configurable caps/start values.
  - runs per-frame hunger drain and hunger-threshold-gated health regeneration.
  - exposes `getState`/`applyState` for persistence and runtime wiring.
- Wired runtime stats usage in `src/game/GameState.lua`:
  - replaced temporary `ui*` HUD values with `PlayerStats` values.
  - updates stats each gameplay frame (`_updateGame`), while paused/menu remains frozen.
  - `SaveSystem:save(...)` now receives current stats state.
- Extended save format parsing/writing in `src/save/SaveSystem.lua`:
  - V2 saves now write a `stats` line before `edits`.
  - loader accepts optional `stats` line for backward compatibility with older V2 saves.
  - `SaveSystem:load(...)` now returns parsed stats state for session restore.
- Added new stats tuning block in `src/constants.lua`:
  - `Constants.STATS` controls caps, defaults, hunger drain rate, and regen behavior.
- Updated `README.md` feature list to document the new survival-stats scaffold and persistence.

### Survival HUD Visual Refresh (UI-Only)
- Reworked `src/ui/HUD.lua` from a text-only overlay into a stylized survival HUD pass:
  - custom crosshair with target-highlight tinting.
  - bottom hotbar panel with selected-slot glow, block swatches, and stack counts.
  - health/armor/hunger pip rows, XP bar, and status-effects panel.
  - target-name tooltip and polished save/help/tip panel styling.
- Preserved existing perf/debug metrics and `F3` behavior, but moved them into a cleaner utility panel while keeping readability-first formatting.
- Added temporary preview values in `src/game/GameState.lua` for health/armor/hunger/xp/effects so UI can be iterated independently before survival systems are wired.
- Follow-up tuning pass:
  - increased overall HUD apparent size for better readability in gameplay view.
  - removed armor row from the main survival HUD.
  - removed status-effects panel from gameplay HUD and dropped now-unused preview plumbing in `src/game/GameState.lua`.
  - spread the lower HUD farther across the screen and moved it closer to the bottom edge.
  - moved the lower gameplay HUD even closer to the screen bottom, and shifted the F3/perf panel much farther toward the top-left corner.
  - final tuning pass: applied another large downward shift for the main HUD and another large up-left shift for the F3/perf panel.
  - removed the XP bar from the gameplay HUD per scope reduction.

### Audit Hardening (Crash Path + Save Safety)
- Removed a renderer crash path in `src/render/ChunkRenderer.lua`:
  - synchronous mesh-apply failures no longer call `error(...)`.
  - rebuild now returns `false` so the chunk stays in deferred/retry flow instead of terminating the game.
- Hardened save persistence in `src/save/SaveSystem.lua`:
  - moved primary save path to `saves/world_v2.txt` to match `MC_SAVE_V2` format.
  - added temp + verification write flow using `saves/world_v2.tmp`.
  - added backup file support (`saves/world_v2.bak`) before overwriting an existing primary save.
  - load/peek now use fallback read order: primary -> backup -> legacy (`saves/world_v1.txt`).
  - delete now removes all related save artifacts (temp/backup/primary/legacy).
  - successful saves clean up legacy `world_v1.txt` after migration.

### World Gen Refresh (Seeded Terrain + Sand/Water)
- Replaced the flat-layer generator in `src/world/ChunkWorld.lua` with seeded height-based terrain:
  - deterministic value-noise/fBM sampling per world column using `WORLD_SEED`.
  - terrain now derives per-column surface height, beach classification, and subsurface depth (dirt/sand over stone).
  - added lazy per-column terrain caching (`_terrainColumnData`) to avoid recomputing noise every voxel lookup.
- Added sea-level water fill and beaches:
  - base terrain now emits sand near sea level and water for air gaps below sea level.
  - spawn now uses center-column terrain and spawns above the higher of surface/sea level.
- Updated feature generation for variable terrain:
  - tree placement now uses per-column terrain surface checks (grass-only, water-buffer aware), instead of fixed `grassY`.
- Added new world blocks in `src/constants.lua`:
  - `SAND`
  - `WATER`
- Added block-behavior flags to support non-collidable rendered water:
  - water uses `collidable = false` and `render = true`.
  - `ChunkWorld:isSolidAt(...)` now respects optional `collidable` override.
- Updated meshing/render rules for render-vs-collision separation:
  - `ChunkRenderer` and `mesher_thread` now honor optional `render` on block info so non-collidable blocks can still be meshed.
  - threaded block metadata now includes a `render` field.
- Updated starting hotbar and docs:
  - hotbar defaults now include sand and water.
  - `README.md` feature/block list now reflects seeded terrain + sand/water support.

### Floodfill Pass 4 (Incremental Strip Queue + Spike Guard + HUD Telemetry)
- Added incremental strip-task processing in `src/world/lighting/FloodfillLighting.lua`:
  - chunk-crossing region delta enqueue now schedules strip rows into a bounded per-frame task queue instead of immediately iterating all strip columns at crossing time.
  - ring-delta prune now schedules `skyColumnsReady` strip removals incrementally (chunk cache strip eviction remains immediate and small).
  - added reusable region-task pooling to reduce per-crossing temporary table churn and GC-induced hitch risk.
  - new tunables in `src/constants.lua`:
    - `regionStripOpsPerFrame`
    - `regionStripMillisPerFrame`
- Added frame-time spike guard for chunk-local ensure work:
  - `GameState` now forwards frame timing each update via `ChunkWorld:setFrameTiming(...)`.
  - `FloodfillLighting:ensureSkyLightForChunk(...)` now scales local ensure budgets down when frame time is high using:
    - `chunkEnsureSpikeSoftMs`, `chunkEnsureSpikeHardMs`
    - `chunkEnsureSpikeSoftScale`, `chunkEnsureSpikeHardScale`
- Added floodfill strip telemetry to HUD:
  - `FloodfillLighting:getPerfStats()` exposes strip ops processed in last lighting update, pending strip ops, and pending strip tasks.
  - `ChunkWorld:getLightingPerfStats()` forwards stats to `GameState`, and `HUD` now shows:
    - `LightQ: Strip <ops>  Pending <ops>  Tasks <n>`
    - optional `Ensure x<scale>` when chunk-ensure spike guard is actively downscaling.
- Added no-op compatibility methods for vertical backend:
  - `VerticalLighting:setFrameTiming(...)`
  - `VerticalLighting:getPerfStats()`

### Floodfill Pass 3 (Urgent Priority + Mesh Gating)
- Added urgent-priority queueing in `src/world/lighting/FloodfillLighting.lua`:
  - sky column, dark, and flood queues now support urgent insertion/promotion.
  - edit-triggered relight seeds now enqueue as urgent (`onOpacityChanged`), and urgency propagates through dark/flood steps.
- Added urgent-aware budget behavior:
  - `updateSkyLight(...)` now boosts to `urgentOpsPerFrame` / `urgentMillisPerFrame` while urgent work exists.
  - added new lighting tunables in `src/constants.lua`:
    - `urgentOpsPerFrame`, `urgentMillisPerFrame`
    - `chunkEnsureOps`, `chunkEnsureMillis`
- Added chunk-ready lighting gate + lower per-chunk ensure cost:
  - `ensureSkyLightForChunk(...)` now performs a small bounded local lighting catch-up and returns `false` while urgent work for that chunk area is still pending.
  - reduced default per-call ensure budget to avoid chunk-load spikes.
- Updated renderer rebuild flow in `src/render/ChunkRenderer.lua` to respect lighting readiness:
  - threaded rebuild enqueue now returns explicit states (`queued`, `defer`, `fallback`).
  - chunks that are not lighting-ready are deferred and requeued instead of immediately forcing a sync mesh build with stale vertical-only lighting.
  - sync rebuild path now also defers if lighting is not ready.

### Floodfill Pass 2 (Startup + Edit-Seeding Reliability)
- Added startup floodfill warmup in `src/world/lighting/FloodfillLighting.lua`:
  - lighting now starts with no active region and first prune enqueues initial region columns for relight.
  - warmup mode boosts lighting budget using `startupWarmupOpsPerFrame` / `startupWarmupMillisPerFrame` until queues drain.
- Added full edit-context lighting hook plumbing:
  - `ChunkWorld:_onSkyOpacityChanged(...)` now passes `x,y,z,cx,cy,cz,oldOpacity,newOpacity` to backends.
  - updated `VerticalLighting:onOpacityChanged(...)` signature for compatibility (no behavior change).
- Added explicit edit-neighborhood seed injection for floodfill:
  - new `_seedEditNeighborhood(...)` seeds flood or dark queues from edited voxel + 6-neighbor cells.
  - opacity decrease (opening) now seeds bright flood sources; opacity increase (closing) seeds dark removal sources.
  - this fixes side-wall/opening cases where vertical column values alone were not enough to trigger relight.
- Added runtime tuning knobs in `src/constants.lua`:
  - `editRelightRadiusBlocks`
  - `startupWarmupOpsPerFrame`
  - `startupWarmupMillisPerFrame`

### Floodfill Pass 1 Follow-up (Bounded Edit Propagation)
- Added optional local propagation bounds to `src/world/lighting/FloodfillLighting.lua` for edit-triggered relight work:
  - new helpers `_setSkyPropagationBounds(...)`, `_clearSkyPropagationBounds(...)`, `_isInsideSkyPropagationWorldXZ(...)`.
  - dark/flood propagation now honors these bounds during edit updates.
- `onOpacityChanged(...)` and `onBulkOpacityChanged(...)` now set a local relight window using `editRelightRadiusBlocks` (default 15) so updates do not flood across the whole active region.
- Non-edit paths now avoid accidentally inheriting edit bounds:
  - bounds clear on idle stage transition and movement-region delta queueing.
  - `fillSkyLightHalo(...)` temporarily lifts bounds for mesh-prep column readiness/drain, then restores prior edit bounds.

### Floodfill Pass 1 (Incremental Edit Relight)
- Reworked floodfill edit updates in `src/world/lighting/FloodfillLighting.lua` to avoid reset-to-vertical behavior on block opacity changes.
- Added a dedicated darkening queue (`skyDarkQueue`) and dark propagation pass:
  - column recompute now enqueues both decrease and increase deltas (dark + flood), instead of flood-only growth.
  - `updateSkyLight(...)` now processes `vertical -> dark -> flood` work under existing per-frame budgets.
- Removed clear-and-reset edit relight path:
  - single-block `onOpacityChanged(...)` now enqueues only the changed column for recompute.
  - bulk-opacity updates now enqueue bounded columns without clearing old skylight state or resetting queues.
- Vertical-stage relight from edit scheduling now stays non-dirty; dirty remesh signaling is driven by actual flood/dark light changes.

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

## 2026-02-15

### Frametime Spike Mitigation Pass (Renderer + Floodfill)
- Added explicit mesh lifetime management in `src/render/ChunkRenderer.lua`:
  - Release old chunk meshes when a mesh entry is replaced.
  - Release meshes when chunks are evicted by mesh-cache pruning.
  - Release all cached chunk meshes during renderer shutdown.
  - Release newly-created meshes on indexed-mesh setup failures to avoid leaking partial mesh objects.
- Reduced dirty-queue churn when threaded meshing is saturated:
  - `ChunkRenderer:rebuildDirty` now exits its pop loop early when all thread slots are full, avoiding repeated pop/defer/requeue work in the same frame.
- Tuned chunk-ensure lighting flow for streaming:
  - `FloodfillLighting:ensureSkyLightForChunk` performs bounded local catch-up (`chunkEnsureOps`/`chunkEnsureMillis`).
  - Chunk meshing still defers when urgent lighting work remains, avoiding repeated not-ready rebuild attempts.
- Reworked floodfill region maintenance to avoid full active-area scans on normal chunk crossings:
  - Added ring-delta column queueing for newly entered regions.
  - Added strip-based pruning for `skyLightChunks` and `skyColumnsReady` when moving by one chunk.
  - Retained full-scan fallback only for large jumps/radius changes.

### Follow-up Tuning (Regression Guard)
- Adjusted runtime behavior after streaming-regression testing:
  - Added `Constants.REBUILD.releaseMeshesRuntime = false` default so mesh releases are deferred during gameplay (still force-released on shutdown).
  - Restored bounded local chunk-ensure lighting catch-up in `FloodfillLighting:ensureSkyLightForChunk(...)` to reduce urgent-work starvation under sustained chunk streaming.

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
