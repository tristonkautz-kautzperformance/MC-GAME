local ItemEntities = {}
ItemEntities.__index = ItemEntities

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function parseInteger(value)
  local n = tonumber(value)
  if not n or n % 1 ~= 0 then
    return nil
  end
  return n
end

local function hashToUnit(seed, x, z, salt)
  local n = math.sin(
    (x + seed * 0.00131) * 127.1
      + (z - seed * 0.00173) * 311.7
      + salt * 97.117
  ) * 43758.5453123
  return n - math.floor(n)
end

function ItemEntities.new(constants, world)
  local self = setmetatable({}, ItemEntities)
  self.constants = constants
  self.world = world

  local cfg = constants.ITEM_ENTITIES or {}
  self.maxActive = math.max(16, math.floor(tonumber(cfg.maxActive) or 384))
  self.maxDistance = math.max(8, tonumber(cfg.maxDistance) or 96)
  self.maxDistanceSq = self.maxDistance * self.maxDistance
  self.drawDistance = math.max(8, tonumber(cfg.drawDistance) or 80)
  self.drawDistanceSq = self.drawDistance * self.drawDistance
  self.pickupRadius = math.max(0.1, tonumber(cfg.pickupRadius) or 0.33)
  self.pickupRadiusSq = self.pickupRadius * self.pickupRadius
  self.itemSize = math.max(0.12, tonumber(cfg.itemSize) or 0.22)
  self.itemHalfSize = self.itemSize * 0.5
  self._groundOffsetY = self.itemHalfSize + 0.01

  self.entities = {}
  self.count = 0
  self._spawnSerial = 0
  self._lastPlayerX = 0
  self._lastPlayerY = 0
  self._lastPlayerZ = 0

  self._ambientSpawnedChunks = {}
  self._ambientSpawnRadius = math.max(0, math.floor(tonumber(cfg.ambientSpawnRadiusChunks) or 1))
  self._ambientMinPerChunk = math.max(1, math.floor(tonumber(cfg.ambientMinPerChunk) or 1))
  self._ambientMaxPerChunk = math.max(self._ambientMinPerChunk, math.floor(tonumber(cfg.ambientMaxPerChunk) or 3))

  return self
end

function ItemEntities:resetSession()
  self.count = 0
  self._spawnSerial = 0
  self._ambientSpawnedChunks = {}
  local entities = self.entities
  for i = #entities, 1, -1 do
    entities[i] = nil
  end
end

function ItemEntities:_isStackable(block)
  local info = self.constants.BLOCK_INFO and self.constants.BLOCK_INFO[block] or nil
  if info and info.stackable == false then
    return false
  end
  return true
end

function ItemEntities:_ensureCapacity()
  if self.count < self.maxActive then
    return
  end

  local dropIndex = 1
  local farthestDistSq = -1
  local px = self._lastPlayerX
  local py = self._lastPlayerY
  local pz = self._lastPlayerZ

  for i = 1, self.count do
    local entity = self.entities[i]
    local dx = entity.x - px
    local dy = entity.y - py
    local dz = entity.z - pz
    local distSq = dx * dx + dy * dy + dz * dz
    if distSq > farthestDistSq then
      farthestDistSq = distSq
      dropIndex = i
    elseif distSq == farthestDistSq and entity.serial < self.entities[dropIndex].serial then
      dropIndex = i
    end
  end

  self:_removeAt(dropIndex)
end

function ItemEntities:_removeAt(index)
  if index < 1 or index > self.count then
    return
  end

  local entities = self.entities
  local tail = self.count
  if index ~= tail then
    entities[index] = entities[tail]
  end
  entities[tail] = nil
  self.count = tail - 1
end

function ItemEntities:spawn(id, x, y, z, count, durability)
  local blockId = parseInteger(id)
  local amount = parseInteger(count) or 1
  if not blockId or blockId <= 0 or amount <= 0 then
    return 0
  end

  local info = self.constants.BLOCK_INFO and self.constants.BLOCK_INFO[blockId] or nil
  if not info then
    return 0
  end

  local stackable = self:_isStackable(blockId)
  local spawned = 0

  if stackable then
    self:_ensureCapacity()
    self.count = self.count + 1
    self._spawnSerial = self._spawnSerial + 1
    self.entities[self.count] = {
      id = blockId,
      count = amount,
      durability = nil,
      x = x,
      y = y,
      z = z,
      serial = self._spawnSerial
    }
    return 1
  end

  local entryDurability = parseInteger(durability)
  if not entryDurability or entryDurability <= 0 then
    entryDurability = parseInteger(info.maxDurability)
  end

  for _ = 1, amount do
    self:_ensureCapacity()
    self.count = self.count + 1
    self._spawnSerial = self._spawnSerial + 1
    self.entities[self.count] = {
      id = blockId,
      count = 1,
      durability = entryDurability,
      x = x,
      y = y,
      z = z,
      serial = self._spawnSerial
    }
    spawned = spawned + 1
  end

  return spawned
end

function ItemEntities:dropStack(x, y, z, block, count, durability)
  if not block or not count or count <= 0 then
    return 0
  end

  local spawned = self:spawn(block, x, y, z, count, durability)
  return spawned
end

function ItemEntities:update(_dt, playerX, playerY, playerZ)
  self._lastPlayerX = playerX
  self._lastPlayerY = playerY
  self._lastPlayerZ = playerZ

  local write = 1
  local maxDistSq = self.maxDistanceSq
  for i = 1, self.count do
    local entity = self.entities[i]

    local dx = entity.x - playerX
    local dy = entity.y - playerY
    local dz = entity.z - playerZ
    local distSq = dx * dx + dy * dy + dz * dz

    if distSq <= maxDistSq and entity.count > 0 then
      if write ~= i then
        self.entities[write] = entity
      end
      write = write + 1
    end
  end

  local nextCount = write - 1
  for i = nextCount + 1, self.count do
    self.entities[i] = nil
  end
  self.count = nextCount
end

function ItemEntities:draw(pass)
  local entities = self.entities
  local count = self.count
  if count <= 0 then
    return
  end

  local px = self._lastPlayerX
  local py = self._lastPlayerY
  local pz = self._lastPlayerZ

  pass:push('state')

  local size = self.itemSize
  local half = size * 0.5

  for i = 1, count do
    local entity = entities[i]
    local dx = entity.x - px
    local dy = entity.y - py
    local dz = entity.z - pz
    local distSq = dx * dx + dy * dy + dz * dz
    if distSq <= self.drawDistanceSq then
      local info = self.constants.BLOCK_INFO and self.constants.BLOCK_INFO[entity.id] or nil
      local color = info and info.color or nil
      local alpha = (info and info.alpha) or 1
      local r = (color and color[1]) or 1
      local g = (color and color[2]) or 0
      local b = (color and color[3]) or 1

      pass:push()
      pass:setColor(r, g, b, alpha)
      pass:translate(entity.x, entity.y, entity.z)
      pass:cube(-half, -half, -half, size)
      pass:pop()
    end
  end

  pass:pop('state')
end

function ItemEntities:raycast(originX, originY, originZ, dirX, dirY, dirZ, maxDistance, outHit)
  local lenSq = dirX * dirX + dirY * dirY + dirZ * dirZ
  if lenSq <= 1e-8 then
    return nil
  end

  local invLen = 1 / math.sqrt(lenSq)
  local dx = dirX * invLen
  local dy = dirY * invLen
  local dz = dirZ * invLen
  local reach = tonumber(maxDistance) or 6.0

  local bestT = reach + 1
  local bestIndex = nil
  local radiusSq = self.pickupRadiusSq

  for i = 1, self.count do
    local entity = self.entities[i]
    local cx = entity.x - originX
    local cy = entity.y - originY
    local cz = entity.z - originZ

    local t = cx * dx + cy * dy + cz * dz
    if t >= 0 and t <= reach then
      local cSq = cx * cx + cy * cy + cz * cz
      local dSq = cSq - t * t
      if dSq <= radiusSq then
        local offset = math.sqrt(math.max(0, radiusSq - dSq))
        local hitT = t - offset
        if hitT < 0 then
          hitT = t
        end

        if hitT < bestT then
          bestT = hitT
          bestIndex = i
        end
      end
    end
  end

  if not bestIndex then
    return nil
  end

  local entity = self.entities[bestIndex]
  local hit = outHit or {}
  hit.index = bestIndex
  hit.entity = entity
  hit.id = entity.id
  hit.count = entity.count
  hit.durability = entity.durability
  hit.distance = bestT
  hit.x = entity.x
  hit.y = entity.y
  hit.z = entity.z
  return hit
end

function ItemEntities:tryPickup(hit, inventory)
  if not hit or not inventory then
    return false
  end

  local index = parseInteger(hit.index)
  if not index or index < 1 or index > self.count then
    return false
  end

  local entity = self.entities[index]
  if not entity then
    return false
  end

  local added = inventory:addStack(entity.id, entity.count, entity.durability)
  if added <= 0 then
    return false
  end

  entity.count = entity.count - added
  if entity.count <= 0 then
    self:_removeAt(index)
  end

  return true
end

function ItemEntities:_findSurfaceY(x, z)
  local world = self.world
  local air = self.constants.BLOCK.AIR
  local water = self.constants.BLOCK.WATER

  for y = world.sizeY, 1, -1 do
    local block = world:get(x, y, z)
    if block and block ~= air and block ~= water then
      return y
    end
  end

  return nil
end

function ItemEntities:_ambientChunkKey(cx, cz)
  return cx + (cz - 1) * self.world.chunksX
end

function ItemEntities:spawnAmbientForChunk(cx, cz)
  if cx < 1 or cx > self.world.chunksX or cz < 1 or cz > self.world.chunksZ then
    return 0
  end

  local chunkKey = self:_ambientChunkKey(cx, cz)
  if self._ambientSpawnedChunks[chunkKey] then
    return 0
  end
  self._ambientSpawnedChunks[chunkKey] = true

  local chunkSize = self.world.chunkSize
  local originX = (cx - 1) * chunkSize
  local originZ = (cz - 1) * chunkSize
  local seed = self.constants.WORLD_SEED or 1

  local stickId = self.constants.ITEM.STICK
  local flintId = self.constants.ITEM.FLINT
  local berryId = self.constants.ITEM.BERRY

  local minPerChunk = self._ambientMinPerChunk
  local maxPerChunk = self._ambientMaxPerChunk
  local spawned = 0
  local itemSpan = maxPerChunk - minPerChunk + 1
  local spawnCount = minPerChunk + math.floor(hashToUnit(seed, cx, cz, 12) * itemSpan)
  if spawnCount < minPerChunk then
    spawnCount = minPerChunk
  elseif spawnCount > maxPerChunk then
    spawnCount = maxPerChunk
  end

  for i = 1, spawnCount do
    local itemRoll = hashToUnit(seed, cx, cz, 40 + i * 3)
    local itemId = berryId
    if itemRoll < 0.42 then
      itemId = stickId
    elseif itemRoll < 0.74 then
      itemId = flintId
    end

    local localX = math.floor(hashToUnit(seed, cx, cz, 60 + i * 5) * chunkSize) + 1
    local localZ = math.floor(hashToUnit(seed, cx, cz, 80 + i * 7) * chunkSize) + 1
    local worldX = clamp(originX + localX, 1, self.world.sizeX)
    local worldZ = clamp(originZ + localZ, 1, self.world.sizeZ)
    local surfaceY = self:_findSurfaceY(worldX, worldZ)
    if surfaceY and surfaceY < self.world.sizeY then
      spawned = spawned + self:spawn(itemId, worldX - 0.5, surfaceY + self._groundOffsetY, worldZ - 0.5, 1)
    end
  end

  return spawned
end

function ItemEntities:spawnAmbientAroundChunk(centerCx, centerCz)
  local radius = self._ambientSpawnRadius
  local minX = clamp(centerCx - radius, 1, self.world.chunksX)
  local maxX = clamp(centerCx + radius, 1, self.world.chunksX)
  local minZ = clamp(centerCz - radius, 1, self.world.chunksZ)
  local maxZ = clamp(centerCz + radius, 1, self.world.chunksZ)

  local spawned = 0
  for cz = minZ, maxZ do
    for cx = minX, maxX do
      spawned = spawned + self:spawnAmbientForChunk(cx, cz)
    end
  end

  return spawned
end

return ItemEntities
