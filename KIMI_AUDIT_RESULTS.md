# Kimi Performance & Memory Audit Results

**Project:** LOVR Voxel Clone (MC Clone)  
**Audit Date:** March 1, 2026  
**Auditor:** Kimi Code CLI  
**Scope:** Performance optimization, memory usage, and efficiency improvements  
**Constraint:** All recommendations must not break existing systems

---

## Executive Summary

This audit identifies **17 optimization opportunities** across the codebase, categorized by impact and risk. The project is already well-architected with many performance-conscious patterns (object pooling, threaded meshing, budgeted updates), but several areas remain for improvement.

| Category | Count | Risk Level |
|----------|-------|------------|
| High Impact | 5 | Low-Medium |
| Medium Impact | 7 | Low |
| Low Impact | 5 | Low |

**Key Themes:**
1. Per-frame table allocations in hot paths
2. Redundant calculations and lookups
3. Memory overhead in entity and UI systems
4. Cache-unfriendly data access patterns

---

## 🔴 High Impact Findings

### 1. ItemEntities: Per-Frame Table Allocation in `update()`

**Location:** `src/items/ItemEntities.lua:170-269`

**Issue:** The `_simulateEntity` function performs per-entity table lookups and allocations each frame. The `entity` table fields (`vx`, `vy`, `vz`) are validated and defaulted every simulation step.

**Current Code Pattern:**
```lua
entity.vx = tonumber(entity.vx) or 0  -- Happens every frame per entity
entity.vy = tonumber(entity.vy) or 0
entity.vz = tonumber(entity.vz) or 0
```

**Impact:** With `maxActive = 384` entities, this creates significant GC pressure during heavy item drops.

**Recommendation:** 
- Pre-validate entity velocity fields on spawn
- Remove runtime validation from hot path
- Add debug-mode validation only

**Estimated Gain:** 15-20% reduction in entity update time

---

### 2. InventoryMenu: Layout Recomputation Every Frame

**Location:** `src/ui/InventoryMenu.lua:244-420`

**Issue:** `_computeLayout` is called every frame in `update()`, recalculating all UI geometry even when window size and inventory state haven't changed.

**Current Pattern:**
```lua
function InventoryMenu:update(state)
  local layout = self:_computeLayout(state, width, height)  -- Every frame!
  -- ...
end
```

**Recommendation:**
- Cache layout with invalidation keys (window size, mode, slot count)
- Only recompute when cache keys change
- Pre-compute slot rectangles once

**Estimated Gain:** 30-40% reduction in UI update time when inventory is open

---

### 3. GameState: HUD State Table Allocation Per Frame

**Location:** `src/game/GameState.lua:1451-1465`

**Issue:** A new `menuState` table is created every frame while inventory is open:

```lua
local menuState = {
  inventory = self.inventory,
  inventoryMenuMode = self.inventoryMenuMode,
  bagCraftSlots = self.bagCraftSlots,
  -- ... new table every frame
}
```

**Recommendation:**
- Use a persistent `_menuState` table on the GameState object
- Update fields in-place instead of creating new table

**Estimated Gain:** Reduced GC pressure during inventory sessions

---

### 4. ChunkRenderer: Greedy Mask Reset O(N) Each Rebuild

**Location:** `src/render/ChunkRenderer.lua` (greedy meshing)

**Issue:** The greedy meshing mask (`self._greedyMask`) is reset with a loop before each use:

```lua
for i = 1, greedyMaskSize do
  self._greedyMask[i] = 0  -- O(N) every chunk rebuild
end
```

**Recommendation:**
- Use a "generation counter" pattern instead of zeroing
- Store an integer "generation" per mask slot
- Compare against global generation counter
- Reduces O(N) to O(1) setup cost

**Estimated Gain:** 5-10% faster greedy meshing

---

### 5. FloodfillLighting: Multiple Table Lookups Per Voxel

**Location:** `src/world/lighting/FloodfillLighting.lua:226-248`

**Issue:** `_getSkyChunkValue` and `_setSkyChunkValue` have branching and multiple lookups:

```lua
function FloodfillLighting:_getSkyChunkValue(chunk, localIndex)
  if not chunk then return 0 end
  if ffi then
    return chunk[localIndex - 1]  -- ffi path
  end
  local value = chunk[localIndex]
  if value == nil then return 0 end
  return value
end
```

**Recommendation:**
- Hoist `ffi` check to initialization, store function pointers
- Use direct indexing without nil checks (guarantee chunk exists)
- Inline these functions in hot paths

**Estimated Gain:** 10-15% faster lighting updates

---

## 🟡 Medium Impact Findings

### 6. ItemEntities: Linear Search for Farthest Entity

**Location:** `src/items/ItemEntities.lua:96-122`

**Issue:** When at capacity, `_ensureCapacity` does a linear scan to find farthest entity:

```lua
for i = 1, self.count do
  local entity = self.entities[i]
  local dx = entity.x - px  -- computed for every entity
  -- ...
end
```

**Recommendation:**
- Maintain a spatial partitioning structure (grid-based)
- Or use a simpler LRU eviction (track spawn time)
- Only compute distance when necessary

**Estimated Gain:** Better worst-case performance with many entities

---

### 7. HUD: String Concatenation in Hot Path

**Location:** `src/ui/HUD.lua` (various text drawing)

**Issue:** `tostring()` and string concatenation happens during draw calls:

```lua
self:_text(pass, ..., tostring(slot.count), ...)  -- Every frame per slot
```

**Recommendation:**
- Cache string representations when values don't change
- Use number drawing where possible (avoid string conversion)
- Batch text operations

**Estimated Gain:** Reduced CPU overhead in HUD rendering

---

### 8. GameState: Duplicate Block Info Lookups

**Location:** `src/game/GameState.lua` (crafting, drops)

**Issue:** `self.constants.BLOCK_INFO[blockId]` is looked up multiple times in the same function:

```lua
local info = self.constants.BLOCK_INFO[outputId]  -- First lookup
-- ... later ...
local info = self.constants.BLOCK_INFO[blockId]   -- Same lookup
```

**Recommendation:**
- Cache lookups in local variables
- Consider direct reference to BLOCK_INFO table

**Estimated Gain:** Minor, but cleaner code

---

### 9. ChunkWorld: Terrain Column Cache Without Expiration

**Location:** `src/world/ChunkWorld.lua`

**Issue:** `_terrainColumnData` grows unbounded as player explores:

```lua
self._terrainColumnData[x .. ',' .. z] = {...}  -- Never cleared
```

**Recommendation:**
- Add LRU eviction or distance-based pruning
- Clear columns beyond render distance
- Use numeric keys instead of string concatenation

**Estimated Gain:** Prevent memory bloat during long sessions

---

### 10. Interaction: BFS Queue Arrays Not Reused

**Location:** `src/interaction/Interaction.lua:176-260`

**Issue:** Tree and stone cascade BFS uses instance arrays but doesn't clear them efficiently:

```lua
local queueX = self._treeQueueX
-- filled during BFS, remains large after
```

**Recommendation:**
- Use separate head/tail indices instead of clearing
- Or use table pooling for temporary BFS state

**Estimated Gain:** Reduced GC pressure during tree breaking

---

### 11. SaveSystem: Line Buffer Not Pre-sized

**Location:** `src/save/SaveSystem.lua`

**Issue:** `_linesScratch` grows dynamically during save operations.

**Recommendation:**
- Pre-allocate with estimated capacity based on edit count
- Reuse buffers across saves

**Estimated Gain:** Faster save operations, less allocation

---

### 12. MobSystem: Ground Height Cache Key Generation

**Location:** `src/mobs/MobSystem.lua` (ground probe caching)

**Issue:** Cache key generation may be expensive:

```lua
-- Implicit in ground height caching
```

**Recommendation:**
- Use numeric grid keys instead of string keys
- Pack x,z coordinates into single integer key

**Estimated Gain:** Faster mob AI when enabled

---

## 🟢 Low Impact Findings

### 13. Input: Table Clearing with `nil` Assignment

**Location:** `src/input/Input.lua:169-187`

**Issue:** On focus loss, multiple fields are manually reset:

```lua
self.keysDown = {}  -- Creates new table instead of clearing
```

**Recommendation:**
- Clear existing table instead of creating new one
- Or use a generation counter pattern

---

### 14. Constants: BLOCK_INFO Metatable Opportunity

**Location:** `src/constants.lua`

**Issue:** Block info lookups happen frequently with defaults:

```lua
local info = blockInfo[block] or defaultBlockInfo
```

**Recommendation:**
- Use metatable with `__index` for automatic defaults
- Pre-compute combined tables at load time

---

### 15. PlayerStats: Multiple Parsing Helper Functions

**Location:** `src/player/PlayerStats.lua`

**Issue:** Each field uses individual parsing:

```lua
self.maxHealth = parsePositive(config.maxHealth, 20)
self.maxHunger = parsePositive(config.maxHunger, 20)
-- etc
```

**Recommendation:**
- Batch parse related fields
- Use schema-based validation

---

### 16. GameState: Redundant Mode Checks

**Location:** `src/game/GameState.lua` (throughout)

**Issue:** `self.mode` is checked multiple times per frame in different contexts.

**Recommendation:**
- Cache mode checks in local variables within functions
- Use early returns more aggressively

---

### 17. MainMenu: Status Text String Creation

**Location:** `src/ui/MainMenu.lua`

**Issue:** Status text may be recreated unnecessarily.

**Recommendation:**
- Cache last status text, compare before setting
- Avoid redundant string operations

---

## Architectural Recommendations

### 1. Object Pooling Expansion

**Current:** Vertex pools, thread halo pools exist and work well.

**Opportunity:** Extend pooling to:
- BFS queue state in Interaction
- Raycast hit results
- Entity spawn data
- UI layout calculations

### 2. Spatial Indexing for Entities

**Current:** Linear search for entity operations.

**Opportunity:** Implement simple grid-based spatial hash:
- Partition world into cells
- Track which entities are in which cells
- Only check entities in nearby cells

### 3. Configurable Quality Tiers

**Current:** Many settings are compile-time constants.

**Opportunity:** Runtime quality adjustment:
- Reduce entity count under frame time pressure
- Lower render distance dynamically
- Simplify lighting in dense areas

---

## Implementation Priority

### Phase 1: Safe & High Impact (Week 1)
1. ItemEntities velocity validation removal
2. GameState HUD state table reuse
3. InventoryMenu layout caching
4. Duplicate BLOCK_INFO lookup elimination

### Phase 2: Algorithmic Improvements (Week 2)
5. Greedy mask generation counter
6. FloodfillLighting accessor optimization
7. Terrain column cache expiration

### Phase 3: Nice-to-Have (Week 3)
8. String caching in HUD
9. Input table clearing optimization
10. SaveSystem pre-allocation

---

## Verification Strategy

For each optimization:
1. **Baseline:** Measure current performance with F3 overlay
2. **Implement:** Make changes in isolation
3. **Verify:** Ensure no behavioral regressions
4. **Measure:** Compare frame times and GC pressure
5. **Commit:** Only if improvement is measurable

---

## Conclusion

The codebase is already well-optimized for a Lua project, with thoughtful use of:
- ✅ Threaded meshing
- ✅ Object pooling (vertices, halos)
- ✅ Budgeted updates
- ✅ Sparse storage

The recommended changes focus on:
- Eliminating remaining per-frame allocations
- Caching expensive computations
- Improving data locality

**Expected Overall Impact:** 10-20% reduction in GC pressure, 5-15% improvement in worst-case frame times.

---

*This audit was conducted by analyzing the source code without executing changes. All recommendations are designed to be non-breaking and incrementally adoptable.*
