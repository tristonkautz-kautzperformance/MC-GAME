local ChunkRenderer = {}
ChunkRenderer.__index = ChunkRenderer

local MeshWorker = require 'src.render.MeshWorker'

local VERTEX_FORMAT = {
  { 'VertexPosition', 'vec3' },
  { 'VertexNormal', 'vec3' },
  { 'VertexColor', 'vec4' }
}

local function writeVertex(pool, count, x, y, z, nx, ny, nz, r, g, b, a)
  count = count + 1
  local vertex = pool[count]
  if not vertex then
    vertex = {}
    pool[count] = vertex
  end

  vertex[1] = x
  vertex[2] = y
  vertex[3] = z
  vertex[4] = nx
  vertex[5] = ny
  vertex[6] = nz
  vertex[7] = r
  vertex[8] = g
  vertex[9] = b
  vertex[10] = a
  return count
end

local function emitQuad(pool, count, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz, r, g, b, a)
  -- Two triangles (a,b,c) + (a,c,d).
  count = writeVertex(pool, count, ax, ay, az, nx, ny, nz, r, g, b, a)
  count = writeVertex(pool, count, bx, by, bz, nx, ny, nz, r, g, b, a)
  count = writeVertex(pool, count, cx, cy, cz, nx, ny, nz, r, g, b, a)

  count = writeVertex(pool, count, ax, ay, az, nx, ny, nz, r, g, b, a)
  count = writeVertex(pool, count, cx, cy, cz, nx, ny, nz, r, g, b, a)
  count = writeVertex(pool, count, dx, dy, dz, nx, ny, nz, r, g, b, a)
  return count
end

local function emitQuadIndexed(vertexPool, vertexCount, indexPool, indexCount,
  ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz, r, g, b, a)
  local base = vertexCount + 1
  vertexCount = writeVertex(vertexPool, vertexCount, ax, ay, az, nx, ny, nz, r, g, b, a)
  vertexCount = writeVertex(vertexPool, vertexCount, bx, by, bz, nx, ny, nz, r, g, b, a)
  vertexCount = writeVertex(vertexPool, vertexCount, cx, cy, cz, nx, ny, nz, r, g, b, a)
  vertexCount = writeVertex(vertexPool, vertexCount, dx, dy, dz, nx, ny, nz, r, g, b, a)

  indexCount = indexCount + 1
  indexPool[indexCount] = base
  indexCount = indexCount + 1
  indexPool[indexCount] = base + 1
  indexCount = indexCount + 1
  indexPool[indexCount] = base + 2
  indexCount = indexCount + 1
  indexPool[indexCount] = base
  indexCount = indexCount + 1
  indexPool[indexCount] = base + 2
  indexCount = indexCount + 1
  indexPool[indexCount] = base + 3
  return vertexCount, indexCount
end

local DIR_NEG_X = 1
local DIR_POS_X = 2
local DIR_NEG_Y = 3
local DIR_POS_Y = 4
local DIR_NEG_Z = 5
local DIR_POS_Z = 6
local HALO_BLOB_PACK_CHUNK = 256
local tableUnpack = (table and table.unpack) or unpack

local function isBlobData(value)
  return type(value) == 'userdata'
    and type(value.getSize) == 'function'
    and type(value.getString) == 'function'
end

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
  self._priorityVersion = 0
  self._hasPriorityChunk = false
  self._rebuildConfig = constants.REBUILD or {}
  self._usePriorityRebuild = self._rebuildConfig.prioritize ~= false
  self._priorityHorizontalOnly = self._rebuildConfig.prioritizeHorizontalOnly ~= false
  self._rebucketFullThreshold = math.floor(tonumber(self._rebuildConfig.rebucketFullThreshold) or 128)
  if self._rebucketFullThreshold < 0 then
    self._rebucketFullThreshold = 0
  end
  self._staleRequeueCap = math.floor(tonumber(self._rebuildConfig.staleRequeueCap) or 32)
  if self._staleRequeueCap < 0 then
    self._staleRequeueCap = 0
  end
  self._pruneMaxChecksPerFrame = math.floor(tonumber(self._rebuildConfig.pruneMaxChecksPerFrame) or 128)
  if self._pruneMaxChecksPerFrame < 0 then
    self._pruneMaxChecksPerFrame = 0
  end
  self._pruneMaxMillisPerFrame = tonumber(self._rebuildConfig.pruneMaxMillisPerFrame) or 0.25
  if self._pruneMaxMillisPerFrame < 0 then
    self._pruneMaxMillisPerFrame = 0
  end
  self._rebuildsLastFrame = 0
  self._dirtyDrainedLastFrame = 0
  self._dirtyQueuedLastFrame = 0
  self._rebuildMsLastFrame = 0
  self._rebuildBudgetMsLastFrame = 0
  self._pruneScannedLastFrame = 0
  self._pruneRemovedLastFrame = 0
  self._prunePending = false
  self._pruneCursorKey = nil
  self._pruneKeepRadius = 0
  self._visibleCount = 0
  self._useGreedyMeshing = not (constants.MESH and constants.MESH.greedy == false)
  self._useIndexedMeshing = constants.MESH and constants.MESH.indexed == true
  self._greedyMask = {}
  local greedyMaskSize = self.chunkSize * self.chunkSize
  for i = 1, greedyMaskSize do
    self._greedyMask[i] = 0
  end
  self._blockHalo = {}
  self._vertexPoolOpaque = {}
  self._vertexPoolAlpha = {}
  self._indexPoolOpaque = {}
  self._indexPoolAlpha = {}
  self._vertexCountOpaque = 0
  self._vertexCountAlpha = 0
  self._indexCountOpaque = 0
  self._indexCountAlpha = 0
  self._drawForward = lovr.math.newVec3(0, 0, -1)
  self._opaqueScratch = {}
  self._opaqueScratchCount = 0
  self._alphaScratch = {}
  self._alphaScratchCount = 0

  local renderConfig = constants.RENDER or {}
  self._cullOpaque = renderConfig.cullOpaque ~= false
  self._cullAlpha = renderConfig.cullAlpha == true

  local threadConfig = constants.THREAD_MESH or {}
  self._threadEnabled = threadConfig.enabled == true
  self._threadHaloBlob = threadConfig.haloBlob ~= false
  self._threadResultBlob = threadConfig.resultBlob ~= false
  self._threadMaxInFlight = math.floor(tonumber(threadConfig.maxInFlight) or 2)
  if self._threadMaxInFlight < 1 then
    self._threadMaxInFlight = 1
  end
  self._threadMaxApplyMillis = tonumber(threadConfig.maxApplyMillis) or 1.0
  if self._threadMaxApplyMillis < 0 then
    self._threadMaxApplyMillis = 0
  end
  self._meshWorker = nil
  self._meshWorkerFailed = false
  self._meshWorkerError = nil
  self._chunkBuildVersion = {}
  self._threadInFlightByKey = {}
  self._threadInFlightHaloByKey = {}
  self._threadInFlightCount = 0
  self._threadHaloTablePool = {}
  self._threadHaloTablePoolCount = 0
  self._threadHaloPackBytes = {}
  self._threadHaloPackParts = {}
  self._threadBlockInfo = self:_buildThreadBlockInfo()
  if not (lovr.data and lovr.data.newBlob) then
    self._threadHaloBlob = false
    self._threadResultBlob = false
  end
  if self._threadEnabled then
    self:_initMeshWorker()
  end

  return self
end

function ChunkRenderer:getLastFrameStats()
  return self._visibleCount or 0,
    self._rebuildsLastFrame or 0,
    self._dirtyDrainedLastFrame or 0,
    self._dirtyQueuedLastFrame or 0,
    self._rebuildMsLastFrame or 0,
    self._rebuildBudgetMsLastFrame or 0,
    self._pruneScannedLastFrame or 0,
    self._pruneRemovedLastFrame or 0,
    self._prunePending and 1 or 0
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

function ChunkRenderer:_buildThreadBlockInfo()
  local src = self.constants.BLOCK_INFO or {}
  local out = {}
  for blockId, info in pairs(src) do
    local color = info.color or {}
    out[blockId] = {
      solid = info.solid and true or false,
      opaque = info.opaque and true or false,
      alpha = info.alpha or 1,
      color = { color[1] or 1, color[2] or 0, color[3] or 1 }
    }
  end
  return out
end

function ChunkRenderer:_acquireThreadHaloTable()
  local count = self._threadHaloTablePoolCount or 0
  if count > 0 then
    local pool = self._threadHaloTablePool
    local halo = pool[count]
    pool[count] = nil
    self._threadHaloTablePoolCount = count - 1
    return halo
  end
  return {}
end

function ChunkRenderer:_releaseThreadHaloTable(halo)
  if not halo then
    return
  end

  local pool = self._threadHaloTablePool
  local count = (self._threadHaloTablePoolCount or 0) + 1
  pool[count] = halo

  local maxPool = self._threadMaxInFlight + 2
  if count > maxPool then
    for i = maxPool + 1, count do
      pool[i] = nil
    end
    count = maxPool
  end

  self._threadHaloTablePoolCount = count
end

function ChunkRenderer:_releaseInFlightHaloForKey(key)
  local inFlightHaloByKey = self._threadInFlightHaloByKey
  local halo = inFlightHaloByKey and inFlightHaloByKey[key]
  if halo then
    inFlightHaloByKey[key] = nil
    self:_releaseThreadHaloTable(halo)
  end
end

function ChunkRenderer:_releaseAllInFlightHalos()
  local inFlightHaloByKey = self._threadInFlightHaloByKey
  if not inFlightHaloByKey then
    return
  end

  for key, halo in pairs(inFlightHaloByKey) do
    inFlightHaloByKey[key] = nil
    self:_releaseThreadHaloTable(halo)
  end
end

function ChunkRenderer:_packHaloBlob(halo)
  if not self._threadHaloBlob then
    return nil
  end
  if not tableUnpack then
    return nil
  end

  local data = lovr.data
  if not data or not data.newBlob then
    return nil
  end

  local bytes = self._threadHaloPackBytes
  local parts = self._threadHaloPackParts
  local byteCount = 0
  local partCount = 0

  for i = 1, #halo do
    byteCount = byteCount + 1
    bytes[byteCount] = halo[i] or 0

    if byteCount >= HALO_BLOB_PACK_CHUNK then
      partCount = partCount + 1
      parts[partCount] = string.char(tableUnpack(bytes, 1, byteCount))
      byteCount = 0
    end
  end

  if byteCount > 0 then
    partCount = partCount + 1
    parts[partCount] = string.char(tableUnpack(bytes, 1, byteCount))
  end

  if partCount == 0 then
    return nil
  end

  local packed
  if partCount == 1 then
    packed = parts[1]
  else
    packed = table.concat(parts, '', 1, partCount)
  end

  for i = partCount + 1, #parts do
    parts[i] = nil
  end

  local ok, blob = pcall(data.newBlob, packed, 'thread_halo')
  if ok and blob then
    return blob
  end

  ok, blob = pcall(data.newBlob, packed)
  if ok and blob then
    return blob
  end

  return nil
end

function ChunkRenderer:_initMeshWorker()
  local worker, err = MeshWorker.new('src/render/mesher_thread.lua')
  if not worker then
    self._meshWorker = nil
    self._meshWorkerFailed = true
    self._meshWorkerError = tostring(err or 'failed_to_start')
    return false
  end

  self._meshWorker = worker
  self._meshWorkerFailed = false
  self._meshWorkerError = nil
  return true
end

function ChunkRenderer:_disableMeshWorker(reason)
  if reason ~= nil then
    self._meshWorkerError = tostring(reason)
  end

  if self._meshWorker then
    self._meshWorker:shutdown()
    self._meshWorker = nil
  end

  self._threadEnabled = false
  self._meshWorkerFailed = true
  self:_releaseAllInFlightHalos()
  self._threadInFlightByKey = {}
  self._threadInFlightHaloByKey = {}
  self._threadInFlightCount = 0
  self._threadHaloTablePool = {}
  self._threadHaloTablePoolCount = 0
end

function ChunkRenderer:_isMeshWorkerReady()
  if not self._threadEnabled then
    return false
  end
  if self._meshWorkerFailed then
    return false
  end
  local worker = self._meshWorker
  if not worker then
    return false
  end
  if not worker:isAlive() then
    self:_disableMeshWorker(worker:getError() or 'worker_stopped')
    return false
  end
  return true
end

function ChunkRenderer:_nextBuildVersion(key)
  local nextVersion = (self._chunkBuildVersion[key] or 0) + 1
  self._chunkBuildVersion[key] = nextVersion
  return nextVersion
end

function ChunkRenderer:_setChunkMeshEntry(key, cx, cy, cz,
  verticesOpaque, opaqueCount,
  verticesAlpha, alphaCount,
  indicesOpaque, indexCountOpaque, indexTypeOpaque,
  indicesAlpha, indexCountAlpha, indexTypeAlpha,
  indexedMode)
  local cs = self.chunkSize
  local entry = self._chunkMeshes[key] or {}

  local function createMesh(vertexData, vertexCount, indexData, indexCount, indexType)
    if vertexCount <= 0 then
      return nil, nil
    end
    if not vertexData then
      return nil, 'missing_vertex_data'
    end

    local okMesh, meshOrErr = pcall(lovr.graphics.newMesh, VERTEX_FORMAT, vertexData, 'cpu')
    if not okMesh then
      return nil, meshOrErr
    end

    local mesh = meshOrErr
    mesh:setDrawMode('triangles')

    if indexedMode and indexCount > 0 then
      if not indexData then
        return nil, 'missing_index_data'
      end

      local okIndex, indexErr
      if isBlobData(indexData) then
        okIndex, indexErr = pcall(function()
          mesh:setIndices(indexData, indexType or 'u32')
        end)
      else
        okIndex, indexErr = pcall(function()
          mesh:setIndices(indexData)
        end)
      end

      if not okIndex then
        return nil, indexErr
      end
    end

    return mesh, nil
  end

  local opaqueMesh, errOpaque = createMesh(verticesOpaque, opaqueCount, indicesOpaque, indexCountOpaque, indexTypeOpaque)
  if errOpaque then
    return false, errOpaque
  end
  if opaqueMesh then
    entry.opaque = opaqueMesh
  else
    entry.opaque = nil
  end

  local alphaMesh, errAlpha = createMesh(verticesAlpha, alphaCount, indicesAlpha, indexCountAlpha, indexTypeAlpha)
  if errAlpha then
    return false, errAlpha
  end
  if alphaMesh then
    entry.alpha = alphaMesh
  else
    entry.alpha = nil
  end

  local originX = (cx - 1) * cs
  local originY = (cy - 1) * cs
  local originZ = (cz - 1) * cs
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
  entry.cx = cx
  entry.cy = cy
  entry.cz = cz

  self._chunkMeshes[key] = entry
  return true
end

function ChunkRenderer:_queueThreadedRebuild(cx, cy, cz, key)
  if not self:_isMeshWorkerReady() then
    return false
  end
  if self._threadInFlightCount >= self._threadMaxInFlight then
    return false
  end
  if self._threadInFlightByKey[key] then
    return false
  end
  if not self.world.fillBlockHalo then
    return false
  end

  if self.world.prepareChunk then
    self.world:prepareChunk(cx, cy, cz)
  end

  local halo = self:_acquireThreadHaloTable()
  self.world:fillBlockHalo(cx, cy, cz, halo)
  local haloBlob = self:_packHaloBlob(halo)
  local version = self:_nextBuildVersion(key)
  local job = {
    type = 'build',
    key = key,
    cx = cx,
    cy = cy,
    cz = cz,
    version = version,
    chunkSize = self.chunkSize,
    haloCount = #halo,
    blockInfo = self._threadBlockInfo,
    airBlock = self.constants.BLOCK.AIR,
    useGreedy = self._useGreedyMeshing,
    indexed = self._useIndexedMeshing,
    resultBlob = self._threadResultBlob
  }
  local usesHaloTablePayload = false
  if haloBlob then
    job.haloBlob = haloBlob
  else
    job.halo = halo
    usesHaloTablePayload = true
  end

  local ok, err = self._meshWorker:push(job)
  if not ok then
    self:_releaseThreadHaloTable(halo)
    self:_disableMeshWorker(err)
    return false
  end

  if usesHaloTablePayload then
    self._threadInFlightHaloByKey[key] = halo
  else
    self:_releaseThreadHaloTable(halo)
  end

  self._threadInFlightByKey[key] = version
  self._threadInFlightCount = self._threadInFlightCount + 1
  return true
end

function ChunkRenderer:_applyThreadedResults(maxMillis)
  if not self:_isMeshWorkerReady() then
    return 0
  end

  local hasTimer = lovr.timer and lovr.timer.getTime
  local useTimeBudget = hasTimer and maxMillis and maxMillis > 0
  local startTime = 0
  if useTimeBudget then
    startTime = lovr.timer.getTime()
  end

  local applied = 0
  while true do
    if useTimeBudget and applied > 0 then
      local elapsedMs = (lovr.timer.getTime() - startTime) * 1000
      if elapsedMs >= maxMillis then
        break
      end
    end

    local result = self._meshWorker:pop()
    if not result then
      break
    end

    if result.type == 'error' then
      self:_disableMeshWorker(result.error or 'mesh_worker_error')
      break
    end

    if result.type == 'result' and result.key then
      local key = result.key
      local inFlightVersion = self._threadInFlightByKey[key]
      if inFlightVersion and inFlightVersion == result.version then
        self._threadInFlightByKey[key] = nil
        self:_releaseInFlightHaloForKey(key)
        if self._threadInFlightCount > 0 then
          self._threadInFlightCount = self._threadInFlightCount - 1
        end
      end

      local latestVersion = self._chunkBuildVersion[key]
      if latestVersion and result.version == latestVersion then
        local okApply, applyErr = self:_setChunkMeshEntry(
          key,
          result.cx,
          result.cy,
          result.cz,
          result.verticesOpaqueBlob or result.verticesOpaque,
          result.opaqueCount or 0,
          result.verticesAlphaBlob or result.verticesAlpha,
          result.alphaCount or 0,
          result.indicesOpaqueBlob or result.indicesOpaque,
          result.indexOpaqueCount or 0,
          result.indicesOpaqueType,
          result.indicesAlphaBlob or result.indicesAlpha,
          result.indexAlphaCount or 0,
          result.indicesAlphaType,
          result.indexed == true
        )
        if not okApply then
          self:_disableMeshWorker(applyErr or 'mesh_apply_failed')
          self:_rebuildChunk(result.cx, result.cy, result.cz)
          break
        end
        applied = applied + 1
      end
    end
  end

  return applied
end

function ChunkRenderer:shutdown()
  if self._meshWorker then
    self._meshWorker:shutdown()
    self._meshWorker = nil
  end
  self:_releaseAllInFlightHalos()
  self._threadInFlightByKey = {}
  self._threadInFlightHaloByKey = {}
  self._threadInFlightCount = 0
  self._threadHaloTablePool = {}
  self._threadHaloTablePoolCount = 0
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

local function opaqueSortFrontToBack(a, b)
  return a._opaqueDistSq < b._opaqueDistSq
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
  self._priorityVersion = self._priorityVersion + 1
  self._hasPriorityChunk = true

  if self._usePriorityRebuild and self._dirtyCount > 0 then
    if self._dirtyCount <= self._rebucketFullThreshold then
      self:_rebucketDirtyEntries()
    end
  end

  self._pruneKeepRadius = self:_computePruneKeepRadius()
  self._prunePending = true
  self._pruneCursorKey = nil
end

function ChunkRenderer:_computePruneKeepRadius()
  local cull = self.constants.CULL or {}
  local drawRadius = tonumber(cull.drawRadiusChunks) or 0
  local alwaysVisiblePadding = tonumber(cull.alwaysVisiblePaddingChunks) or 0
  local meshCachePadding = tonumber(cull.meshCachePaddingChunks) or 0
  local keepRadius = math.floor(drawRadius + alwaysVisiblePadding + meshCachePadding)
  if keepRadius < 0 then
    keepRadius = 0
  end
  return keepRadius
end

function ChunkRenderer:_pruneChunkMeshesStep(maxChecks, maxMillis)
  self._pruneScannedLastFrame = 0
  self._pruneRemovedLastFrame = 0
  if not self._prunePending or not self._hasPriorityChunk then
    return 0, 0
  end

  local checksLimit = tonumber(maxChecks)
  if checksLimit == nil then
    checksLimit = self._pruneMaxChecksPerFrame
  else
    checksLimit = math.floor(checksLimit)
    if checksLimit < 0 then
      checksLimit = 0
    end
  end

  local millisLimit = tonumber(maxMillis)
  if millisLimit == nil then
    millisLimit = self._pruneMaxMillisPerFrame
  end

  local hasTimer = lovr.timer and lovr.timer.getTime
  local useTimeBudget = hasTimer and millisLimit and millisLimit > 0
  local startTime = 0
  if useTimeBudget then
    startTime = lovr.timer.getTime()
  end
  if checksLimit <= 0 and not useTimeBudget then
    checksLimit = 1
  end

  local keepRadius = self._pruneKeepRadius or self:_computePruneKeepRadius()
  local scanned = 0
  local removed = 0
  local resumeKey = self._pruneCursorKey
  local lastKeptKey = nil

  local key, entry
  if resumeKey then
    key, entry = next(self._chunkMeshes, resumeKey)
  else
    key, entry = next(self._chunkMeshes)
  end

  local pcx = self._priorityChunkX
  local pcz = self._priorityChunkZ

  while key do
    if checksLimit > 0 and scanned >= checksLimit then
      break
    end
    if useTimeBudget and scanned > 0 then
      local elapsedMs = (lovr.timer.getTime() - startTime) * 1000
      if elapsedMs >= millisLimit then
        break
      end
    end

    local nextKey, nextEntry = next(self._chunkMeshes, key)
    scanned = scanned + 1

    local keep = true
    local cx = entry.cx
    local cz = entry.cz

    if cx and cz then
      local dx = math.abs(cx - pcx)
      local dz = math.abs(cz - pcz)
      local dist = dx
      if dz > dist then
        dist = dz
      end

      if dist > keepRadius then
        self._chunkMeshes[key] = nil
        removed = removed + 1
        keep = false
      end
    end

    if keep then
      lastKeptKey = key
    end
    key, entry = nextKey, nextEntry
  end

  if key then
    if lastKeptKey then
      self._pruneCursorKey = lastKeptKey
    elseif resumeKey and self._chunkMeshes[resumeKey] then
      self._pruneCursorKey = resumeKey
    else
      self._pruneCursorKey = nil
    end
    self._prunePending = true
  else
    self._prunePending = false
    self._pruneCursorKey = nil
  end

  self._pruneScannedLastFrame = scanned
  self._pruneRemovedLastFrame = removed
  return scanned, removed
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
  entry.priorityVersion = self._priorityVersion

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

function ChunkRenderer:_requeueDirtyEntry(entry)
  if not entry or not entry.key then
    return false
  end

  if self._dirtyEntries[entry.key] then
    return false
  end

  self._dirtyEntries[entry.key] = entry
  self._dirtyCount = self._dirtyCount + 1
  self:_pushDirtyEntry(entry)
  return true
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

function ChunkRenderer:_queueDirtyKeys(dirtyKeys, count, forceRebuild)
  count = count or #dirtyKeys
  local queued = 0
  for i = 1, count do
    local key = dirtyKeys[i]
    if type(key) == 'number' and not self._dirtyEntries[key] then
      if forceRebuild or not self._chunkMeshes[key] then
        local cx, cy, cz = self.world:decodeChunkKey(key)
        local entry = { key = key, cx = cx, cy = cy, cz = cz, dist = 0 }
        self._dirtyEntries[key] = entry
        self._dirtyCount = self._dirtyCount + 1
        self:_pushDirtyEntry(entry)
        queued = queued + 1
      end
    end
  end
  return queued
end

function ChunkRenderer:enqueueMissingKeys(chunkKeys, count)
  return self:_queueDirtyKeys(chunkKeys, count, false)
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
  local useIndexed = self._useIndexedMeshing

  local originX = (cx - 1) * cs
  local originY = (cy - 1) * cs
  local originZ = (cz - 1) * cs

  local verticesOpaque = self._vertexPoolOpaque
  local verticesAlpha = self._vertexPoolAlpha
  local indicesOpaque = self._indexPoolOpaque
  local indicesAlpha = self._indexPoolAlpha
  local opaqueCount = 0
  local alphaCount = 0
  local indexOpaqueCount = 0
  local indexAlphaCount = 0

  local halo = self._blockHalo
  world:fillBlockHalo(cx, cy, cz, halo)
  local haloSize = cs + 2
  local strideZ = haloSize
  local strideY = haloSize * haloSize

  for ly = 1, cs do
    local y0 = ly - 1
    local y1 = ly
    local hyOffset = ly * strideY + 1

    for lz = 1, cs do
      local z0 = lz - 1
      local z1 = lz
      local hzOffset = hyOffset + lz * strideZ

      for lx = 1, cs do
        local x0 = lx - 1
        local x1 = lx
        local index = hzOffset + lx

        local block = halo[index]
        if not isAir(constants, block) then
          local info = blockInfo[block]
          local r = info and info.color[1] or 1
          local g = info and info.color[2] or 0
          local b = info and info.color[3] or 1
          local a = info and (info.alpha or 1) or 1
          local isOpaqueBlock = info and info.opaque or false
          local out = isOpaqueBlock and verticesOpaque or verticesAlpha
          local outIndices = isOpaqueBlock and indicesOpaque or indicesAlpha
          local count = isOpaqueBlock and opaqueCount or alphaCount
          local indexCount = isOpaqueBlock and indexOpaqueCount or indexAlphaCount

          local ok = self:_shouldDrawFace(block, halo[index - 1])
          if ok then
            if useIndexed then
              count, indexCount = emitQuadIndexed(
                out, count, outIndices, indexCount,
                x0, y0, z0, x0, y0, z1, x0, y1, z1, x0, y1, z0,
                -1, 0, 0, r, g, b, a
              )
            else
              count = emitQuad(out, count, x0, y0, z0, x0, y0, z1, x0, y1, z1, x0, y1, z0, -1, 0, 0, r, g, b, a)
            end
          end

          ok = self:_shouldDrawFace(block, halo[index + 1])
          if ok then
            if useIndexed then
              count, indexCount = emitQuadIndexed(
                out, count, outIndices, indexCount,
                x1, y0, z1, x1, y0, z0, x1, y1, z0, x1, y1, z1,
                1, 0, 0, r, g, b, a
              )
            else
              count = emitQuad(out, count, x1, y0, z1, x1, y0, z0, x1, y1, z0, x1, y1, z1, 1, 0, 0, r, g, b, a)
            end
          end

          ok = self:_shouldDrawFace(block, halo[index - strideY])
          if ok then
            if useIndexed then
              count, indexCount = emitQuadIndexed(
                out, count, outIndices, indexCount,
                x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1,
                0, -1, 0, r, g, b, a
              )
            else
              count = emitQuad(out, count, x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1, 0, -1, 0, r, g, b, a)
            end
          end

          ok = self:_shouldDrawFace(block, halo[index + strideY])
          if ok then
            if useIndexed then
              count, indexCount = emitQuadIndexed(
                out, count, outIndices, indexCount,
                x0, y1, z1, x1, y1, z1, x1, y1, z0, x0, y1, z0,
                0, 1, 0, r, g, b, a
              )
            else
              count = emitQuad(out, count, x0, y1, z1, x1, y1, z1, x1, y1, z0, x0, y1, z0, 0, 1, 0, r, g, b, a)
            end
          end

          ok = self:_shouldDrawFace(block, halo[index - strideZ])
          if ok then
            if useIndexed then
              count, indexCount = emitQuadIndexed(
                out, count, outIndices, indexCount,
                x0, y0, z0, x0, y1, z0, x1, y1, z0, x1, y0, z0,
                0, 0, -1, r, g, b, a
              )
            else
              count = emitQuad(out, count, x0, y0, z0, x0, y1, z0, x1, y1, z0, x1, y0, z0, 0, 0, -1, r, g, b, a)
            end
          end

          ok = self:_shouldDrawFace(block, halo[index + strideZ])
          if ok then
            if useIndexed then
              count, indexCount = emitQuadIndexed(
                out, count, outIndices, indexCount,
                x1, y0, z1, x1, y1, z1, x0, y1, z1, x0, y0, z1,
                0, 0, 1, r, g, b, a
              )
            else
              count = emitQuad(out, count, x1, y0, z1, x1, y1, z1, x0, y1, z1, x0, y0, z1, 0, 0, 1, r, g, b, a)
            end
          end

          if isOpaqueBlock then
            opaqueCount = count
            indexOpaqueCount = indexCount
          else
            alphaCount = count
            indexAlphaCount = indexCount
          end
        end
      end
    end
  end

  return originX, originY, originZ,
    verticesOpaque, verticesAlpha, opaqueCount, alphaCount,
    indicesOpaque, indicesAlpha, indexOpaqueCount, indexAlphaCount
end

function ChunkRenderer:_buildChunkGreedy(cx, cy, cz)
  local constants = self.constants
  local cs = self.chunkSize
  local world = self.world
  local blockInfo = constants.BLOCK_INFO
  local useIndexed = self._useIndexedMeshing

  local originX = (cx - 1) * cs
  local originY = (cy - 1) * cs
  local originZ = (cz - 1) * cs

  local verticesOpaque = self._vertexPoolOpaque
  local verticesAlpha = self._vertexPoolAlpha
  local indicesOpaque = self._indexPoolOpaque
  local indicesAlpha = self._indexPoolAlpha
  local opaqueCount = 0
  local alphaCount = 0
  local indexOpaqueCount = 0
  local indexAlphaCount = 0

  local halo = self._blockHalo
  world:fillBlockHalo(cx, cy, cz, halo)
  local haloSize = cs + 2
  local strideZ = haloSize
  local strideY = haloSize * haloSize

  local function emitRect(direction, slice, u, v, width, height, block)
    local info = blockInfo[block]
    if not info then
      return
    end

    local isOpaqueBlock = info.opaque and true or false
    local out = isOpaqueBlock and verticesOpaque or verticesAlpha
    local outIndices = isOpaqueBlock and indicesOpaque or indicesAlpha
    local count = isOpaqueBlock and opaqueCount or alphaCount
    local indexCount = isOpaqueBlock and indexOpaqueCount or indexAlphaCount
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
      if useIndexed then
        count, indexCount = emitQuadIndexed(out, count, outIndices, indexCount, x, y0, z0, x, y0, z1, x, y1, z1, x, y1, z0, -1, 0, 0, r, g, b, a)
      else
        count = emitQuad(out, count, x, y0, z0, x, y0, z1, x, y1, z1, x, y1, z0, -1, 0, 0, r, g, b, a)
      end
    elseif direction == DIR_POS_X then
      local x = slice
      local y0 = v - 1
      local y1 = y0 + height
      local z0 = u - 1
      local z1 = z0 + width
      if useIndexed then
        count, indexCount = emitQuadIndexed(out, count, outIndices, indexCount, x, y0, z1, x, y0, z0, x, y1, z0, x, y1, z1, 1, 0, 0, r, g, b, a)
      else
        count = emitQuad(out, count, x, y0, z1, x, y0, z0, x, y1, z0, x, y1, z1, 1, 0, 0, r, g, b, a)
      end
    elseif direction == DIR_NEG_Y then
      local y = slice - 1
      local x0 = u - 1
      local x1 = x0 + width
      local z0 = v - 1
      local z1 = z0 + height
      if useIndexed then
        count, indexCount = emitQuadIndexed(out, count, outIndices, indexCount, x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1, 0, -1, 0, r, g, b, a)
      else
        count = emitQuad(out, count, x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1, 0, -1, 0, r, g, b, a)
      end
    elseif direction == DIR_POS_Y then
      local y = slice
      local x0 = u - 1
      local x1 = x0 + width
      local z0 = v - 1
      local z1 = z0 + height
      if useIndexed then
        count, indexCount = emitQuadIndexed(out, count, outIndices, indexCount, x0, y, z1, x1, y, z1, x1, y, z0, x0, y, z0, 0, 1, 0, r, g, b, a)
      else
        count = emitQuad(out, count, x0, y, z1, x1, y, z1, x1, y, z0, x0, y, z0, 0, 1, 0, r, g, b, a)
      end
    elseif direction == DIR_NEG_Z then
      local z = slice - 1
      local x0 = u - 1
      local x1 = x0 + width
      local y0 = v - 1
      local y1 = y0 + height
      if useIndexed then
        count, indexCount = emitQuadIndexed(out, count, outIndices, indexCount, x0, y0, z, x0, y1, z, x1, y1, z, x1, y0, z, 0, 0, -1, r, g, b, a)
      else
        count = emitQuad(out, count, x0, y0, z, x0, y1, z, x1, y1, z, x1, y0, z, 0, 0, -1, r, g, b, a)
      end
    else
      local z = slice
      local x0 = u - 1
      local x1 = x0 + width
      local y0 = v - 1
      local y1 = y0 + height
      if useIndexed then
        count, indexCount = emitQuadIndexed(out, count, outIndices, indexCount, x1, y0, z, x1, y1, z, x0, y1, z, x0, y0, z, 0, 0, 1, r, g, b, a)
      else
        count = emitQuad(out, count, x1, y0, z, x1, y1, z, x0, y1, z, x0, y0, z, 0, 0, 1, r, g, b, a)
      end
    end

    if isOpaqueBlock then
      opaqueCount = count
      indexOpaqueCount = indexCount
    else
      alphaCount = count
      indexAlphaCount = indexCount
    end
  end

  local mask = self._greedyMask
  local maskSize = cs * cs
  if #mask < maskSize then
    for i = #mask + 1, maskSize do
      mask[i] = 0
    end
  elseif #mask > maskSize then
    for i = maskSize + 1, #mask do
      mask[i] = nil
    end
  end

  for direction = DIR_NEG_X, DIR_POS_Z do
    local nx, ny, nz = 0, 0, 0
    if direction == DIR_NEG_X then nx = -1 end
    if direction == DIR_POS_X then nx = 1 end
    if direction == DIR_NEG_Y then ny = -1 end
    if direction == DIR_POS_Y then ny = 1 end
    if direction == DIR_NEG_Z then nz = -1 end
    if direction == DIR_POS_Z then nz = 1 end
    local neighborOffset = nx + nz * strideZ + ny * strideY

    for slice = 1, cs do
      for i = 1, maskSize do
        mask[i] = 0
      end

      for v = 1, cs do
        for u = 1, cs do
          local hx, hy, hz
          if direction == DIR_NEG_X or direction == DIR_POS_X then
            hx, hy, hz = slice, v, u
          elseif direction == DIR_NEG_Y or direction == DIR_POS_Y then
            hx, hy, hz = u, slice, v
          else
            hx, hy, hz = u, v, slice
          end

          local index = hy * strideY + hz * strideZ + hx + 1
          local block = halo[index]
          local neighbor = halo[index + neighborOffset]
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

  return originX, originY, originZ,
    verticesOpaque, verticesAlpha, opaqueCount, alphaCount,
    indicesOpaque, indicesAlpha, indexOpaqueCount, indexAlphaCount
end

function ChunkRenderer:_rebuildChunk(cx, cy, cz)
  local key = self.world:chunkKey(cx, cy, cz)
  -- Any synchronous rebuild supersedes older in-flight thread results.
  self:_nextBuildVersion(key)

  if self.world.prepareChunk then
    self.world:prepareChunk(cx, cy, cz)
  end

  local oldOpaqueCount = #self._vertexPoolOpaque
  local oldAlphaCount = #self._vertexPoolAlpha
  local oldOpaqueIndexCount = #self._indexPoolOpaque
  local oldAlphaIndexCount = #self._indexPoolAlpha
  local ignoredOriginX, ignoredOriginY, ignoredOriginZ
  local verticesOpaque, verticesAlpha, opaqueCount, alphaCount
  local indicesOpaque, indicesAlpha, indexOpaqueCount, indexAlphaCount

  if self._useGreedyMeshing then
    ignoredOriginX, ignoredOriginY, ignoredOriginZ, verticesOpaque, verticesAlpha, opaqueCount, alphaCount, indicesOpaque, indicesAlpha, indexOpaqueCount, indexAlphaCount = self:_buildChunkGreedy(cx, cy, cz)
  else
    ignoredOriginX, ignoredOriginY, ignoredOriginZ, verticesOpaque, verticesAlpha, opaqueCount, alphaCount, indicesOpaque, indicesAlpha, indexOpaqueCount, indexAlphaCount = self:_buildChunkNaive(cx, cy, cz)
  end

  if opaqueCount < oldOpaqueCount then
    for i = opaqueCount + 1, oldOpaqueCount do
      verticesOpaque[i] = nil
    end
  end

  if alphaCount < oldAlphaCount then
    for i = alphaCount + 1, oldAlphaCount do
      verticesAlpha[i] = nil
    end
  end

  self._vertexCountOpaque = opaqueCount
  self._vertexCountAlpha = alphaCount

  if self._useIndexedMeshing then
    if indexOpaqueCount < oldOpaqueIndexCount then
      for i = indexOpaqueCount + 1, oldOpaqueIndexCount do
        indicesOpaque[i] = nil
      end
    end
    if indexAlphaCount < oldAlphaIndexCount then
      for i = indexAlphaCount + 1, oldAlphaIndexCount do
        indicesAlpha[i] = nil
      end
    end
    self._indexCountOpaque = indexOpaqueCount
    self._indexCountAlpha = indexAlphaCount
  else
    self._indexCountOpaque = 0
    self._indexCountAlpha = 0
    if oldOpaqueIndexCount > 0 then
      for i = 1, oldOpaqueIndexCount do
        self._indexPoolOpaque[i] = nil
      end
    end
    if oldAlphaIndexCount > 0 then
      for i = 1, oldAlphaIndexCount do
        self._indexPoolAlpha[i] = nil
      end
    end
    indicesOpaque = nil
    indicesAlpha = nil
    indexOpaqueCount = 0
    indexAlphaCount = 0
  end

  local okApply, applyErr = self:_setChunkMeshEntry(
    key,
    cx,
    cy,
    cz,
    verticesOpaque,
    opaqueCount,
    verticesAlpha,
    alphaCount,
    indicesOpaque or {},
    indexOpaqueCount or 0,
    nil,
    indicesAlpha or {},
    indexAlphaCount or 0,
    nil,
    self._useIndexedMeshing
  )
  if not okApply then
    error(tostring(applyErr or 'mesh_apply_failed'))
  end
end

function ChunkRenderer:rebuildDirty(maxPerFrame, maxMillisPerFrame)
  local hasTimer = lovr.timer and lovr.timer.getTime
  local rebuildStartTime = 0
  if hasTimer then
    rebuildStartTime = lovr.timer.getTime()
  end

  local hardCap = tonumber(maxPerFrame)
  if hardCap ~= nil then
    hardCap = math.floor(hardCap)
    if hardCap < 0 then
      hardCap = 0
    end
  else
    hardCap = tonumber(self._rebuildConfig.maxPerFrame)
    if hardCap and hardCap > 0 then
      hardCap = math.floor(hardCap)
    else
      hardCap = math.huge
    end
  end

  local maxMillis = tonumber(maxMillisPerFrame)
  if maxMillis == nil then
    maxMillis = tonumber(self._rebuildConfig.maxMillisPerFrame)
  end
  local useTimeBudget = maxMillis and maxMillis > 0 and hasTimer
  self._rebuildBudgetMsLastFrame = (maxMillis and maxMillis > 0) and maxMillis or 0
  local startTime = 0
  if useTimeBudget then
    startTime = lovr.timer.getTime()
  end

  self._rebuildsLastFrame = 0
  self:_applyThreadedResults(self._threadMaxApplyMillis)
  self:_pruneChunkMeshesStep(self._pruneMaxChecksPerFrame, self._pruneMaxMillisPerFrame)

  local dirtyCount = 0
  local dirtyKeys = self._dirtyScratch
  if self.world.drainDirtyChunkKeys then
    dirtyCount = self.world:drainDirtyChunkKeys(dirtyKeys)
  else
    dirtyKeys = self.world:getDirtyChunkKeys()
    dirtyCount = #dirtyKeys
  end

  local queued = 0
  if dirtyCount > 0 then
    queued = self:_queueDirtyKeys(dirtyKeys, dirtyCount, true)
  end
  self._dirtyDrainedLastFrame = dirtyCount
  self._dirtyQueuedLastFrame = queued

  if self._dirtyCount <= 0 then
    self:_applyThreadedResults(self._threadMaxApplyMillis)
    if hasTimer then
      self._rebuildMsLastFrame = (lovr.timer.getTime() - rebuildStartTime) * 1000
    else
      self._rebuildMsLastFrame = 0
    end
    return 0
  end

  local rebuilt = 0
  local staleRequeued = 0
  local staleRequeueCap = self._staleRequeueCap or 0
  local function processRebuildEntry(chunkEntry)
    local queuedThreaded = self:_queueThreadedRebuild(chunkEntry.cx, chunkEntry.cy, chunkEntry.cz, chunkEntry.key)
    if not queuedThreaded then
      self:_rebuildChunk(chunkEntry.cx, chunkEntry.cy, chunkEntry.cz)
    end
    rebuilt = rebuilt + 1
  end

  while rebuilt < hardCap do
    if useTimeBudget and rebuilt > 0 then
      local elapsedMs = (lovr.timer.getTime() - startTime) * 1000
      if elapsedMs >= maxMillis then
        break
      end
    end

    local entry = self:_popDirtyEntry()
    if not entry then
      break
    end

    local stalePriority = self._usePriorityRebuild
      and self._hasPriorityChunk
      and entry.priorityVersion ~= self._priorityVersion

    if stalePriority and staleRequeued < staleRequeueCap then
      if self:_requeueDirtyEntry(entry) then
        staleRequeued = staleRequeued + 1
      else
        processRebuildEntry(entry)
      end
    else
      processRebuildEntry(entry)
    end
  end

  self:_applyThreadedResults(self._threadMaxApplyMillis)
  self._rebuildsLastFrame = rebuilt
  if hasTimer then
    self._rebuildMsLastFrame = (lovr.timer.getTime() - rebuildStartTime) * 1000
  else
    self._rebuildMsLastFrame = 0
  end
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

  local opaqueScratch = self._opaqueScratch
  local prevOpaqueCount = self._opaqueScratchCount or 0
  local opaqueCount = 0
  local alphaScratch = self._alphaScratch
  local prevAlphaCount = self._alphaScratchCount or 0
  local alphaCount = 0

  -- Gather visible opaque + alpha entries in one pass.
  for _, entry in pairs(self._chunkMeshes) do
    if entry.opaque or entry.alpha then
      if self:_isVisibleChunk(entry, cameraX, cameraY, cameraZ, forward.x, forward.y, forward.z) then
        self._visibleCount = self._visibleCount + 1

        local dx = entry.centerX - cameraX
        local dy = entry.centerY - cameraY
        local dz = entry.centerZ - cameraZ
        local distSq = dx * dx + dy * dy + dz * dz

        if entry.opaque then
          opaqueCount = opaqueCount + 1
          opaqueScratch[opaqueCount] = entry
          entry._opaqueDistSq = distSq
        end
        if entry.alpha then
          alphaCount = alphaCount + 1
          alphaScratch[alphaCount] = entry
          entry._alphaDistSq = distSq
        end
      end
    end
  end

  for i = opaqueCount + 1, prevOpaqueCount do
    opaqueScratch[i] = nil
  end
  self._opaqueScratchCount = opaqueCount

  for i = alphaCount + 1, prevAlphaCount do
    alphaScratch[i] = nil
  end
  self._alphaScratchCount = alphaCount

  if opaqueCount > 1 then
    table.sort(opaqueScratch, opaqueSortFrontToBack)
  end

  pass:setCullMode(self._cullOpaque and 'back' or 'none')
  for i = 1, opaqueCount do
    local entry = opaqueScratch[i]
    if entry and entry.opaque then
      pass:draw(entry.opaque, entry.originX, entry.originY, entry.originZ)
    end
  end

  if alphaCount > 1 then
    table.sort(alphaScratch, alphaSortBackToFront)
  end

  pass:setCullMode(self._cullAlpha and 'back' or 'none')
  for i = 1, alphaCount do
    local entry = alphaScratch[i]
    if entry and entry.alpha then
      pass:draw(entry.alpha, entry.originX, entry.originY, entry.originZ)
    end
  end

  pass:pop('state')
end

return ChunkRenderer
