local Chunk = require 'src.world.Chunk'

local ChunkWorld = {}
ChunkWorld.__index = ChunkWorld
local EMPTY_DIRTY_KEYS = {}

local function clampInt(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function makeRng(seed)
  -- Deterministic LCG RNG (avoids depending on global math.randomseed state).
  local state = seed or 1
  return function()
    state = (1103515245 * state + 12345) % 2147483648
    return state / 2147483648
  end
end

function ChunkWorld.new(constants)
  local self = setmetatable({}, ChunkWorld)
  self.constants = constants
  self.sizeX = constants.WORLD_SIZE_X
  self.sizeY = constants.WORLD_SIZE_Y
  self.sizeZ = constants.WORLD_SIZE_Z
  self.chunkSize = constants.CHUNK_SIZE

  self.chunksX = constants.WORLD_CHUNKS_X
  self.chunksY = constants.WORLD_CHUNKS_Y
  self.chunksZ = constants.WORLD_CHUNKS_Z

  self._chunks = {}
  self._dirty = {}

  for cy = 1, self.chunksY do
    self._chunks[cy] = {}
    for cz = 1, self.chunksZ do
      self._chunks[cy][cz] = {}
      for cx = 1, self.chunksX do
        self._chunks[cy][cz][cx] = Chunk.new(self.chunkSize)
      end
    end
  end

  return self
end

function ChunkWorld:isInside(x, y, z)
  return x >= 1 and x <= self.sizeX and y >= 1 and y <= self.sizeY and z >= 1 and z <= self.sizeZ
end

function ChunkWorld:_toChunkCoords(x, y, z)
  local cx = math.floor((x - 1) / self.chunkSize) + 1
  local cy = math.floor((y - 1) / self.chunkSize) + 1
  local cz = math.floor((z - 1) / self.chunkSize) + 1

  local lx = (x - 1) % self.chunkSize + 1
  local ly = (y - 1) % self.chunkSize + 1
  local lz = (z - 1) % self.chunkSize + 1

  return cx, cy, cz, lx, ly, lz
end

function ChunkWorld:getChunk(cx, cy, cz)
  if cx < 1 or cx > self.chunksX or cy < 1 or cy > self.chunksY or cz < 1 or cz > self.chunksZ then
    return nil
  end
  return self._chunks[cy][cz][cx]
end

function ChunkWorld:_markDirty(cx, cy, cz)
  local chunk = self:getChunk(cx, cy, cz)
  if not chunk then
    return
  end

  chunk.dirty = true
  local key = cx .. ',' .. cy .. ',' .. cz
  self._dirty[key] = true
end

function ChunkWorld:_markDirtyAtWorld(x, y, z)
  local cx, cy, cz = self:_toChunkCoords(x, y, z)
  self:_markDirty(cx, cy, cz)
end

function ChunkWorld:_markNeighborsIfBoundary(cx, cy, cz, lx, ly, lz)
  local cs = self.chunkSize
  if lx == 1 then self:_markDirty(cx - 1, cy, cz) end
  if lx == cs then self:_markDirty(cx + 1, cy, cz) end
  if ly == 1 then self:_markDirty(cx, cy - 1, cz) end
  if ly == cs then self:_markDirty(cx, cy + 1, cz) end
  if lz == 1 then self:_markDirty(cx, cy, cz - 1) end
  if lz == cs then self:_markDirty(cx, cy, cz + 1) end
end

function ChunkWorld:get(x, y, z)
  if not self:isInside(x, y, z) then
    return self.constants.BLOCK.AIR
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  local chunk = self:getChunk(cx, cy, cz)
  return chunk and chunk:getLocal(lx, ly, lz) or self.constants.BLOCK.AIR
end

function ChunkWorld:set(x, y, z, value)
  if not self:isInside(x, y, z) then
    return false
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  local chunk = self:getChunk(cx, cy, cz)
  if not chunk then
    return false
  end

  chunk:setLocal(lx, ly, lz, value)
  self:_markDirty(cx, cy, cz)
  self:_markNeighborsIfBoundary(cx, cy, cz, lx, ly, lz)
  return true
end

function ChunkWorld:isSolidAt(x, y, z)
  local block = self:get(x, y, z)
  local info = self.constants.BLOCK_INFO[block]
  return info and info.solid or false
end

function ChunkWorld:isOpaque(block)
  local info = self.constants.BLOCK_INFO[block]
  return info and info.opaque or false
end

function ChunkWorld:isBreakable(block)
  local info = self.constants.BLOCK_INFO[block]
  return info and info.breakable or false
end

function ChunkWorld:isPlaceable(block)
  local info = self.constants.BLOCK_INFO[block]
  return info and info.placeable or false
end

function ChunkWorld:getSpawnPoint()
  -- Center-ish, a couple blocks above the ground.
  local x = math.floor(self.sizeX / 2) + 0.5
  local z = math.floor(self.sizeZ / 2) + 0.5
  local y = 10
  return x, y, z
end

function ChunkWorld:getDirtyChunkKeys()
  if next(self._dirty) == nil then
    return EMPTY_DIRTY_KEYS
  end

  local keys = {}
  local count = self:drainDirtyChunkKeys(keys)
  if count == 0 then
    return EMPTY_DIRTY_KEYS
  end
  return keys
end

function ChunkWorld:drainDirtyChunkKeys(out)
  if not out then
    return 0
  end

  if next(self._dirty) == nil then
    for i = #out, 1, -1 do
      out[i] = nil
    end
    return 0
  end

  local count = 0
  for key in pairs(self._dirty) do
    count = count + 1
    out[count] = key
  end

  for i = count + 1, #out do
    out[i] = nil
  end

  self._dirty = {}
  return count
end

function ChunkWorld:generate()
  local rng = makeRng(self.constants.WORLD_SEED or 1)
  local cs = self.chunkSize
  local sizeX = self.sizeX
  local sizeY = self.sizeY
  local sizeZ = self.sizeZ
  local blockIds = self.constants.BLOCK

  -- Simple flat world: bedrock base + stone + dirt + grass.
  local bedrockY = 1
  local stoneTop = 4
  local dirtTop = 6
  local grassY = 7
  local AIR = blockIds.AIR
  local BEDROCK = blockIds.BEDROCK
  local STONE = blockIds.STONE
  local DIRT = blockIds.DIRT
  local GRASS = blockIds.GRASS

  self._dirty = {}

  -- Base terrain fill: write directly into chunk storage (avoid per-voxel set/dirty bookkeeping).
  for cy = 1, self.chunksY do
    local originY = (cy - 1) * cs
    for cz = 1, self.chunksZ do
      local originZ = (cz - 1) * cs
      for cx = 1, self.chunksX do
        local originX = (cx - 1) * cs
        local chunk = self._chunks[cy][cz][cx]
        chunk.blocks = {}
        chunk.dirty = false

        for ly = 1, cs do
          local wy = originY + ly
          if wy > sizeY then break end

          local block = AIR
          if wy == bedrockY then
            block = BEDROCK
          elseif wy <= stoneTop then
            block = STONE
          elseif wy <= dirtTop then
            block = DIRT
          elseif wy == grassY then
            block = GRASS
          end

          if block ~= AIR then
            local yBase = (ly - 1) * cs * cs
            for lz = 1, cs do
              local wz = originZ + lz
              if wz > sizeZ then break end
              local zBase = yBase + (lz - 1) * cs
              for lx = 1, cs do
                local wx = originX + lx
                if wx > sizeX then break end
                chunk.blocks[zBase + lx] = block
              end
            end
          end
        end
      end
    end
  end

  -- Quick tree pass.
  local density = self.constants.TREE_DENSITY or 0
  for z = 2, self.sizeZ - 1 do
    for x = 2, self.sizeX - 1 do
      if rng() < density then
        -- Plant on grass.
        if self:get(x, grassY, z) == self.constants.BLOCK.GRASS then
          self:_placeTree(x, grassY + 1, z, rng)
        end
      end
    end
  end

  -- Mark everything dirty once at end (avoid rebuilding chunk-by-chunk during generation).
  for cy = 1, self.chunksY do
    for cz = 1, self.chunksZ do
      for cx = 1, self.chunksX do
        self:_markDirty(cx, cy, cz)
      end
    end
  end
end

function ChunkWorld:_placeTree(x, y, z, rng)
  local trunkHeight = 3 + math.floor(rng() * 3)
  local maxY = math.min(self.sizeY - 2, y + trunkHeight + 2)

  for iy = y, math.min(y + trunkHeight - 1, self.sizeY) do
    self:set(x, iy, z, self.constants.BLOCK.WOOD)
  end

  local leafStart = y + trunkHeight - 2
  for iy = leafStart, maxY do
    local radius = (iy == maxY) and 1 or 2
    for dz = -radius, radius do
      for dx = -radius, radius do
        local ax = x + dx
        local az = z + dz
        if self:isInside(ax, iy, az) then
          local dist = math.abs(dx) + math.abs(dz)
          if dist <= radius + 1 then
            if self:get(ax, iy, az) == self.constants.BLOCK.AIR then
              self:set(ax, iy, az, self.constants.BLOCK.LEAF)
            end
          end
        end
      end
    end
  end
end

function ChunkWorld:raycast(originX, originY, originZ, dirX, dirY, dirZ, maxDistance)
  maxDistance = maxDistance or 6.0

  local len = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ)
  if len < 1e-6 then
    return nil
  end
  dirX, dirY, dirZ = dirX / len, dirY / len, dirZ / len

  -- Convert to voxel coords (1-based blocks).
  local x = math.floor(originX) + 1
  local y = math.floor(originY) + 1
  local z = math.floor(originZ) + 1

  local stepX = dirX >= 0 and 1 or -1
  local stepY = dirY >= 0 and 1 or -1
  local stepZ = dirZ >= 0 and 1 or -1

  local function intBound(s, ds)
    -- Find smallest positive t such that s + t*ds is an integer.
    if ds == 0 then
      return math.huge
    end
    local sIsInteger = (math.floor(s) == s)
    if ds > 0 then
      return ((sIsInteger and s or (math.floor(s) + 1)) - s) / ds
    else
      return (s - (sIsInteger and s or math.floor(s))) / -ds
    end
  end

  local tMaxX = intBound(originX, dirX)
  local tMaxY = intBound(originY, dirY)
  local tMaxZ = intBound(originZ, dirZ)

  local tDeltaX = (dirX == 0) and math.huge or (1 / math.abs(dirX))
  local tDeltaY = (dirY == 0) and math.huge or (1 / math.abs(dirY))
  local tDeltaZ = (dirZ == 0) and math.huge or (1 / math.abs(dirZ))

  local traveled = 0
  local prevX, prevY, prevZ = nil, nil, nil

  while traveled <= maxDistance do
    if self:isInside(x, y, z) then
      local block = self:get(x, y, z)
      if block ~= self.constants.BLOCK.AIR then
        return {
          x = x, y = y, z = z,
          previousX = prevX, previousY = prevY, previousZ = prevZ,
          block = block
        }
      end
    end

    prevX, prevY, prevZ = x, y, z

    if tMaxX < tMaxY then
      if tMaxX < tMaxZ then
        x = x + stepX
        traveled = tMaxX
        tMaxX = tMaxX + tDeltaX
      else
        z = z + stepZ
        traveled = tMaxZ
        tMaxZ = tMaxZ + tDeltaZ
      end
    else
      if tMaxY < tMaxZ then
        y = y + stepY
        traveled = tMaxY
        tMaxY = tMaxY + tDeltaY
      else
        z = z + stepZ
        traveled = tMaxZ
        tMaxZ = tMaxZ + tDeltaZ
      end
    end

    -- Early exit if we're far outside the world bounds in all axes.
    if x < 0 or x > self.sizeX + 2 or y < 0 or y > self.sizeY + 2 or z < 0 or z > self.sizeZ + 2 then
      if traveled > maxDistance then
        break
      end
    end
  end

  return nil
end

return ChunkWorld
