local Interaction = {}
Interaction.__index = Interaction
local RNG_MOD = 2147483648

local function isSameBlockTarget(hit, x, y, z)
  return hit and hit.x == x and hit.y == y and hit.z == z
end

local function clearArrayTail(t, fromIndex)
  for i = fromIndex, #t do
    t[i] = nil
  end
end

function Interaction.new(constants, world, player, inventory)
  local self = setmetatable({}, Interaction)
  self.constants = constants
  self.world = world
  self.player = player
  self.inventory = inventory

  self.targetHit = nil
  self._targetHitScratch = {}

  self.breakTargetX = nil
  self.breakTargetY = nil
  self.breakTargetZ = nil
  self.breakBlock = nil
  self.breakProgress = 0
  self.breakDuration = 1

  self._breakBatchScratch = {}
  self._treeQueueX = {}
  self._treeQueueY = {}
  self._treeQueueZ = {}
  self._treeVisited = {}
  self._treeVisitedKeys = {}
  self._stoneQueueX = {}
  self._stoneQueueY = {}
  self._stoneQueueZ = {}
  self._stoneVisited = {}
  self._stoneVisitedKeys = {}
  self._rngState = math.floor(tonumber(constants.WORLD_SEED) or 1) % RNG_MOD
  if self._rngState <= 0 then
    self._rngState = 1
  end

  return self
end

function Interaction:updateTarget()
  local cameraX, cameraY, cameraZ = self.player:getCameraPosition()
  local lookX, lookY, lookZ = self.player:getLookVector()
  self.targetHit = self.world:raycast(cameraX, cameraY, cameraZ, lookX, lookY, lookZ, self.player.reach, self._targetHitScratch)
  return self.targetHit
end

function Interaction:resetBreakProgress()
  self.breakTargetX = nil
  self.breakTargetY = nil
  self.breakTargetZ = nil
  self.breakBlock = nil
  self.breakProgress = 0
  self.breakDuration = 1
end

function Interaction:_getBreakDuration(block)
  local timings = self.constants.BLOCK_BREAK_TIME_SECONDS or {}
  local t = tonumber(timings[block])
  if not t or t <= 0 then
    t = tonumber(timings.default) or 0.55
  end
  if t <= 0 then
    t = 0.55
  end
  return t
end

function Interaction:_canBreakBlock(block)
  if not self.world:isBreakable(block) then
    return false, false
  end

  local selectedTool = self.inventory and self.inventory.getSelectedToolType and self.inventory:getSelectedToolType() or nil
  local requirements = self.constants.BLOCK_BREAK_REQUIREMENTS or {}
  local requiredTool = requirements[block]
  if not requiredTool then
    return true, selectedTool ~= nil
  end

  if selectedTool == requiredTool then
    return true, true
  end

  return false, false
end

function Interaction:_rand01()
  self._rngState = (1103515245 * self._rngState + 12345) % RNG_MOD
  return self._rngState / RNG_MOD
end

function Interaction:_randInt(minValue, maxValue)
  if minValue > maxValue then
    minValue, maxValue = maxValue, minValue
  end
  local span = maxValue - minValue + 1
  if span <= 1 then
    return minValue
  end
  return minValue + math.floor(self:_rand01() * span)
end

function Interaction:_isNaturalBlock(x, y, z, block)
  if not (self.world and self.world.isNaturallyGeneratedBlock) then
    return false
  end
  return self.world:isNaturallyGeneratedBlock(x, y, z, block)
end

function Interaction:_setBreakEntry(out, index, x, y, z, block)
  local entry = out[index]
  if entry then
    entry.x = x
    entry.y = y
    entry.z = z
    entry.block = block
    return
  end
  out[index] = {
    x = x,
    y = y,
    z = z,
    block = block
  }
end

function Interaction:_clearVisitedSet(visited, keys, keyCount)
  for i = 1, keyCount do
    local key = keys[i]
    if key ~= nil then
      visited[key] = nil
      keys[i] = nil
    end
  end
end

function Interaction:_tryEnqueueNaturalTreeNeighbor(nx, ny, nz, rootY, queueX, queueY, queueZ, tail, visited, visitedKeys, visitedCount, sizeX, strideY, woodId, leafId)
  if ny < rootY then
    return tail, visitedCount
  end
  if not self.world:isInside(nx, ny, nz) then
    return tail, visitedCount
  end

  local key = nx + (nz - 1) * sizeX + (ny - 1) * strideY
  if visited[key] then
    return tail, visitedCount
  end

  local block = self.world:get(nx, ny, nz)
  if block ~= woodId and block ~= leafId then
    return tail, visitedCount
  end

  visited[key] = true
  visitedCount = visitedCount + 1
  visitedKeys[visitedCount] = key
  tail = tail + 1
  queueX[tail] = nx
  queueY[tail] = ny
  queueZ[tail] = nz
  return tail, visitedCount
end

function Interaction:_collectNaturalTreeBreakBlocks(rootX, rootY, rootZ, out)
  local blockIds = self.constants.BLOCK
  local woodId = blockIds.WOOD
  local leafId = blockIds.LEAF
  if not self:_isNaturalBlock(rootX, rootY, rootZ, woodId) then
    return 0
  end

  local special = self.constants.BLOCK_BREAK_SPECIAL or {}
  local maxBlocks = math.floor(tonumber(special.naturalTreeMaxBlocks) or 192)
  if maxBlocks < 1 then
    maxBlocks = 1
  end

  local queueX = self._treeQueueX
  local queueY = self._treeQueueY
  local queueZ = self._treeQueueZ
  local visited = self._treeVisited
  local visitedKeys = self._treeVisitedKeys
  local sizeX = self.world.sizeX
  local strideY = sizeX * self.world.sizeZ

  local head = 1
  local tail = 1
  local visitedCount = 1
  local rootKey = rootX + (rootZ - 1) * sizeX + (rootY - 1) * strideY
  queueX[1] = rootX
  queueY[1] = rootY
  queueZ[1] = rootZ
  visited[rootKey] = true
  visitedKeys[1] = rootKey

  local count = 0
  while head <= tail and count < maxBlocks do
    local x = queueX[head]
    local y = queueY[head]
    local z = queueZ[head]
    head = head + 1

    local block = self.world:get(x, y, z)
    if (block == woodId or block == leafId) and self:_isNaturalBlock(x, y, z, block) then
      count = count + 1
      self:_setBreakEntry(out, count, x, y, z, block)

      tail, visitedCount = self:_tryEnqueueNaturalTreeNeighbor(
        x + 1, y, z,
        rootY,
        queueX, queueY, queueZ, tail,
        visited, visitedKeys, visitedCount,
        sizeX, strideY,
        woodId, leafId
      )
      tail, visitedCount = self:_tryEnqueueNaturalTreeNeighbor(
        x - 1, y, z,
        rootY,
        queueX, queueY, queueZ, tail,
        visited, visitedKeys, visitedCount,
        sizeX, strideY,
        woodId, leafId
      )
      tail, visitedCount = self:_tryEnqueueNaturalTreeNeighbor(
        x, y + 1, z,
        rootY,
        queueX, queueY, queueZ, tail,
        visited, visitedKeys, visitedCount,
        sizeX, strideY,
        woodId, leafId
      )
      tail, visitedCount = self:_tryEnqueueNaturalTreeNeighbor(
        x, y - 1, z,
        rootY,
        queueX, queueY, queueZ, tail,
        visited, visitedKeys, visitedCount,
        sizeX, strideY,
        woodId, leafId
      )
      tail, visitedCount = self:_tryEnqueueNaturalTreeNeighbor(
        x, y, z + 1,
        rootY,
        queueX, queueY, queueZ, tail,
        visited, visitedKeys, visitedCount,
        sizeX, strideY,
        woodId, leafId
      )
      tail, visitedCount = self:_tryEnqueueNaturalTreeNeighbor(
        x, y, z - 1,
        rootY,
        queueX, queueY, queueZ, tail,
        visited, visitedKeys, visitedCount,
        sizeX, strideY,
        woodId, leafId
      )
    end
  end

  clearArrayTail(queueX, 1)
  clearArrayTail(queueY, 1)
  clearArrayTail(queueZ, 1)
  self:_clearVisitedSet(visited, visitedKeys, visitedCount)
  return count
end

function Interaction:_tryEnqueueNaturalStoneNeighbor(nx, ny, nz, queueX, queueY, queueZ, tail, visited, visitedKeys, visitedCount, sizeX, strideY, stoneId)
  if not self.world:isInside(nx, ny, nz) then
    return tail, visitedCount, false
  end

  local key = nx + (nz - 1) * sizeX + (ny - 1) * strideY
  if visited[key] then
    return tail, visitedCount, false
  end

  local block = self.world:get(nx, ny, nz)
  if block ~= stoneId or not self:_isNaturalBlock(nx, ny, nz, stoneId) then
    return tail, visitedCount, false
  end

  visited[key] = true
  visitedCount = visitedCount + 1
  visitedKeys[visitedCount] = key
  tail = tail + 1
  queueX[tail] = nx
  queueY[tail] = ny
  queueZ[tail] = nz
  return tail, visitedCount, true
end

function Interaction:_collectStoneCascadeBreakBlocks(rootX, rootY, rootZ, out, startCount)
  local blockIds = self.constants.BLOCK
  local stoneId = blockIds.STONE
  if not self:_isNaturalBlock(rootX, rootY, rootZ, stoneId) then
    return startCount
  end

  local special = self.constants.BLOCK_BREAK_SPECIAL or {}
  local cascadeChance = tonumber(special.stoneCascadeChance)
  if cascadeChance == nil then
    cascadeChance = 0.5
  end
  if cascadeChance <= 0 then
    return startCount
  end
  if cascadeChance < 1 and self:_rand01() >= cascadeChance then
    return startCount
  end

  local minExtra = math.floor(tonumber(special.stoneCascadeMin) or 5)
  local maxExtra = math.floor(tonumber(special.stoneCascadeMax) or 10)
  if minExtra < 0 then
    minExtra = 0
  end
  if maxExtra < minExtra then
    maxExtra = minExtra
  end
  local targetExtra = self:_randInt(minExtra, maxExtra)
  if targetExtra <= 0 then
    return startCount
  end

  local queueX = self._stoneQueueX
  local queueY = self._stoneQueueY
  local queueZ = self._stoneQueueZ
  local visited = self._stoneVisited
  local visitedKeys = self._stoneVisitedKeys
  local sizeX = self.world.sizeX
  local strideY = sizeX * self.world.sizeZ

  local head = 1
  local tail = 1
  local visitedCount = 1
  local rootKey = rootX + (rootZ - 1) * sizeX + (rootY - 1) * strideY
  queueX[1] = rootX
  queueY[1] = rootY
  queueZ[1] = rootZ
  visited[rootKey] = true
  visitedKeys[1] = rootKey

  local count = startCount
  local extraCount = 0

  while head <= tail and extraCount < targetExtra do
    local x = queueX[head]
    local y = queueY[head]
    local z = queueZ[head]
    head = head + 1

    local added = false
    tail, visitedCount, added = self:_tryEnqueueNaturalStoneNeighbor(
      x + 1, y, z,
      queueX, queueY, queueZ, tail,
      visited, visitedKeys, visitedCount,
      sizeX, strideY,
      stoneId
    )
    if added then
      count = count + 1
      extraCount = extraCount + 1
      self:_setBreakEntry(out, count, x + 1, y, z, stoneId)
      if extraCount >= targetExtra then
        break
      end
    end

    tail, visitedCount, added = self:_tryEnqueueNaturalStoneNeighbor(
      x - 1, y, z,
      queueX, queueY, queueZ, tail,
      visited, visitedKeys, visitedCount,
      sizeX, strideY,
      stoneId
    )
    if added then
      count = count + 1
      extraCount = extraCount + 1
      self:_setBreakEntry(out, count, x - 1, y, z, stoneId)
      if extraCount >= targetExtra then
        break
      end
    end

    tail, visitedCount, added = self:_tryEnqueueNaturalStoneNeighbor(
      x, y + 1, z,
      queueX, queueY, queueZ, tail,
      visited, visitedKeys, visitedCount,
      sizeX, strideY,
      stoneId
    )
    if added then
      count = count + 1
      extraCount = extraCount + 1
      self:_setBreakEntry(out, count, x, y + 1, z, stoneId)
      if extraCount >= targetExtra then
        break
      end
    end

    tail, visitedCount, added = self:_tryEnqueueNaturalStoneNeighbor(
      x, y - 1, z,
      queueX, queueY, queueZ, tail,
      visited, visitedKeys, visitedCount,
      sizeX, strideY,
      stoneId
    )
    if added then
      count = count + 1
      extraCount = extraCount + 1
      self:_setBreakEntry(out, count, x, y - 1, z, stoneId)
      if extraCount >= targetExtra then
        break
      end
    end

    tail, visitedCount, added = self:_tryEnqueueNaturalStoneNeighbor(
      x, y, z + 1,
      queueX, queueY, queueZ, tail,
      visited, visitedKeys, visitedCount,
      sizeX, strideY,
      stoneId
    )
    if added then
      count = count + 1
      extraCount = extraCount + 1
      self:_setBreakEntry(out, count, x, y, z + 1, stoneId)
      if extraCount >= targetExtra then
        break
      end
    end

    tail, visitedCount, added = self:_tryEnqueueNaturalStoneNeighbor(
      x, y, z - 1,
      queueX, queueY, queueZ, tail,
      visited, visitedKeys, visitedCount,
      sizeX, strideY,
      stoneId
    )
    if added then
      count = count + 1
      extraCount = extraCount + 1
      self:_setBreakEntry(out, count, x, y, z - 1, stoneId)
      if extraCount >= targetExtra then
        break
      end
    end
  end

  clearArrayTail(queueX, 1)
  clearArrayTail(queueY, 1)
  clearArrayTail(queueZ, 1)
  self:_clearVisitedSet(visited, visitedKeys, visitedCount)
  return count
end

function Interaction:_buildBreakBatch(x, y, z, block)
  local batch = self._breakBatchScratch
  local count = 0

  if block == self.constants.BLOCK.WOOD then
    local special = self.constants.BLOCK_BREAK_SPECIAL or {}
    if special.naturalTreeCascade ~= false then
      count = self:_collectNaturalTreeBreakBlocks(x, y, z, batch)
    end
  end

  if count == 0 then
    count = 1
    self:_setBreakEntry(batch, 1, x, y, z, block)
  end

  if block == self.constants.BLOCK.STONE then
    count = self:_collectStoneCascadeBreakBlocks(x, y, z, batch, count)
  end

  clearArrayTail(batch, count + 1)
  return batch, count
end

function Interaction:_breakBatchToResult(hit, rootBlock, usedTool, batch, count)
  local result = {
    x = hit.x,
    y = hit.y,
    z = hit.z,
    block = rootBlock,
    usedTool = usedTool,
    blockCount = count
  }

  if count > 1 then
    local blocks = {}
    for i = 1, count do
      local src = batch[i]
      blocks[i] = {
        x = src.x,
        y = src.y,
        z = src.z,
        block = src.block
      }
    end
    result.blocks = blocks
  end

  return result
end

function Interaction:updateBreaking(dt, isHolding)
  if not isHolding then
    self:resetBreakProgress()
    return nil
  end

  local hit = self.targetHit
  if not hit then
    self:resetBreakProgress()
    return nil
  end

  local block = self.world:get(hit.x, hit.y, hit.z)
  local canBreak, usedTool = self:_canBreakBlock(block)
  if not canBreak then
    self:resetBreakProgress()
    return nil
  end

  if not isSameBlockTarget(hit, self.breakTargetX, self.breakTargetY, self.breakTargetZ) or self.breakBlock ~= block then
    self.breakTargetX = hit.x
    self.breakTargetY = hit.y
    self.breakTargetZ = hit.z
    self.breakBlock = block
    self.breakProgress = 0
    self.breakDuration = self:_getBreakDuration(block)
  end

  local duration = self.breakDuration
  if duration <= 0 then
    duration = 0.01
  end

  self.breakProgress = self.breakProgress + math.max(0, dt) / duration
  if self.breakProgress < 1 then
    return nil
  end

  local batch, count = self:_buildBreakBatch(hit.x, hit.y, hit.z, block)
  for i = 1, count do
    local entry = batch[i]
    self.world:set(entry.x, entry.y, entry.z, self.constants.BLOCK.AIR)
  end

  if usedTool and self.inventory and self.inventory.damageSelectedTool then
    self.inventory:damageSelectedTool(1)
  end

  local result = self:_breakBatchToResult(hit, block, usedTool, batch, count)

  self:resetBreakProgress()
  return result
end

function Interaction:tryBreak()
  local hit = self.targetHit
  if not hit then
    return nil
  end

  local block = self.world:get(hit.x, hit.y, hit.z)
  local canBreak, usedTool = self:_canBreakBlock(block)
  if not canBreak then
    return nil
  end

  local batch, count = self:_buildBreakBatch(hit.x, hit.y, hit.z, block)
  for i = 1, count do
    local entry = batch[i]
    self.world:set(entry.x, entry.y, entry.z, self.constants.BLOCK.AIR)
  end

  if usedTool and self.inventory and self.inventory.damageSelectedTool then
    self.inventory:damageSelectedTool(1)
  end

  self:resetBreakProgress()
  return self:_breakBatchToResult(hit, block, usedTool, batch, count)
end

function Interaction:tryPlace()
  local hit = self.targetHit
  if not hit then
    return false
  end

  if not hit.previousX or not hit.previousY or not hit.previousZ then
    return false
  end

  local placeX = hit.previousX
  local placeY = hit.previousY
  local placeZ = hit.previousZ

  if not self.world:isInside(placeX, placeY, placeZ) then
    return false
  end

  if self.world:get(placeX, placeY, placeZ) ~= self.constants.BLOCK.AIR then
    return false
  end

  local block = self.inventory:getSelectedBlock()
  if not block or not self.world:isPlaceable(block) then
    return false
  end

  if self.player:overlapsBlock(placeX, placeY, placeZ) then
    return false
  end

  if self.inventory:consumeSelected(1) then
    self.world:set(placeX, placeY, placeZ, block)
    return true
  end

  return false
end

function Interaction:getTargetName()
  if not self.targetHit then
    return 'None'
  end

  local info = self.constants.BLOCK_INFO[self.targetHit.block]
  return info and info.name or 'Unknown'
end

function Interaction:drawOutline(pass)
  local hit = self.targetHit
  if not hit then
    return
  end

  pass:push('state')
  pass:setWireframe(true)
  pass:setColor(1, 1, 1, 1)
  pass:cube(hit.x - .5, hit.y - .5, hit.z - .5, 1.02)
  pass:pop('state')

  if self.breakProgress <= 0 then
    return
  end

  if not isSameBlockTarget(hit, self.breakTargetX, self.breakTargetY, self.breakTargetZ) then
    return
  end

  local stage = math.floor(self.breakProgress * 6)
  if stage < 1 then
    stage = 1
  elseif stage > 6 then
    stage = 6
  end

  local alpha = 0.06 + stage * 0.10

  pass:push('state')
  pass:setColor(0.93, 0.93, 0.93, alpha)
  pass:cube(hit.x - .513, hit.y - .513, hit.z - .513, 1.026)
  pass:pop('state')
end

return Interaction
