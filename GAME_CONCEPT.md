# Game Concept (V1)

Goal: recreate the feel of Alpha Minecraft survival in Lua/LOVR while staying lightweight and performant.

## Pillars
- Player actions and mechanics: movement, interaction, inventory, basic survival loop.
- World generation: finite bounded world, readable terrain, simple trees.
- Performance: chunking + meshing + culling to keep frame time stable.

## Target Experience
- Fast load into a small world with clear day/night lighting.
- Walk, jump, mine blocks, place blocks, build simple structures.
- Simple hotbar/inventory management.

## V1 Scope (Finite World)
- Fixed world bounds (not infinite yet).
- World edits persist during session (save/load later milestone).
- No mobs required for V1.

## Milestones
1. MVP Sandbox: move, collide, break/place, UI, day/night.
2. Performance Foundation: chunk storage + chunk meshes.
3. Performance Polish: culling + greedy meshing + rebuild budget.
4. Persistence: save/load chunk diffs.
5. Survival Loop: minimal progression (optional hunger/health) + crafting (optional).
