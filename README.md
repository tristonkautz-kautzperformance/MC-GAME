# LOVR Voxel Clone

Simple Minecraft-style prototype in Lua using LOVR.

## Features

- Fixed voxel world size: `32 x 32 x 64` (`X x Z x Y`)
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
- Chunked `16 x 16 x 16` mesh-based rendering + conservative culling

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
- `F3`: toggle performance overlay (FPS + pass stats)
- `F11`: toggle fullscreen (restarts app)
- `Esc`: unlock mouse if captured, otherwise quit

## Run

From this folder:

```bash
lovr .
```

If your `lovr` executable is not on PATH, run it with the full path to your LOVR install.

### Relative mouse / pointer lock

This project vendors `lovr-mouse.lua` (from the `bjornbytes/lovr-mouse` project) to enable true FPS-style relative mouse mode on LOVR 0.18.

### Fullscreen

Fullscreen state is persisted in a local `.fullscreen` file in the project root and applied on startup.
