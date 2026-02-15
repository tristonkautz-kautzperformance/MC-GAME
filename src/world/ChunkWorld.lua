local ChunkWorld = {}
ChunkWorld.__index = ChunkWorld

local EMPTY_DIRTY_KEYS = {}
local RNG_MOD = 2147483648
local COLUMN_SEED_MOD = 2147483647
local hasFfi, ffi = pcall(require, 'ffi')
if not hasFfi then
  ffi = nil
end

local function clampInt(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function makeRng(seed)
  -- Deterministic LCG RNG (avoids depending on global math.randomseed state).
  local state = seed or 1
  return function()
    state = (1103515245 * state + 12345) % RNG_MOD
    return state / RNG_MOD
  end
end

local function mixColumnSeed(worldSeed, cx, cz)
  local seed = math.floor(tonumber(worldSeed) or 1)
  local state = seed % COLUMN_SEED_MOD
  if state < 0 then
    state = state + COLUMN_SEED_MOD
  end

  -- Stable integer hash from world seed + chunk column.
  state = (state + cx * 73856093 + cz * 19349663) % COLUMN_SEED_MOD
  if state == 0 then
    state = 1
  end
  return state
end

function ChunkWorld.new(constants)
  local self = setmetatable({}, ChunkWorld)
  self.constants = constants
  self.sizeX = constants.WORLD_SIZE_X
  self.sizeY = constants.WORLD_SIZE_Y
  self.sizeZ = constants.WORLD_SIZE_Z
  self.chunkSize = constants.CHUNK_SIZE
  self.groundY = nil

  self.chunksX = constants.WORLD_CHUNKS_X
  self.chunksY = constants.WORLD_CHUNKS_Y
  self.chunksZ = constants.WORLD_CHUNKS_Z

  self._dirty = {}
  self._editChunks = {}
  self._editChunkCounts = {}
  self._featureChunks = {}
  self._featureColumnsPrepared = {}
  self._editCount = 0

  self._genGrassY = 2
  self._genStoneTop = 1
  self._genDirtTop = 1
  self._treeTrunkMin = 3
  self._treeTrunkMax = 5
  self._treeLeafPad = 2
  self._activeMinChunkY = 1
  self._activeMaxChunkY = self.chunksY
  self._chunkVolume = self.chunkSize * self.chunkSize * self.chunkSize
  self._worldStrideZ = self.sizeX
  self._worldStrideY = self.sizeX * self.sizeZ

  self._lighting = constants.LIGHTING or {}
  self._lightingEnabled = self._lighting.enabled ~= false
  self._lightingMode = self._lighting.mode == 'floodfill' and 'floodfill' or 'vertical'
  self._lightOpacityByBlock = {}
  self._skyLightChunks = {}
  self._skyColumnsReady = {}
  self._skyColumnsQueue = {}
  self._skyColumnsQueueSet = {}
  self._skyColumnsQueueHead = 1
  self._skyColumnsQueueTail = 0
  self._skyFloodQueue = {}
  self._skyFloodQueueHead = 1
  self._skyFloodQueueTail = 0
  self._skyStage = 'idle'
  self._skyTrackDirty = false
  self._skyCenterCx = 1
  self._skyCenterCz = 1
  self._skyKeepRadius = 0
  self._skyActiveMinCx = 1
  self._skyActiveMaxCx = 0
  self._skyActiveMinCz = 1
  self._skyActiveMaxCz = 0
  self._skyActiveMinX = 1
  self._skyActiveMaxX = 0
  self._skyActiveMinZ = 1
  self._skyActiveMaxZ = 0

  self:_initLighting()
  self:_computeGenerationThresholds()

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

function ChunkWorld:_chunkKey(cx, cy, cz)
  return cx + (cz - 1) * self.chunksX + (cy - 1) * self.chunksX * self.chunksZ
end

function ChunkWorld:_decodeChunkKey(chunkKey)
  local chunksPerLayer = self.chunksX * self.chunksZ
  local zeroBased = chunkKey - 1
  local cy = math.floor(zeroBased / chunksPerLayer) + 1
  local rem = zeroBased % chunksPerLayer
  local cz = math.floor(rem / self.chunksX) + 1
  local cx = (rem % self.chunksX) + 1
  return cx, cy, cz
end

function ChunkWorld:chunkKey(cx, cy, cz)
  return self:_chunkKey(cx, cy, cz)
end

function ChunkWorld:decodeChunkKey(chunkKey)
  return self:_decodeChunkKey(chunkKey)
end

function ChunkWorld:_localIndex(lx, ly, lz)
  local cs = self.chunkSize
  return (ly - 1) * cs * cs + (lz - 1) * cs + lx
end

function ChunkWorld:_columnKey(cx, cz)
  return cx + (cz - 1) * self.chunksX
end

function ChunkWorld:_worldColumnKey(x, z)
  return x + (z - 1) * self.sizeX
end

function ChunkWorld:_decodeWorldColumnKey(columnKey)
  local zeroBased = columnKey - 1
  local z = math.floor(zeroBased / self.sizeX) + 1
  local x = (zeroBased % self.sizeX) + 1
  return x, z
end

function ChunkWorld:_worldIndex(x, y, z)
  return x + (z - 1) * self._worldStrideZ + (y - 1) * self._worldStrideY
end

function ChunkWorld:_decodeWorldIndex(index)
  local zeroBased = index - 1
  local x = (zeroBased % self.sizeX) + 1
  zeroBased = math.floor(zeroBased / self.sizeX)
  local z = (zeroBased % self.sizeZ) + 1
  local y = math.floor(zeroBased / self.sizeZ) + 1
  return x, y, z
end

function ChunkWorld:_initLighting()
  local lighting = self._lighting or {}
  local leafOpacity = math.floor(tonumber(lighting.leafOpacity) or 2)
  if leafOpacity < 0 then
    leafOpacity = 0
  elseif leafOpacity > 15 then
    leafOpacity = 15
  end

  local blockInfo = self.constants.BLOCK_INFO or {}
  local AIR = self.constants.BLOCK and self.constants.BLOCK.AIR or 0
  local LEAF = self.constants.BLOCK and self.constants.BLOCK.LEAF or -1

  for blockId, info in pairs(blockInfo) do
    local opacity = tonumber(info.lightOpacity)
    if opacity == nil then
      if blockId == AIR then
        opacity = 0
      elseif blockId == LEAF then
        opacity = leafOpacity
      elseif info.opaque then
        opacity = 15
      else
        opacity = 0
      end
    end
    opacity = math.floor(opacity + 0.5)
    if opacity < 0 then
      opacity = 0
    elseif opacity > 15 then
      opacity = 15
    end
    self._lightOpacityByBlock[blockId] = opacity
  end

  self:_resetSkyLightData()
end

function ChunkWorld:_resetSkyLightData()
  self._skyLightChunks = {}
  self._skyColumnsReady = {}
  self._skyColumnsQueue = {}
  self._skyColumnsQueueSet = {}
  self._skyColumnsQueueHead = 1
  self._skyColumnsQueueTail = 0
  self._skyFloodQueue = {}
  self._skyFloodQueueHead = 1
  self._skyFloodQueueTail = 0
  self._skyStage = 'idle'
  self._skyTrackDirty = false
  self._skyCenterCx = 1
  self._skyCenterCz = 1
  self._skyKeepRadius = 0
  self._skyActiveMinCx = 1
  self._skyActiveMaxCx = 0
  self._skyActiveMinCz = 1
  self._skyActiveMaxCz = 0
  self._skyActiveMinX = 1
  self._skyActiveMaxX = 0
  self._skyActiveMinZ = 1
  self._skyActiveMaxZ = 0
end

function ChunkWorld:_getBlockLightOpacity(block)
  local value = self._lightOpacityByBlock[block]
  if value == nil then
    return 0
  end
  return value
end

function ChunkWorld:_newSkyChunkData()
  if ffi then
    return ffi.new('uint8_t[?]', self._chunkVolume)
  end
  local data = {}
  for i = 1, self._chunkVolume do
    data[i] = 0
  end
  return data
end

function ChunkWorld:_getSkyChunk(chunkKey, create)
  local chunk = self._skyLightChunks[chunkKey]
  if chunk or not create then
    return chunk
  end

  chunk = self:_newSkyChunkData()
  self._skyLightChunks[chunkKey] = chunk
  return chunk
end

function ChunkWorld:_getSkyChunkValue(chunk, localIndex)
  if not chunk then
    return 0
  end
  if ffi then
    return chunk[localIndex - 1]
  end
  local value = chunk[localIndex]
  if value == nil then
    return 0
  end
  return value
end

function ChunkWorld:_setSkyChunkValue(chunk, localIndex, value)
  if ffi then
    chunk[localIndex - 1] = value
  else
    chunk[localIndex] = value
  end
end

function ChunkWorld:_getSkyLightWorld(x, y, z)
  if x < 1 or x > self.sizeX or z < 1 or z > self.sizeZ then
    return 0
  end
  if y > self.sizeY then
    return 15
  end
  if y < 1 then
    return 0
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  local chunkKey = self:chunkKey(cx, cy, cz)
  local chunk = self._skyLightChunks[chunkKey]
  if not chunk then
    return 0
  end

  local localIndex = self:_localIndex(lx, ly, lz)
  return self:_getSkyChunkValue(chunk, localIndex)
end

function ChunkWorld:_setSkyLightWorld(x, y, z, value, markDirty)
  if not self:isInside(x, y, z) then
    return false
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  local chunkKey = self:chunkKey(cx, cy, cz)
  local chunk = self:_getSkyChunk(chunkKey, true)
  local localIndex = self:_localIndex(lx, ly, lz)
  local oldValue = self:_getSkyChunkValue(chunk, localIndex)
  if oldValue == value then
    return false
  end

  self:_setSkyChunkValue(chunk, localIndex, value)
  if markDirty then
    self:_markDirty(cx, cy, cz)
  end
  return true
end

function ChunkWorld:getSkyLight(x, y, z)
  if not self._lightingEnabled then
    return 15
  end

  if y > self.sizeY and x >= 1 and x <= self.sizeX and z >= 1 and z <= self.sizeZ then
    return 15
  end
  if not self:isInside(x, y, z) then
    return 0
  end

  self:_ensureSkyColumnReady(x, z, false, false)
  return self:_getSkyLightWorld(x, y, z)
end

function ChunkWorld:_enqueueSkyColumn(columnKey)
  if self._skyColumnsQueueSet[columnKey] then
    return false
  end

  local tail = self._skyColumnsQueueTail + 1
  self._skyColumnsQueueTail = tail
  self._skyColumnsQueue[tail] = columnKey
  self._skyColumnsQueueSet[columnKey] = true
  return true
end

function ChunkWorld:_dequeueSkyColumn()
  local head = self._skyColumnsQueueHead
  local tail = self._skyColumnsQueueTail
  if head > tail then
    return nil
  end

  local columnKey = self._skyColumnsQueue[head]
  self._skyColumnsQueue[head] = nil
  self._skyColumnsQueueHead = head + 1
  if columnKey ~= nil then
    self._skyColumnsQueueSet[columnKey] = nil
  end

  if self._skyColumnsQueueHead > self._skyColumnsQueueTail then
    self._skyColumnsQueueHead = 1
    self._skyColumnsQueueTail = 0
  end

  return columnKey
end

function ChunkWorld:_clearSkyColumnsQueue()
  local queue = self._skyColumnsQueue
  for i = self._skyColumnsQueueHead, self._skyColumnsQueueTail do
    queue[i] = nil
  end
  self._skyColumnsQueueHead = 1
  self._skyColumnsQueueTail = 0
  for columnKey in pairs(self._skyColumnsQueueSet) do
    self._skyColumnsQueueSet[columnKey] = nil
  end
end

function ChunkWorld:_enqueueSkyFlood(worldIndex)
  local tail = self._skyFloodQueueTail + 1
  self._skyFloodQueueTail = tail
  self._skyFloodQueue[tail] = worldIndex
end

function ChunkWorld:_dequeueSkyFlood()
  local head = self._skyFloodQueueHead
  local tail = self._skyFloodQueueTail
  if head > tail then
    return nil
  end

  local worldIndex = self._skyFloodQueue[head]
  self._skyFloodQueue[head] = nil
  self._skyFloodQueueHead = head + 1
  if self._skyFloodQueueHead > self._skyFloodQueueTail then
    self._skyFloodQueueHead = 1
    self._skyFloodQueueTail = 0
  end
  return worldIndex
end

function ChunkWorld:_clearSkyFloodQueue()
  local queue = self._skyFloodQueue
  for i = self._skyFloodQueueHead, self._skyFloodQueueTail do
    queue[i] = nil
  end
  self._skyFloodQueueHead = 1
  self._skyFloodQueueTail = 0
end

function ChunkWorld:_isInsideSkyActiveWorldXZ(x, z)
  return x >= self._skyActiveMinX
    and x <= self._skyActiveMaxX
    and z >= self._skyActiveMinZ
    and z <= self._skyActiveMaxZ
end

function ChunkWorld:_recomputeSkyColumn(x, z, enqueueFlood, markDirty)
  if x < 1 or x > self.sizeX or z < 1 or z > self.sizeZ then
    return false
  end

  local columnKey = self:_worldColumnKey(x, z)
  local light = 15

  for y = self.sizeY, 1, -1 do
    local block = self:get(x, y, z)
    local opacity = self:_getBlockLightOpacity(block)
    light = light - opacity
    if light < 0 then
      light = 0
    end

    self:_setSkyLightWorld(x, y, z, light, markDirty)
    if enqueueFlood and light > 0 then
      self:_enqueueSkyFlood(self:_worldIndex(x, y, z))
    end

    if light == 0 and opacity >= 15 then
      for clearY = y - 1, 1, -1 do
        self:_setSkyLightWorld(x, clearY, z, 0, markDirty)
      end
      break
    end
  end

  self._skyColumnsReady[columnKey] = true
  return true
end

function ChunkWorld:_ensureSkyColumnReady(x, z, enqueueFlood, markDirty)
  if x < 1 or x > self.sizeX or z < 1 or z > self.sizeZ then
    return false
  end

  local columnKey = self:_worldColumnKey(x, z)
  if self._skyColumnsReady[columnKey] then
    return true
  end

  return self:_recomputeSkyColumn(x, z, enqueueFlood, markDirty)
end

function ChunkWorld:_ensureSkyHaloColumns(cx, cz, enqueueFlood, markDirty)
  local cs = self.chunkSize
  local minX = (cx - 1) * cs
  local maxX = cx * cs + 1
  local minZ = (cz - 1) * cs
  local maxZ = cz * cs + 1

  for z = minZ, maxZ do
    if z >= 1 and z <= self.sizeZ then
      for x = minX, maxX do
        if x >= 1 and x <= self.sizeX then
          self:_ensureSkyColumnReady(x, z, enqueueFlood, markDirty)
        end
      end
    end
  end
end

function ChunkWorld:_markLightingDirtyRadius(cx, cz)
  local radius = math.ceil(15 / self.chunkSize)
  if radius < 0 then
    radius = 0
  end

  local minX = clampInt(cx - radius, 1, self.chunksX)
  local maxX = clampInt(cx + radius, 1, self.chunksX)
  local minZ = clampInt(cz - radius, 1, self.chunksZ)
  local maxZ = clampInt(cz + radius, 1, self.chunksZ)

  for markCz = minZ, maxZ do
    for markCx = minX, maxX do
      for markCy = 1, self.chunksY do
        self:_markDirty(markCx, markCy, markCz)
      end
    end
  end
end

function ChunkWorld:_scheduleSkyRegionRebuild(trackDirty)
  if not self._lightingEnabled or self._lightingMode ~= 'floodfill' then
    return
  end
  if self._skyActiveMaxX < self._skyActiveMinX or self._skyActiveMaxZ < self._skyActiveMinZ then
    return
  end

  self:_clearSkyColumnsQueue()
  self:_clearSkyFloodQueue()

  for z = self._skyActiveMinZ, self._skyActiveMaxZ do
    for x = self._skyActiveMinX, self._skyActiveMaxX do
      local columnKey = self:_worldColumnKey(x, z)
      self._skyColumnsReady[columnKey] = nil
      self:_enqueueSkyColumn(columnKey)
    end
  end

  if self._skyColumnsQueueTail >= self._skyColumnsQueueHead then
    self._skyStage = 'vertical'
  else
    self._skyStage = 'flood'
  end
  self._skyTrackDirty = trackDirty and true or false
end

function ChunkWorld:_onSkyOpacityChanged(x, z, cx, cz)
  if not self._lightingEnabled then
    return
  end

  self._skyColumnsReady[self:_worldColumnKey(x, z)] = nil
  self:_markLightingDirtyRadius(cx, cz)

  if self._lightingMode == 'floodfill' then
    self:_scheduleSkyRegionRebuild(true)
  else
    self:_recomputeSkyColumn(x, z, false, false)
  end
end

function ChunkWorld:ensureSkyLightForChunk(cx, cy, cz)
  if not self._lightingEnabled then
    return true
  end
  if cx < 1 or cx > self.chunksX
    or cy < 1 or cy > self.chunksY
    or cz < 1 or cz > self.chunksZ then
    return false
  end

  self:prepareChunk(cx, cy, cz)
  self:_ensureSkyHaloColumns(cx, cz, false, false)
  return true
end

function ChunkWorld:fillSkyLightHalo(cx, cy, cz, out)
  if not out then
    return nil
  end

  if not self._lightingEnabled then
    local cs = self.chunkSize
    local haloSize = cs + 2
    local required = haloSize * haloSize * haloSize
    for i = 1, required do
      out[i] = 15
    end
    for i = required + 1, #out do
      out[i] = nil
    end
    return out
  end

  local cs = self.chunkSize
  self:_ensureSkyHaloColumns(cx, cz, false, false)
  local haloSize = cs + 2
  local strideZ = haloSize
  local strideY = haloSize * haloSize
  local baseOriginX = (cx - 1) * cs
  local baseOriginY = (cy - 1) * cs
  local baseOriginZ = (cz - 1) * cs

  for hy = 0, cs + 1 do
    local wy = baseOriginY + hy
    local syBase = (hy * strideY) + 1

    for hz = 0, cs + 1 do
      local wz = baseOriginZ + hz
      local szBase = syBase + (hz * strideZ)

      for hx = 0, cs + 1 do
        local wx = baseOriginX + hx
        local index = szBase + hx

        if wx < 1 or wx > self.sizeX or wz < 1 or wz > self.sizeZ or wy < 1 then
          out[index] = 0
        elseif wy > self.sizeY then
          out[index] = 15
        else
          out[index] = self:_getSkyLightWorld(wx, wy, wz)
        end
      end
    end
  end

  local required = haloSize * haloSize * haloSize
  for i = required + 1, #out do
    out[i] = nil
  end
  return out
end

function ChunkWorld:_propagateSkyFloodFrom(worldIndex, markDirty)
  local x, y, z = self:_decodeWorldIndex(worldIndex)
  local sourceLight = self:_getSkyLightWorld(x, y, z)
  if sourceLight <= 1 then
    return
  end

  local function tryNeighbor(nx, ny, nz)
    if ny < 1 or ny > self.sizeY then
      return
    end
    if not self:_isInsideSkyActiveWorldXZ(nx, nz) then
      return
    end

    local block = self:get(nx, ny, nz)
    local step = self:_getBlockLightOpacity(block)
    if step < 1 then
      step = 1
    end
    local candidate = sourceLight - step
    if candidate <= 0 then
      return
    end

    local neighborLight = self:_getSkyLightWorld(nx, ny, nz)
    if candidate > neighborLight then
      self:_setSkyLightWorld(nx, ny, nz, candidate, markDirty)
      self:_enqueueSkyFlood(self:_worldIndex(nx, ny, nz))
    end
  end

  tryNeighbor(x - 1, y, z)
  tryNeighbor(x + 1, y, z)
  tryNeighbor(x, y - 1, z)
  tryNeighbor(x, y + 1, z)
  tryNeighbor(x, y, z - 1)
  tryNeighbor(x, y, z + 1)
end

function ChunkWorld:updateSkyLight(maxOps, maxMillis)
  if not self._lightingEnabled then
    return 0
  end
  if self._lightingMode ~= 'floodfill' then
    return 0
  end

  if self._skyStage ~= 'vertical' and self._skyStage ~= 'flood' then
    return 0
  end

  local config = self._lighting or {}
  local opsLimit = tonumber(maxOps)
  if opsLimit == nil then
    opsLimit = tonumber(config.maxUpdatesPerFrame)
  end
  if opsLimit ~= nil then
    opsLimit = math.floor(opsLimit)
    if opsLimit < 0 then
      opsLimit = 0
    end
  end

  local millisLimit = tonumber(maxMillis)
  if millisLimit == nil then
    millisLimit = tonumber(config.maxMillisPerFrame)
  end

  local hasTimer = lovr and lovr.timer and lovr.timer.getTime
  local useTimeBudget = hasTimer and millisLimit and millisLimit > 0
  local startTime = 0
  if useTimeBudget then
    startTime = lovr.timer.getTime()
  end
  if (not opsLimit or opsLimit <= 0) and not useTimeBudget then
    opsLimit = 1
  end

  local processed = 0
  while true do
    if opsLimit and opsLimit > 0 and processed >= opsLimit then
      break
    end
    if useTimeBudget and processed > 0 then
      local elapsedMs = (lovr.timer.getTime() - startTime) * 1000
      if elapsedMs >= millisLimit then
        break
      end
    end

    if self._skyStage == 'vertical' then
      local columnKey = self:_dequeueSkyColumn()
      if not columnKey then
        self._skyStage = 'flood'
      else
        if not self._skyColumnsReady[columnKey] then
          local x, z = self:_decodeWorldColumnKey(columnKey)
          self:_recomputeSkyColumn(x, z, true, self._skyTrackDirty)
        end
        processed = processed + 1
      end
    elseif self._skyStage == 'flood' then
      local worldIndex = self:_dequeueSkyFlood()
      if not worldIndex then
        self._skyStage = 'idle'
        self._skyTrackDirty = false
        break
      end
      self:_propagateSkyFloodFrom(worldIndex, self._skyTrackDirty)
      processed = processed + 1
    else
      break
    end
  end

  return processed
end

function ChunkWorld:pruneSkyLightChunks(centerCx, centerCz, keepRadiusChunks)
  if not self._lightingEnabled then
    return 0
  end

  local cx = clampInt(math.floor(tonumber(centerCx) or 1), 1, self.chunksX)
  local cz = clampInt(math.floor(tonumber(centerCz) or 1), 1, self.chunksZ)
  local keepRadius = math.floor(tonumber(keepRadiusChunks) or 0)
  if keepRadius < 0 then
    keepRadius = 0
  end

  local extraRadius = 0
  if self._lightingMode == 'floodfill' then
    extraRadius = math.floor(tonumber(self._lighting.floodfillExtraKeepRadiusChunks) or 1)
    if extraRadius < 0 then
      extraRadius = 0
    end
  end

  local radius = keepRadius + extraRadius
  local minCx = clampInt(cx - radius, 1, self.chunksX)
  local maxCx = clampInt(cx + radius, 1, self.chunksX)
  local minCz = clampInt(cz - radius, 1, self.chunksZ)
  local maxCz = clampInt(cz + radius, 1, self.chunksZ)

  local regionChanged = cx ~= self._skyCenterCx
    or cz ~= self._skyCenterCz
    or radius ~= self._skyKeepRadius
    or minCx ~= self._skyActiveMinCx
    or maxCx ~= self._skyActiveMaxCx
    or minCz ~= self._skyActiveMinCz
    or maxCz ~= self._skyActiveMaxCz

  self._skyCenterCx = cx
  self._skyCenterCz = cz
  self._skyKeepRadius = radius
  self._skyActiveMinCx = minCx
  self._skyActiveMaxCx = maxCx
  self._skyActiveMinCz = minCz
  self._skyActiveMaxCz = maxCz
  self._skyActiveMinX = (minCx - 1) * self.chunkSize + 1
  self._skyActiveMaxX = math.min(maxCx * self.chunkSize, self.sizeX)
  self._skyActiveMinZ = (minCz - 1) * self.chunkSize + 1
  self._skyActiveMaxZ = math.min(maxCz * self.chunkSize, self.sizeZ)

  local removed = 0
  for chunkKey, _ in pairs(self._skyLightChunks) do
    local chunkX, _, chunkZ = self:decodeChunkKey(chunkKey)
    local dx = math.abs(chunkX - cx)
    local dz = math.abs(chunkZ - cz)
    local dist = dx
    if dz > dist then
      dist = dz
    end
    if dist > radius then
      self._skyLightChunks[chunkKey] = nil
      removed = removed + 1
    end
  end

  for columnKey, _ in pairs(self._skyColumnsReady) do
    local x, z = self:_decodeWorldColumnKey(columnKey)
    if x < self._skyActiveMinX or x > self._skyActiveMaxX or z < self._skyActiveMinZ or z > self._skyActiveMaxZ then
      self._skyColumnsReady[columnKey] = nil
    end
  end

  if regionChanged and self._lightingMode == 'floodfill' then
    self:_scheduleSkyRegionRebuild(false)
  end

  return removed
end

function ChunkWorld:_markDirty(cx, cy, cz)
  if cx < 1 or cx > self.chunksX or cy < 1 or cy > self.chunksY or cz < 1 or cz > self.chunksZ then
    return
  end

  local chunkKey = self:chunkKey(cx, cy, cz)
  self._dirty[chunkKey] = true
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

function ChunkWorld:_computeGenerationThresholds()
  local bedrockY = 1
  local gen = self.constants.GEN or {}
  local bedrockDepth = tonumber(gen.bedrockDepth) or 6
  if bedrockDepth < 1 then
    bedrockDepth = 1
  end

  local grassY = bedrockY + math.floor(bedrockDepth + 0.5)
  if self.sizeY <= bedrockY then
    grassY = bedrockY
  else
    grassY = clampInt(grassY, bedrockY + 1, self.sizeY)
  end

  local subsurfaceLayers = math.max(0, grassY - (bedrockY + 1))
  local dirtFraction = tonumber(gen.dirtFraction) or (2 / 3)
  if dirtFraction < 0 then dirtFraction = 0 end
  if dirtFraction > 1 then dirtFraction = 1 end

  local dirtLayers = math.floor(subsurfaceLayers * dirtFraction + 0.5)
  dirtLayers = clampInt(dirtLayers, 0, subsurfaceLayers)
  local stoneLayers = subsurfaceLayers - dirtLayers

  local stoneTop = bedrockY
  if grassY > bedrockY then
    stoneTop = clampInt(bedrockY + stoneLayers, bedrockY, grassY - 1)
  end

  local trunkMin = math.floor(tonumber(gen.treeTrunkMin) or 3)
  if trunkMin < 1 then
    trunkMin = 1
  end
  local trunkMax = math.floor(tonumber(gen.treeTrunkMax) or 5)
  if trunkMax < trunkMin then
    trunkMax = trunkMin
  end
  local leafPad = math.floor(tonumber(gen.treeLeafPad) or 2)
  if leafPad < 0 then
    leafPad = 0
  end

  self._genGrassY = grassY
  self._genStoneTop = stoneTop
  self._genDirtTop = math.max(bedrockY, grassY - 1)
  self._treeTrunkMin = trunkMin
  self._treeTrunkMax = trunkMax
  self._treeLeafPad = leafPad
  self.groundY = grassY

  local maxFeatureY = grassY
  local treeDensity = tonumber(self.constants.TREE_DENSITY) or 0
  local treeRootY = grassY + 1
  if treeDensity > 0 and treeRootY <= self.sizeY then
    local treeTopY = treeRootY + trunkMax + leafPad
    local hardTop = self.sizeY - 2
    if hardTop < 1 then
      hardTop = self.sizeY
    end
    if treeTopY > hardTop then
      treeTopY = hardTop
    end
    if treeTopY > maxFeatureY then
      maxFeatureY = treeTopY
    end
  end

  maxFeatureY = clampInt(maxFeatureY, 1, self.sizeY)
  self._activeMinChunkY = 1
  self._activeMaxChunkY = clampInt(math.floor((maxFeatureY - 1) / self.chunkSize) + 1, 1, self.chunksY)
end

function ChunkWorld:getActiveChunkYRange()
  local minCy = self._activeMinChunkY or 1
  local maxCy = self._activeMaxChunkY or self.chunksY
  minCy = clampInt(minCy, 1, self.chunksY)
  maxCy = clampInt(maxCy, 1, self.chunksY)
  if minCy > maxCy then
    minCy, maxCy = maxCy, minCy
  end
  return minCy, maxCy
end

function ChunkWorld:_normalizeChunkYRange(minCy, maxCy)
  local minY = clampInt(math.floor(tonumber(minCy) or 1), 1, self.chunksY)
  local maxY = clampInt(math.floor(tonumber(maxCy) or self.chunksY), 1, self.chunksY)
  if minY > maxY then
    minY, maxY = maxY, minY
  end
  return minY, maxY
end

function ChunkWorld:_getBaseBlock(x, y, z)
  local blockIds = self.constants.BLOCK
  if not self:isInside(x, y, z) then
    return blockIds.AIR
  end

  if y == 1 then
    return blockIds.BEDROCK
  end
  if y <= self._genStoneTop then
    return blockIds.STONE
  end
  if y <= self._genDirtTop then
    return blockIds.DIRT
  end
  if y == self._genGrassY then
    return blockIds.GRASS
  end

  return blockIds.AIR
end

function ChunkWorld:_getBaseWithFeaturesByKey(x, y, z, chunkKey, localIndex)
  local featureChunk = self._featureChunks[chunkKey]
  if featureChunk then
    local featureValue = featureChunk[localIndex]
    if featureValue ~= nil then
      return featureValue
    end
  end
  return self:_getBaseBlock(x, y, z)
end

function ChunkWorld:_getByChunkKey(chunkKey, localIndex, x, y, z)
  if not self:isInside(x, y, z) then
    return self.constants.BLOCK.AIR
  end

  local editChunk = self._editChunks[chunkKey]
  if editChunk then
    local editValue = editChunk[localIndex]
    if editValue ~= nil then
      return editValue
    end
  end

  local featureChunk = self._featureChunks[chunkKey]
  if featureChunk then
    local featureValue = featureChunk[localIndex]
    if featureValue ~= nil then
      return featureValue
    end
  end

  return self:_getBaseBlock(x, y, z)
end

function ChunkWorld:_getBaseWithFeatures(x, y, z)
  if not self:isInside(x, y, z) then
    return self.constants.BLOCK.AIR
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  local chunkKey = self:chunkKey(cx, cy, cz)
  local localIndex = self:_localIndex(lx, ly, lz)
  return self:_getBaseWithFeaturesByKey(x, y, z, chunkKey, localIndex)
end

function ChunkWorld:_setFeatureBlock(x, y, z, block)
  if block == self.constants.BLOCK.AIR then
    return
  end
  if not self:isInside(x, y, z) then
    return
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  local chunkKey = self:chunkKey(cx, cy, cz)
  local localIndex = self:_localIndex(lx, ly, lz)

  local featureChunk = self._featureChunks[chunkKey]
  if not featureChunk then
    featureChunk = {}
    self._featureChunks[chunkKey] = featureChunk
  end

  featureChunk[localIndex] = block
end

function ChunkWorld:get(x, y, z)
  if not self:isInside(x, y, z) then
    return self.constants.BLOCK.AIR
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  local chunkKey = self:chunkKey(cx, cy, cz)
  local localIndex = self:_localIndex(lx, ly, lz)
  return self:_getByChunkKey(chunkKey, localIndex, x, y, z)
end

function ChunkWorld:fillBlockHalo(cx, cy, cz, out)
  if not out then
    return nil
  end

  local AIR = self.constants.BLOCK.AIR
  local cs = self.chunkSize
  local cs2 = cs * cs
  local haloSize = cs + 2
  local strideZ = haloSize
  local strideY = haloSize * haloSize

  local sizeX = self.sizeX
  local sizeY = self.sizeY
  local sizeZ = self.sizeZ
  local chunksX = self.chunksX
  local chunksY = self.chunksY
  local chunksZ = self.chunksZ
  local chunksPerLayer = chunksX * chunksZ

  local baseOriginX = (cx - 1) * cs
  local baseOriginY = (cy - 1) * cs
  local baseOriginZ = (cz - 1) * cs

  for hy = 0, cs + 1 do
    local scy, sly
    if hy == 0 then
      scy = cy - 1
      sly = cs
    elseif hy == cs + 1 then
      scy = cy + 1
      sly = 1
    else
      scy = cy
      sly = hy
    end

    local wy = baseOriginY + hy
    local syBase = (hy * strideY) + 1

    for hz = 0, cs + 1 do
      local scz, slz
      if hz == 0 then
        scz = cz - 1
        slz = cs
      elseif hz == cs + 1 then
        scz = cz + 1
        slz = 1
      else
        scz = cz
        slz = hz
      end

      local wz = baseOriginZ + hz
      local szBase = syBase + (hz * strideZ)

      for hx = 0, cs + 1 do
        local scx, slx
        if hx == 0 then
          scx = cx - 1
          slx = cs
        elseif hx == cs + 1 then
          scx = cx + 1
          slx = 1
        else
          scx = cx
          slx = hx
        end

        local wx = baseOriginX + hx
        local index = szBase + hx

        if wx < 1 or wx > sizeX
          or wy < 1 or wy > sizeY
          or wz < 1 or wz > sizeZ
          or scx < 1 or scx > chunksX
          or scy < 1 or scy > chunksY
          or scz < 1 or scz > chunksZ then
          out[index] = AIR
        else
          local chunkKey = scx + (scz - 1) * chunksX + (scy - 1) * chunksPerLayer
          local localIndex = (sly - 1) * cs2 + (slz - 1) * cs + slx
          out[index] = self:_getByChunkKey(chunkKey, localIndex, wx, wy, wz)
        end
      end
    end
  end

  local required = haloSize * haloSize * haloSize
  for i = required + 1, #out do
    out[i] = nil
  end

  return out
end

function ChunkWorld:set(x, y, z, value)
  if not self:isInside(x, y, z) then
    return false
  end

  if value == nil then
    value = self.constants.BLOCK.AIR
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  self:prepareChunk(cx, cy, cz)

  local chunkKey = self:chunkKey(cx, cy, cz)
  local localIndex = self:_localIndex(lx, ly, lz)

  local oldValue = self:get(x, y, z)
  if oldValue == value then
    return true
  end
  local oldOpacity = self:_getBlockLightOpacity(oldValue)
  local newOpacity = self:_getBlockLightOpacity(value)

  local baseValue = self:_getBaseWithFeaturesByKey(x, y, z, chunkKey, localIndex)
  local editChunk = self._editChunks[chunkKey]
  local previousEdit = editChunk and editChunk[localIndex] or nil

  if value == baseValue then
    if previousEdit ~= nil then
      editChunk[localIndex] = nil
      self._editCount = self._editCount - 1

      local remaining = (self._editChunkCounts[chunkKey] or 1) - 1
      if remaining <= 0 then
        self._editChunkCounts[chunkKey] = nil
        self._editChunks[chunkKey] = nil
      else
        self._editChunkCounts[chunkKey] = remaining
      end
    end
  else
    if not editChunk then
      editChunk = {}
      self._editChunks[chunkKey] = editChunk
      self._editChunkCounts[chunkKey] = 0
    end

    if previousEdit == nil then
      self._editCount = self._editCount + 1
      self._editChunkCounts[chunkKey] = (self._editChunkCounts[chunkKey] or 0) + 1
    end

    editChunk[localIndex] = value
  end

  self:_markDirty(cx, cy, cz)
  self:_markNeighborsIfBoundary(cx, cy, cz, lx, ly, lz)

  if oldOpacity ~= newOpacity then
    self:_onSkyOpacityChanged(x, z, cx, cz)
  end
  return true
end

function ChunkWorld:applyEditsBulk(edits, count)
  if not edits then
    return false, 0
  end

  local limit = math.floor(tonumber(count) or #edits)
  if limit <= 0 then
    return true, 0
  end

  local applied = 0
  local AIR = self.constants.BLOCK.AIR
  local opacityChanged = false

  for i = 1, limit do
    local entry = edits[i]
    if entry then
      local x = tonumber(entry[1])
      local y = tonumber(entry[2])
      local z = tonumber(entry[3])
      local value = tonumber(entry[4])
      if value == nil then
        value = AIR
      end

      if x and y and z and self:isInside(x, y, z) then
        local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
        self:prepareChunk(cx, cy, cz)

        local chunkKey = self:chunkKey(cx, cy, cz)
        local localIndex = self:_localIndex(lx, ly, lz)
        local baseValue = self:_getBaseWithFeaturesByKey(x, y, z, chunkKey, localIndex)
        local editChunk = self._editChunks[chunkKey]
        local previousEdit = editChunk and editChunk[localIndex] or nil
        local oldValue = previousEdit ~= nil and previousEdit or baseValue
        local oldOpacity = self:_getBlockLightOpacity(oldValue)
        local newOpacity = self:_getBlockLightOpacity(value)

        if oldValue ~= value then
          if value == baseValue then
            if previousEdit ~= nil then
              editChunk[localIndex] = nil
              self._editCount = self._editCount - 1

              local remaining = (self._editChunkCounts[chunkKey] or 1) - 1
              if remaining <= 0 then
                self._editChunkCounts[chunkKey] = nil
                self._editChunks[chunkKey] = nil
              else
                self._editChunkCounts[chunkKey] = remaining
              end
            end
          else
            if not editChunk then
              editChunk = {}
              self._editChunks[chunkKey] = editChunk
              self._editChunkCounts[chunkKey] = 0
            end

            if previousEdit == nil then
              self._editCount = self._editCount + 1
              self._editChunkCounts[chunkKey] = (self._editChunkCounts[chunkKey] or 0) + 1
            end

            editChunk[localIndex] = value
          end

          self:_markDirty(cx, cy, cz)
          self:_markNeighborsIfBoundary(cx, cy, cz, lx, ly, lz)
          if oldOpacity ~= newOpacity then
            opacityChanged = true
            self._skyColumnsReady[self:_worldColumnKey(x, z)] = nil
          end
          applied = applied + 1
        end
      end
    end
  end

  if opacityChanged then
    if self._lightingMode == 'floodfill' then
      self:_scheduleSkyRegionRebuild(false)
    else
      self._skyStage = 'idle'
      self:_clearSkyFloodQueue()
    end
  end

  return true, applied
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
  local y = (self.groundY or 7) + 3
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

function ChunkWorld:markDirtyRadius(centerCx, centerCz, radiusChunks)
  if self.chunksX <= 0 or self.chunksY <= 0 or self.chunksZ <= 0 then
    return
  end

  local cx = clampInt(math.floor(tonumber(centerCx) or 1), 1, self.chunksX)
  local cz = clampInt(math.floor(tonumber(centerCz) or 1), 1, self.chunksZ)
  local radius = math.floor(tonumber(radiusChunks) or 0)
  if radius < 0 then
    radius = 0
  end

  local minX = clampInt(cx - radius, 1, self.chunksX)
  local maxX = clampInt(cx + radius, 1, self.chunksX)
  local minZ = clampInt(cz - radius, 1, self.chunksZ)
  local maxZ = clampInt(cz + radius, 1, self.chunksZ)

  for markCz = minZ, maxZ do
    for markCx = minX, maxX do
      for markCy = 1, self.chunksY do
        self:_markDirty(markCx, markCy, markCz)
      end
    end
  end
end

function ChunkWorld:enqueueChunkSquare(centerCx, centerCz, radiusChunks, minCy, maxCy, outKeys)
  if not outKeys then
    return 0
  end
  if self.chunksX <= 0 or self.chunksY <= 0 or self.chunksZ <= 0 then
    return 0
  end

  local cx = clampInt(math.floor(tonumber(centerCx) or 1), 1, self.chunksX)
  local cz = clampInt(math.floor(tonumber(centerCz) or 1), 1, self.chunksZ)
  local radius = math.floor(tonumber(radiusChunks) or 0)
  if radius < 0 then
    radius = 0
  end

  local lowCy, highCy = self:_normalizeChunkYRange(minCy, maxCy)
  local minX = clampInt(cx - radius, 1, self.chunksX)
  local maxX = clampInt(cx + radius, 1, self.chunksX)
  local minZ = clampInt(cz - radius, 1, self.chunksZ)
  local maxZ = clampInt(cz + radius, 1, self.chunksZ)

  local count = 0
  for queueCz = minZ, maxZ do
    for queueCx = minX, maxX do
      for queueCy = lowCy, highCy do
        count = count + 1
        outKeys[count] = self:chunkKey(queueCx, queueCy, queueCz)
      end
    end
  end

  return count
end

function ChunkWorld:enqueueRingDelta(oldCx, oldCz, newCx, newCz, radiusChunks, minCy, maxCy, outKeys)
  if not outKeys then
    return 0
  end
  if self.chunksX <= 0 or self.chunksY <= 0 or self.chunksZ <= 0 then
    return 0
  end

  local fromCx = clampInt(math.floor(tonumber(oldCx) or 1), 1, self.chunksX)
  local fromCz = clampInt(math.floor(tonumber(oldCz) or 1), 1, self.chunksZ)
  local toCx = clampInt(math.floor(tonumber(newCx) or 1), 1, self.chunksX)
  local toCz = clampInt(math.floor(tonumber(newCz) or 1), 1, self.chunksZ)

  local dx = toCx - fromCx
  local dz = toCz - fromCz
  if dx == 0 and dz == 0 then
    return 0
  end
  if math.abs(dx) > 1 or math.abs(dz) > 1 then
    return -1
  end

  local radius = math.floor(tonumber(radiusChunks) or 0)
  if radius < 0 then
    radius = 0
  end
  local lowCy, highCy = self:_normalizeChunkYRange(minCy, maxCy)
  local minX = clampInt(toCx - radius, 1, self.chunksX)
  local maxX = clampInt(toCx + radius, 1, self.chunksX)
  local minZ = clampInt(toCz - radius, 1, self.chunksZ)
  local maxZ = clampInt(toCz + radius, 1, self.chunksZ)

  local count = 0
  local xColumn = nil

  if dx ~= 0 then
    xColumn = toCx + (dx > 0 and radius or -radius)
    if xColumn >= 1 and xColumn <= self.chunksX then
      for queueCz = minZ, maxZ do
        for queueCy = lowCy, highCy do
          count = count + 1
          outKeys[count] = self:chunkKey(xColumn, queueCy, queueCz)
        end
      end
    else
      xColumn = nil
    end
  end

  if dz ~= 0 then
    local zRow = toCz + (dz > 0 and radius or -radius)
    if zRow >= 1 and zRow <= self.chunksZ then
      for queueCx = minX, maxX do
        if not xColumn or queueCx ~= xColumn then
          for queueCy = lowCy, highCy do
            count = count + 1
            outKeys[count] = self:chunkKey(queueCx, queueCy, zRow)
          end
        end
      end
    end
  end

  return count
end

function ChunkWorld:generate()
  self:_computeGenerationThresholds()

  -- O(1) reset: no eager per-voxel terrain allocation.
  self._dirty = {}
  self._editChunks = {}
  self._editChunkCounts = {}
  self._featureChunks = {}
  self._featureColumnsPrepared = {}
  self._editCount = 0
  self:_resetSkyLightData()
end

function ChunkWorld:_placeTreeFeature(x, y, z, trunkHeight)
  local AIR = self.constants.BLOCK.AIR
  local WOOD = self.constants.BLOCK.WOOD
  local LEAF = self.constants.BLOCK.LEAF

  local trunkTop = math.min(y + trunkHeight - 1, self.sizeY)
  for iy = y, trunkTop do
    self:_setFeatureBlock(x, iy, z, WOOD)
  end

  local leafStart = y + trunkHeight - 2
  local maxY = math.min(self.sizeY - 2, y + trunkHeight + self._treeLeafPad)
  for iy = leafStart, maxY do
    local radius = (iy == maxY) and 1 or 2
    for dz = -radius, radius do
      for dx = -radius, radius do
        local ax = x + dx
        local az = z + dz
        if self:isInside(ax, iy, az) then
          local dist = math.abs(dx) + math.abs(dz)
          if dist <= radius + 1 and self:_getBaseWithFeatures(ax, iy, az) == AIR then
            self:_setFeatureBlock(ax, iy, az, LEAF)
          end
        end
      end
    end
  end
end

function ChunkWorld:_prepareColumnFeatures(cx, cz)
  local density = tonumber(self.constants.TREE_DENSITY) or 0
  if density <= 0 then
    return
  end

  local cs = self.chunkSize
  local originX = (cx - 1) * cs
  local originZ = (cz - 1) * cs

  local margin = 3
  local minLocal = margin + 1
  local maxLocal = cs - margin
  if minLocal > maxLocal then
    return
  end

  local treeY = self._genGrassY + 1
  if treeY < 1 or treeY > self.sizeY then
    return
  end

  local treeCy = math.floor((treeY - 1) / cs) + 1
  if treeCy < 1 or treeCy > self.chunksY then
    return
  end

  local chunkTopY = treeCy * cs
  local rng = makeRng(mixColumnSeed(self.constants.WORLD_SEED, cx, cz))
  local grass = self.constants.BLOCK.GRASS

  for lz = minLocal, maxLocal do
    local wz = originZ + lz
    if wz <= self.sizeZ then
      for lx = minLocal, maxLocal do
        local wx = originX + lx
        if wx <= self.sizeX and rng() < density then
          if self:_getBaseBlock(wx, self._genGrassY, wz) == grass then
            local trunkRange = self._treeTrunkMax - self._treeTrunkMin + 1
            local trunkHeight = self._treeTrunkMin + math.floor(rng() * trunkRange)
            if trunkHeight > self._treeTrunkMax then
              trunkHeight = self._treeTrunkMax
            end
            local maxY = math.min(self.sizeY - 2, treeY + trunkHeight + self._treeLeafPad)
            if maxY <= chunkTopY then
              self:_placeTreeFeature(wx, treeY, wz, trunkHeight)
            end
          end
        end
      end
    end
  end
end

function ChunkWorld:prepareChunk(cx, cy, cz)
  if cx < 1 or cx > self.chunksX or cz < 1 or cz > self.chunksZ then
    return
  end

  local columnKey = self:_columnKey(cx, cz)
  if self._featureColumnsPrepared[columnKey] then
    return
  end

  self._featureColumnsPrepared[columnKey] = true
  self:_prepareColumnFeatures(cx, cz)

  if self._lightingEnabled then
    local cs = self.chunkSize
    local minX = (cx - 1) * cs + 1
    local maxX = math.min(cx * cs, self.sizeX)
    local minZ = (cz - 1) * cs + 1
    local maxZ = math.min(cz * cs, self.sizeZ)
    for z = minZ, maxZ do
      for x = minX, maxX do
        self._skyColumnsReady[self:_worldColumnKey(x, z)] = nil
      end
    end
  end
end

function ChunkWorld:getEditCount()
  return self._editCount
end

function ChunkWorld:collectEdits(out)
  if not out then
    return 0
  end

  local count = 0
  local cs = self.chunkSize
  local cs2 = cs * cs

  for chunkKey, chunkEdits in pairs(self._editChunks) do
    local cx, cy, cz = self:decodeChunkKey(chunkKey)
    local originX = (cx - 1) * cs
    local originY = (cy - 1) * cs
    local originZ = (cz - 1) * cs

    for localIndex, blockId in pairs(chunkEdits) do
      local zeroBased = localIndex - 1
      local ly = math.floor(zeroBased / cs2) + 1
      local rem = zeroBased % cs2
      local lz = math.floor(rem / cs) + 1
      local lx = (rem % cs) + 1

      count = count + 1
      local entry = out[count]
      local worldX = originX + lx
      local worldY = originY + ly
      local worldZ = originZ + lz

      if entry then
        entry[1] = worldX
        entry[2] = worldY
        entry[3] = worldZ
        entry[4] = blockId
      else
        out[count] = { worldX, worldY, worldZ, blockId }
      end
    end
  end

  for i = count + 1, #out do
    out[i] = nil
  end

  return count
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

