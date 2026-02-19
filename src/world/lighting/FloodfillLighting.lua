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
  self.skyColumnsUrgentCount = 0

  self.skyFloodQueue = {}
  self.skyFloodQueueSet = {}
  self.skyFloodQueueHead = 1
  self.skyFloodQueueTail = 0
  self.skyFloodUrgentCount = 0

  self.skyDarkQueue = {}
  self.skyDarkQueueLevels = {}
  self.skyDarkQueuePriority = {}
  self.skyDarkQueueHead = 1
  self.skyDarkQueueTail = 0
  self.skyDarkUrgentCount = 0

  self.skyStage = 'idle'
  self.skyTrackDirtyVertical = false
  self.skyTrackDirtyFlood = false
  self.skyWarmupActive = false

  -- Start with no active region so first prune call can enqueue initial relight work.
  self.skyCenterCx = 0
  self.skyCenterCz = 0
  self.skyKeepRadius = -1

  self.skyActiveMinCx = 1
  self.skyActiveMaxCx = 0
  self.skyActiveMinCz = 1
  self.skyActiveMaxCz = 0

  self.skyActiveMinX = 1
  self.skyActiveMaxX = 0
  self.skyActiveMinZ = 1
  self.skyActiveMaxZ = 0

  self.skyPropMinX = nil
  self.skyPropMaxX = nil
  self.skyPropMinZ = nil
  self.skyPropMaxZ = nil

  self.skyRegionTasks = {}
  self.skyRegionTaskHead = 1
  self.skyRegionTaskTail = 0
  self.skyRegionTaskCount = 0
  self.skyRegionOpsPending = 0
  self.skyRegionOpsProcessedLast = 0
  self.skyRegionTaskPool = {}

  self._frameMsHint = 0
  self._worstFrameMsHint = 0
  self._chunkEnsureScaleLast = 1
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

function FloodfillLighting:_hasSkyDarkQueue()
  return self.skyDarkQueueHead <= self.skyDarkQueueTail
end

function FloodfillLighting:_hasUrgentWork()
  return self.skyColumnsUrgentCount > 0
    or self.skyDarkUrgentCount > 0
    or self.skyFloodUrgentCount > 0
end

function FloodfillLighting:_hasSkyQueueWork()
  return self:_hasSkyColumnsQueue()
    or self:_hasSkyDarkQueue()
    or self:_hasSkyFloodQueue()
end

function FloodfillLighting:_setSkyStageFromQueues()
  if self:_hasSkyColumnsQueue() then
    self.skyStage = 'vertical'
    return
  end

  if self:_hasSkyDarkQueue() then
    self.skyStage = 'dark'
    return
  end

  if self:_hasSkyFloodQueue() then
    self.skyStage = 'flood'
    return
  end

  if self:_hasRegionTasks() then
    self.skyStage = 'idle'
    return
  end

  self.skyStage = 'idle'
  self.skyTrackDirtyVertical = false
  self.skyTrackDirtyFlood = false
  self.skyWarmupActive = false
  self:_clearSkyPropagationBounds()
end

function FloodfillLighting:_hasRegionTasks()
  return self.skyRegionTaskHead <= self.skyRegionTaskTail
end

function FloodfillLighting:_acquireRegionTask(kind, x1, z, x, urgent, opsRemaining)
  local pool = self.skyRegionTaskPool
  local task = pool[#pool]
  if task then
    pool[#pool] = nil
  else
    task = {}
  end

  task.kind = kind
  task.x1 = x1
  task.z = z
  task.x = x
  task.urgent = urgent and true or false
  task.opsRemaining = opsRemaining
  return task
end

function FloodfillLighting:_recycleRegionTask(task)
  if not task then
    return
  end
  task.kind = nil
  task.x1 = nil
  task.z = nil
  task.x = nil
  task.urgent = nil
  task.opsRemaining = nil
  local pool = self.skyRegionTaskPool
  pool[#pool + 1] = task
end

function FloodfillLighting:_clearRegionTasks()
  local tasks = self.skyRegionTasks
  for i = self.skyRegionTaskHead, self.skyRegionTaskTail do
    local task = tasks[i]
    tasks[i] = nil
    if task then
      self:_recycleRegionTask(task)
    end
  end
  self.skyRegionTaskHead = 1
  self.skyRegionTaskTail = 0
  self.skyRegionTaskCount = 0
  self.skyRegionOpsPending = 0
  self.skyRegionOpsProcessedLast = 0
end

function FloodfillLighting:_enqueueRegionTask(task)
  if not task then
    return 0
  end

  local opsRemaining = math.floor(tonumber(task.opsRemaining) or 0)
  if opsRemaining <= 0 then
    return 0
  end

  task.opsRemaining = opsRemaining
  local tail = self.skyRegionTaskTail + 1
  self.skyRegionTaskTail = tail
  self.skyRegionTasks[tail] = task
  self.skyRegionTaskCount = self.skyRegionTaskCount + 1
  self.skyRegionOpsPending = self.skyRegionOpsPending + opsRemaining
  return opsRemaining
end

function FloodfillLighting:_peekRegionTask()
  if self.skyRegionTaskHead > self.skyRegionTaskTail then
    return nil
  end
  return self.skyRegionTasks[self.skyRegionTaskHead]
end

function FloodfillLighting:_popRegionTask()
  if self.skyRegionTaskHead > self.skyRegionTaskTail then
    self.skyRegionTaskHead = 1
    self.skyRegionTaskTail = 0
    self.skyRegionTaskCount = 0
    return
  end

  local head = self.skyRegionTaskHead
  local task = self.skyRegionTasks[head]
  self.skyRegionTasks[head] = nil
  self.skyRegionTaskHead = head + 1
  if self.skyRegionTaskCount > 0 then
    self.skyRegionTaskCount = self.skyRegionTaskCount - 1
  end

  if self.skyRegionTaskHead > self.skyRegionTaskTail then
    self.skyRegionTaskHead = 1
    self.skyRegionTaskTail = 0
    self.skyRegionTaskCount = 0
  end
  self:_recycleRegionTask(task)
end

function FloodfillLighting:_scheduleRegionQueueColumnsRows(minX, maxX, minZ, maxZ, urgent, clipToActive)
  local world = self.world
  local bx0 = clampInt(math.floor(tonumber(minX) or 1), 1, world.sizeX)
  local bx1 = clampInt(math.floor(tonumber(maxX) or world.sizeX), 1, world.sizeX)
  local bz0 = clampInt(math.floor(tonumber(minZ) or 1), 1, world.sizeZ)
  local bz1 = clampInt(math.floor(tonumber(maxZ) or world.sizeZ), 1, world.sizeZ)
  if bx1 < bx0 or bz1 < bz0 then
    return 0
  end

  if clipToActive then
    if bx0 < self.skyActiveMinX then bx0 = self.skyActiveMinX end
    if bx1 > self.skyActiveMaxX then bx1 = self.skyActiveMaxX end
    if bz0 < self.skyActiveMinZ then bz0 = self.skyActiveMinZ end
    if bz1 > self.skyActiveMaxZ then bz1 = self.skyActiveMaxZ end
    if bx1 < bx0 or bz1 < bz0 then
      return 0
    end
  end

  local width = bx1 - bx0 + 1
  local scheduled = 0
  local isUrgent = urgent and true or false
  for z = bz0, bz1 do
    local task = self:_acquireRegionTask('queue_columns_row', bx1, z, bx0, isUrgent, width)
    scheduled = scheduled + self:_enqueueRegionTask(task)
  end
  return scheduled
end

function FloodfillLighting:_scheduleRegionRemoveReadyRows(minX, maxX, minZ, maxZ)
  local world = self.world
  local bx0 = clampInt(math.floor(tonumber(minX) or 1), 1, world.sizeX)
  local bx1 = clampInt(math.floor(tonumber(maxX) or world.sizeX), 1, world.sizeX)
  local bz0 = clampInt(math.floor(tonumber(minZ) or 1), 1, world.sizeZ)
  local bz1 = clampInt(math.floor(tonumber(maxZ) or world.sizeZ), 1, world.sizeZ)
  if bx1 < bx0 or bz1 < bz0 then
    return 0
  end

  local width = bx1 - bx0 + 1
  local scheduled = 0
  for z = bz0, bz1 do
    local task = self:_acquireRegionTask('remove_ready_row', bx1, z, bx0, false, width)
    scheduled = scheduled + self:_enqueueRegionTask(task)
  end
  return scheduled
end

function FloodfillLighting:_processRegionTasks(maxOps, maxMillis)
  if not self:_hasRegionTasks() then
    self.skyRegionOpsProcessedLast = 0
    return 0
  end

  local explicitOpsLimit = maxOps ~= nil
  local opsLimit = tonumber(maxOps)
  if opsLimit ~= nil then
    opsLimit = math.floor(opsLimit)
    if opsLimit < 0 then
      opsLimit = 0
    end
  end

  local millisLimit = tonumber(maxMillis)
  local hasTimer = lovr and lovr.timer and lovr.timer.getTime
  local useTimeBudget = hasTimer and millisLimit and millisLimit > 0
  local startTime = 0
  if useTimeBudget then
    startTime = lovr.timer.getTime()
  end

  if (not opsLimit or opsLimit <= 0) and not useTimeBudget then
    if explicitOpsLimit then
      self.skyRegionOpsProcessedLast = 0
      return 0
    end
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

    local task = self:_peekRegionTask()
    if not task then
      break
    end

    local stepDone = false
    if task.kind == 'queue_columns_row' then
      local x = task.x
      if x and x <= task.x1 then
        if self:_isInsideSkyActiveWorldXZ(x, task.z) then
          local columnKey = world:_worldColumnKey(x, task.z)
          self.skyColumnsReady[columnKey] = nil
          self:_enqueueSkyColumn(columnKey, task.urgent)
        end
        task.x = x + 1
        stepDone = true
      end
    elseif task.kind == 'remove_ready_row' then
      local x = task.x
      if x and x <= task.x1 then
        self.skyColumnsReady[world:_worldColumnKey(x, task.z)] = nil
        task.x = x + 1
        stepDone = true
      end
    end

    if not stepDone then
      self:_popRegionTask()
    else
      processed = processed + 1
      task.opsRemaining = (task.opsRemaining or 1) - 1
      if self.skyRegionOpsPending > 0 then
        self.skyRegionOpsPending = self.skyRegionOpsPending - 1
      end
      if task.opsRemaining <= 0 then
        self:_popRegionTask()
      end
    end
  end

  if self.skyRegionOpsPending < 0 then
    self.skyRegionOpsPending = 0
  end
  self.skyRegionOpsProcessedLast = processed
  return processed
end

function FloodfillLighting:setFrameTiming(frameMs, worstFrameMs)
  self._frameMsHint = tonumber(frameMs) or 0
  self._worstFrameMsHint = tonumber(worstFrameMs) or self._frameMsHint
end

function FloodfillLighting:getPerfStats()
  return self.skyRegionOpsProcessedLast or 0,
    self.skyRegionOpsPending or 0,
    self.skyRegionTaskCount or 0,
    self._chunkEnsureScaleLast or 1
end

function FloodfillLighting:hasUrgentSkyWork()
  return self:_hasUrgentWork()
end

function FloodfillLighting:hasSkyWork()
  return self:_hasSkyQueueWork() or self:_hasRegionTasks()
end

function FloodfillLighting:_enqueueSkyColumn(columnKey, urgent)
  local priority = self.skyColumnsQueueSet[columnKey]
  if priority == nil then
    priority = urgent and 1 or 0
    self.skyColumnsQueueSet[columnKey] = priority
    if priority == 1 then
      self.skyColumnsUrgentCount = self.skyColumnsUrgentCount + 1
      local head = self.skyColumnsQueueHead - 1
      self.skyColumnsQueueHead = head
      self.skyColumnsQueue[head] = columnKey
    else
      local tail = self.skyColumnsQueueTail + 1
      self.skyColumnsQueueTail = tail
      self.skyColumnsQueue[tail] = columnKey
    end
    return true
  end

  if urgent and priority == 0 then
    self.skyColumnsQueueSet[columnKey] = 1
    self.skyColumnsUrgentCount = self.skyColumnsUrgentCount + 1
    local head = self.skyColumnsQueueHead - 1
    self.skyColumnsQueueHead = head
    self.skyColumnsQueue[head] = columnKey
    return true
  end

  return false
end

function FloodfillLighting:_dequeueSkyColumn()
  local queue = self.skyColumnsQueue
  local set = self.skyColumnsQueueSet

  while self.skyColumnsQueueHead <= self.skyColumnsQueueTail do
    local head = self.skyColumnsQueueHead
    local columnKey = queue[head]
    queue[head] = nil
    self.skyColumnsQueueHead = head + 1

    if columnKey ~= nil then
      local priority = set[columnKey]
      if priority ~= nil then
        set[columnKey] = nil
        if priority == 1 and self.skyColumnsUrgentCount > 0 then
          self.skyColumnsUrgentCount = self.skyColumnsUrgentCount - 1
        end
        if self.skyColumnsQueueHead > self.skyColumnsQueueTail then
          self.skyColumnsQueueHead = 1
          self.skyColumnsQueueTail = 0
        end
        return columnKey, priority == 1
      end
    end
  end

  self.skyColumnsQueueHead = 1
  self.skyColumnsQueueTail = 0
  return nil, false
end

function FloodfillLighting:_clearSkyColumnsQueue()
  self.skyColumnsQueue = {}
  self.skyColumnsQueueSet = {}
  self.skyColumnsQueueHead = 1
  self.skyColumnsQueueTail = 0
  self.skyColumnsUrgentCount = 0
end

function FloodfillLighting:_enqueueSkyFlood(worldIndex, urgent)
  local priority = self.skyFloodQueueSet[worldIndex]
  if priority == nil then
    priority = urgent and 1 or 0
    self.skyFloodQueueSet[worldIndex] = priority
    if priority == 1 then
      self.skyFloodUrgentCount = self.skyFloodUrgentCount + 1
      local head = self.skyFloodQueueHead - 1
      self.skyFloodQueueHead = head
      self.skyFloodQueue[head] = worldIndex
    else
      local tail = self.skyFloodQueueTail + 1
      self.skyFloodQueueTail = tail
      self.skyFloodQueue[tail] = worldIndex
    end
    return true
  end

  if urgent and priority == 0 then
    self.skyFloodQueueSet[worldIndex] = 1
    self.skyFloodUrgentCount = self.skyFloodUrgentCount + 1
    local head = self.skyFloodQueueHead - 1
    self.skyFloodQueueHead = head
    self.skyFloodQueue[head] = worldIndex
    return true
  end

  return false
end

function FloodfillLighting:_dequeueSkyFlood()
  local queue = self.skyFloodQueue
  local set = self.skyFloodQueueSet

  while self.skyFloodQueueHead <= self.skyFloodQueueTail do
    local head = self.skyFloodQueueHead
    local worldIndex = queue[head]
    queue[head] = nil
    self.skyFloodQueueHead = head + 1

    if worldIndex ~= nil then
      local priority = set[worldIndex]
      if priority ~= nil then
        set[worldIndex] = nil
        if priority == 1 and self.skyFloodUrgentCount > 0 then
          self.skyFloodUrgentCount = self.skyFloodUrgentCount - 1
        end
        if self.skyFloodQueueHead > self.skyFloodQueueTail then
          self.skyFloodQueueHead = 1
          self.skyFloodQueueTail = 0
        end
        return worldIndex, priority == 1
      end
    end
  end

  self.skyFloodQueueHead = 1
  self.skyFloodQueueTail = 0
  return nil, false
end

function FloodfillLighting:_clearSkyFloodQueue()
  self.skyFloodQueue = {}
  self.skyFloodQueueSet = {}
  self.skyFloodQueueHead = 1
  self.skyFloodQueueTail = 0
  self.skyFloodUrgentCount = 0
end

function FloodfillLighting:_enqueueSkyDark(worldIndex, removedLight, urgent)
  if removedLight == nil then
    return false
  end

  local oldLevel = self.skyDarkQueueLevels[worldIndex]
  local priority = self.skyDarkQueuePriority[worldIndex]
  if oldLevel ~= nil then
    if removedLight > oldLevel then
      self.skyDarkQueueLevels[worldIndex] = removedLight
    end
    if urgent and priority == 0 then
      self.skyDarkQueuePriority[worldIndex] = 1
      self.skyDarkUrgentCount = self.skyDarkUrgentCount + 1
      local head = self.skyDarkQueueHead - 1
      self.skyDarkQueueHead = head
      self.skyDarkQueue[head] = worldIndex
      return true
    end
    return removedLight > oldLevel
  end

  self.skyDarkQueuePriority[worldIndex] = urgent and 1 or 0
  if urgent then
    self.skyDarkUrgentCount = self.skyDarkUrgentCount + 1
    local head = self.skyDarkQueueHead - 1
    self.skyDarkQueueHead = head
    self.skyDarkQueue[head] = worldIndex
  else
    local tail = self.skyDarkQueueTail + 1
    self.skyDarkQueueTail = tail
    self.skyDarkQueue[tail] = worldIndex
  end
  self.skyDarkQueueLevels[worldIndex] = removedLight
  return true
end

function FloodfillLighting:_dequeueSkyDark()
  local queue = self.skyDarkQueue
  local levels = self.skyDarkQueueLevels
  local priorities = self.skyDarkQueuePriority

  while self.skyDarkQueueHead <= self.skyDarkQueueTail do
    local head = self.skyDarkQueueHead
    local worldIndex = queue[head]
    queue[head] = nil
    self.skyDarkQueueHead = head + 1

    if worldIndex ~= nil then
      local removedLight = levels[worldIndex]
      local priority = priorities[worldIndex]
      if removedLight ~= nil then
        levels[worldIndex] = nil
        priorities[worldIndex] = nil
        if priority == 1 and self.skyDarkUrgentCount > 0 then
          self.skyDarkUrgentCount = self.skyDarkUrgentCount - 1
        end
        if self.skyDarkQueueHead > self.skyDarkQueueTail then
          self.skyDarkQueueHead = 1
          self.skyDarkQueueTail = 0
        end
        return worldIndex, removedLight, priority == 1
      end
    end
  end

  self.skyDarkQueueHead = 1
  self.skyDarkQueueTail = 0
  return nil, nil, false
end

function FloodfillLighting:_clearSkyDarkQueue()
  self.skyDarkQueue = {}
  self.skyDarkQueueLevels = {}
  self.skyDarkQueuePriority = {}
  self.skyDarkQueueHead = 1
  self.skyDarkQueueTail = 0
  self.skyDarkUrgentCount = 0
end

function FloodfillLighting:_isInsideSkyActiveWorldXZ(x, z)
  return x >= self.skyActiveMinX
    and x <= self.skyActiveMaxX
    and z >= self.skyActiveMinZ
    and z <= self.skyActiveMaxZ
end

function FloodfillLighting:_isChunkInsideSkyActiveRegion(cx, cz)
  return cx >= self.skyActiveMinCx
    and cx <= self.skyActiveMaxCx
    and cz >= self.skyActiveMinCz
    and cz <= self.skyActiveMaxCz
end

function FloodfillLighting:_isInsideSkyPropagationWorldXZ(x, z)
  if not self:_isInsideSkyActiveWorldXZ(x, z) then
    return false
  end
  if self.skyPropMinX == nil then
    return true
  end
  return x >= self.skyPropMinX
    and x <= self.skyPropMaxX
    and z >= self.skyPropMinZ
    and z <= self.skyPropMaxZ
end

function FloodfillLighting:_clearSkyPropagationBounds()
  self.skyPropMinX = nil
  self.skyPropMaxX = nil
  self.skyPropMinZ = nil
  self.skyPropMaxZ = nil
end

function FloodfillLighting:_setSkyPropagationBounds(minX, maxX, minZ, maxZ)
  local world = self.world
  local bx0 = clampInt(math.floor(tonumber(minX) or 1), 1, world.sizeX)
  local bx1 = clampInt(math.floor(tonumber(maxX) or world.sizeX), 1, world.sizeX)
  local bz0 = clampInt(math.floor(tonumber(minZ) or 1), 1, world.sizeZ)
  local bz1 = clampInt(math.floor(tonumber(maxZ) or world.sizeZ), 1, world.sizeZ)
  if bx1 < bx0 or bz1 < bz0 then
    self:_clearSkyPropagationBounds()
    return
  end

  if bx0 < self.skyActiveMinX then bx0 = self.skyActiveMinX end
  if bx1 > self.skyActiveMaxX then bx1 = self.skyActiveMaxX end
  if bz0 < self.skyActiveMinZ then bz0 = self.skyActiveMinZ end
  if bz1 > self.skyActiveMaxZ then bz1 = self.skyActiveMaxZ end
  if bx1 < bx0 or bz1 < bz0 then
    self:_clearSkyPropagationBounds()
    return
  end

  self.skyPropMinX = bx0
  self.skyPropMaxX = bx1
  self.skyPropMinZ = bz0
  self.skyPropMaxZ = bz1
end

function FloodfillLighting:_enqueueSkyFloodSeed(x, y, z, urgent)
  local world = self.world
  if not world:isInside(x, y, z) then
    return false
  end
  if not self:_isInsideSkyPropagationWorldXZ(x, z) then
    return false
  end

  local light = self:_getSkyLightWorld(x, y, z)
  if light <= 1 then
    return false
  end
  return self:_enqueueSkyFlood(world:_worldIndex(x, y, z), urgent)
end

function FloodfillLighting:_enqueueSkyDarkSeed(x, y, z, urgent)
  local world = self.world
  if not world:isInside(x, y, z) then
    return false
  end
  if not self:_isInsideSkyPropagationWorldXZ(x, z) then
    return false
  end

  local light = self:_getSkyLightWorld(x, y, z)
  if light <= 0 then
    return false
  end
  return self:_enqueueSkyDark(world:_worldIndex(x, y, z), light, urgent)
end

function FloodfillLighting:_seedEditNeighborhood(x, y, z, seedDark, seedFlood, urgent)
  if not x or not y or not z then
    return
  end

  if seedDark then
    self:_enqueueSkyDarkSeed(x, y, z, urgent)
    self:_enqueueSkyDarkSeed(x - 1, y, z, urgent)
    self:_enqueueSkyDarkSeed(x + 1, y, z, urgent)
    self:_enqueueSkyDarkSeed(x, y - 1, z, urgent)
    self:_enqueueSkyDarkSeed(x, y + 1, z, urgent)
    self:_enqueueSkyDarkSeed(x, y, z - 1, urgent)
    self:_enqueueSkyDarkSeed(x, y, z + 1, urgent)
  end

  if seedFlood then
    self:_enqueueSkyFloodSeed(x, y, z, urgent)
    self:_enqueueSkyFloodSeed(x - 1, y, z, urgent)
    self:_enqueueSkyFloodSeed(x + 1, y, z, urgent)
    self:_enqueueSkyFloodSeed(x, y - 1, z, urgent)
    self:_enqueueSkyFloodSeed(x, y + 1, z, urgent)
    self:_enqueueSkyFloodSeed(x, y, z - 1, urgent)
    self:_enqueueSkyFloodSeed(x, y, z + 1, urgent)
  end
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

function FloodfillLighting:_recomputeSkyColumn(x, z, enqueueFlood, markDirty, seedUrgent)
  local world = self.world
  if x < 1 or x > world.sizeX or z < 1 or z > world.sizeZ then
    return false
  end

  local columnKey = world:_worldColumnKey(x, z)
  local light = 15

  for y = world.sizeY, 1, -1 do
    local oldLight = self:_getSkyLightWorld(x, y, z)
    local block = world:get(x, y, z)
    local opacity = self:_getBlockLightOpacity(block)
    light = light - opacity
    if light < 0 then
      light = 0
    end

    if oldLight ~= light then
      self:_setSkyLightWorld(x, y, z, light, markDirty, true)
      if enqueueFlood then
        local worldIndex = world:_worldIndex(x, y, z)
        if light < oldLight and oldLight > 0 then
          self:_enqueueSkyDark(worldIndex, oldLight, seedUrgent)
        elseif light > oldLight and light > 1 then
          self:_enqueueSkyFlood(worldIndex, seedUrgent)
        end
      end
    end

    if light == 0 and opacity >= 15 then
      for clearY = y - 1, 1, -1 do
        local oldClear = self:_getSkyLightWorld(x, clearY, z)
        if oldClear ~= 0 then
          self:_setSkyLightWorld(x, clearY, z, 0, markDirty, true)
          if enqueueFlood then
            self:_enqueueSkyDark(world:_worldIndex(x, clearY, z), oldClear, seedUrgent)
          end
        end
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

function FloodfillLighting:_ensureSkyColumnReady(x, z, enqueueFlood, markDirty, seedUrgent)
  local world = self.world
  if x < 1 or x > world.sizeX or z < 1 or z > world.sizeZ then
    return false
  end

  local columnKey = world:_worldColumnKey(x, z)
  if self.skyColumnsReady[columnKey] then
    return true
  end

  return self:_recomputeSkyColumn(x, z, enqueueFlood, markDirty, seedUrgent)
end

function FloodfillLighting:_ensureSkyHaloColumns(cx, cz, enqueueFlood, markDirty, seedUrgent)
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
          self:_ensureSkyColumnReady(x, z, enqueueFlood, markDirty, seedUrgent)
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
    self:_clearSkyDarkQueue()
    self:_clearSkyFloodQueue()
    self:_clearRegionTasks()
  end

  if clearOld then
    self:_clearSkyBounds(bx0, bx1, bz0, bz1)
  end

  local queued = 0
  for z = bz0, bz1 do
    for x = bx0, bx1 do
      local columnKey = world:_worldColumnKey(x, z)
      self.skyColumnsReady[columnKey] = nil
      if self:_enqueueSkyColumn(columnKey, false) then
        queued = queued + 1
      end
    end
  end

  if queued > 0 then
    local dirty = asBool(trackDirty)
    self.skyTrackDirtyVertical = false
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
    false,
    false
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

function FloodfillLighting:_removeSkyLightChunksInBounds(minCx, maxCx, minCz, maxCz)
  local world = self.world
  local cx0 = clampInt(math.floor(tonumber(minCx) or 1), 1, world.chunksX)
  local cx1 = clampInt(math.floor(tonumber(maxCx) or world.chunksX), 1, world.chunksX)
  local cz0 = clampInt(math.floor(tonumber(minCz) or 1), 1, world.chunksZ)
  local cz1 = clampInt(math.floor(tonumber(maxCz) or world.chunksZ), 1, world.chunksZ)
  if cx1 < cx0 or cz1 < cz0 then
    return 0
  end

  local removed = 0
  for cz = cz0, cz1 do
    for cx = cx0, cx1 do
      for cy = 1, world.chunksY do
        local chunkKey = world:chunkKey(cx, cy, cz)
        if self.skyLightChunks[chunkKey] ~= nil then
          self.skyLightChunks[chunkKey] = nil
          removed = removed + 1
        end
      end
    end
  end

  return removed
end

function FloodfillLighting:_queueSkyRegionDelta(oldMinX, oldMaxX, oldMinZ, oldMaxZ)
  if not self.enabled then
    return 0
  end

  self:_clearSkyPropagationBounds()

  local world = self.world
  local oldHasRegion = oldMaxX and oldMinX and oldMaxX >= oldMinX and oldMaxZ and oldMinZ and oldMaxZ >= oldMinZ
  local newMinX = self.skyActiveMinX
  local newMaxX = self.skyActiveMaxX
  local newMinZ = self.skyActiveMinZ
  local newMaxZ = self.skyActiveMaxZ
  local queued = 0

  if not oldHasRegion then
    self:_clearRegionTasks()
    queued = self:_scheduleRegionQueueColumnsRows(newMinX, newMaxX, newMinZ, newMaxZ, false, true)
  else
    local oldWidth = oldMaxX - oldMinX + 1
    local oldDepth = oldMaxZ - oldMinZ + 1
    local newWidth = newMaxX - newMinX + 1
    local newDepth = newMaxZ - newMinZ + 1
    local shiftX = newMinX - oldMinX
    local shiftZ = newMinZ - oldMinZ
    local canUseRingDelta = oldWidth == newWidth
      and oldDepth == newDepth
      and math.abs(shiftX) <= world.chunkSize
      and math.abs(shiftZ) <= world.chunkSize

    if canUseRingDelta then
      if shiftX > 0 then
        queued = queued + self:_scheduleRegionQueueColumnsRows(oldMaxX + 1, newMaxX, newMinZ, newMaxZ, false, true)
      elseif shiftX < 0 then
        queued = queued + self:_scheduleRegionQueueColumnsRows(newMinX, oldMinX - 1, newMinZ, newMaxZ, false, true)
      end

      if shiftZ > 0 then
        queued = queued + self:_scheduleRegionQueueColumnsRows(newMinX, newMaxX, oldMaxZ + 1, newMaxZ, false, true)
      elseif shiftZ < 0 then
        queued = queued + self:_scheduleRegionQueueColumnsRows(newMinX, newMaxX, newMinZ, oldMinZ - 1, false, true)
      end
    else
      self:_clearRegionTasks()
      queued = self:_scheduleRegionQueueColumnsRows(newMinX, newMaxX, newMinZ, newMaxZ, false, true)
    end
  end

  if queued > 0 then
    self.skyTrackDirtyVertical = false
    self.skyTrackDirtyFlood = true
    if not oldHasRegion then
      self.skyWarmupActive = true
    end
    if self:_hasSkyColumnsQueue() or self:_hasSkyDarkQueue() or self:_hasSkyFloodQueue() then
      self:_setSkyStageFromQueues()
    end
  end

  return queued
end

function FloodfillLighting:_propagateSkyDarkFrom(worldIndex, removedLight, markDirty, urgent)
  if not worldIndex or not removedLight or removedLight <= 0 then
    return
  end

  local world = self.world
  local x, y, z = world:_decodeWorldIndex(worldIndex)
  if not self:_isInsideSkyPropagationWorldXZ(x, z) then
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
    if not self:_isInsideSkyPropagationWorldXZ(nx, nz) then
      return
    end

    local neighborLight = self:_getSkyLightWorld(nx, ny, nz)
    if neighborLight <= 0 then
      return
    end

    local block = world:get(nx, ny, nz)
    local step = self:_getBlockLightOpacity(block)
    if step < 1 then
      step = 1
    end

    if neighborLight + step <= removedLight then
      if self:_setSkyLightWorld(nx, ny, nz, 0, markDirty, true) then
        self:_enqueueSkyDark(world:_worldIndex(nx, ny, nz), neighborLight, urgent)
      end
    else
      self:_enqueueSkyFlood(world:_worldIndex(nx, ny, nz), urgent)
    end
  end

  tryNeighbor(x - 1, y, z)
  tryNeighbor(x + 1, y, z)
  tryNeighbor(x, y - 1, z)
  tryNeighbor(x, y + 1, z)
  tryNeighbor(x, y, z - 1)
  tryNeighbor(x, y, z + 1)
  self:_enqueueSkyFlood(worldIndex, urgent)
end

function FloodfillLighting:_propagateSkyFloodFrom(worldIndex, markDirty, urgent)
  local world = self.world
  local x, y, z = world:_decodeWorldIndex(worldIndex)
  if not self:_isInsideSkyPropagationWorldXZ(x, z) then
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
    if not self:_isInsideSkyPropagationWorldXZ(nx, nz) then
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
        self:_enqueueSkyFlood(world:_worldIndex(nx, ny, nz), urgent)
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

function FloodfillLighting:_computeChunkEnsureScale(config)
  local softMs = tonumber(config.chunkEnsureSpikeSoftMs)
  if softMs == nil then
    softMs = 12
  end

  local hardMs = tonumber(config.chunkEnsureSpikeHardMs)
  if hardMs == nil then
    hardMs = 20
  end
  if hardMs < softMs then
    hardMs = softMs
  end

  local softScale = tonumber(config.chunkEnsureSpikeSoftScale)
  if softScale == nil then
    softScale = 0.5
  end
  local hardScale = tonumber(config.chunkEnsureSpikeHardScale)
  if hardScale == nil then
    hardScale = 0.2
  end

  if softScale < 0 then
    softScale = 0
  elseif softScale > 1 then
    softScale = 1
  end

  if hardScale < 0 then
    hardScale = 0
  elseif hardScale > softScale then
    hardScale = softScale
  end

  local frameMs = tonumber(self._frameMsHint) or 0
  local worstMs = tonumber(self._worstFrameMsHint) or frameMs
  local sampleMs = frameMs
  local dampedWorstMs = worstMs * 0.5
  if dampedWorstMs > sampleMs then
    sampleMs = dampedWorstMs
  end

  if sampleMs >= hardMs then
    return hardScale
  end
  if sampleMs >= softMs then
    return softScale
  end
  return 1
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

  local config = self.lightingConfig or {}
  local localOps = math.floor(tonumber(config.chunkEnsureOps) or 768)
  local localMillis = tonumber(config.chunkEnsureMillis)
  if localMillis == nil then
    localMillis = 0.2
  end

  local ensureScale = self:_computeChunkEnsureScale(config)
  self._chunkEnsureScaleLast = ensureScale
  if ensureScale < 1 then
    localOps = math.floor(localOps * ensureScale)
    if localOps < 0 then
      localOps = 0
    end
    localMillis = localMillis * ensureScale
  end

  world:prepareChunk(cx, cy, cz)

  local insideActiveRegion = self:_isChunkInsideSkyActiveRegion(cx, cz)
  if not insideActiveRegion then
    -- Outside simulation lighting region: skip sky solve work and render full skylight.
    return true
  end

  if self:_hasSkyQueueWork() then
    if localOps > 0 then
      self:updateSkyLight(localOps, localMillis)
    end
    if self:_hasSkyQueueWork() then
      return false
    end
  end

  self:_ensureSkyHaloColumns(cx, cz, true, false, true)

  if localOps > 0 and self:_hasSkyQueueWork() then
    self:updateSkyLight(localOps, localMillis)
  end

  if self:_hasSkyQueueWork() then
    return false
  end
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

  local insideActiveRegion = self:_isChunkInsideSkyActiveRegion(cx, cz)
  if not insideActiveRegion then
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
          else
            out[index] = 15
          end
        end
      end
    end

    for i = required + 1, #out do
      out[i] = nil
    end
    return out
  end

  local queueBacklog = self:_hasSkyQueueWork()
  local skyColumnsReady = self.skyColumnsReady
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
        elseif queueBacklog or not skyColumnsReady[world:_worldColumnKey(wx, wz)] then
          -- While floodfill queues are pending, prefer a no-shadow fallback over dark interim vertical values.
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
    self.skyRegionOpsProcessedLast = 0
    return 0
  end

  local config = self.lightingConfig or {}
  local explicitOpsLimit = maxOps ~= nil
  local explicitMillisLimit = maxMillis ~= nil
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

  if self.skyWarmupActive then
    local warmupOps = math.floor(tonumber(config.startupWarmupOpsPerFrame) or 32768)
    if warmupOps > 0 and not explicitOpsLimit then
      if opsLimit == nil or opsLimit < warmupOps then
        opsLimit = warmupOps
      end
    end

    local warmupMillis = tonumber(config.startupWarmupMillisPerFrame) or 4.0
    if warmupMillis > 0 and not explicitMillisLimit then
      if millisLimit == nil or millisLimit < warmupMillis then
        millisLimit = warmupMillis
      end
    end
  end

  if self:_hasUrgentWork() then
    local urgentOps = math.floor(tonumber(config.urgentOpsPerFrame) or 12288)
    if urgentOps > 0 and not explicitOpsLimit then
      if opsLimit == nil or opsLimit < urgentOps then
        opsLimit = urgentOps
      end
    end

    local urgentMillis = tonumber(config.urgentMillisPerFrame) or 1.75
    if urgentMillis > 0 and not explicitMillisLimit then
      if millisLimit == nil or millisLimit < urgentMillis then
        millisLimit = urgentMillis
      end
    end
  end

  local hasTimer = lovr and lovr.timer and lovr.timer.getTime
  local useOverallTimeBudget = hasTimer and millisLimit and millisLimit > 0
  local overallStartTime = 0
  if useOverallTimeBudget then
    overallStartTime = lovr.timer.getTime()
  end

  if (not opsLimit or opsLimit <= 0) and not useOverallTimeBudget then
    opsLimit = 1
  end

  local regionOpsLimit = math.floor(tonumber(config.regionStripOpsPerFrame) or 1024)
  if regionOpsLimit < 0 then
    regionOpsLimit = 0
  end
  local regionMillisLimit = tonumber(config.regionStripMillisPerFrame)
  if regionMillisLimit == nil then
    regionMillisLimit = 0.35
  end
  if explicitOpsLimit and opsLimit and opsLimit >= 0 and regionOpsLimit > opsLimit then
    regionOpsLimit = opsLimit
  end
  if explicitMillisLimit and millisLimit and millisLimit >= 0 and regionMillisLimit > millisLimit then
    regionMillisLimit = millisLimit
  end

  local regionProcessed = 0
  if self:_hasRegionTasks() then
    regionProcessed = self:_processRegionTasks(regionOpsLimit, regionMillisLimit)
  else
    self.skyRegionOpsProcessedLast = 0
  end

  if opsLimit and opsLimit > 0 then
    opsLimit = opsLimit - regionProcessed
    if opsLimit < 0 then
      opsLimit = 0
    end
  end

  if useOverallTimeBudget then
    local spentMs = (lovr.timer.getTime() - overallStartTime) * 1000
    millisLimit = millisLimit - spentMs
    if millisLimit < 0 then
      millisLimit = 0
    end
  end

  self:_setSkyStageFromQueues()
  if self.skyStage == 'idle' then
    return regionProcessed
  end

  local useTimeBudget = hasTimer and millisLimit and millisLimit > 0
  local startTime = 0
  if useTimeBudget then
    startTime = lovr.timer.getTime()
  end
  if (not opsLimit or opsLimit <= 0) and not useTimeBudget then
    return regionProcessed
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

    local columnKey, isUrgent = self:_dequeueSkyColumn()
    if columnKey then
      local x, z = world:_decodeWorldColumnKey(columnKey)
      if self:_isInsideSkyActiveWorldXZ(x, z) and not self.skyColumnsReady[columnKey] then
        self:_recomputeSkyColumn(x, z, true, self.skyTrackDirtyVertical, isUrgent)
      end
      processed = processed + 1
    else
      local darkIndex, removedLight, darkUrgent = self:_dequeueSkyDark()
      if darkIndex then
        self:_propagateSkyDarkFrom(darkIndex, removedLight, self.skyTrackDirtyFlood, darkUrgent)
        processed = processed + 1
      else
        local worldIndex, floodUrgent = self:_dequeueSkyFlood()
        if not worldIndex then
          break
        end
        self:_propagateSkyFloodFrom(worldIndex, self.skyTrackDirtyFlood, floodUrgent)
        processed = processed + 1
      end
    end
  end

  self:_setSkyStageFromQueues()
  return processed + regionProcessed
end

function FloodfillLighting:pruneSkyLightChunks(centerCx, centerCz, keepRadiusChunks)
  if not self.enabled then
    return 0
  end

  local world = self.world
  local oldMinCx = self.skyActiveMinCx
  local oldMaxCx = self.skyActiveMaxCx
  local oldMinCz = self.skyActiveMinCz
  local oldMaxCz = self.skyActiveMaxCz
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
  if regionChanged then
    local oldHasRegion = oldMaxCx and oldMinCx and oldMaxCx >= oldMinCx and oldMaxCz and oldMinCz and oldMaxCz >= oldMinCz
    local oldWidth = oldHasRegion and (oldMaxCx - oldMinCx + 1) or 0
    local oldDepth = oldHasRegion and (oldMaxCz - oldMinCz + 1) or 0
    local newWidth = maxCx - minCx + 1
    local newDepth = maxCz - minCz + 1
    local shiftCx = minCx - (oldMinCx or minCx)
    local shiftCz = minCz - (oldMinCz or minCz)
    local canUseRingDeltaPrune = oldHasRegion
      and oldWidth == newWidth
      and oldDepth == newDepth
      and math.abs(shiftCx) <= 1
      and math.abs(shiftCz) <= 1

    if not canUseRingDeltaPrune then
      self:_clearRegionTasks()
    end

    if canUseRingDeltaPrune then
      if shiftCx > 0 then
        removed = removed + self:_removeSkyLightChunksInBounds(oldMinCx, minCx - 1, oldMinCz, oldMaxCz)
        self:_scheduleRegionRemoveReadyRows(oldMinX, self.skyActiveMinX - 1, oldMinZ, oldMaxZ)
      elseif shiftCx < 0 then
        removed = removed + self:_removeSkyLightChunksInBounds(maxCx + 1, oldMaxCx, oldMinCz, oldMaxCz)
        self:_scheduleRegionRemoveReadyRows(self.skyActiveMaxX + 1, oldMaxX, oldMinZ, oldMaxZ)
      end

      if shiftCz > 0 then
        removed = removed + self:_removeSkyLightChunksInBounds(oldMinCx, oldMaxCx, oldMinCz, minCz - 1)
        self:_scheduleRegionRemoveReadyRows(oldMinX, oldMaxX, oldMinZ, self.skyActiveMinZ - 1)
      elseif shiftCz < 0 then
        removed = removed + self:_removeSkyLightChunksInBounds(oldMinCx, oldMaxCx, maxCz + 1, oldMaxCz)
        self:_scheduleRegionRemoveReadyRows(oldMinX, oldMaxX, self.skyActiveMaxZ + 1, oldMaxZ)
      end
    else
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
    end

    self:_queueSkyRegionDelta(oldMinX, oldMaxX, oldMinZ, oldMaxZ)
  end

  return removed
end

function FloodfillLighting:onOpacityChanged(x, y, z, cx, cy, cz, oldOpacity, newOpacity)
  if not self.enabled then
    return
  end

  local world = self.world
  local config = self.lightingConfig or {}
  local radius = math.floor(tonumber(config.editRelightRadiusBlocks) or 15)
  if radius < 1 then
    radius = 1
  end
  self:_setSkyPropagationBounds(x - radius, x + radius, z - radius, z + radius)

  local columnKey = world:_worldColumnKey(x, z)
  self.skyColumnsReady[columnKey] = nil
  self:_enqueueSkyColumn(columnKey, true)

  local increase = oldOpacity and newOpacity and newOpacity > oldOpacity
  local decrease = oldOpacity and newOpacity and newOpacity < oldOpacity
  if increase then
    self:_seedEditNeighborhood(x, y, z, true, false, true)
  elseif decrease then
    self:_seedEditNeighborhood(x, y, z, false, true, true)
  else
    -- Fallback for unknown/ambiguous opacity changes.
    self:_seedEditNeighborhood(x, y, z, true, true, true)
  end

  self.skyTrackDirtyVertical = false
  self.skyTrackDirtyFlood = true
  self:_setSkyStageFromQueues()
  self:_primeSkyLightAfterOpacityEdit()
end

function FloodfillLighting:onBulkOpacityChanged(minX, maxX, minZ, maxZ)
  if not self.enabled or minX == nil or maxX == nil or minZ == nil or maxZ == nil then
    return
  end

  local config = self.lightingConfig or {}
  local radius = math.floor(tonumber(config.editRelightRadiusBlocks) or 15)
  if radius < 1 then
    radius = 1
  end
  self:_setSkyPropagationBounds(minX - radius, maxX + radius, minZ - radius, maxZ + radius)

  local queuePad = 1
  local queued = self:_scheduleSkyBoundsRebuild(
    minX - queuePad,
    maxX + queuePad,
    minZ - queuePad,
    maxZ + queuePad,
    true,
    false,
    false
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
