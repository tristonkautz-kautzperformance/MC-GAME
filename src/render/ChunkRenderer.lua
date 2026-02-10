local ChunkRenderer = {}
ChunkRenderer.__index = ChunkRenderer

local VERTEX_FORMAT = {
  { 'VertexPosition', 'vec3' },
  { 'VertexNormal', 'vec3' },
  { 'VertexColor', 'vec4' }
}

local function addVertex(list, x, y, z, nx, ny, nz, r, g, b, a)
  list[#list + 1] = { x, y, z, nx, ny, nz, r, g, b, a }
end

local function emitQuad(list, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz, r, g, b, a)
  -- Two triangles (a,b,c) + (a,c,d).
  addVertex(list, ax, ay, az, nx, ny, nz, r, g, b, a)
  addVertex(list, bx, by, bz, nx, ny, nz, r, g, b, a)
  addVertex(list, cx, cy, cz, nx, ny, nz, r, g, b, a)

  addVertex(list, ax, ay, az, nx, ny, nz, r, g, b, a)
  addVertex(list, cx, cy, cz, nx, ny, nz, r, g, b, a)
  addVertex(list, dx, dy, dz, nx, ny, nz, r, g, b, a)
end

local DIR_NEG_X = 1
local DIR_POS_X = 2
local DIR_NEG_Y = 3
local DIR_POS_Y = 4
local DIR_NEG_Z = 5
local DIR_POS_Z = 6

function ChunkRenderer.new(constants, world)
  local self = setmetatable({}, ChunkRenderer)
  self.constants = constants
  self.world = world

  self.chunkSize = constants.CHUNK_SIZE
  self._chunkMeshes = {} -- key -> { opaqueMesh, alphaMesh }
  self._dirtyEntries = {} -- key -> { key, cx, cy, cz, dist }
  self._dirtyBuckets = {} -- dist -> { items, head, tail }
  self._dirtyScratch = {}
  self._dirtyMinDist = nil
  self._dirtyMaxDist = 0
  self._dirtyCount = 0
  self._priorityChunkX = 1
  self._priorityChunkY = 1
  self._priorityChunkZ = 1
  self._hasPriorityChunk = false
  self._rebuildConfig = constants.REBUILD or {}
  self._usePriorityRebuild = self._rebuildConfig.prioritize ~= false
  self._priorityHorizontalOnly = self._rebuildConfig.prioritizeHorizontalOnly ~= false
  self._rebuildsLastFrame = 0
  self._visibleCount = 0
  self._useGreedyMeshing = not (constants.MESH and constants.MESH.greedy == false)
  self._drawForward = lovr.math.newVec3(0, 0, -1)
  self._alphaScratch = {}
  self._alphaScratchCount = 0

  return self
end

function ChunkRenderer:getLastFrameStats()
  return self._visibleCount or 0, self._rebuildsLastFrame or 0
end

function ChunkRenderer:getDirtyQueueSize()
  return self._dirtyCount or 0
end

function ChunkRenderer:isGreedyMeshingEnabled()
  return self._useGreedyMeshing
end

function ChunkRenderer:getMeshingModeLabel()
  if self._useGreedyMeshing then
    return 'Greedy'
  end
  return 'Naive'
end

local function parseKey(key)
  local cx, cy, cz = key:match('^(%d+),(%d+),(%d+)$')
  return tonumber(cx), tonumber(cy), tonumber(cz)
end

local function isAir(constants, block)
  return block == constants.BLOCK.AIR
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

local function alphaSortBackToFront(a, b)
  return a._alphaDistSq > b._alphaDistSq
end

function ChunkRenderer:setPriorityOriginWorld(cameraX, cameraY, cameraZ)
  local cs = self.chunkSize
  local world = self.world

  local pcx = math.floor((cameraX or 0) / cs) + 1
  local pcy = math.floor((cameraY or 0) / cs) + 1
  local pcz = math.floor((cameraZ or 0) / cs) + 1

  if world then
    pcx = clamp(pcx, 1, world.chunksX)
    pcy = clamp(pcy, 1, world.chunksY)
    pcz = clamp(pcz, 1, world.chunksZ)
  end

  if self._hasPriorityChunk
    and pcx == self._priorityChunkX
    and pcy == self._priorityChunkY
    and pcz == self._priorityChunkZ then
    return
  end

  self._priorityChunkX = pcx
  self._priorityChunkY = pcy
  self._priorityChunkZ = pcz
  self._hasPriorityChunk = true

  if self._usePriorityRebuild and self._dirtyCount > 0 then
    self:_rebucketDirtyEntries()
  end
end

function ChunkRenderer:_computeDirtyDistance(cx, cy, cz)
  if not self._usePriorityRebuild or not self._hasPriorityChunk then
    return 0
  end

  local dx = math.abs(cx - self._priorityChunkX)
  local dz = math.abs(cz - self._priorityChunkZ)
  if self._priorityHorizontalOnly then
    if dx > dz then
      return dx
    end
    return dz
  end

  local dy = math.abs(cy - self._priorityChunkY)
  local dist = dx
  if dy > dist then
    dist = dy
  end
  if dz > dist then
    dist = dz
  end
  return dist
end

function ChunkRenderer:_pushDirtyEntry(entry)
  local dist = self:_computeDirtyDistance(entry.cx, entry.cy, entry.cz)
  entry.dist = dist

  local bucket = self._dirtyBuckets[dist]
  if not bucket then
    bucket = { items = {}, head = 1, tail = 0 }
    self._dirtyBuckets[dist] = bucket
  end

  local tail = bucket.tail + 1
  bucket.tail = tail
  bucket.items[tail] = entry

  if not self._dirtyMinDist or dist < self._dirtyMinDist then
    self._dirtyMinDist = dist
  end
  if dist > self._dirtyMaxDist then
    self._dirtyMaxDist = dist
  end
end

function ChunkRenderer:_findNextDirtyBucket(startDist)
  local maxDist = self._dirtyMaxDist or 0
  for dist = startDist, maxDist do
    local bucket = self._dirtyBuckets[dist]
    if bucket and bucket.head <= bucket.tail then
      return dist
    end
    self._dirtyBuckets[dist] = nil
  end
  return nil
end

function ChunkRenderer:_popDirtyEntry()
  if self._dirtyCount <= 0 then
    return nil
  end

  local dist = self._dirtyMinDist
  if not dist then
    dist = self:_findNextDirtyBucket(0)
    self._dirtyMinDist = dist
    if not dist then
      return nil
    end
  end

  while dist do
    local bucket = self._dirtyBuckets[dist]
    if bucket and bucket.head <= bucket.tail then
      local head = bucket.head
      local entry = bucket.items[head]
      bucket.items[head] = nil
      bucket.head = head + 1

      if bucket.head > bucket.tail then
        self._dirtyBuckets[dist] = nil
        self._dirtyMinDist = self:_findNextDirtyBucket(dist + 1)
        if not self._dirtyMinDist then
          self._dirtyMaxDist = 0
        end
      else
        self._dirtyMinDist = dist
      end

      if entry then
        self._dirtyEntries[entry.key] = nil
        self._dirtyCount = self._dirtyCount - 1
        return entry
      end
    else
      self._dirtyBuckets[dist] = nil
      dist = self:_findNextDirtyBucket(dist + 1)
      self._dirtyMinDist = dist
      if not dist then
        self._dirtyMaxDist = 0
      end
    end
  end

  return nil
end

function ChunkRenderer:_rebucketDirtyEntries()
  if self._dirtyCount <= 0 then
    self._dirtyBuckets = {}
    self._dirtyMinDist = nil
    self._dirtyMaxDist = 0
    return
  end

  local oldBuckets = self._dirtyBuckets
  local oldMin = self._dirtyMinDist or 0
  local oldMax = self._dirtyMaxDist or 0

  self._dirtyBuckets = {}
  self._dirtyMinDist = nil
  self._dirtyMaxDist = 0

  for dist = oldMin, oldMax do
    local bucket = oldBuckets[dist]
    if bucket then
      for i = bucket.head, bucket.tail do
        local entry = bucket.items[i]
        if entry and self._dirtyEntries[entry.key] then
          self:_pushDirtyEntry(entry)
        end
      end
    end
  end

  if not self._dirtyMinDist and self._dirtyCount > 0 then
    for _, entry in pairs(self._dirtyEntries) do
      self:_pushDirtyEntry(entry)
    end
  end
end

function ChunkRenderer:_queueDirtyKeys(dirtyKeys, count)
  count = count or #dirtyKeys
  for i = 1, count do
    local key = dirtyKeys[i]
    if not self._dirtyEntries[key] then
      local cx, cy, cz = parseKey(key)
      if cx and cy and cz then
        local entry = { key = key, cx = cx, cy = cy, cz = cz, dist = 0 }
        self._dirtyEntries[key] = entry
        self._dirtyCount = self._dirtyCount + 1
        self:_pushDirtyEntry(entry)
      end
    end
  end
end

function ChunkRenderer:_shouldDrawFace(block, neighbor)
  local constants = self.constants
  if isAir(constants, block) then
    return false, false
  end

  local info = constants.BLOCK_INFO[block]
  if not info or not info.solid then
    return false, false
  end

  if info.opaque then
    -- Opaque: draw when neighbor is not opaque (air or translucent).
    local nInfo = constants.BLOCK_INFO[neighbor]
    local neighborOpaque = nInfo and nInfo.opaque or false
    return not neighborOpaque, false
  end

  -- Translucent (leaf): only draw faces against air; cull internal leaf faces.
  if neighbor == block then
    return false, true
  end
  return isAir(constants, neighbor), true
end

function ChunkRenderer:_buildChunkNaive(cx, cy, cz)
  local constants = self.constants
  local cs = self.chunkSize
  local world = self.world
  local blockInfo = constants.BLOCK_INFO

  local originX = (cx - 1) * cs
  local originY = (cy - 1) * cs
  local originZ = (cz - 1) * cs

  local verticesOpaque = {}
  local verticesAlpha = {}

  local function getBlock(wx, wy, wz)
    return world:get(wx, wy, wz)
  end

  for ly = 1, cs do
    local wy = originY + ly
    if wy > world.sizeY then break end
    for lz = 1, cs do
      local wz = originZ + lz
      if wz > world.sizeZ then break end
      for lx = 1, cs do
        local wx = originX + lx
        if wx > world.sizeX then break end

        local block = getBlock(wx, wy, wz)
        if not isAir(constants, block) then
          local info = blockInfo[block]
          local r = info and info.color[1] or 1
          local g = info and info.color[2] or 0
          local b = info and info.color[3] or 1
          local a = info and (info.alpha or 1) or 1
          local out = (info and info.opaque) and verticesOpaque or verticesAlpha

          local x0 = lx - 1
          local x1 = lx
          local y0 = ly - 1
          local y1 = ly
          local z0 = lz - 1
          local z1 = lz

          local ok = self:_shouldDrawFace(block, getBlock(wx - 1, wy, wz))
          if ok then
            emitQuad(out, x0, y0, z0, x0, y0, z1, x0, y1, z1, x0, y1, z0, -1, 0, 0, r, g, b, a)
          end

          ok = self:_shouldDrawFace(block, getBlock(wx + 1, wy, wz))
          if ok then
            emitQuad(out, x1, y0, z1, x1, y0, z0, x1, y1, z0, x1, y1, z1, 1, 0, 0, r, g, b, a)
          end

          ok = self:_shouldDrawFace(block, getBlock(wx, wy - 1, wz))
          if ok then
            emitQuad(out, x0, y0, z1, x1, y0, z1, x1, y0, z0, x0, y0, z0, 0, -1, 0, r, g, b, a)
          end

          ok = self:_shouldDrawFace(block, getBlock(wx, wy + 1, wz))
          if ok then
            emitQuad(out, x0, y1, z0, x1, y1, z0, x1, y1, z1, x0, y1, z1, 0, 1, 0, r, g, b, a)
          end

          ok = self:_shouldDrawFace(block, getBlock(wx, wy, wz - 1))
          if ok then
            emitQuad(out, x0, y0, z0, x1, y0, z0, x1, y1, z0, x0, y1, z0, 0, 0, -1, r, g, b, a)
          end

          ok = self:_shouldDrawFace(block, getBlock(wx, wy, wz + 1))
          if ok then
            emitQuad(out, x1, y0, z1, x0, y0, z1, x0, y1, z1, x1, y1, z1, 0, 0, 1, r, g, b, a)
          end
        end
      end
    end
  end

  return originX, originY, originZ, verticesOpaque, verticesAlpha
end

function ChunkRenderer:_buildChunkGreedy(cx, cy, cz)
  local constants = self.constants
  local cs = self.chunkSize
  local world = self.world
  local blockInfo = constants.BLOCK_INFO

  local originX = (cx - 1) * cs
  local originY = (cy - 1) * cs
  local originZ = (cz - 1) * cs

  local verticesOpaque = {}
  local verticesAlpha = {}

  local function getBlock(wx, wy, wz)
    return world:get(wx, wy, wz)
  end

  local function emitRect(direction, slice, u, v, width, height, block)
    local info = blockInfo[block]
    if not info then
      return
    end

    local out = info.opaque and verticesOpaque or verticesAlpha
    local r = info.color[1]
    local g = info.color[2]
    local b = info.color[3]
    local a = info.alpha or 1

    if direction == DIR_NEG_X then
      local x = slice - 1
      local y0 = v - 1
      local y1 = y0 + height
      local z0 = u - 1
      local z1 = z0 + width
      emitQuad(out, x, y0, z0, x, y0, z1, x, y1, z1, x, y1, z0, -1, 0, 0, r, g, b, a)
      return
    end

    if direction == DIR_POS_X then
      local x = slice
      local y0 = v - 1
      local y1 = y0 + height
      local z0 = u - 1
      local z1 = z0 + width
      emitQuad(out, x, y0, z1, x, y0, z0, x, y1, z0, x, y1, z1, 1, 0, 0, r, g, b, a)
      return
    end

    if direction == DIR_NEG_Y then
      local y = slice - 1
      local x0 = u - 1
      local x1 = x0 + width
      local z0 = v - 1
      local z1 = z0 + height
      emitQuad(out, x0, y, z1, x1, y, z1, x1, y, z0, x0, y, z0, 0, -1, 0, r, g, b, a)
      return
    end

    if direction == DIR_POS_Y then
      local y = slice
      local x0 = u - 1
      local x1 = x0 + width
      local z0 = v - 1
      local z1 = z0 + height
      emitQuad(out, x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1, 0, 1, 0, r, g, b, a)
      return
    end

    if direction == DIR_NEG_Z then
      local z = slice - 1
      local x0 = u - 1
      local x1 = x0 + width
      local y0 = v - 1
      local y1 = y0 + height
      emitQuad(out, x0, y0, z, x1, y0, z, x1, y1, z, x0, y1, z, 0, 0, -1, r, g, b, a)
      return
    end

    local z = slice
    local x0 = u - 1
    local x1 = x0 + width
    local y0 = v - 1
    local y1 = y0 + height
    emitQuad(out, x1, y0, z, x0, y0, z, x0, y1, z, x1, y1, z, 0, 0, 1, r, g, b, a)
  end

  local mask = {}
  local maskSize = cs * cs
  for i = 1, maskSize do
    mask[i] = 0
  end

  for direction = DIR_NEG_X, DIR_POS_Z do
    local nx, ny, nz = 0, 0, 0
    if direction == DIR_NEG_X then nx = -1 end
    if direction == DIR_POS_X then nx = 1 end
    if direction == DIR_NEG_Y then ny = -1 end
    if direction == DIR_POS_Y then ny = 1 end
    if direction == DIR_NEG_Z then nz = -1 end
    if direction == DIR_POS_Z then nz = 1 end

    for slice = 1, cs do
      for i = 1, maskSize do
        mask[i] = 0
      end

      for v = 1, cs do
        for u = 1, cs do
          local lx, ly, lz
          if direction == DIR_NEG_X or direction == DIR_POS_X then
            lx, ly, lz = slice, v, u
          elseif direction == DIR_NEG_Y or direction == DIR_POS_Y then
            lx, ly, lz = u, slice, v
          else
            lx, ly, lz = u, v, slice
          end

          local wx = originX + lx
          local wy = originY + ly
          local wz = originZ + lz

          local block = getBlock(wx, wy, wz)
          local neighbor = getBlock(wx + nx, wy + ny, wz + nz)
          local shouldDraw = self:_shouldDrawFace(block, neighbor)
          if shouldDraw then
            mask[(v - 1) * cs + u] = block
          end
        end
      end

      for v = 1, cs do
        local u = 1
        while u <= cs do
          local index = (v - 1) * cs + u
          local block = mask[index]
          if block == 0 then
            u = u + 1
          else
            local width = 1
            while (u + width) <= cs and mask[index + width] == block do
              width = width + 1
            end

            local height = 1
            local canGrow = true
            while (v + height) <= cs and canGrow do
              local row = (v + height - 1) * cs + u
              for k = 0, width - 1 do
                if mask[row + k] ~= block then
                  canGrow = false
                  break
                end
              end
              if canGrow then
                height = height + 1
              end
            end

            emitRect(direction, slice, u, v, width, height, block)

            for clearV = v, v + height - 1 do
              local base = (clearV - 1) * cs + u
              for clearU = 0, width - 1 do
                mask[base + clearU] = 0
              end
            end

            u = u + width
          end
        end
      end
    end
  end

  return originX, originY, originZ, verticesOpaque, verticesAlpha
end

function ChunkRenderer:_rebuildChunk(cx, cy, cz)
  local cs = self.chunkSize
  local originX, originY, originZ, verticesOpaque, verticesAlpha

  if self._useGreedyMeshing then
    originX, originY, originZ, verticesOpaque, verticesAlpha = self:_buildChunkGreedy(cx, cy, cz)
  else
    originX, originY, originZ, verticesOpaque, verticesAlpha = self:_buildChunkNaive(cx, cy, cz)
  end

  local entry = self._chunkMeshes[cx .. ',' .. cy .. ',' .. cz] or {}

  if #verticesOpaque > 0 then
    entry.opaque = lovr.graphics.newMesh(VERTEX_FORMAT, verticesOpaque, 'cpu')
    entry.opaque:setDrawMode('triangles')
  else
    entry.opaque = nil
  end

  if #verticesAlpha > 0 then
    entry.alpha = lovr.graphics.newMesh(VERTEX_FORMAT, verticesAlpha, 'cpu')
    entry.alpha:setDrawMode('triangles')
  else
    entry.alpha = nil
  end

  entry.originX = originX
  entry.originY = originY
  entry.originZ = originZ

  local centerX = originX + cs * 0.5
  local centerY = originY + cs * 0.5
  local centerZ = originZ + cs * 0.5
  entry.centerX = centerX
  entry.centerY = centerY
  entry.centerZ = centerZ
  entry.radius = math.sqrt(3) * (cs * 0.5) + 0.05
  entry.radiusHorizontal = math.sqrt(2) * (cs * 0.5) + 0.05

  self._chunkMeshes[cx .. ',' .. cy .. ',' .. cz] = entry
end

function ChunkRenderer:rebuildDirty(maxPerFrame)
  maxPerFrame = maxPerFrame or self._rebuildConfig.maxPerFrame or 4
  self._rebuildsLastFrame = 0

  local dirtyCount = 0
  local dirtyKeys = self._dirtyScratch
  if self.world.drainDirtyChunkKeys then
    dirtyCount = self.world:drainDirtyChunkKeys(dirtyKeys)
  else
    dirtyKeys = self.world:getDirtyChunkKeys()
    dirtyCount = #dirtyKeys
  end

  if dirtyCount > 0 then
    self:_queueDirtyKeys(dirtyKeys, dirtyCount)
  end

  if self._dirtyCount <= 0 then
    return 0
  end

  local rebuilt = 0
  while rebuilt < maxPerFrame do
    local entry = self:_popDirtyEntry()
    if not entry then
      break
    end
    self:_rebuildChunk(entry.cx, entry.cy, entry.cz)
    rebuilt = rebuilt + 1
  end

  self._rebuildsLastFrame = rebuilt
  return rebuilt
end

function ChunkRenderer:_isVisibleChunk(entry, cameraX, cameraY, cameraZ, forwardX, forwardY, forwardZ)
  local cull = self.constants.CULL or {}
  if not cull.enabled then
    return true
  end

  local horizontalOnly = cull.horizontalOnly and true or false
  local chunkRadius = horizontalOnly and (entry.radiusHorizontal or entry.radius or 0) or (entry.radius or 0)

  local dx = entry.centerX - cameraX
  local dy = horizontalOnly and 0 or (entry.centerY - cameraY)
  local dz = entry.centerZ - cameraZ

  -- Radius culling uses sphere-extended range to avoid dropping chunks whose center is just beyond range.
  local radiusChunks = cull.drawRadiusChunks or 999
  local radiusWorld = radiusChunks * self.chunkSize
  local maxRange = radiusWorld + chunkRadius
  local radiusSq = maxRange * maxRange

  local distSq = dx * dx + dy * dy + dz * dz
  if distSq > radiusSq then
    return false
  end

  -- Optional FOV culling, expanded by the chunk's angular radius for conservative behavior.
  local fovDegrees = cull.fovDegrees
  if not fovDegrees then
    return true
  end

  local pad = (cull.alwaysVisiblePaddingChunks or 0) * self.chunkSize + chunkRadius
  if distSq <= pad * pad then
    return true
  end

  local fx = forwardX
  local fy = horizontalOnly and 0 or forwardY
  local fz = forwardZ
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  if fl < 1e-4 then
    return true
  end
  fx, fy, fz = fx / fl, fy / fl, fz / fl

  local dl = math.sqrt(distSq)
  if dl < 1e-4 then
    return true
  end
  dx, dy, dz = dx / dl, dy / dl, dz / dl

  local dot = clamp(fx * dx + fy * dy + fz * dz, -1, 1)
  local halfFov = math.rad(fovDegrees) * 0.5
  local chunkAngle = math.asin(clamp(chunkRadius / dl, 0, 1))
  local fovPadding = math.rad(cull.fovPaddingDegrees or 0)
  local maxAngle = halfFov + chunkAngle + fovPadding

  if maxAngle >= math.pi then
    return true
  end

  return dot >= math.cos(maxAngle)
end

function ChunkRenderer:draw(pass, cameraX, cameraY, cameraZ, cameraOrientation)
  local forward = self._drawForward
  if forward.set then
    forward:set(0, 0, -1)
  else
    forward.x, forward.y, forward.z = 0, 0, -1
  end
  forward:rotate(cameraOrientation)

  self._visibleCount = 0

  pass:push('state')
  pass:setCullMode('none')

  local alphaScratch = self._alphaScratch
  local prevAlphaCount = self._alphaScratchCount or 0
  local alphaCount = 0

  -- Opaque first (gathers alpha to draw after).
  for _, entry in pairs(self._chunkMeshes) do
    if entry.opaque or entry.alpha then
      if self:_isVisibleChunk(entry, cameraX, cameraY, cameraZ, forward.x, forward.y, forward.z) then
        self._visibleCount = self._visibleCount + 1
        if entry.opaque then
          pass:draw(entry.opaque, entry.originX, entry.originY, entry.originZ)
        end
        if entry.alpha then
          alphaCount = alphaCount + 1
          alphaScratch[alphaCount] = entry
          local dx = entry.centerX - cameraX
          local dy = entry.centerY - cameraY
          local dz = entry.centerZ - cameraZ
          entry._alphaDistSq = dx * dx + dy * dy + dz * dz
        end
      end
    end
  end

  for i = alphaCount + 1, prevAlphaCount do
    alphaScratch[i] = nil
  end
  self._alphaScratchCount = alphaCount

  -- Alpha after opaque, sorted back-to-front to reduce blending artifacts.
  if alphaCount > 1 then
    table.sort(alphaScratch, alphaSortBackToFront)
  end

  for i = 1, alphaCount do
    local entry = alphaScratch[i]
    if entry and entry.alpha then
      pass:draw(entry.alpha, entry.originX, entry.originY, entry.originZ)
    end
  end

  pass:pop('state')
end

return ChunkRenderer
