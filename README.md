# LOVR Voxel Clone

Simple Minecraft-style prototype in Lua using LOVR.

## Features

- Fixed voxel world size: `1280 x 1280 x 64` (`X x Z x Y`)
- Block types: grass, dirt, stone, sand, water, bedrock, wood (tree), leaf
  - Leaf rendering: opaque leaves with uniform color
- First-person character controller:
  - WASD movement
  - Mouse look
  - Jump + gravity
  - Collision with blocks
- Block interaction:
  - Break blocks (except bedrock)
  - Place selected block from inventory
- Inventory / hotbar UI:
  - 8-slot hotbar + bag storage
  - Number keys and mouse wheel selection
  - Tab bag menu with full-stack move/swap across storage + hotbar
- Basic survival stats scaffold:
  - Health and hunger values feed the HUD
  - Hunger drains over time
  - Health regeneration is enabled only above a hunger threshold
  - On death (health reaches 0), player respawns at world spawn with full health/hunger
  - Respawn grants a short damage-immunity window to avoid instant death loops
- Lightweight mobs:
  - Sheep (passive ambient mobs)
  - Ghost (hostile mob) spawns at night only and damages player on contact
  - Spawn caps are intentionally low for early perf safety
  - Mob AI runs on a fixed tick and is temporarily skipped during heavy chunk-rebuild backlog
- Combat starter:
  - Added Sword item to hotbar
  - Left click attacks targeted mobs; sword deals higher damage than hand hits
- Day/night cycle with animated sky color and sun/moon
- Seeded procedural terrain (height + beaches + sea level) with sparse edit/feature overlays (no eager per-voxel base storage)
- Chunked `16 x 16 x 16` mesh-based rendering + conservative culling + mesh cache pruning
- Render and simulation distances are now separated:
  - render distance controls chunk meshing/draw culling.
  - simulation distance controls gameplay ticking (currently locked to 4 chunks).
  - floodfill lighting active-region tracking follows simulation radius, not render radius.
  - chunks outside simulation distance render with full skylight (no far-distance shadow solve).
  - during in-range floodfill backlog, meshing is temporarily throttled and chunks use a no-shadow fallback until lighting catches up.
- Threaded chunk meshing worker pool:
  - Auto-scales worker count from CPU logical cores (`cores - 1`, clamped)
  - Gracefully falls back to synchronous meshing if thread APIs/hardware support is unavailable
- Main menu + pause menu with keyboard navigation
- Single-slot save/load for world block edits (diff-based)
- Continue restores player position/look, inventory/hotbar state, time-of-day, and survival stats
- Autosave system exists but is currently disabled by default for perf testing
- Main menu save metadata (availability, last saved time, edit count, version health)

## Controls

- `WASD`: move
- `Mouse`: look (when captured)
- `Space`: jump
- `Left Mouse`: click to capture mouse, then attack mob / break block
- `Right Mouse`: place selected block (when captured)
- `Mouse Wheel`: cycle hotbar
- `1-8`: select hotbar slot
- `Tab`: open/close bag menu (restores previous capture state when closed)
- `Arrows` / `WASD` (bag open): move bag cursor
- `Enter` / `Space` / `Left Mouse` (bag open): pick/place full stack
- `F1`: toggle help text
- `F3`: toggle performance overlay (FPS + frame/chunk stats)
- `F11`: toggle fullscreen (restarts app)
- `Esc`: close bag if open; otherwise unlock mouse if captured; if already unlocked, open pause menu
- `Up/Down` or `W/S`: menu navigation
- `Enter`: menu select / confirm

Quit and save:
- Use pause menu `Save` to save without exiting.
- Autosave is currently disabled by default (`Constants.SAVE.enabled = false`).
- In pause menu, `Quit` saves and returns to the main menu.
- In main menu, `Quit` exits the game.
- Window close/Alt+F4 also saves world edits.
- In main menu, `New Game` requires pressing `Enter` twice when a save already exists.

## Run

From this folder:

```bash
lovr .
```

If your `lovr` executable is not on PATH, run it with the full path to your LOVR install.

### Relative mouse / pointer lock

This project vendors `lovr-mouse.lua` (from the `bjornbytes/lovr-mouse` project) to enable true FPS-style relative mouse mode on LOVR 0.18.
License and attribution details are in `THIRD_PARTY_NOTICES.md`.

### Fullscreen

Fullscreen state is persisted in a local `.fullscreen` file in the project root and applied on startup.
