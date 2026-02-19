local Interaction = {}
Interaction.__index = Interaction

function Interaction.new(constants, world, player, inventory)
  local self = setmetatable({}, Interaction)
  self.constants = constants
  self.world = world
  self.player = player
  self.inventory = inventory
  self.targetHit = nil
  self._targetHitScratch = {}
  return self
end

function Interaction:updateTarget()
  local cameraX, cameraY, cameraZ = self.player:getCameraPosition()
  local lookX, lookY, lookZ = self.player:getLookVector()
  self.targetHit = self.world:raycast(cameraX, cameraY, cameraZ, lookX, lookY, lookZ, self.player.reach, self._targetHitScratch)
  return self.targetHit
end

function Interaction:tryBreak()
  local hit = self.targetHit
  if not hit then
    return
  end

  local block = self.world:get(hit.x, hit.y, hit.z)
  if not self.world:isBreakable(block) then
    return
  end

  if not self.inventory:canAdd(block, 1) then
    return
  end

  self.world:set(hit.x, hit.y, hit.z, self.constants.BLOCK.AIR)
  self.inventory:add(block, 1)
end

function Interaction:tryPlace()
  local hit = self.targetHit
  if not hit then
    return
  end

  if not hit.previousX or not hit.previousY or not hit.previousZ then
    return
  end

  local placeX = hit.previousX
  local placeY = hit.previousY
  local placeZ = hit.previousZ

  if not self.world:isInside(placeX, placeY, placeZ) then
    return
  end

  if self.world:get(placeX, placeY, placeZ) ~= self.constants.BLOCK.AIR then
    return
  end

  local block = self.inventory:getSelectedBlock()
  if not block or not self.world:isPlaceable(block) then
    return
  end

  if self.player:overlapsBlock(placeX, placeY, placeZ) then
    return
  end

  if self.inventory:consumeSelected(1) then
    self.world:set(placeX, placeY, placeZ, block)
  end
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
end

return Interaction
