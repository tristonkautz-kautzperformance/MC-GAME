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

function Inventory.new(defaultBlocks, slotCount, startCount)
  local self = setmetatable({}, Inventory)
  self.slotCount = slotCount or 8
  self.selected = 1
  self.slots = {}

  for i = 1, self.slotCount do
    local block = defaultBlocks and defaultBlocks[i] or nil
    self.slots[i] = {
      block = block,
      count = block and (startCount or 0) or 0
    }
  end

  return self
end

function Inventory:getSelectedIndex()
  return self.selected
end

function Inventory:setSelectedIndex(index)
  if index >= 1 and index <= self.slotCount then
    self.selected = index
  end
end

function Inventory:cycle(delta)
  if delta == 0 then
    return
  end

  local index = self.selected + (delta > 0 and 1 or -1)
  if index < 1 then
    index = self.slotCount
  elseif index > self.slotCount then
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

function Inventory:consumeSelected(amount)
  amount = amount or 1
  local slot = self.slots[self.selected]
  if not slot or not slot.block or slot.count < amount then
    return false
  end

  slot.count = slot.count - amount
  if slot.count <= 0 then
    slot.count = 0
  end
  return true
end

function Inventory:canAdd(block, amount)
  amount = amount or 1
  if not block or amount <= 0 then
    return false
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if slot.block == block then
      return true
    end
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if not slot.block or slot.count == 0 then
      return true
    end
  end

  return false
end

function Inventory:add(block, amount)
  amount = amount or 1
  if not block or amount <= 0 then
    return false
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if slot.block == block then
      slot.count = slot.count + amount
      return true
    end
  end

  for i = 1, self.slotCount do
    local slot = self.slots[i]
    if not slot.block or slot.count == 0 then
      slot.block = block
      slot.count = amount
      return true
    end
  end

  return false
end

function Inventory:getState(out)
  if type(out) ~= 'table' then
    out = {}
  end

  out.slotCount = self.slotCount
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
    if slot and slot.block and slot.count and slot.count > 0 then
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
  self.selected = clamp(selected, 1, self.slotCount)
  return true
end

return Inventory
