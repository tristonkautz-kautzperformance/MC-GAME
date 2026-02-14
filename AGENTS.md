# AI Agent Instructions (Project)

This file describes the project's intent, tech stack, and engineering constraints for humans and AI agents working in this repo.

## Project Summary
- Goal: lightweight, performant "Alpha Minecraft survival" inspired voxel game in Lua/LOVR.
- V1 target: finite world (not infinite yet), ship a complete playable survival slice.
- Priority: performance and responsiveness (large voxel worlds get heavy fast).

## Tech Stack
- Language: Lua (LOVR runtime, LuaJIT expected).
- Engine/framework: LOVR `0.18`.
- Platform focus (V1): desktop keyboard + mouse (no VR required).

## Dependencies
- `lovr-mouse.lua` (vendored in repo root):
  - Purpose: true FPS-style relative mouse mode / pointer lock on LOVR 0.18.
  - Integrated in `src/game/GameState.lua` via `pcall(require, 'lovr-mouse')`.

## How To Run
- From repo root: `lovr .`
- Pointer lock:
  - Click to capture mouse.
  - `Tab` toggles lock.
  - `Esc` unlocks mouse if locked; otherwise opens the pause menu.

## Current Code Layout
- `main.lua`: LOVR lifecycle callback forwarding only.
- `conf.lua`: desktop-first configuration (headset disabled).
- `src/game/GameState.lua`: game wiring and per-frame orchestration.
- `src/constants.lua`: world sizes, block IDs, colors, tuning constants.
- `src/world.lua`: world module alias (currently chunked world).
- `src/world/ChunkWorld.lua`: chunked world storage, generation, raycast, bounds.
- `src/world/Chunk.lua`: per-chunk block storage.
- `src/render/ChunkRenderer.lua`: chunk meshing + culling + draw.
- `src/player.lua`: FPS controller, collision, camera yaw/pitch.
- `src/inventory.lua`: hotbar/inventory state.
- `src/input/MouseLock.lua`: pointer-lock state and lock/unlock behavior.
- `src/input/Input.lua`: callback-to-intent input processing.
- `src/ui/HUD.lua`: HUD rendering and inventory text.
- `src/sky/Sky.lua`: day/night timing, background color, sun/moon draw.
- `src/interaction/Interaction.lua`: target selection and break/place interactions.
- Docs:
  - `README.md`: run + controls.
  - `GAME_CONCEPT.md`: design outline + milestones.
  - `DEVLOG.md`: chronological progress notes.
  - `Codex_Instructions`: current engineering task spec for Codex.

## Engineering Guidelines
- Performance-first for voxels:
  - Use chunk meshes, not per-block draw calls.
  - Rebuild meshes only for dirty chunks; avoid spikes (budget rebuild work).
  - Separate opaque vs translucent (leaves) meshes.
  - Prefer conservative culling (avoid visible popping).
- Keep frame allocations low:
  - Avoid creating lots of temporary tables per-frame.
  - Reuse scratch buffers where it matters (meshing/culling).
- Keep systems simple:
  - Prefer a few robust mechanics over many half-finished features.
  - Alpha-feel > strict feature parity with Minecraft.

## Input and Camera Rules
- Camera orientation is yaw/pitch only (no roll).
- Mouse look must be relative-mode while captured.
- Do not regress pointer lock; use `lovr-mouse.lua` rather than OS cursor hacks.

## World Rules (V1)
- Finite world bounds should be explicit and enforced.
- Bedrock is unbreakable.
- Block edits should mark appropriate chunks dirty (including neighbors on boundaries).

## When Changing Files
- Keep files ASCII when practical.
- Update `DEVLOG.md` for meaningful changes and `README.md` for control changes.
