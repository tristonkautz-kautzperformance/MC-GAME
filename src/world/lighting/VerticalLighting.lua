local hasFfi, ffi = pcall(require, 'ffi')
if not hasFfi then
  ffi = nil
end

local VerticalLighting = {}
VerticalLighting.__index = VerticalLighting

local function clampInt(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

function VerticalLighting.new(world, options)
  local self = setmetatable({}, VerticalLighting)
  self.world = world
  self.options = options or {}
  self.enabled = self.options.enabled ~= false
  self.lightOpacityByBlock = self.options.lightOpacityByBlock or {}
  self.chunkVolume = world._chunkVolume or (world.chunkSize * world.chunkSize * world.chunkSize)

  self.skyLightChunks = {}
  self.skyColumnsReady = {}

  self.skyCenterCx = 1
  self.skyCenterCz = 1
  self.skyKeepRadius = 0
  self.skyActiveMinCx = 1
  self.skyActiveMaxCx = 0
  self.skyActiveMinCz = 1
  self.skyActiveMaxCz = 0
  self.skyActiveMinX = 1
  self.skyActiveMaxX = 0
  self.skyActiveMinZ = 1
  self.skyActiveMaxZ = 0

  return self
end

function VerticalLighting:reset()
  self.skyLightChunks = {}
  self.skyColumnsReady = {}
  self.skyCenterCx = 1
  self.skyCenterCz = 1
  self.skyKeepRadius = 0
  self.skyActiveMinCx = 1
  self.skyActiveMaxCx = 0
  self.skyActiveMinCz = 1
  self.skyActiveMaxCz = 0
  self.skyActiveMinX = 1
  self.skyActiveMaxX = 0
  self.skyActiveMinZ = 1
  self.skyActiveMaxZ = 0
end

function VerticalLighting:_getBlockLightOpacity(block)
  local value = self.lightOpacityByBlock[block]
  if value == nil then
    return 0
  end
  return value
end

function VerticalLighting:_newSkyChunkData()
  if ffi then
    return ffi.new('uint8_t[?]', self.chunkVolume)
  end
  local data = {}
  for i = 1, self.chunkVolume do
    data[i] = 0
  end
  return data
end

function VerticalLighting:_getSkyChunk(chunkKey, create)
  local chunk = self.skyLightChunks[chunkKey]
  if chunk or not create then
    return chunk
  end

  chunk = self:_newSkyChunkData()
  self.skyLightChunks[chunkKey] = chunk
  return chunk
end

function VerticalLighting:_getSkyChunkValue(chunk, localIndex)
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

function VerticalLighting:_setSkyChunkValue(chunk, localIndex, value)
  if ffi then
    chunk[localIndex - 1] = value
  else
    chunk[localIndex] = value
  end
end

function VerticalLighting:_getSkyLightWorld(x, y, z)
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

function VerticalLighting:_setSkyLightWorld(x, y, z, value, markDirty)
  local world = self.world
  if not world:isInside(x, y, z) then
    return false
  end

  local cx, cy, cz, lx, ly, lz = world:_toChunkCoords(x, y, z)
  local chunkKey = world:chunkKey(cx, cy, cz)
  local chunk = self:_getSkyChunk(chunkKey, true)
  local localIndex = world:_localIndex(lx, ly, lz)
  local oldValue = self:_getSkyChunkValue(chunk, localIndex)
  if oldValue == value then
    return false
  end

  self:_setSkyChunkValue(chunk, localIndex, value)
  if markDirty then
    world:_markDirty(cx, cy, cz)
  end
  return true
end

function VerticalLighting:_recomputeSkyColumn(x, z, markDirty)
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

    self:_setSkyLightWorld(x, y, z, light, markDirty)

    if light == 0 and opacity >= 15 then
      for clearY = y - 1, 1, -1 do
        self:_setSkyLightWorld(x, clearY, z, 0, markDirty)
      end
      break
    end
  end

  self.skyColumnsReady[columnKey] = true
  return true
end

function VerticalLighting:_ensureSkyColumnReady(x, z, markDirty)
  local world = self.world
  if x < 1 or x > world.sizeX or z < 1 or z > world.sizeZ then
    return false
  end

  local columnKey = world:_worldColumnKey(x, z)
  if self.skyColumnsReady[columnKey] then
    return true
  end

  return self:_recomputeSkyColumn(x, z, markDirty)
end

function VerticalLighting:_ensureSkyHaloColumns(cx, cz, markDirty)
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
          self:_ensureSkyColumnReady(x, z, markDirty)
        end
      end
    end
  end
end

function VerticalLighting:_markLightingDirtyRadius(cx, cz)
  local world = self.world
  local radius = math.ceil(15 / world.chunkSize)
  if radius < 0 then
    radius = 0
  end

  local minX = clampInt(cx - radius, 1, world.chunksX)
  local maxX = clampInt(cx + radius, 1, world.chunksX)
  local minZ = clampInt(cz - radius, 1, world.chunksZ)
  local maxZ = clampInt(cz + radius, 1, world.chunksZ)

  for markCz = minZ, maxZ do
    for markCx = minX, maxX do
      for markCy = 1, world.chunksY do
        world:_markDirty(markCx, markCy, markCz)
      end
    end
  end
end

function VerticalLighting:getSkyLight(x, y, z)
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

  self:_ensureSkyColumnReady(x, z, false)
  return self:_getSkyLightWorld(x, y, z)
end

function VerticalLighting:ensureSkyLightForChunk(cx, cy, cz)
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
  self:_ensureSkyHaloColumns(cx, cz, false)
  return true
end

function VerticalLighting:fillSkyLightHalo(cx, cy, cz, out)
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

  self:_ensureSkyHaloColumns(cx, cz, false)
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

function VerticalLighting:updateSkyLight(maxOps, maxMillis)
  return 0
end

function VerticalLighting:setFrameTiming(frameMs, worstFrameMs)
end

function VerticalLighting:getPerfStats()
  return 0, 0, 0, 1
end

function VerticalLighting:hasUrgentSkyWork()
  return false
end

function VerticalLighting:hasSkyWork()
  return false
end

function VerticalLighting:pruneSkyLightChunks(centerCx, centerCz, keepRadiusChunks)
  if not self.enabled then
    return 0
  end

  local world = self.world
  local cx = clampInt(math.floor(tonumber(centerCx) or 1), 1, world.chunksX)
  local cz = clampInt(math.floor(tonumber(centerCz) or 1), 1, world.chunksZ)
  local keepRadius = math.floor(tonumber(keepRadiusChunks) or 0)
  if keepRadius < 0 then
    keepRadius = 0
  end

  local minCx = clampInt(cx - keepRadius, 1, world.chunksX)
  local maxCx = clampInt(cx + keepRadius, 1, world.chunksX)
  local minCz = clampInt(cz - keepRadius, 1, world.chunksZ)
  local maxCz = clampInt(cz + keepRadius, 1, world.chunksZ)

  self.skyCenterCx = cx
  self.skyCenterCz = cz
  self.skyKeepRadius = keepRadius
  self.skyActiveMinCx = minCx
  self.skyActiveMaxCx = maxCx
  self.skyActiveMinCz = minCz
  self.skyActiveMaxCz = maxCz
  self.skyActiveMinX = (minCx - 1) * world.chunkSize + 1
  self.skyActiveMaxX = math.min(maxCx * world.chunkSize, world.sizeX)
  self.skyActiveMinZ = (minCz - 1) * world.chunkSize + 1
  self.skyActiveMaxZ = math.min(maxCz * world.chunkSize, world.sizeZ)

  local removed = 0
  for chunkKey, _ in pairs(self.skyLightChunks) do
    local chunkX, _, chunkZ = world:decodeChunkKey(chunkKey)
    local dx = math.abs(chunkX - cx)
    local dz = math.abs(chunkZ - cz)
    local dist = dx
    if dz > dist then
      dist = dz
    end
    if dist > keepRadius then
      self.skyLightChunks[chunkKey] = nil
      removed = removed + 1
    end
  end

  for columnKey, _ in pairs(self.skyColumnsReady) do
    local x, z = world:_decodeWorldColumnKey(columnKey)
    if x < self.skyActiveMinX or x > self.skyActiveMaxX or z < self.skyActiveMinZ or z > self.skyActiveMaxZ then
      self.skyColumnsReady[columnKey] = nil
    end
  end

  return removed
end

function VerticalLighting:onOpacityChanged(x, y, z, cx, cy, cz, oldOpacity, newOpacity)
  if not self.enabled then
    return
  end

  self.skyColumnsReady[self.world:_worldColumnKey(x, z)] = nil
  self:_markLightingDirtyRadius(cx, cz)
  self:_recomputeSkyColumn(x, z, false)
end

function VerticalLighting:onBulkOpacityChanged(minX, maxX, minZ, maxZ)
  if not self.enabled or minX == nil or maxX == nil or minZ == nil or maxZ == nil then
    return
  end

  local world = self.world
  local x0 = clampInt(math.floor(minX), 1, world.sizeX)
  local x1 = clampInt(math.floor(maxX), 1, world.sizeX)
  local z0 = clampInt(math.floor(minZ), 1, world.sizeZ)
  local z1 = clampInt(math.floor(maxZ), 1, world.sizeZ)
  if x1 < x0 or z1 < z0 then
    return
  end

  for z = z0, z1 do
    for x = x0, x1 do
      self.skyColumnsReady[world:_worldColumnKey(x, z)] = nil
    end
  end
end

function VerticalLighting:onPrepareChunk(cx, cz)
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

return VerticalLighting
