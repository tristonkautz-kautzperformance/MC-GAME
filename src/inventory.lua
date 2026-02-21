local Inventory = {}
Inventory.__index = Inventory

local function parseInteger(value)
  local n = tonumber(value)
  if not n or n % 1 ~= 0 then
    return nil
  end
  return n
end

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function slotHasStack(slot)
  return slot and slot.block and slot.count and slot.count > 0
end

local function clearSlot(slot)
  if not slot then
    return
  end
  slot.block = nil
  slot.count = 0
  slot.durability = nil
end

local function sanitizeDurability(value)
  local n = parseInteger(value)
  if not n or n <= 0 then
    return nil
  end
  return n
end

function Inventory.new(defaultBlocks, slotCount, startCount, hotbarCount, blockInfo)
  local self = setmetatable({}, Inventory)

  local totalSlots = parseInteger(slotCount) or 8
  if totalSlots < 1 then
    totalSlots = 1
  end
  self.slotCount = totalSlots

  local derivedHotbarCount = parseInteger(hotbarCount)
  if not derivedHotbarCount then
    if type(defaultBlocks) == 'table' and #defaultBlocks > 0 then
      derivedHotbarCount = #defaultBlocks
    else
      derivedHotbarCount = totalSlots
    end
  end
  self.hotbarCount = clamp(derivedHotbarCount, 1, self.slotCount)

  self.selected = 1
  self.slots = {}
  self.heldBlock = nil
  self.heldCount = 0
  self.heldDurability = nil
  self.blockInfo = blockInfo or {}

  local defaultCount = parseInteger(startCount) or 0

  for i = 1, self.slotCount do
    local entry = defaultBlocks and defaultBlocks[i] or nil
    local block = nil
    local count = 0
    local durability = nil

    if type(entry) == 'table' then
      block = entry.block or entry.id
      local explicitCount = parseInteger(entry.count)
      if block then
        count = explicitCount or defaultCount
      end
      durability = sanitizeDurability(entry.durability)
    else
      block = entry
      if block then
        count = defaultCount
      end
    end

    block = parseInteger(block)
    count = parseInteger(count) or 0

    local slot = { block = nil, count = 0, durability = nil }
    if block and block > 0 and count > 0 then
      local stackable = self:isStackable(block)
      if not stackable and count > 1 then
        count = 1
      end
      slot.block = block
      slot.count = count
      if not stackable then
        durability = sanitizeDurability(durability) or self:getDefaultDurability(block)
        slot.durability = durability
      end
    end

    self.slots[i] = slot
  end

  return self
end

function Inventory:getBlockInfo(block)
  return self.blockInfo and self.blockInfo[block] or nil
end

function Inventory:isStackable(block)
  local info = self:getBlockInfo(block)
  if info and info.stackable == false then
    return false
  end
  return true
end

function Inventory:getToolType(block)
  local info = self:getBlockInfo(block)
  if info and type(info.toolType) == 'string' then
    return info.toolType
  end
  return nil
end

function Inventory:getDefaultDurability(block)
  local info = self:getBlockInfo(block)
  if not info then
    return nil
  end

  local maxDurability = parseInteger(info.maxDurability)
  if maxDurability and maxDurability > 0 then
    return maxDurability
  end

  local durability = parseInteger(info.durability)
  if durability and durability > 0 then
    return durability
  end

  return nil
end

function Inventory:getHotbarCount()
  return self.hotbarCount
end

function Inventory:getStorageCount()
  return math.max(0, self.slotCount - self.hotbarCount)
end

function Inventory:getSelectedIndex()
  return self.selected
end

function Inventory:setSelectedIndex(index)
  if index >= 1 and index <= self.hotbarCount then
    self.selected = index
  end
end

function Inventory:cycle(delta)
  if delta == 0 then
    return
  end

  local index = self.selected + (delta > 0 and 1 or -1)
  if index < 1 then
    index = self.hotbarCount
  elseif index > self.hotbarCount then
    index = 1
  end

  self.selected = index
end

function Inventory:getSlot(index)
  return self.slots[index]
end

function Inventory:getSelectedSlot()
  return self.slots[self.selected]
end

function Inventory:getSelectedBlock()
  local slot = self.slots[self.selected]
  if not slotHasStack(slot) then
    return nil
  end
  return slot.block
end

function Inventory:getSelectedToolType()
  local slot = self.slots[self.selected]
  if not slotHasStack(slot) then
    return nil
  end
  return self:getToolType(slot.block)
end

function Inventory:hasHeldStack()
  return self.heldBlock ~= nil and self.heldCount > 0
end

function Inventory:getHeldStack(out)
  if not self:hasHeldStack() then
    return nil
  end

  if type(out) ~= 'table' then
    out = {}
  end
  out.block = self.heldBlock
  out.count = self.heldCount
  out.durability = self.heldDurability
  return out
end

function Inventory:_setHeldStack(block, count, durability)
  block = parseInteger(block)
  count = parseInteger(count) or 0
  if not block or block <= 0 or count <= 0 then
    self:_clearHeldStack()
    return false
  end

  local stackable = self:isStackable(block)
  if not stackable and count > 1 then
    count = 1
  end

  self.heldBlock = block
  self.heldCount = count
  self.heldDurability = stackable and nil or (sanitizeDurability(durability) or self:getDefaultDurability(block))
  return true
end

function Inventory:_clearHeldStack()
  self.heldBlock = nil
  self.heldCount = 0
  self.heldDurability = nil
end

function Inventory:dropHeldStack(out)
  if not self:hasHeldStack() then
    return nil
  end

  if type(out) ~= 'table' then
    out = {}
  end
  out.block = self.heldBlock
  out.count = self.heldCount
  out.durability = self.heldDurability
  self:_clearHeldStack()
  return out
end

function Inventory:consumeSelected(amount)
  amount = parseInteger(amount) or 1
  if amount <= 0 then
    return false
  end

  local slot = self.slots[self.selected]
  if not slotHasStack(slot) then
    return false
  end

  if slot.count < amount then
    return false
  end

  slot.count = slot.count - amount
  if slot.count <= 0 then
    clearSlot(slot)
  end
  return true
end

function Inventory:_countEmptySlots()
  local count = 0
  for i = 1, self.slotCount do
    if not slotHasStack(self.slots[i]) then
      count = count + 1
    end
  end
  return count
end

function Inventory:countEmptySlots()
  return self:_countEmptySlots()
end

function Inventory:canAdd(block, amount)
  return self:canAddStack(block, amount)
end

function Inventory:canAddStack(block, amount)
  amount = parseInteger(amount) or 1
  block = parseInteger(block)
  if not block or amount <= 0 then
    return false
  end

  if self:isStackable(block) then
    for i = 1, self.slotCount do
      local slot = self.slots[i]
      if slotHasStack(slot) and slot.block == block then
        return true
      end
    end

    for i = 1, self.slotCount do
      if not slotHasStack(self.slots[i]) then
        return true
      end
    end
    return false
  end

  return self:_countEmptySlots() >= amount
end

function Inventory:add(block, amount, durability)
  local added = self:addStack(block, amount, durability)
  return added >= (parseInteger(amount) or 1)
end

function Inventory:addStack(block, amount, durability)
  amount = parseInteger(amount) or 1
  block = parseInteger(block)
  if not block or amount <= 0 then
    return 0
  end

  if self:isStackable(block) then
    for i = 1, self.slotCount do
      local slot = self.slots[i]
      if slotHasStack(slot) and slot.block == block then
        slot.count = slot.count + amount
        return amount
      end
    end

    for i = 1, self.slotCount do
      local slot = self.slots[i]
      if not slotHasStack(slot) then
        slot.block = block
        slot.count = amount
        slot.durability = nil
        return amount
      end
    end

    return 0
  end

  local remaining = amount
  local added = 0
  local entryDurability = sanitizeDurability(durability) or self:getDefaultDurability(block)
  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if not slotHasStack(slot) then
      slot.block = block
      slot.count = 1
      slot.durability = entryDurability
      added = added + 1
      remaining = remaining - 1
      if remaining <= 0 then
        break
      end
    end
  end

  return added
end

function Inventory:_mergeHeldIntoSlot(slot)
  if not self:isStackable(self.heldBlock) then
    return false
  end

  slot.count = slot.count + self.heldCount
  self:_clearHeldStack()
  return true
end

function Inventory:_swapHeldWithSlot(slot)
  local swapBlock = slot.block
  local swapCount = slot.count
  local swapDurability = slot.durability

  slot.block = self.heldBlock
  slot.count = self.heldCount
  slot.durability = self.heldDurability

  self.heldBlock = swapBlock
  self.heldCount = swapCount
  self.heldDurability = swapDurability
  return true
end

function Inventory:interactAnySlot(slot, button)
  if not slot then
    return false
  end

  local actionButton = parseInteger(button) or 1
  local hasSlotStack = slotHasStack(slot)

  if actionButton == 1 then
    if not self:hasHeldStack() then
      if not hasSlotStack then
        return false
      end
      self:_setHeldStack(slot.block, slot.count, slot.durability)
      clearSlot(slot)
      return true
    end

    if not hasSlotStack then
      slot.block = self.heldBlock
      slot.count = self.heldCount
      slot.durability = self.heldDurability
      self:_clearHeldStack()
      return true
    end

    if slot.block == self.heldBlock and self:isStackable(slot.block) then
      return self:_mergeHeldIntoSlot(slot)
    end

    return self:_swapHeldWithSlot(slot)
  end

  if actionButton ~= 2 then
    return false
  end

  if not self:hasHeldStack() then
    if not hasSlotStack then
      return false
    end
    if not self:isStackable(slot.block) then
      return false
    end

    slot.count = slot.count - 1
    self:_setHeldStack(slot.block, 1, slot.durability)
    if slot.count <= 0 then
      clearSlot(slot)
    end
    return true
  end

  if not self:isStackable(self.heldBlock) then
    return false
  end

  if not hasSlotStack then
    slot.block = self.heldBlock
    slot.count = 1
    slot.durability = nil
    self.heldCount = self.heldCount - 1
    if self.heldCount <= 0 then
      self:_clearHeldStack()
    end
    return true
  end

  if slot.block ~= self.heldBlock or not self:isStackable(slot.block) then
    return false
  end

  slot.count = slot.count + 1
  self.heldCount = self.heldCount - 1
  if self.heldCount <= 0 then
    self:_clearHeldStack()
  end
  return true
end

function Inventory:interactSlot(index)
  local slot = self.slots[index]
  if not slot then
    return false
  end
  return self:interactAnySlot(slot, 1)
end

function Inventory:stowHeldStack()
  if not self:hasHeldStack() then
    return true
  end

  local added = self:addStack(self.heldBlock, self.heldCount, self.heldDurability)
  if added <= 0 then
    return false
  end

  self.heldCount = self.heldCount - added
  if self.heldCount <= 0 then
    self:_clearHeldStack()
    return true
  end

  return false
end

function Inventory:damageSelectedTool(amount)
  amount = parseInteger(amount) or 1
  if amount <= 0 then
    return false
  end

  local slot = self.slots[self.selected]
  if not slotHasStack(slot) then
    return false
  end

  local toolType = self:getToolType(slot.block)
  if not toolType then
    return false
  end

  local durability = sanitizeDurability(slot.durability) or self:getDefaultDurability(slot.block)
  if not durability then
    clearSlot(slot)
    return true
  end

  durability = durability - amount
  if durability <= 0 then
    clearSlot(slot)
  else
    slot.durability = durability
  end

  return true
end

function Inventory:getState(out)
  if type(out) ~= 'table' then
    out = {}
  end

  out.slotCount = self.slotCount
  out.hotbarCount = self.hotbarCount
  out.selected = self.selected

  local slotsOut = out.slots
  if type(slotsOut) ~= 'table' then
    slotsOut = {}
    out.slots = slotsOut
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    local blockId = 0
    local count = 0
    local durability = 0
    if slotHasStack(slot) then
      blockId = parseInteger(slot.block) or 0
      count = parseInteger(slot.count) or 0
      if blockId <= 0 or count <= 0 then
        blockId = 0
        count = 0
      else
        if not self:isStackable(blockId) and count > 1 then
          count = 1
        end
        durability = sanitizeDurability(slot.durability) or 0
      end
    end

    local outSlot = slotsOut[i]
    if outSlot then
      outSlot.block = blockId
      outSlot.count = count
      outSlot.durability = durability
    else
      slotsOut[i] = { block = blockId, count = count, durability = durability }
    end
  end

  for i = self.slotCount + 1, #slotsOut do
    slotsOut[i] = nil
  end

  return out
end

function Inventory:applyState(state)
  if type(state) ~= 'table' then
    return false
  end

  local slots = state.slots
  for i = 1, self.slotCount do
    local source = (type(slots) == 'table') and slots[i] or nil
    local blockId = source and parseInteger(source.block) or nil
    local count = source and parseInteger(source.count) or nil
    local durability = source and sanitizeDurability(source.durability) or nil

    local slot = self.slots[i]
    if not slot then
      slot = { block = nil, count = 0, durability = nil }
      self.slots[i] = slot
    end

    if not blockId or blockId <= 0 or not count or count <= 0 then
      clearSlot(slot)
    else
      if not self:isStackable(blockId) and count > 1 then
        count = 1
      end
      slot.block = blockId
      slot.count = count
      if self:isStackable(blockId) then
        slot.durability = nil
      else
        slot.durability = durability or self:getDefaultDurability(blockId)
      end
    end
  end

  local selected = parseInteger(state.selected) or self.selected
  self.selected = clamp(selected, 1, self.hotbarCount)
  self:_clearHeldStack()
  return true
end

return Inventory
