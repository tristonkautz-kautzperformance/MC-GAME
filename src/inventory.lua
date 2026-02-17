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
end

function Inventory.new(defaultBlocks, slotCount, startCount, hotbarCount)
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

  for i = 1, self.slotCount do
    local entry = defaultBlocks and defaultBlocks[i] or nil
    local block = nil
    local count = 0

    if type(entry) == 'table' then
      block = entry.block or entry.id
      local explicitCount = parseInteger(entry.count)
      if block then
        count = explicitCount or (startCount or 0)
      end
    else
      block = entry
      if block then
        count = startCount or 0
      end
    end

    block = parseInteger(block)
    count = parseInteger(count) or 0
    if not block or block <= 0 or count <= 0 then
      block = nil
      count = 0
    end

    self.slots[i] = {
      block = block,
      count = count
    }
  end

  return self
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

function Inventory:getSelectedBlock()
  local slot = self.slots[self.selected]
  if not slot or not slot.block or slot.count <= 0 then
    return nil
  end
  return slot.block
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
  return out
end

function Inventory:_clearHeldStack()
  self.heldBlock = nil
  self.heldCount = 0
end

function Inventory:consumeSelected(amount)
  amount = amount or 1
  local slot = self.slots[self.selected]
  if not slot or not slot.block or slot.count < amount then
    return false
  end

  slot.count = slot.count - amount
  if slot.count <= 0 then
    clearSlot(slot)
  end
  return true
end

function Inventory:canAdd(block, amount)
  amount = amount or 1
  block = parseInteger(block)
  if not block or amount <= 0 then
    return false
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if slotHasStack(slot) and slot.block == block then
      return true
    end
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if not slotHasStack(slot) then
      return true
    end
  end

  return false
end

function Inventory:add(block, amount)
  amount = amount or 1
  block = parseInteger(block)
  if not block or amount <= 0 then
    return false
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if slotHasStack(slot) and slot.block == block then
      slot.count = slot.count + amount
      return true
    end
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if not slotHasStack(slot) then
      slot.block = block
      slot.count = amount
      return true
    end
  end

  return false
end

function Inventory:interactSlot(index)
  local slot = self.slots[index]
  if not slot then
    return false
  end

  if not self:hasHeldStack() then
    if not slotHasStack(slot) then
      return false
    end

    self.heldBlock = slot.block
    self.heldCount = slot.count
    clearSlot(slot)
    return true
  end

  if not slotHasStack(slot) then
    slot.block = self.heldBlock
    slot.count = self.heldCount
    self:_clearHeldStack()
    return true
  end

  if slot.block == self.heldBlock then
    slot.count = slot.count + self.heldCount
    self:_clearHeldStack()
    return true
  end

  local swapBlock = slot.block
  local swapCount = slot.count
  slot.block = self.heldBlock
  slot.count = self.heldCount
  self.heldBlock = swapBlock
  self.heldCount = swapCount
  return true
end

function Inventory:stowHeldStack()
  if not self:hasHeldStack() then
    return true
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if slotHasStack(slot) and slot.block == self.heldBlock then
      slot.count = slot.count + self.heldCount
      self:_clearHeldStack()
      return true
    end
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if not slotHasStack(slot) then
      slot.block = self.heldBlock
      slot.count = self.heldCount
      self:_clearHeldStack()
      return true
    end
  end

  local fallbackIndex = clamp(self.selected, 1, self.slotCount)
  local slot = self.slots[fallbackIndex]
  if not slotHasStack(slot) then
    slot.block = self.heldBlock
    slot.count = self.heldCount
    self:_clearHeldStack()
    return true
  end

  local swapBlock = slot.block
  local swapCount = slot.count
  slot.block = self.heldBlock
  slot.count = self.heldCount
  self.heldBlock = swapBlock
  self.heldCount = swapCount
  return false
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
    if slotHasStack(slot) then
      blockId = parseInteger(slot.block) or 0
      count = parseInteger(slot.count) or 0
      if blockId <= 0 or count <= 0 then
        blockId = 0
        count = 0
      end
    end

    local outSlot = slotsOut[i]
    if outSlot then
      outSlot.block = blockId
      outSlot.count = count
    else
      slotsOut[i] = { block = blockId, count = count }
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

    local slot = self.slots[i]
    if not slot then
      slot = { block = nil, count = 0 }
      self.slots[i] = slot
    end

    if not blockId or blockId <= 0 or not count or count <= 0 then
      slot.block = nil
      slot.count = 0
    else
      slot.block = blockId
      slot.count = count
    end
  end

  local selected = parseInteger(state.selected) or self.selected
  self.selected = clamp(selected, 1, self.hotbarCount)
  self:_clearHeldStack()
  return true
end

return Inventory
