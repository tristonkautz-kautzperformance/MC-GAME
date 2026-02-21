# LOVR Voxel Clone

Simple Minecraft-style prototype in Lua using LOVR.

## Features

- Fixed voxel world size: `1280 x 1280 x 96` (`X x Z x Y`)
- Block types: grass, dirt, stone, sand, water, bedrock, wood (tree), leaf, workbench
  - Leaf rendering: opaque leaves with uniform color
- First-person character controller:
  - WASD movement
  - Mouse look
  - Jump + gravity
  - Collision with blocks
- Survival baseline loop:
  - Start with an empty inventory
  - Find static on-ground item pickups (stick, flint, berry) and pick them up with `RMB` (no vacuum)
  - Craft in bag (2 ingredient slots) and in workbench (5x5 ingredient slots)
  - Hold `LMB` to break blocks over time with crack overlay feedback
  - Breaking blocks drops world item entities (not auto-added to inventory)
  - Wood requires an axe and stone requires a pickaxe (hands cannot break those)
  - Flint/stone tools are non-stackable and lose durability on successful block breaks
  - Berries restore hunger when used with `RMB`
- Inventory / hotbar UI:
  - 8-slot hotbar + bag storage
  - Number keys and mouse wheel selection
  - Bag/workbench now open as a dedicated pause-style screen menu (world simulation pauses while open)
  - Mouse-driven slot interactions (LMB move/swap, RMB split/place-one)
  - Clicking outside the bag/workbench UI drops the held stack into the world
- Workbench interaction:
  - Craft a workbench from wood in the bag crafting UI
  - `RMB` on placed workbench opens workbench crafting UI
  - `Shift+RMB` on a workbench bypasses open behavior and performs normal placement logic
- Basic survival stats scaffold:
  - Health and hunger values feed the HUD
  - Hunger drains over time
  - Health regeneration is enabled only above a hunger threshold
  - On death (health reaches 0), player respawns at world spawn with full health/hunger
  - Respawn grants a short damage-immunity window to avoid instant death loops
- Lightweight mob systems (temporarily disabled in gameplay):
  - Sheep and Ghost implementations remain in code for future use
  - Default spawn caps are set to `0`, so no mobs spawn right now
  - Mob AI runs on a fixed tick and is temporarily skipped during heavy chunk-rebuild backlog
- Combat starter:
  - Left click attacks targeted mobs (when enabled)
  - Sword-type tools deal higher mob damage than hand hits
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
- `Left Mouse`: click to capture mouse, then hold to break blocks / attack mobs
- `Right Mouse` world priority (when captured):
  - pickup targeted world item entity
  - open targeted workbench (`Shift` overrides this open behavior)
  - consume selected berry
  - place selected placeable block/item
- `Mouse Wheel`: cycle hotbar
- `1-8`: select hotbar slot
- `Tab`: open/close bag menu (restores previous capture state when closed)
- `Left Mouse` (bag/workbench open): pick/place/merge/swap full stack
- `Right Mouse` (bag/workbench open): pick/place exactly 1 for stackable items
- `Shift+Left Mouse` on craft output: craft as many as possible
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
