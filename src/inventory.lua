local Inventory = {}
Inventory.__index = Inventory

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

return Inventory
