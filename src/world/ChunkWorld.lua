local ChunkWorld = {}
ChunkWorld.__index = ChunkWorld

local EMPTY_DIRTY_KEYS = {}
local RNG_MOD = 2147483648
local COLUMN_SEED_MOD = 2147483647
local VerticalLighting = require 'src.world.lighting.VerticalLighting'
local FloodfillLighting = require 'src.world.lighting.FloodfillLighting'

local function clampInt(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function makeRng(seed)
  -- Deterministic LCG RNG (avoids depending on global math.randomseed state).
  local state = seed or 1
  return function()
    state = (1103515245 * state + 12345) % RNG_MOD
    return state / RNG_MOD
  end
end

local function mixColumnSeed(worldSeed, cx, cz)
  local seed = math.floor(tonumber(worldSeed) or 1)
  local state = seed % COLUMN_SEED_MOD
  if state < 0 then
    state = state + COLUMN_SEED_MOD
  end

  -- Stable integer hash from world seed + chunk column.
  state = (state + cx * 73856093 + cz * 19349663) % COLUMN_SEED_MOD
  if state == 0 then
    state = 1
  end
  return state
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function smoothstep(t)
  return t * t * (3 - 2 * t)
end

local function rayIntBound(s, ds)
  -- Find smallest positive t such that s + t*ds is an integer.
  if ds == 0 then
    return math.huge
  end
  local sIsInteger = (math.floor(s) == s)
  if ds > 0 then
    return ((sIsInteger and s or (math.floor(s) + 1)) - s) / ds
  end
  return (s - (sIsInteger and s or math.floor(s))) / -ds
end

local function hashToUnit(seed, x, z)
  local n = math.sin(
    (x + seed * 0.00131) * 127.1
      + (z - seed * 0.00173) * 311.7
      + seed * 91.345
  ) * 43758.5453123
  return n - math.floor(n)
end

local function valueNoise2D(seed, x, z, frequency)
  local fx = x * frequency
  local fz = z * frequency
  local x0 = math.floor(fx)
  local z0 = math.floor(fz)
  local tx = smoothstep(fx - x0)
  local tz = smoothstep(fz - z0)

  local n00 = hashToUnit(seed, x0, z0)
  local n10 = hashToUnit(seed, x0 + 1, z0)
  local n01 = hashToUnit(seed, x0, z0 + 1)
  local n11 = hashToUnit(seed, x0 + 1, z0 + 1)

  local nx0 = lerp(n00, n10, tx)
  local nx1 = lerp(n01, n11, tx)
  return lerp(nx0, nx1, tz) * 2 - 1
end

local function fbm2D(seed, x, z, octaves, baseFrequency, persistence)
  local total = 0
  local amplitude = 1
  local frequency = baseFrequency
  local norm = 0
  local octaveCount = math.max(1, math.floor(tonumber(octaves) or 1))
  local keep = tonumber(persistence) or 0.5
  if keep < 0 then
    keep = 0
  elseif keep > 1 then
    keep = 1
  end

  for i = 1, octaveCount do
    local octaveSeed = seed + i * 1013
    total = total + valueNoise2D(octaveSeed, x, z, frequency) * amplitude
    norm = norm + amplitude
    amplitude = amplitude * keep
    frequency = frequency * 2
  end

  if norm <= 0 then
    return 0
  end
  return total / norm
end

function ChunkWorld.new(constants)
  local self = setmetatable({}, ChunkWorld)
  self.constants = constants
  self.sizeX = constants.WORLD_SIZE_X
  self.sizeY = constants.WORLD_SIZE_Y
  self.sizeZ = constants.WORLD_SIZE_Z
  self.chunkSize = constants.CHUNK_SIZE
  self.groundY = nil

  self.chunksX = constants.WORLD_CHUNKS_X
  self.chunksY = constants.WORLD_CHUNKS_Y
  self.chunksZ = constants.WORLD_CHUNKS_Z

  self._dirty = {}
  self._editChunks = {}
  self._editChunkCounts = {}
  self._featureChunks = {}
  self._featureColumnsPrepared = {}
  self._editCount = 0
  self._editRevision = 0
  self._haloEditChunks = {}
  self._haloFeatureChunks = {}

  self._genSeaLevel = 20
  self._genBaseHeight = 22
  self._genTerrainAmplitude = 11
  self._genDetailFrequency = 0.018
  self._genDetailOctaves = 4
  self._genDetailPersistence = 0.5
  self._genContinentFrequency = 0.0035
  self._genContinentAmplitude = 8
  self._genMountainBiomeFrequency = 0.0028
  self._genMountainBiomeOctaves = 2
  self._genMountainBiomeThreshold = 0.52
  self._genMountainRidgeFrequency = 0.0085
  self._genMountainRidgeOctaves = 3
  self._genMountainRidgePersistence = 0.55
  self._genMountainHeightBoost = 20
  self._genMountainHeightAmplitude = 52
  self._genMountainStoneStartY = 58
  self._genMountainStoneTransition = 8
  self._genBeachBand = 2
  self._genDirtMinDepth = 2
  self._genDirtMaxDepth = 4
  self._genSandMinDepth = 2
  self._genSandMaxDepth = 4
  self._treeTrunkMin = 3
  self._treeTrunkMax = 5
  self._treeLeafPad = 2
  self._treeWaterBuffer = 1
  self._activeMinChunkY = 1
  self._activeMaxChunkY = self.chunksY
  self._chunkVolume = self.chunkSize * self.chunkSize * self.chunkSize
  self._worldStrideZ = self.sizeX
  self._worldStrideY = self.sizeX * self.sizeZ
  self._terrainColumnData = {}

  self._lighting = constants.LIGHTING or {}
  self._lightingEnabled = self._lighting.enabled ~= false
  self._lightingMode = self._lighting.mode == 'floodfill' and 'floodfill' or 'vertical'
  self._lightOpacityByBlock = {}
  self._lightingBackend = nil
  self._lightingBackendName = nil

  self:_initLighting()
  self:_computeGenerationThresholds()

  return self
end

function ChunkWorld:isInside(x, y, z)
  return x >= 1 and x <= self.sizeX and y >= 1 and y <= self.sizeY and z >= 1 and z <= self.sizeZ
end

function ChunkWorld:_toChunkCoords(x, y, z)
  local cx = math.floor((x - 1) / self.chunkSize) + 1
  local cy = math.floor((y - 1) / self.chunkSize) + 1
  local cz = math.floor((z - 1) / self.chunkSize) + 1

  local lx = (x - 1) % self.chunkSize + 1
  local ly = (y - 1) % self.chunkSize + 1
  local lz = (z - 1) % self.chunkSize + 1

  return cx, cy, cz, lx, ly, lz
end

function ChunkWorld:_chunkKey(cx, cy, cz)
  return cx + (cz - 1) * self.chunksX + (cy - 1) * self.chunksX * self.chunksZ
end

function ChunkWorld:_decodeChunkKey(chunkKey)
  local chunksPerLayer = self.chunksX * self.chunksZ
  local zeroBased = chunkKey - 1
  local cy = math.floor(zeroBased / chunksPerLayer) + 1
  local rem = zeroBased % chunksPerLayer
  local cz = math.floor(rem / self.chunksX) + 1
  local cx = (rem % self.chunksX) + 1
  return cx, cy, cz
end

function ChunkWorld:chunkKey(cx, cy, cz)
  return self:_chunkKey(cx, cy, cz)
end

function ChunkWorld:decodeChunkKey(chunkKey)
  return self:_decodeChunkKey(chunkKey)
end

function ChunkWorld:_localIndex(lx, ly, lz)
  local cs = self.chunkSize
  return (ly - 1) * cs * cs + (lz - 1) * cs + lx
end

function ChunkWorld:_columnKey(cx, cz)
  return cx + (cz - 1) * self.chunksX
end

function ChunkWorld:_worldColumnKey(x, z)
  return x + (z - 1) * self.sizeX
end

function ChunkWorld:_decodeWorldColumnKey(columnKey)
  local zeroBased = columnKey - 1
  local z = math.floor(zeroBased / self.sizeX) + 1
  local x = (zeroBased % self.sizeX) + 1
  return x, z
end

function ChunkWorld:_worldIndex(x, y, z)
  return x + (z - 1) * self._worldStrideZ + (y - 1) * self._worldStrideY
end

function ChunkWorld:_decodeWorldIndex(index)
  local zeroBased = index - 1
  local x = (zeroBased % self.sizeX) + 1
  zeroBased = math.floor(zeroBased / self.sizeX)
  local z = (zeroBased % self.sizeZ) + 1
  local y = math.floor(zeroBased / self.sizeZ) + 1
  return x, y, z
end

function ChunkWorld:_initLighting()
  local lighting = self._lighting or {}
  local leafOpacity = math.floor(tonumber(lighting.leafOpacity) or 2)
  if leafOpacity < 0 then
    leafOpacity = 0
  elseif leafOpacity > 15 then
    leafOpacity = 15
  end

  local blockInfo = self.constants.BLOCK_INFO or {}
  local AIR = self.constants.BLOCK and self.constants.BLOCK.AIR or 0
  local LEAF = self.constants.BLOCK and self.constants.BLOCK.LEAF or -1

  for blockId, info in pairs(blockInfo) do
    local opacity = tonumber(info.lightOpacity)
    if opacity == nil then
      if blockId == AIR then
        opacity = 0
      elseif blockId == LEAF then
        opacity = leafOpacity
      elseif info.opaque then
        opacity = 15
      else
        opacity = 0
      end
    end
    opacity = math.floor(opacity + 0.5)
    if opacity < 0 then
      opacity = 0
    elseif opacity > 15 then
      opacity = 15
    end
    self._lightOpacityByBlock[blockId] = opacity
  end

  local backendOptions = {
    enabled = self._lightingEnabled,
    mode = self._lightingMode,
    lightingConfig = lighting,
    lightOpacityByBlock = self._lightOpacityByBlock
  }

  if self._lightingMode == 'floodfill' then
    self._lightingBackend = FloodfillLighting.new(self, backendOptions)
    self._lightingBackendName = 'floodfill'
  else
    self._lightingBackend = VerticalLighting.new(self, backendOptions)
    self._lightingBackendName = 'vertical'
  end

  self:_resetSkyLightData()
end

function ChunkWorld:_resetSkyLightData()
  local backend = self._lightingBackend
  if backend and backend.reset then
    backend:reset()
  end
end

function ChunkWorld:_getBlockLightOpacity(block)
  local value = self._lightOpacityByBlock[block]
  if value == nil then
    return 0
  end
  return value
end

function ChunkWorld:getSkyLight(x, y, z)
  local backend = self._lightingBackend
  if backend and backend.getSkyLight then
    return backend:getSkyLight(x, y, z)
  end
  return 15
end

function ChunkWorld:_onSkyOpacityChanged(x, y, z, cx, cy, cz, oldOpacity, newOpacity)
  local backend = self._lightingBackend
  if backend and backend.onOpacityChanged then
    backend:onOpacityChanged(x, y, z, cx, cy, cz, oldOpacity, newOpacity)
  end
end

function ChunkWorld:ensureSkyLightForChunk(cx, cy, cz)
  local backend = self._lightingBackend
  if backend and backend.ensureSkyLightForChunk then
    return backend:ensureSkyLightForChunk(cx, cy, cz)
  end
  return true
end

function ChunkWorld:fillSkyLightHalo(cx, cy, cz, out)
  local backend = self._lightingBackend
  if backend and backend.fillSkyLightHalo then
    return backend:fillSkyLightHalo(cx, cy, cz, out)
  end
  return nil
end

function ChunkWorld:updateSkyLight(maxOps, maxMillis, sourceTag)
  local backend = self._lightingBackend
  if backend and backend.updateSkyLight then
    return backend:updateSkyLight(maxOps, maxMillis, sourceTag)
  end
  return 0
end

function ChunkWorld:setFrameTiming(frameMs, worstFrameMs)
  local backend = self._lightingBackend
  if backend and backend.setFrameTiming then
    backend:setFrameTiming(frameMs, worstFrameMs)
  end
end

function ChunkWorld:getLightingPerfStats()
  local backend = self._lightingBackend
  if backend and backend.getPerfStats then
    return backend:getPerfStats()
  end
  return 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
end

function ChunkWorld:hasUrgentSkyLightWork()
  local backend = self._lightingBackend
  if backend and backend.hasUrgentSkyWork then
    return backend:hasUrgentSkyWork()
  end
  return false
end

function ChunkWorld:hasSkyLightWork()
  local backend = self._lightingBackend
  if backend and backend.hasSkyWork then
    return backend:hasSkyWork()
  end
  return false
end

function ChunkWorld:pruneSkyLightChunks(centerCx, centerCz, keepRadiusChunks)
  local backend = self._lightingBackend
  if backend and backend.pruneSkyLightChunks then
    return backend:pruneSkyLightChunks(centerCx, centerCz, keepRadiusChunks)
  end
  return 0
end

function ChunkWorld:_markDirty(cx, cy, cz)
  if cx < 1 or cx > self.chunksX or cy < 1 or cy > self.chunksY or cz < 1 or cz > self.chunksZ then
    return
  end

  local chunkKey = self:chunkKey(cx, cy, cz)
  self._dirty[chunkKey] = true
end

function ChunkWorld:_markNeighborsIfBoundary(cx, cy, cz, lx, ly, lz)
  local cs = self.chunkSize
  if lx == 1 then self:_markDirty(cx - 1, cy, cz) end
  if lx == cs then self:_markDirty(cx + 1, cy, cz) end
  if ly == 1 then self:_markDirty(cx, cy - 1, cz) end
  if ly == cs then self:_markDirty(cx, cy + 1, cz) end
  if lz == 1 then self:_markDirty(cx, cy, cz - 1) end
  if lz == cs then self:_markDirty(cx, cy, cz + 1) end
end

function ChunkWorld:_computeGenerationThresholds()
  local gen = self.constants.GEN or {}
  local seaLevel = math.floor(tonumber(gen.seaLevel) or 20)
  local baseHeight = tonumber(gen.baseHeight) or 22
  local terrainAmplitude = tonumber(gen.terrainAmplitude) or 11
  local detailFrequency = tonumber(gen.detailFrequency) or 0.018
  local detailOctaves = math.floor(tonumber(gen.detailOctaves) or 4)
  local detailPersistence = tonumber(gen.detailPersistence) or 0.5
  local continentFrequency = tonumber(gen.continentFrequency) or 0.0035
  local continentAmplitude = tonumber(gen.continentAmplitude) or 8
  local mountainBiomeFrequency = tonumber(gen.mountainBiomeFrequency) or 0.0028
  local mountainBiomeOctaves = math.floor(tonumber(gen.mountainBiomeOctaves) or 2)
  local mountainBiomeThreshold = tonumber(gen.mountainBiomeThreshold)
  if mountainBiomeThreshold == nil then
    mountainBiomeThreshold = 0.52
  end
  local mountainRidgeFrequency = tonumber(gen.mountainRidgeFrequency) or 0.0085
  local mountainRidgeOctaves = math.floor(tonumber(gen.mountainRidgeOctaves) or 3)
  local mountainRidgePersistence = tonumber(gen.mountainRidgePersistence) or 0.55
  local mountainHeightBoost = tonumber(gen.mountainHeightBoost) or 20
  local mountainHeightAmplitude = tonumber(gen.mountainHeightAmplitude) or 52
  local defaultStoneStart = math.floor(self.sizeY * 0.66 + 0.5)
  local mountainStoneStartY = math.floor(tonumber(gen.mountainStoneStartY) or defaultStoneStart)
  local mountainStoneTransition = math.floor(tonumber(gen.mountainStoneTransition) or 8)
  local beachBand = math.floor(tonumber(gen.beachBand) or 2)
  local dirtMinDepth = math.floor(tonumber(gen.dirtMinDepth) or 2)
  local dirtMaxDepth = math.floor(tonumber(gen.dirtMaxDepth) or 4)
  local sandMinDepth = math.floor(tonumber(gen.sandMinDepth) or 2)
  local sandMaxDepth = math.floor(tonumber(gen.sandMaxDepth) or 4)

  local trunkMin = math.floor(tonumber(gen.treeTrunkMin) or 3)
  if trunkMin < 1 then
    trunkMin = 1
  end
  local trunkMax = math.floor(tonumber(gen.treeTrunkMax) or 5)
  if trunkMax < trunkMin then
    trunkMax = trunkMin
  end
  local leafPad = math.floor(tonumber(gen.treeLeafPad) or 2)
  if leafPad < 0 then
    leafPad = 0
  end
  local treeWaterBuffer = math.floor(tonumber(gen.treeWaterBuffer) or 1)
  if treeWaterBuffer < 0 then
    treeWaterBuffer = 0
  end

  if seaLevel < 2 then
    seaLevel = 2
  elseif seaLevel > self.sizeY - 1 then
    seaLevel = self.sizeY - 1
  end
  if detailFrequency <= 0 then
    detailFrequency = 0.018
  end
  if detailOctaves < 1 then
    detailOctaves = 1
  elseif detailOctaves > 6 then
    detailOctaves = 6
  end
  if detailPersistence < 0 then
    detailPersistence = 0
  elseif detailPersistence > 1 then
    detailPersistence = 1
  end
  if continentFrequency <= 0 then
    continentFrequency = 0.0035
  end
  if mountainBiomeFrequency <= 0 then
    mountainBiomeFrequency = 0.0028
  end
  if mountainBiomeOctaves < 1 then
    mountainBiomeOctaves = 1
  elseif mountainBiomeOctaves > 4 then
    mountainBiomeOctaves = 4
  end
  if mountainBiomeThreshold < 0 then
    mountainBiomeThreshold = 0
  elseif mountainBiomeThreshold > 0.98 then
    mountainBiomeThreshold = 0.98
  end
  if mountainRidgeFrequency <= 0 then
    mountainRidgeFrequency = 0.0085
  end
  if mountainRidgeOctaves < 1 then
    mountainRidgeOctaves = 1
  elseif mountainRidgeOctaves > 6 then
    mountainRidgeOctaves = 6
  end
  if mountainRidgePersistence < 0 then
    mountainRidgePersistence = 0
  elseif mountainRidgePersistence > 1 then
    mountainRidgePersistence = 1
  end
  if mountainHeightBoost < 0 then
    mountainHeightBoost = 0
  end
  if mountainHeightAmplitude < 0 then
    mountainHeightAmplitude = 0
  end
  local stoneStartMin = seaLevel + 2
  if stoneStartMin > self.sizeY - 1 then
    stoneStartMin = self.sizeY - 1
  end
  mountainStoneStartY = clampInt(mountainStoneStartY, stoneStartMin, self.sizeY - 1)
  if mountainStoneTransition < 0 then
    mountainStoneTransition = 0
  elseif mountainStoneTransition > 16 then
    mountainStoneTransition = 16
  end
  if beachBand < 0 then
    beachBand = 0
  end
  if dirtMinDepth < 1 then
    dirtMinDepth = 1
  end
  if dirtMaxDepth < dirtMinDepth then
    dirtMaxDepth = dirtMinDepth
  end
  if sandMinDepth < 1 then
    sandMinDepth = 1
  end
  if sandMaxDepth < sandMinDepth then
    sandMaxDepth = sandMinDepth
  end

  self._genSeaLevel = seaLevel
  self._genBaseHeight = baseHeight
  self._genTerrainAmplitude = terrainAmplitude
  self._genDetailFrequency = detailFrequency
  self._genDetailOctaves = detailOctaves
  self._genDetailPersistence = detailPersistence
  self._genContinentFrequency = continentFrequency
  self._genContinentAmplitude = continentAmplitude
  self._genMountainBiomeFrequency = mountainBiomeFrequency
  self._genMountainBiomeOctaves = mountainBiomeOctaves
  self._genMountainBiomeThreshold = mountainBiomeThreshold
  self._genMountainRidgeFrequency = mountainRidgeFrequency
  self._genMountainRidgeOctaves = mountainRidgeOctaves
  self._genMountainRidgePersistence = mountainRidgePersistence
  self._genMountainHeightBoost = mountainHeightBoost
  self._genMountainHeightAmplitude = mountainHeightAmplitude
  self._genMountainStoneStartY = mountainStoneStartY
  self._genMountainStoneTransition = mountainStoneTransition
  self._genBeachBand = beachBand
  self._genDirtMinDepth = dirtMinDepth
  self._genDirtMaxDepth = dirtMaxDepth
  self._genSandMinDepth = sandMinDepth
  self._genSandMaxDepth = sandMaxDepth
  self._treeTrunkMin = trunkMin
  self._treeTrunkMax = trunkMax
  self._treeLeafPad = leafPad
  self._treeWaterBuffer = treeWaterBuffer

  local minSurface = math.floor(baseHeight - terrainAmplitude - continentAmplitude + 0.5)
  if minSurface < 2 then
    minSurface = 2
  elseif minSurface > self.sizeY - 1 then
    minSurface = self.sizeY - 1
  end
  local mountainMaxRaise = mountainHeightBoost + mountainHeightAmplitude
  local maxSurface = math.floor(baseHeight + terrainAmplitude + continentAmplitude + mountainMaxRaise + 0.5)
  if maxSurface < 2 then
    maxSurface = 2
  elseif maxSurface > self.sizeY - 1 then
    maxSurface = self.sizeY - 1
  end
  self.groundY = clampInt(math.floor(baseHeight + 0.5), minSurface, maxSurface)

  local maxFeatureY = maxSurface
  local treeDensity = tonumber(self.constants.TREE_DENSITY) or 0
  local treeRootY = maxSurface + 1
  if treeDensity > 0 and treeRootY <= self.sizeY then
    local treeTopY = treeRootY + trunkMax + leafPad
    local hardTop = self.sizeY - 2
    if hardTop < 1 then
      hardTop = self.sizeY
    end
    treeTopY = math.min(treeTopY, hardTop)
    if treeTopY > maxFeatureY then
      maxFeatureY = treeTopY
    end
  end
  if seaLevel > maxFeatureY then
    maxFeatureY = seaLevel
  end

  maxFeatureY = clampInt(maxFeatureY, 1, self.sizeY)
  self._activeMinChunkY = 1
  self._activeMaxChunkY = clampInt(math.floor((maxFeatureY - 1) / self.chunkSize) + 1, 1, self.chunksY)
end

function ChunkWorld:getActiveChunkYRange()
  local minCy = self._activeMinChunkY or 1
  local maxCy = self._activeMaxChunkY or self.chunksY
  minCy = clampInt(minCy, 1, self.chunksY)
  maxCy = clampInt(maxCy, 1, self.chunksY)
  if minCy > maxCy then
    minCy, maxCy = maxCy, minCy
  end
  return minCy, maxCy
end

function ChunkWorld:_normalizeChunkYRange(minCy, maxCy)
  local minY = clampInt(math.floor(tonumber(minCy) or 1), 1, self.chunksY)
  local maxY = clampInt(math.floor(tonumber(maxCy) or self.chunksY), 1, self.chunksY)
  if minY > maxY then
    minY, maxY = maxY, minY
  end
  return minY, maxY
end

function ChunkWorld:_packTerrainColumnData(surfaceY, surfaceBlock, layerDepth)
  return surfaceY + surfaceBlock * 128 + layerDepth * 32768
end

function ChunkWorld:_unpackTerrainColumnData(packed)
  local layerDepth = math.floor(packed / 32768)
  local rem = packed - layerDepth * 32768
  local surfaceBlock = math.floor(rem / 128)
  local surfaceY = rem - surfaceBlock * 128
  return surfaceY, surfaceBlock, layerDepth
end

function ChunkWorld:_computeTerrainColumnData(x, z)
  local seed = math.floor(tonumber(self.constants.WORLD_SEED) or 1)
  local detail = fbm2D(
    seed + 17,
    x,
    z,
    self._genDetailOctaves,
    self._genDetailFrequency,
    self._genDetailPersistence
  )
  local continent = fbm2D(
    seed + 7919,
    x,
    z,
    2,
    self._genContinentFrequency,
    0.5
  )
  local mountainBiome = fbm2D(
    seed + 15877,
    x,
    z,
    self._genMountainBiomeOctaves,
    self._genMountainBiomeFrequency,
    0.5
  ) * 0.5 + 0.5
  local mountainMask = 0
  local mountainThreshold = self._genMountainBiomeThreshold
  if mountainBiome > mountainThreshold then
    local mountainRange = 1 - mountainThreshold
    if mountainRange > 0 then
      mountainMask = (mountainBiome - mountainThreshold) / mountainRange
      if mountainMask < 0 then
        mountainMask = 0
      elseif mountainMask > 1 then
        mountainMask = 1
      end
      mountainMask = smoothstep(mountainMask)
    else
      mountainMask = 1
    end
  end

  local rawHeight = self._genBaseHeight
    + detail * self._genTerrainAmplitude
    + continent * self._genContinentAmplitude
  if mountainMask > 0 then
    local mountainRidge = fbm2D(
      seed + 26153,
      x,
      z,
      self._genMountainRidgeOctaves,
      self._genMountainRidgeFrequency,
      self._genMountainRidgePersistence
    )
    local ridge = 1 - math.abs(mountainRidge)
    ridge = ridge * ridge
    rawHeight = rawHeight + mountainMask * (
      self._genMountainHeightBoost + ridge * self._genMountainHeightAmplitude
    )
  end
  local surfaceY = clampInt(math.floor(rawHeight + 0.5), 2, self.sizeY - 1)

  local blocks = self.constants.BLOCK
  local beachMax = self._genSeaLevel + self._genBeachBand
  local isBeach = surfaceY <= beachMax
  local surfaceBlock = isBeach and blocks.SAND or blocks.GRASS
  if not isBeach and mountainMask > 0 then
    local stoneStartY = self._genMountainStoneStartY
    local stoneTransition = self._genMountainStoneTransition
    local stoneBandStart = stoneStartY - stoneTransition
    if surfaceY >= stoneBandStart then
      local stoneChance = 1
      if surfaceY < stoneStartY then
        local t = (surfaceY - stoneBandStart + 1) / (stoneTransition + 1)
        if t < 0 then
          t = 0
        elseif t > 1 then
          t = 1
        end
        stoneChance = t * t
      end
      stoneChance = stoneChance * (0.4 + mountainMask * 0.6)
      if stoneChance >= 1 or hashToUnit(seed + 33391, x, z) < stoneChance then
        surfaceBlock = blocks.STONE
      end
    end
  end

  local layerDepth = 0
  if surfaceBlock ~= blocks.STONE then
    local depthMin = surfaceBlock == blocks.SAND and self._genSandMinDepth or self._genDirtMinDepth
    local depthMax = surfaceBlock == blocks.SAND and self._genSandMaxDepth or self._genDirtMaxDepth
    local depthRange = depthMax - depthMin + 1
    if depthRange < 1 then
      depthRange = 1
    end
    local depthNoise = hashToUnit(seed + 37961, x, z)
    layerDepth = depthMin + math.floor(depthNoise * depthRange)
    if layerDepth > depthMax then
      layerDepth = depthMax
    end
    if layerDepth > surfaceY - 1 then
      layerDepth = surfaceY - 1
    end
  end

  return self:_packTerrainColumnData(surfaceY, surfaceBlock, layerDepth)
end

function ChunkWorld:_getTerrainColumnData(x, z)
  local key = self:_worldColumnKey(x, z)
  local packed = self._terrainColumnData[key]
  if packed == nil then
    packed = self:_computeTerrainColumnData(x, z)
    self._terrainColumnData[key] = packed
  end
  return self:_unpackTerrainColumnData(packed)
end

function ChunkWorld:_getBaseBlock(x, y, z)
  local blockIds = self.constants.BLOCK
  if not self:isInside(x, y, z) then
    return blockIds.AIR
  end

  if y <= 1 then
    return blockIds.BEDROCK
  end

  local surfaceY, surfaceBlock, layerDepth = self:_getTerrainColumnData(x, z)
  if y <= surfaceY then
    if y == surfaceY then
      return surfaceBlock
    end

    local layerFloor = surfaceY - layerDepth
    if y > layerFloor then
      if surfaceBlock == blockIds.SAND then
        return blockIds.SAND
      end
      if surfaceBlock == blockIds.GRASS then
        return blockIds.DIRT
      end
      return blockIds.STONE
    end

    return blockIds.STONE
  end

  if y <= self._genSeaLevel then
    return blockIds.WATER
  end

  return blockIds.AIR
end

function ChunkWorld:_getBaseWithFeaturesByKey(x, y, z, chunkKey, localIndex)
  local featureChunk = self._featureChunks[chunkKey]
  if featureChunk then
    local featureValue = featureChunk[localIndex]
    if featureValue ~= nil then
      return featureValue
    end
  end
  return self:_getBaseBlock(x, y, z)
end

function ChunkWorld:_getByChunkKey(chunkKey, localIndex, x, y, z)
  if not self:isInside(x, y, z) then
    return self.constants.BLOCK.AIR
  end

  local editChunk = self._editChunks[chunkKey]
  if editChunk then
    local editValue = editChunk[localIndex]
    if editValue ~= nil then
      return editValue
    end
  end

  local featureChunk = self._featureChunks[chunkKey]
  if featureChunk then
    local featureValue = featureChunk[localIndex]
    if featureValue ~= nil then
      return featureValue
    end
  end

  return self:_getBaseBlock(x, y, z)
end

function ChunkWorld:_getBaseWithFeatures(x, y, z)
  if not self:isInside(x, y, z) then
    return self.constants.BLOCK.AIR
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  local chunkKey = self:chunkKey(cx, cy, cz)
  local localIndex = self:_localIndex(lx, ly, lz)
  return self:_getBaseWithFeaturesByKey(x, y, z, chunkKey, localIndex)
end

function ChunkWorld:_setFeatureBlock(x, y, z, block)
  if block == self.constants.BLOCK.AIR then
    return
  end
  if not self:isInside(x, y, z) then
    return
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  local chunkKey = self:chunkKey(cx, cy, cz)
  local localIndex = self:_localIndex(lx, ly, lz)

  local featureChunk = self._featureChunks[chunkKey]
  if not featureChunk then
    featureChunk = {}
    self._featureChunks[chunkKey] = featureChunk
  end

  featureChunk[localIndex] = block
end

function ChunkWorld:get(x, y, z)
  if not self:isInside(x, y, z) then
    return self.constants.BLOCK.AIR
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  local chunkKey = self:chunkKey(cx, cy, cz)
  local localIndex = self:_localIndex(lx, ly, lz)
  return self:_getByChunkKey(chunkKey, localIndex, x, y, z)
end

function ChunkWorld:fillBlockHalo(cx, cy, cz, out)
  if not out then
    return nil
  end

  local AIR = self.constants.BLOCK.AIR
  local cs = self.chunkSize
  local cs2 = cs * cs
  local haloSize = cs + 2
  local strideZ = haloSize
  local strideY = haloSize * haloSize

  local sizeX = self.sizeX
  local sizeY = self.sizeY
  local sizeZ = self.sizeZ
  local chunksX = self.chunksX
  local chunksY = self.chunksY
  local chunksZ = self.chunksZ
  local chunksPerLayer = chunksX * chunksZ

  local baseOriginX = (cx - 1) * cs
  local baseOriginY = (cy - 1) * cs
  local baseOriginZ = (cz - 1) * cs

  local isInterior = cx > 1 and cx < chunksX
    and cy > 1 and cy < chunksY
    and cz > 1 and cz < chunksZ

  if isInterior then
    local editRefs = self._haloEditChunks
    local featureRefs = self._haloFeatureChunks
    local refCount = 0

    for sy = -1, 1 do
      local scy = cy + sy
      local layerBase = (scy - 1) * chunksPerLayer
      for sz = -1, 1 do
        local scz = cz + sz
        local rowBase = layerBase + (scz - 1) * chunksX
        for sx = -1, 1 do
          refCount = refCount + 1
          local chunkKey = (cx + sx) + rowBase
          editRefs[refCount] = self._editChunks[chunkKey]
          featureRefs[refCount] = self._featureChunks[chunkKey]
        end
      end
    end

    local getBaseBlock = self._getBaseBlock
    for hy = 0, cs + 1 do
      local syOffset, sly
      if hy == 0 then
        syOffset = 0
        sly = cs
      elseif hy == cs + 1 then
        syOffset = 2
        sly = 1
      else
        syOffset = 1
        sly = hy
      end

      local wy = baseOriginY + hy
      local syBase = (hy * strideY) + 1
      local srcY = syOffset * 9
      local lyBase = (sly - 1) * cs2

      for hz = 0, cs + 1 do
        local szOffset, slz
        if hz == 0 then
          szOffset = 0
          slz = cs
        elseif hz == cs + 1 then
          szOffset = 2
          slz = 1
        else
          szOffset = 1
          slz = hz
        end

        local wz = baseOriginZ + hz
        local szBase = syBase + (hz * strideZ)
        local srcYZ = srcY + szOffset * 3
        local lzBase = lyBase + (slz - 1) * cs

        for hx = 0, cs + 1 do
          local sxOffset, slx
          if hx == 0 then
            sxOffset = 0
            slx = cs
          elseif hx == cs + 1 then
            sxOffset = 2
            slx = 1
          else
            sxOffset = 1
            slx = hx
          end

          local srcIndex = srcYZ + sxOffset + 1
          local localIndex = lzBase + slx
          local index = szBase + hx

          local value = nil
          local editChunk = editRefs[srcIndex]
          if editChunk then
            value = editChunk[localIndex]
          end
          if value == nil then
            local featureChunk = featureRefs[srcIndex]
            if featureChunk then
              value = featureChunk[localIndex]
            end
            if value == nil then
              local wx = baseOriginX + hx
              value = getBaseBlock(self, wx, wy, wz)
            end
          end

          out[index] = value
        end
      end
    end

    local requiredFast = haloSize * haloSize * haloSize
    for i = requiredFast + 1, #out do
      out[i] = nil
    end
    return out
  end

  for hy = 0, cs + 1 do
    local scy, sly
    if hy == 0 then
      scy = cy - 1
      sly = cs
    elseif hy == cs + 1 then
      scy = cy + 1
      sly = 1
    else
      scy = cy
      sly = hy
    end

    local wy = baseOriginY + hy
    local syBase = (hy * strideY) + 1

    for hz = 0, cs + 1 do
      local scz, slz
      if hz == 0 then
        scz = cz - 1
        slz = cs
      elseif hz == cs + 1 then
        scz = cz + 1
        slz = 1
      else
        scz = cz
        slz = hz
      end

      local wz = baseOriginZ + hz
      local szBase = syBase + (hz * strideZ)

      for hx = 0, cs + 1 do
        local scx, slx
        if hx == 0 then
          scx = cx - 1
          slx = cs
        elseif hx == cs + 1 then
          scx = cx + 1
          slx = 1
        else
          scx = cx
          slx = hx
        end

        local wx = baseOriginX + hx
        local index = szBase + hx

        if wx < 1 or wx > sizeX
          or wy < 1 or wy > sizeY
          or wz < 1 or wz > sizeZ
          or scx < 1 or scx > chunksX
          or scy < 1 or scy > chunksY
          or scz < 1 or scz > chunksZ then
          out[index] = AIR
        else
          local chunkKey = scx + (scz - 1) * chunksX + (scy - 1) * chunksPerLayer
          local localIndex = (sly - 1) * cs2 + (slz - 1) * cs + slx
          out[index] = self:_getByChunkKey(chunkKey, localIndex, wx, wy, wz)
        end
      end
    end
  end

  local required = haloSize * haloSize * haloSize
  for i = required + 1, #out do
    out[i] = nil
  end

  return out
end

function ChunkWorld:set(x, y, z, value)
  if not self:isInside(x, y, z) then
    return false
  end

  if value == nil then
    value = self.constants.BLOCK.AIR
  end

  local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
  self:prepareChunk(cx, cy, cz)

  local chunkKey = self:chunkKey(cx, cy, cz)
  local localIndex = self:_localIndex(lx, ly, lz)

  local oldValue = self:get(x, y, z)
  if oldValue == value then
    return true
  end
  local oldOpacity = self:_getBlockLightOpacity(oldValue)
  local newOpacity = self:_getBlockLightOpacity(value)

  local baseValue = self:_getBaseWithFeaturesByKey(x, y, z, chunkKey, localIndex)
  local editChunk = self._editChunks[chunkKey]
  local previousEdit = editChunk and editChunk[localIndex] or nil

  if value == baseValue then
    if previousEdit ~= nil then
      editChunk[localIndex] = nil
      self._editCount = self._editCount - 1

      local remaining = (self._editChunkCounts[chunkKey] or 1) - 1
      if remaining <= 0 then
        self._editChunkCounts[chunkKey] = nil
        self._editChunks[chunkKey] = nil
      else
        self._editChunkCounts[chunkKey] = remaining
      end
    end
  else
    if not editChunk then
      editChunk = {}
      self._editChunks[chunkKey] = editChunk
      self._editChunkCounts[chunkKey] = 0
    end

    if previousEdit == nil then
      self._editCount = self._editCount + 1
      self._editChunkCounts[chunkKey] = (self._editChunkCounts[chunkKey] or 0) + 1
    end

    editChunk[localIndex] = value
  end

  self:_markDirty(cx, cy, cz)
  self:_markNeighborsIfBoundary(cx, cy, cz, lx, ly, lz)

  if oldOpacity ~= newOpacity then
    self:_onSkyOpacityChanged(x, y, z, cx, cy, cz, oldOpacity, newOpacity)
  end
  self._editRevision = self._editRevision + 1
  return true
end

function ChunkWorld:applyEditsBulk(edits, count)
  if not edits then
    return false, 0
  end

  local limit = math.floor(tonumber(count) or #edits)
  if limit <= 0 then
    return true, 0
  end

  local applied = 0
  local AIR = self.constants.BLOCK.AIR
  local opacityChanged = false
  local opacityMinX = nil
  local opacityMaxX = nil
  local opacityMinZ = nil
  local opacityMaxZ = nil

  for i = 1, limit do
    local entry = edits[i]
    if entry then
      local x = tonumber(entry[1])
      local y = tonumber(entry[2])
      local z = tonumber(entry[3])
      local value = tonumber(entry[4])
      if value == nil then
        value = AIR
      end

      if x and y and z and self:isInside(x, y, z) then
        local cx, cy, cz, lx, ly, lz = self:_toChunkCoords(x, y, z)
        self:prepareChunk(cx, cy, cz)

        local chunkKey = self:chunkKey(cx, cy, cz)
        local localIndex = self:_localIndex(lx, ly, lz)
        local baseValue = self:_getBaseWithFeaturesByKey(x, y, z, chunkKey, localIndex)
        local editChunk = self._editChunks[chunkKey]
        local previousEdit = editChunk and editChunk[localIndex] or nil
        local oldValue = previousEdit ~= nil and previousEdit or baseValue
        local oldOpacity = self:_getBlockLightOpacity(oldValue)
        local newOpacity = self:_getBlockLightOpacity(value)

        if oldValue ~= value then
          if value == baseValue then
            if previousEdit ~= nil then
              editChunk[localIndex] = nil
              self._editCount = self._editCount - 1

              local remaining = (self._editChunkCounts[chunkKey] or 1) - 1
              if remaining <= 0 then
                self._editChunkCounts[chunkKey] = nil
                self._editChunks[chunkKey] = nil
              else
                self._editChunkCounts[chunkKey] = remaining
              end
            end
          else
            if not editChunk then
              editChunk = {}
              self._editChunks[chunkKey] = editChunk
              self._editChunkCounts[chunkKey] = 0
            end

            if previousEdit == nil then
              self._editCount = self._editCount + 1
              self._editChunkCounts[chunkKey] = (self._editChunkCounts[chunkKey] or 0) + 1
            end

            editChunk[localIndex] = value
          end

          self:_markDirty(cx, cy, cz)
          self:_markNeighborsIfBoundary(cx, cy, cz, lx, ly, lz)
          if oldOpacity ~= newOpacity then
            opacityChanged = true
            if opacityMinX == nil or x < opacityMinX then
              opacityMinX = x
            end
            if opacityMaxX == nil or x > opacityMaxX then
              opacityMaxX = x
            end
            if opacityMinZ == nil or z < opacityMinZ then
              opacityMinZ = z
            end
            if opacityMaxZ == nil or z > opacityMaxZ then
              opacityMaxZ = z
            end
          end
          self._editRevision = self._editRevision + 1
          applied = applied + 1
        end
      end
    end
  end

  if opacityChanged then
    local backend = self._lightingBackend
    if backend and backend.onBulkOpacityChanged then
      backend:onBulkOpacityChanged(opacityMinX, opacityMaxX, opacityMinZ, opacityMaxZ)
    end
  end

  return true, applied
end

function ChunkWorld:isSolidAt(x, y, z)
  local block = self:get(x, y, z)
  local info = self.constants.BLOCK_INFO[block]
  if not info then
    return false
  end
  if info.collidable ~= nil then
    return info.collidable and true or false
  end
  return info.solid and true or false
end

function ChunkWorld:isOpaque(block)
  local info = self.constants.BLOCK_INFO[block]
  return info and info.opaque or false
end

function ChunkWorld:isBreakable(block)
  local info = self.constants.BLOCK_INFO[block]
  return info and info.breakable or false
end

function ChunkWorld:isPlaceable(block)
  local info = self.constants.BLOCK_INFO[block]
  return info and info.placeable or false
end

function ChunkWorld:getSpawnPoint()
  -- Center-ish, above whichever is higher: terrain surface or sea level.
  local x = math.floor(self.sizeX / 2) + 0.5
  local z = math.floor(self.sizeZ / 2) + 0.5
  local wx = math.floor(x) + 1
  local wz = math.floor(z) + 1
  local surfaceY = self.groundY or 7
  if wx >= 1 and wx <= self.sizeX and wz >= 1 and wz <= self.sizeZ then
    surfaceY = self:_getTerrainColumnData(wx, wz)
  end
  local y = math.max(surfaceY, self._genSeaLevel or 0) + 3
  if y > self.sizeY - 1 then
    y = self.sizeY - 1
  end
  return x, y, z
end

function ChunkWorld:getDirtyChunkKeys()
  if next(self._dirty) == nil then
    return EMPTY_DIRTY_KEYS
  end

  local keys = {}
  local count = self:drainDirtyChunkKeys(keys)
  if count == 0 then
    return EMPTY_DIRTY_KEYS
  end
  return keys
end

function ChunkWorld:drainDirtyChunkKeys(out)
  if not out then
    return 0
  end

  if next(self._dirty) == nil then
    for i = #out, 1, -1 do
      out[i] = nil
    end
    return 0
  end

  local count = 0
  for key in pairs(self._dirty) do
    count = count + 1
    out[count] = key
    self._dirty[key] = nil
  end

  for i = count + 1, #out do
    out[i] = nil
  end

  return count
end

function ChunkWorld:markDirtyRadius(centerCx, centerCz, radiusChunks)
  if self.chunksX <= 0 or self.chunksY <= 0 or self.chunksZ <= 0 then
    return
  end

  local cx = clampInt(math.floor(tonumber(centerCx) or 1), 1, self.chunksX)
  local cz = clampInt(math.floor(tonumber(centerCz) or 1), 1, self.chunksZ)
  local radius = math.floor(tonumber(radiusChunks) or 0)
  if radius < 0 then
    radius = 0
  end

  local minX = clampInt(cx - radius, 1, self.chunksX)
  local maxX = clampInt(cx + radius, 1, self.chunksX)
  local minZ = clampInt(cz - radius, 1, self.chunksZ)
  local maxZ = clampInt(cz + radius, 1, self.chunksZ)

  for markCz = minZ, maxZ do
    for markCx = minX, maxX do
      for markCy = 1, self.chunksY do
        self:_markDirty(markCx, markCy, markCz)
      end
    end
  end
end

function ChunkWorld:enqueueChunkSquare(centerCx, centerCz, radiusChunks, minCy, maxCy, outKeys)
  if not outKeys then
    return 0
  end
  if self.chunksX <= 0 or self.chunksY <= 0 or self.chunksZ <= 0 then
    return 0
  end

  local cx = clampInt(math.floor(tonumber(centerCx) or 1), 1, self.chunksX)
  local cz = clampInt(math.floor(tonumber(centerCz) or 1), 1, self.chunksZ)
  local radius = math.floor(tonumber(radiusChunks) or 0)
  if radius < 0 then
    radius = 0
  end

  local lowCy, highCy = self:_normalizeChunkYRange(minCy, maxCy)
  local minX = clampInt(cx - radius, 1, self.chunksX)
  local maxX = clampInt(cx + radius, 1, self.chunksX)
  local minZ = clampInt(cz - radius, 1, self.chunksZ)
  local maxZ = clampInt(cz + radius, 1, self.chunksZ)

  local count = 0
  for queueCz = minZ, maxZ do
    for queueCx = minX, maxX do
      for queueCy = lowCy, highCy do
        count = count + 1
        outKeys[count] = self:chunkKey(queueCx, queueCy, queueCz)
      end
    end
  end

  return count
end

function ChunkWorld:enqueueRingDelta(oldCx, oldCz, newCx, newCz, radiusChunks, minCy, maxCy, outKeys)
  if not outKeys then
    return 0
  end
  if self.chunksX <= 0 or self.chunksY <= 0 or self.chunksZ <= 0 then
    return 0
  end

  local fromCx = clampInt(math.floor(tonumber(oldCx) or 1), 1, self.chunksX)
  local fromCz = clampInt(math.floor(tonumber(oldCz) or 1), 1, self.chunksZ)
  local toCx = clampInt(math.floor(tonumber(newCx) or 1), 1, self.chunksX)
  local toCz = clampInt(math.floor(tonumber(newCz) or 1), 1, self.chunksZ)

  local dx = toCx - fromCx
  local dz = toCz - fromCz
  if dx == 0 and dz == 0 then
    return 0
  end
  if math.abs(dx) > 1 or math.abs(dz) > 1 then
    return -1
  end

  local radius = math.floor(tonumber(radiusChunks) or 0)
  if radius < 0 then
    radius = 0
  end
  local lowCy, highCy = self:_normalizeChunkYRange(minCy, maxCy)
  local minX = clampInt(toCx - radius, 1, self.chunksX)
  local maxX = clampInt(toCx + radius, 1, self.chunksX)
  local minZ = clampInt(toCz - radius, 1, self.chunksZ)
  local maxZ = clampInt(toCz + radius, 1, self.chunksZ)

  local count = 0
  local xColumn = nil

  if dx ~= 0 then
    xColumn = toCx + (dx > 0 and radius or -radius)
    if xColumn >= 1 and xColumn <= self.chunksX then
      for queueCz = minZ, maxZ do
        for queueCy = lowCy, highCy do
          count = count + 1
          outKeys[count] = self:chunkKey(xColumn, queueCy, queueCz)
        end
      end
    else
      xColumn = nil
    end
  end

  if dz ~= 0 then
    local zRow = toCz + (dz > 0 and radius or -radius)
    if zRow >= 1 and zRow <= self.chunksZ then
      for queueCx = minX, maxX do
        if not xColumn or queueCx ~= xColumn then
          for queueCy = lowCy, highCy do
            count = count + 1
            outKeys[count] = self:chunkKey(queueCx, queueCy, zRow)
          end
        end
      end
    end
  end

  return count
end

function ChunkWorld:generate()
  self:_computeGenerationThresholds()

  -- O(1) reset: no eager per-voxel terrain allocation.
  self._dirty = {}
  self._editChunks = {}
  self._editChunkCounts = {}
  self._featureChunks = {}
  self._featureColumnsPrepared = {}
  self._terrainColumnData = {}
  self._editCount = 0
  self._editRevision = 0
  self:_resetSkyLightData()
end

function ChunkWorld:_placeTreeFeature(x, y, z, trunkHeight)
  local AIR = self.constants.BLOCK.AIR
  local WOOD = self.constants.BLOCK.WOOD
  local LEAF = self.constants.BLOCK.LEAF

  local trunkTop = math.min(y + trunkHeight - 1, self.sizeY)
  for iy = y, trunkTop do
    self:_setFeatureBlock(x, iy, z, WOOD)
  end

  local leafStart = y + trunkHeight - 2
  local maxY = math.min(self.sizeY - 2, y + trunkHeight + self._treeLeafPad)
  for iy = leafStart, maxY do
    local radius = (iy == maxY) and 1 or 2
    for dz = -radius, radius do
      for dx = -radius, radius do
        local ax = x + dx
        local az = z + dz
        if self:isInside(ax, iy, az) then
          local dist = math.abs(dx) + math.abs(dz)
          if dist <= radius + 1 and self:_getBaseWithFeatures(ax, iy, az) == AIR then
            self:_setFeatureBlock(ax, iy, az, LEAF)
          end
        end
      end
    end
  end
end

function ChunkWorld:_prepareColumnFeatures(cx, cz)
  local density = tonumber(self.constants.TREE_DENSITY) or 0
  if density <= 0 then
    return
  end

  local cs = self.chunkSize
  local originX = (cx - 1) * cs
  local originZ = (cz - 1) * cs

  local margin = 3
  local minLocal = margin + 1
  local maxLocal = cs - margin
  if minLocal > maxLocal then
    return
  end

  local rng = makeRng(mixColumnSeed(self.constants.WORLD_SEED, cx, cz))
  local grass = self.constants.BLOCK.GRASS
  local waterSafeMinY = (self._genSeaLevel or 0) + (self._treeWaterBuffer or 0)

  for lz = minLocal, maxLocal do
    local wz = originZ + lz
    if wz <= self.sizeZ then
      for lx = minLocal, maxLocal do
        local wx = originX + lx
        if wx <= self.sizeX and rng() < density then
          local surfaceY, surfaceBlock = self:_getTerrainColumnData(wx, wz)
          if surfaceBlock == grass and surfaceY >= waterSafeMinY then
            local treeY = surfaceY + 1
            if treeY >= 1 and treeY <= self.sizeY then
              local trunkRange = self._treeTrunkMax - self._treeTrunkMin + 1
              local trunkHeight = self._treeTrunkMin + math.floor(rng() * trunkRange)
              if trunkHeight > self._treeTrunkMax then
                trunkHeight = self._treeTrunkMax
              end
              local maxY = math.min(self.sizeY - 2, treeY + trunkHeight + self._treeLeafPad)
              local treeCy = math.floor((treeY - 1) / cs) + 1
              local chunkTopY = treeCy * cs
              if maxY <= chunkTopY then
                self:_placeTreeFeature(wx, treeY, wz, trunkHeight)
              end
            end
          end
        end
      end
    end
  end
end

function ChunkWorld:prepareChunk(cx, cy, cz)
  if cx < 1 or cx > self.chunksX or cz < 1 or cz > self.chunksZ then
    return
  end

  local columnKey = self:_columnKey(cx, cz)
  if self._featureColumnsPrepared[columnKey] then
    return
  end

  self._featureColumnsPrepared[columnKey] = true
  self:_prepareColumnFeatures(cx, cz)

  local backend = self._lightingBackend
  if backend and backend.onPrepareChunk then
    backend:onPrepareChunk(cx, cz)
  end
end

function ChunkWorld:getEditCount()
  return self._editCount
end

function ChunkWorld:getEditRevision()
  return self._editRevision or 0
end

function ChunkWorld:collectEdits(out)
  if not out then
    return 0
  end

  local count = 0
  local cs = self.chunkSize
  local cs2 = cs * cs

  for chunkKey, chunkEdits in pairs(self._editChunks) do
    local cx, cy, cz = self:decodeChunkKey(chunkKey)
    local originX = (cx - 1) * cs
    local originY = (cy - 1) * cs
    local originZ = (cz - 1) * cs

    for localIndex, blockId in pairs(chunkEdits) do
      local zeroBased = localIndex - 1
      local ly = math.floor(zeroBased / cs2) + 1
      local rem = zeroBased % cs2
      local lz = math.floor(rem / cs) + 1
      local lx = (rem % cs) + 1

      count = count + 1
      local entry = out[count]
      local worldX = originX + lx
      local worldY = originY + ly
      local worldZ = originZ + lz

      if entry then
        entry[1] = worldX
        entry[2] = worldY
        entry[3] = worldZ
        entry[4] = blockId
      else
        out[count] = { worldX, worldY, worldZ, blockId }
      end
    end
  end

  for i = count + 1, #out do
    out[i] = nil
  end

  return count
end

function ChunkWorld:raycast(originX, originY, originZ, dirX, dirY, dirZ, maxDistance, outHit)
  maxDistance = maxDistance or 6.0

  local len = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ)
  if len < 1e-6 then
    return nil
  end
  dirX, dirY, dirZ = dirX / len, dirY / len, dirZ / len

  -- Convert to voxel coords (1-based blocks).
  local x = math.floor(originX) + 1
  local y = math.floor(originY) + 1
  local z = math.floor(originZ) + 1

  local stepX = dirX >= 0 and 1 or -1
  local stepY = dirY >= 0 and 1 or -1
  local stepZ = dirZ >= 0 and 1 or -1

  local tMaxX = rayIntBound(originX, dirX)
  local tMaxY = rayIntBound(originY, dirY)
  local tMaxZ = rayIntBound(originZ, dirZ)

  local tDeltaX = (dirX == 0) and math.huge or (1 / math.abs(dirX))
  local tDeltaY = (dirY == 0) and math.huge or (1 / math.abs(dirY))
  local tDeltaZ = (dirZ == 0) and math.huge or (1 / math.abs(dirZ))

  local traveled = 0
  local prevX, prevY, prevZ = nil, nil, nil

  while traveled <= maxDistance do
    if self:isInside(x, y, z) then
      local block = self:get(x, y, z)
      if block ~= self.constants.BLOCK.AIR then
        local hit = outHit or {}
        hit.x = x
        hit.y = y
        hit.z = z
        hit.previousX = prevX
        hit.previousY = prevY
        hit.previousZ = prevZ
        hit.block = block
        return hit
      end
    end

    prevX, prevY, prevZ = x, y, z

    if tMaxX < tMaxY then
      if tMaxX < tMaxZ then
        x = x + stepX
        traveled = tMaxX
        tMaxX = tMaxX + tDeltaX
      else
        z = z + stepZ
        traveled = tMaxZ
        tMaxZ = tMaxZ + tDeltaZ
      end
    else
      if tMaxY < tMaxZ then
        y = y + stepY
        traveled = tMaxY
        tMaxY = tMaxY + tDeltaY
      else
        z = z + stepZ
        traveled = tMaxZ
        tMaxZ = tMaxZ + tDeltaZ
      end
    end

    -- Early exit if we're far outside the world bounds in all axes.
    if x < 0 or x > self.sizeX + 2 or y < 0 or y > self.sizeY + 2 or z < 0 or z > self.sizeZ + 2 then
      if traveled > maxDistance then
        break
      end
    end
  end

  return nil
end

return ChunkWorld

