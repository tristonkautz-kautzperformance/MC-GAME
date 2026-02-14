# LOVR Voxel Clone

Simple Minecraft-style prototype in Lua using LOVR.

## Features

- Fixed voxel world size: `1280 x 1280 x 64` (`X x Z x Y`)
- Block types: grass, dirt, stone, bedrock, wood (tree), leaf
- First-person character controller:
  - WASD movement
  - Mouse look
  - Jump + gravity
  - Collision with blocks
- Block interaction:
  - Break blocks (except bedrock)
  - Place selected block from inventory
- Inventory / hotbar UI:
  - 8 slots
  - Number keys and mouse wheel selection
- Day/night cycle with animated sky color and sun/moon
- Procedural base terrain + sparse edit/feature overlays (no eager per-voxel base storage)
- Chunked `16 x 16 x 16` mesh-based rendering + conservative culling + mesh cache pruning
- Main menu + pause menu with keyboard navigation
- Single-slot save/load for world block edits (diff-based)
- Continue restores player position/look, inventory/hotbar state, and time-of-day
- Autosave every 60 seconds during active gameplay with HUD/menu status text
- Main menu save metadata (availability, last saved time, edit count, version health)

## Controls

- `WASD`: move
- `Mouse`: look (when captured)
- `Space`: jump
- `Left Mouse`: click to capture mouse, then break block
- `Right Mouse`: place selected block (when captured)
- `Mouse Wheel`: cycle hotbar
- `1-8`: select hotbar slot
- `Tab`: toggle mouse capture
- `F1`: toggle help text
- `F3`: toggle performance overlay (FPS + frame/chunk stats)
- `F11`: toggle fullscreen (restarts app)
- `Esc`: unlock mouse if captured; if already unlocked, open pause menu
- `Up/Down` or `W/S`: menu navigation
- `Enter`: menu select / confirm

Quit and save:
- Use pause menu `Save` to save without exiting.
- Autosave runs every 60 seconds while actively playing (not paused/menu).
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
