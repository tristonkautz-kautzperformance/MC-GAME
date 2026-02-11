# Dev Log

## 2026-02-11

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
