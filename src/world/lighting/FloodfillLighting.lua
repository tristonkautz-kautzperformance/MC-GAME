local FloodfillLighting = {}
FloodfillLighting.__index = FloodfillLighting

local hasFfi, ffi = pcall(require, 'ffi')
if not hasFfi then
  ffi = nil
end

local function clampInt(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function asBool(v)
  return v and true or false
end

function FloodfillLighting.new(world, options)
  local self = setmetatable({}, FloodfillLighting)
  self.world = world
  self.options = options or {}
  self.enabled = self.options.enabled ~= false
  self.lightingConfig = self.options.lightingConfig or {}
  self.lightOpacityByBlock = self.options.lightOpacityByBlock or {}
  self.chunkVolume = world._chunkVolume or (world.chunkSize * world.chunkSize * world.chunkSize)
  self:reset()
  return self
end

function FloodfillLighting:reset()
  local world = self.world

  self.skyLightChunks = {}
  self.skyColumnsReady = {}

  self.skyColumnsQueue = {}
  self.skyColumnsQueueSet = {}
  self.skyColumnsQueueHead = 1
  self.skyColumnsQueueTail = 0

  self.skyFloodQueue = {}
  self.skyFloodQueueSet = {}
  self.skyFloodQueueHead = 1
  self.skyFloodQueueTail = 0

  self.skyStage = 'idle'
  self.skyTrackDirtyVertical = false
  self.skyTrackDirtyFlood = false

  self.skyCenterCx = clampInt(math.floor((world.chunksX + 1) * 0.5), 1, world.chunksX)
  self.skyCenterCz = clampInt(math.floor((world.chunksZ + 1) * 0.5), 1, world.chunksZ)
  self.skyKeepRadius = math.max(world.chunksX, world.chunksZ)

  self.skyActiveMinCx = 1
  self.skyActiveMaxCx = world.chunksX
  self.skyActiveMinCz = 1
  self.skyActiveMaxCz = world.chunksZ

  self.skyActiveMinX = 1
  self.skyActiveMaxX = world.sizeX
  self.skyActiveMinZ = 1
  self.skyActiveMaxZ = world.sizeZ
end

function FloodfillLighting:_getBlockLightOpacity(block)
  local value = self.lightOpacityByBlock[block]
  if value == nil then
    return 0
  end
  return value
end

function FloodfillLighting:_newSkyChunkData()
  if ffi then
    return ffi.new('uint8_t[?]', self.chunkVolume)
  end

  local data = {}
  for i = 1, self.chunkVolume do
    data[i] = 0
  end
  return data
end

function FloodfillLighting:_getSkyChunk(chunkKey, create)
  local chunk = self.skyLightChunks[chunkKey]
  if chunk or not create then
    return chunk
  end

  chunk = self:_newSkyChunkData()
  self.skyLightChunks[chunkKey] = chunk
  return chunk
end

function FloodfillLighting:_getSkyChunkValue(chunk, localIndex)
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

function FloodfillLighting:_setSkyChunkValue(chunk, localIndex, value)
  if ffi then
    chunk[localIndex - 1] = value
  else
    chunk[localIndex] = value
  end
end

function FloodfillLighting:_hasSkyColumnsQueue()
  return self.skyColumnsQueueHead <= self.skyColumnsQueueTail
end

function FloodfillLighting:_hasSkyFloodQueue()
  return self.skyFloodQueueHead <= self.skyFloodQueueTail
end

function FloodfillLighting:_setSkyStageFromQueues()
  if self:_hasSkyColumnsQueue() then
    self.skyStage = 'vertical'
    return
  end

  if self:_hasSkyFloodQueue() then
    self.skyStage = 'flood'
    return
  end

  self.skyStage = 'idle'
  self.skyTrackDirtyVertical = false
  self.skyTrackDirtyFlood = false
end

function FloodfillLighting:_enqueueSkyColumn(columnKey)
  if self.skyColumnsQueueSet[columnKey] then
    return false
  end

  local tail = self.skyColumnsQueueTail + 1
  self.skyColumnsQueueTail = tail
  self.skyColumnsQueue[tail] = columnKey
  self.skyColumnsQueueSet[columnKey] = true
  return true
end

function FloodfillLighting:_dequeueSkyColumn()
  local head = self.skyColumnsQueueHead
  local tail = self.skyColumnsQueueTail
  if head > tail then
    return nil
  end

  local columnKey = self.skyColumnsQueue[head]
  self.skyColumnsQueue[head] = nil
  self.skyColumnsQueueHead = head + 1
  if columnKey ~= nil then
    self.skyColumnsQueueSet[columnKey] = nil
  end

  if self.skyColumnsQueueHead > self.skyColumnsQueueTail then
    self.skyColumnsQueueHead = 1
    self.skyColumnsQueueTail = 0
  end

  return columnKey
end

function FloodfillLighting:_clearSkyColumnsQueue()
  local queue = self.skyColumnsQueue
  for i = self.skyColumnsQueueHead, self.skyColumnsQueueTail do
    queue[i] = nil
  end
  self.skyColumnsQueueHead = 1
  self.skyColumnsQueueTail = 0

  for columnKey in pairs(self.skyColumnsQueueSet) do
    self.skyColumnsQueueSet[columnKey] = nil
  end
end

function FloodfillLighting:_enqueueSkyFlood(worldIndex)
  if self.skyFloodQueueSet[worldIndex] then
    return false
  end

  local tail = self.skyFloodQueueTail + 1
  self.skyFloodQueueTail = tail
  self.skyFloodQueue[tail] = worldIndex
  self.skyFloodQueueSet[worldIndex] = true
  return true
end

function FloodfillLighting:_dequeueSkyFlood()
  local head = self.skyFloodQueueHead
  local tail = self.skyFloodQueueTail
  if head > tail then
    return nil
  end

  local worldIndex = self.skyFloodQueue[head]
  self.skyFloodQueue[head] = nil
  self.skyFloodQueueHead = head + 1
  if worldIndex ~= nil then
    self.skyFloodQueueSet[worldIndex] = nil
  end

  if self.skyFloodQueueHead > self.skyFloodQueueTail then
    self.skyFloodQueueHead = 1
    self.skyFloodQueueTail = 0
  end

  return worldIndex
end

function FloodfillLighting:_clearSkyFloodQueue()
  local queue = self.skyFloodQueue
  for i = self.skyFloodQueueHead, self.skyFloodQueueTail do
    queue[i] = nil
  end
  self.skyFloodQueueHead = 1
  self.skyFloodQueueTail = 0

  for worldIndex in pairs(self.skyFloodQueueSet) do
    self.skyFloodQueueSet[worldIndex] = nil
  end
end

function FloodfillLighting:_isInsideSkyActiveWorldXZ(x, z)
  return x >= self.skyActiveMinX
    and x <= self.skyActiveMaxX
    and z >= self.skyActiveMinZ
    and z <= self.skyActiveMaxZ
end

function FloodfillLighting:_getSkyLightWorld(x, y, z)
  local world = self.world
  if x < 1 or x > world.sizeX or z < 1 or z > world.sizeZ then
    return 0
  end
  if y > world.sizeY then
    return 15
  end
  if y < 1 then
    return 0
  end

  local cx, cy, cz, lx, ly, lz = world:_toChunkCoords(x, y, z)
  local chunkKey = world:chunkKey(cx, cy, cz)
  local chunk = self.skyLightChunks[chunkKey]
  if not chunk then
    return 0
  end

  local localIndex = world:_localIndex(lx, ly, lz)
  return self:_getSkyChunkValue(chunk, localIndex)
end

function FloodfillLighting:_setSkyLightWorld(x, y, z, value, markDirty, createIfMissing)
  local world = self.world
  if not world:isInside(x, y, z) then
    return false
  end

  if createIfMissing == nil then
    createIfMissing = true
  end

  local cx, cy, cz, lx, ly, lz = world:_toChunkCoords(x, y, z)
  local chunkKey = world:chunkKey(cx, cy, cz)
  local chunk = self:_getSkyChunk(chunkKey, createIfMissing)
  if not chunk then
    return false
  end

  local localIndex = world:_localIndex(lx, ly, lz)
  local oldValue = self:_getSkyChunkValue(chunk, localIndex)
  if oldValue == value then
    return false
  end

  self:_setSkyChunkValue(chunk, localIndex, value)
  if markDirty then
    world:_markDirty(cx, cy, cz)
    if world._markNeighborsIfBoundary then
      world:_markNeighborsIfBoundary(cx, cy, cz, lx, ly, lz)
    end
  end
  return true
end

function FloodfillLighting:_recomputeSkyColumn(x, z, enqueueFlood, markDirty)
  local world = self.world
  if x < 1 or x > world.sizeX or z < 1 or z > world.sizeZ then
    return false
  end

  local columnKey = world:_worldColumnKey(x, z)
  local light = 15

  for y = world.sizeY, 1, -1 do
    local block = world:get(x, y, z)
    local opacity = self:_getBlockLightOpacity(block)
    light = light - opacity
    if light < 0 then
      light = 0
    end

    local changed = self:_setSkyLightWorld(x, y, z, light, markDirty, true)
    if enqueueFlood and changed and light > 1 then
      self:_enqueueSkyFlood(world:_worldIndex(x, y, z))
    end

    if light == 0 and opacity >= 15 then
      for clearY = y - 1, 1, -1 do
        self:_setSkyLightWorld(x, clearY, z, 0, markDirty, true)
      end
      break
    end
  end

  self.skyColumnsReady[columnKey] = true
  if enqueueFlood then
    self:_setSkyStageFromQueues()
  end
  return true
end

function FloodfillLighting:_ensureSkyColumnReady(x, z, enqueueFlood, markDirty)
  local world = self.world
  if x < 1 or x > world.sizeX or z < 1 or z > world.sizeZ then
    return false
  end

  local columnKey = world:_worldColumnKey(x, z)
  if self.skyColumnsReady[columnKey] then
    return true
  end

  return self:_recomputeSkyColumn(x, z, enqueueFlood, markDirty)
end

function FloodfillLighting:_ensureSkyHaloColumns(cx, cz, enqueueFlood, markDirty)
  local world = self.world
  local cs = world.chunkSize
  local minX = (cx - 1) * cs
  local maxX = cx * cs + 1
  local minZ = (cz - 1) * cs
  local maxZ = cz * cs + 1

  for z = minZ, maxZ do
    if z >= 1 and z <= world.sizeZ then
      for x = minX, maxX do
        if x >= 1 and x <= world.sizeX then
          self:_ensureSkyColumnReady(x, z, enqueueFlood, markDirty)
        end
      end
    end
  end
end

function FloodfillLighting:_clearSkyBounds(minX, maxX, minZ, maxZ)
  local world = self.world
  for z = minZ, maxZ do
    for x = minX, maxX do
      for y = 1, world.sizeY do
        self:_setSkyLightWorld(x, y, z, 0, false, false)
      end
    end
  end
end

function FloodfillLighting:_scheduleSkyBoundsRebuild(minX, maxX, minZ, maxZ, trackDirty, resetQueues, clearOld)
  if not self.enabled then
    return 0
  end

  local world = self.world
  local bx0 = clampInt(math.floor(tonumber(minX) or 1), 1, world.sizeX)
  local bx1 = clampInt(math.floor(tonumber(maxX) or world.sizeX), 1, world.sizeX)
  local bz0 = clampInt(math.floor(tonumber(minZ) or 1), 1, world.sizeZ)
  local bz1 = clampInt(math.floor(tonumber(maxZ) or world.sizeZ), 1, world.sizeZ)

  if bx1 < bx0 or bz1 < bz0 then
    return 0
  end

  if bx0 < self.skyActiveMinX then bx0 = self.skyActiveMinX end
  if bx1 > self.skyActiveMaxX then bx1 = self.skyActiveMaxX end
  if bz0 < self.skyActiveMinZ then bz0 = self.skyActiveMinZ end
  if bz1 > self.skyActiveMaxZ then bz1 = self.skyActiveMaxZ end
  if bx1 < bx0 or bz1 < bz0 then
    return 0
  end

  if resetQueues then
    self:_clearSkyColumnsQueue()
    self:_clearSkyFloodQueue()
  end

  if clearOld then
    self:_clearSkyBounds(bx0, bx1, bz0, bz1)
  end

  local queued = 0
  for z = bz0, bz1 do
    for x = bx0, bx1 do
      local columnKey = world:_worldColumnKey(x, z)
      self.skyColumnsReady[columnKey] = nil
      if self:_enqueueSkyColumn(columnKey) then
        queued = queued + 1
      end
    end
  end

  if queued > 0 then
    local dirty = asBool(trackDirty)
    self.skyTrackDirtyVertical = dirty
    self.skyTrackDirtyFlood = dirty
    self:_setSkyStageFromQueues()
  elseif resetQueues then
    self:_setSkyStageFromQueues()
  end

  return queued
end

function FloodfillLighting:_scheduleSkyLocalRebuild(centerX, centerZ, radiusBlocks, trackDirty)
  local x = tonumber(centerX) or 1
  local z = tonumber(centerZ) or 1
  local radius = math.floor(tonumber(radiusBlocks) or 15)
  if radius < 0 then
    radius = 0
  end

  return self:_scheduleSkyBoundsRebuild(
    x - radius,
    x + radius,
    z - radius,
    z + radius,
    trackDirty,
    true,
    true
  )
end

function FloodfillLighting:_primeSkyLightAfterOpacityEdit()
  if not self.enabled then
    return 0
  end

  local config = self.lightingConfig or {}
  local immediateOps = math.floor(tonumber(config.editImmediateOps) or 8192)
  if immediateOps <= 0 then
    return 0
  end

  local immediateMillis = tonumber(config.editImmediateMillis)
  if immediateMillis == nil then
    immediateMillis = 0
  end

  return self:updateSkyLight(immediateOps, immediateMillis)
end

function FloodfillLighting:_drainSkyLightForMeshPrep()
  if not self.enabled then
    return 0
  end

  local config = self.lightingConfig or {}
  local immediateOps = math.floor(tonumber(config.meshImmediateOps) or 256)
  if immediateOps <= 0 then
    return 0
  end

  local immediateMillis = tonumber(config.meshImmediateMillis)
  if immediateMillis == nil then
    immediateMillis = 0
  end

  return self:updateSkyLight(immediateOps, immediateMillis)
end

function FloodfillLighting:_queueSkyRegionDelta(oldMinX, oldMaxX, oldMinZ, oldMaxZ)
  if not self.enabled then
    return 0
  end

  local world = self.world
  local oldHasRegion = oldMaxX and oldMinX and oldMaxX >= oldMinX and oldMaxZ and oldMinZ and oldMaxZ >= oldMinZ
  local queued = 0

  for z = self.skyActiveMinZ, self.skyActiveMaxZ do
    for x = self.skyActiveMinX, self.skyActiveMaxX do
      local inOldRegion = oldHasRegion
        and x >= oldMinX and x <= oldMaxX
        and z >= oldMinZ and z <= oldMaxZ

      if not inOldRegion then
        local columnKey = world:_worldColumnKey(x, z)
        self.skyColumnsReady[columnKey] = nil
        if self:_enqueueSkyColumn(columnKey) then
          queued = queued + 1
        end
      end
    end
  end

  if queued > 0 then
    self.skyTrackDirtyVertical = false
    self.skyTrackDirtyFlood = true
    self:_setSkyStageFromQueues()
  end

  return queued
end

function FloodfillLighting:_propagateSkyFloodFrom(worldIndex, markDirty)
  local world = self.world
  local x, y, z = world:_decodeWorldIndex(worldIndex)
  if not self:_isInsideSkyActiveWorldXZ(x, z) then
    return
  end

  local sourceLight = self:_getSkyLightWorld(x, y, z)
  if sourceLight <= 1 then
    return
  end

  local function tryNeighbor(nx, ny, nz)
    if nx < 1 or nx > world.sizeX then
      return
    end
    if ny < 1 or ny > world.sizeY then
      return
    end
    if nz < 1 or nz > world.sizeZ then
      return
    end
    if not self:_isInsideSkyActiveWorldXZ(nx, nz) then
      return
    end

    local block = world:get(nx, ny, nz)
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
      if self:_setSkyLightWorld(nx, ny, nz, candidate, markDirty, true) then
        self:_enqueueSkyFlood(world:_worldIndex(nx, ny, nz))
      end
    end
  end

  tryNeighbor(x - 1, y, z)
  tryNeighbor(x + 1, y, z)
  tryNeighbor(x, y - 1, z)
  tryNeighbor(x, y + 1, z)
  tryNeighbor(x, y, z - 1)
  tryNeighbor(x, y, z + 1)
end

function FloodfillLighting:getSkyLight(x, y, z)
  local world = self.world
  if not self.enabled then
    return 15
  end

  if y > world.sizeY and x >= 1 and x <= world.sizeX and z >= 1 and z <= world.sizeZ then
    return 15
  end
  if not world:isInside(x, y, z) then
    return 0
  end

  self:_ensureSkyColumnReady(x, z, true, false)
  return self:_getSkyLightWorld(x, y, z)
end

function FloodfillLighting:ensureSkyLightForChunk(cx, cy, cz)
  local world = self.world
  if not self.enabled then
    return true
  end

  if cx < 1 or cx > world.chunksX
    or cy < 1 or cy > world.chunksY
    or cz < 1 or cz > world.chunksZ then
    return false
  end

  world:prepareChunk(cx, cy, cz)
  self:_ensureSkyHaloColumns(cx, cz, true, false)
  return true
end

function FloodfillLighting:fillSkyLightHalo(cx, cy, cz, out)
  if not out then
    return nil
  end

  local world = self.world
  local cs = world.chunkSize
  local haloSize = cs + 2
  local required = haloSize * haloSize * haloSize

  if not self.enabled then
    for i = 1, required do
      out[i] = 15
    end
    for i = required + 1, #out do
      out[i] = nil
    end
    return out
  end

  self:_ensureSkyHaloColumns(cx, cz, true, false)
  self:_drainSkyLightForMeshPrep()

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

        if wx < 1 or wx > world.sizeX or wz < 1 or wz > world.sizeZ or wy < 1 then
          out[index] = 0
        elseif wy > world.sizeY then
          out[index] = 15
        else
          out[index] = self:_getSkyLightWorld(wx, wy, wz)
        end
      end
    end
  end

  for i = required + 1, #out do
    out[i] = nil
  end
  return out
end

function FloodfillLighting:updateSkyLight(maxOps, maxMillis)
  if not self.enabled then
    return 0
  end

  self:_setSkyStageFromQueues()
  if self.skyStage == 'idle' then
    return 0
  end

  local config = self.lightingConfig or {}
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

  local world = self.world
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

    local columnKey = self:_dequeueSkyColumn()
    if columnKey then
      local x, z = world:_decodeWorldColumnKey(columnKey)
      if self:_isInsideSkyActiveWorldXZ(x, z) and not self.skyColumnsReady[columnKey] then
        self:_recomputeSkyColumn(x, z, true, self.skyTrackDirtyVertical)
      end
      processed = processed + 1
    else
      local worldIndex = self:_dequeueSkyFlood()
      if not worldIndex then
        break
      end
      self:_propagateSkyFloodFrom(worldIndex, self.skyTrackDirtyFlood)
      processed = processed + 1
    end
  end

  self:_setSkyStageFromQueues()
  return processed
end

function FloodfillLighting:pruneSkyLightChunks(centerCx, centerCz, keepRadiusChunks)
  if not self.enabled then
    return 0
  end

  local world = self.world
  local oldMinX = self.skyActiveMinX
  local oldMaxX = self.skyActiveMaxX
  local oldMinZ = self.skyActiveMinZ
  local oldMaxZ = self.skyActiveMaxZ

  local cx = clampInt(math.floor(tonumber(centerCx) or 1), 1, world.chunksX)
  local cz = clampInt(math.floor(tonumber(centerCz) or 1), 1, world.chunksZ)
  local keepRadius = math.floor(tonumber(keepRadiusChunks) or 0)
  if keepRadius < 0 then
    keepRadius = 0
  end

  local config = self.lightingConfig or {}
  local extraRadius = math.floor(tonumber(config.floodfillExtraKeepRadiusChunks) or 1)
  if extraRadius < 0 then
    extraRadius = 0
  end

  local radius = keepRadius + extraRadius
  local minCx = clampInt(cx - radius, 1, world.chunksX)
  local maxCx = clampInt(cx + radius, 1, world.chunksX)
  local minCz = clampInt(cz - radius, 1, world.chunksZ)
  local maxCz = clampInt(cz + radius, 1, world.chunksZ)

  local regionChanged = cx ~= self.skyCenterCx
    or cz ~= self.skyCenterCz
    or radius ~= self.skyKeepRadius
    or minCx ~= self.skyActiveMinCx
    or maxCx ~= self.skyActiveMaxCx
    or minCz ~= self.skyActiveMinCz
    or maxCz ~= self.skyActiveMaxCz

  self.skyCenterCx = cx
  self.skyCenterCz = cz
  self.skyKeepRadius = radius
  self.skyActiveMinCx = minCx
  self.skyActiveMaxCx = maxCx
  self.skyActiveMinCz = minCz
  self.skyActiveMaxCz = maxCz
  self.skyActiveMinX = (minCx - 1) * world.chunkSize + 1
  self.skyActiveMaxX = math.min(maxCx * world.chunkSize, world.sizeX)
  self.skyActiveMinZ = (minCz - 1) * world.chunkSize + 1
  self.skyActiveMaxZ = math.min(maxCz * world.chunkSize, world.sizeZ)

  local removed = 0
  for chunkKey in pairs(self.skyLightChunks) do
    local chunkX, _, chunkZ = world:decodeChunkKey(chunkKey)
    if chunkX < minCx or chunkX > maxCx or chunkZ < minCz or chunkZ > maxCz then
      self.skyLightChunks[chunkKey] = nil
      removed = removed + 1
    end
  end

  for columnKey in pairs(self.skyColumnsReady) do
    local x, z = world:_decodeWorldColumnKey(columnKey)
    if x < self.skyActiveMinX or x > self.skyActiveMaxX or z < self.skyActiveMinZ or z > self.skyActiveMaxZ then
      self.skyColumnsReady[columnKey] = nil
    end
  end

  if regionChanged then
    self:_queueSkyRegionDelta(oldMinX, oldMaxX, oldMinZ, oldMaxZ)
  end

  return removed
end

function FloodfillLighting:onOpacityChanged(x, z, cx, cz)
  if not self.enabled then
    return
  end

  local world = self.world
  self.skyColumnsReady[world:_worldColumnKey(x, z)] = nil

  local queued = self:_scheduleSkyLocalRebuild(x, z, 15, true)
  if queued > 0 then
    self:_primeSkyLightAfterOpacityEdit()
  end
end

function FloodfillLighting:onBulkOpacityChanged(minX, maxX, minZ, maxZ)
  if not self.enabled or minX == nil or maxX == nil or minZ == nil or maxZ == nil then
    return
  end

  local radius = 15
  local queued = self:_scheduleSkyBoundsRebuild(
    minX - radius,
    maxX + radius,
    minZ - radius,
    maxZ + radius,
    true,
    true,
    true
  )
  if queued > 0 then
    self:_primeSkyLightAfterOpacityEdit()
  end
end

function FloodfillLighting:onPrepareChunk(cx, cz)
  if not self.enabled then
    return
  end

  local world = self.world
  local cs = world.chunkSize
  local minX = (cx - 1) * cs + 1
  local maxX = math.min(cx * cs, world.sizeX)
  local minZ = (cz - 1) * cs + 1
  local maxZ = math.min(cz * cs, world.sizeZ)

  for z = minZ, maxZ do
    for x = minX, maxX do
      self.skyColumnsReady[world:_worldColumnKey(x, z)] = nil
    end
  end
end

return FloodfillLighting
