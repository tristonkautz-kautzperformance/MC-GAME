local Chunk = {}
Chunk.__index = Chunk

local function index3(x, y, z, size)
  -- x,y,z are 1..size
  return ((y - 1) * size + (z - 1)) * size + x
end

function Chunk.new(size)
  local self = setmetatable({}, Chunk)
  self.size = size
  self.blocks = {}
  self.dirty = true
  return self
end

function Chunk:getLocal(x, y, z)
  return self.blocks[index3(x, y, z, self.size)] or 0
end

function Chunk:setLocal(x, y, z, value)
  local index = index3(x, y, z, self.size)
  if value == 0 then
    self.blocks[index] = nil
  else
    self.blocks[index] = value
  end
  self.dirty = true
end

function Chunk:clearDirty()
  self.dirty = false
end

return Chunk
