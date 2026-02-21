local Interaction = {}
Interaction.__index = Interaction

local function isSameBlockTarget(hit, x, y, z)
  return hit and hit.x == x and hit.y == y and hit.z == z
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

  self.world:set(hit.x, hit.y, hit.z, self.constants.BLOCK.AIR)

  if usedTool and self.inventory and self.inventory.damageSelectedTool then
    self.inventory:damageSelectedTool(1)
  end

  local result = {
    x = hit.x,
    y = hit.y,
    z = hit.z,
    block = block,
    usedTool = usedTool
  }

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

  self.world:set(hit.x, hit.y, hit.z, self.constants.BLOCK.AIR)
  if usedTool and self.inventory and self.inventory.damageSelectedTool then
    self.inventory:damageSelectedTool(1)
  end

  self:resetBreakProgress()
  return {
    x = hit.x,
    y = hit.y,
    z = hit.z,
    block = block,
    usedTool = usedTool
  }
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
