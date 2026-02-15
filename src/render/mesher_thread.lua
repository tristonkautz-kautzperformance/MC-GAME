local DIR_NEG_X = 1
local DIR_POS_X = 2
local DIR_NEG_Y = 3
local DIR_POS_Y = 4
local DIR_NEG_Z = 5
local DIR_POS_Z = 6
local VERTEX_FLOAT_STRIDE = 11

local lovrGlobal = rawget(_G, 'lovr')
local lovrThread = lovrGlobal and lovrGlobal.thread or nil
local lovrData = lovrGlobal and lovrGlobal.data or nil
local lovrTimer = lovrGlobal and lovrGlobal.timer or nil

if not lovrThread then
  local okThread, threadModule = pcall(require, 'lovr.thread')
  if okThread then
    lovrThread = threadModule
  end
end

if not lovrData then
  local okData, dataModule = pcall(require, 'lovr.data')
  if okData then
    lovrData = dataModule
  end
end

if not lovrTimer then
  local okTimer, timerModule = pcall(require, 'lovr.timer')
  if okTimer then
    lovrTimer = timerModule
  end
end

local hasFfi, ffi = pcall(require, 'ffi')
if not hasFfi then
  ffi = nil
end

local vertexPackBuffer = nil
local vertexPackCapacity = 0
local indexPackU16Buffer = nil
local indexPackU16Capacity = 0
local indexPackU32Buffer = nil
local indexPackU32Capacity = 0
local greedyMaskScratch = {}

local function ensureVertexPackBuffer(floatCount)
  if not ffi then
    return nil
  end
  if vertexPackCapacity < floatCount then
    vertexPackBuffer = ffi.new('float[?]', floatCount)
    vertexPackCapacity = floatCount
  end
  return vertexPackBuffer
end

local function ensureIndexPackBufferU16(indexCount)
  if not ffi then
    return nil
  end
  if indexPackU16Capacity < indexCount then
    indexPackU16Buffer = ffi.new('uint16_t[?]', indexCount)
    indexPackU16Capacity = indexCount
  end
  return indexPackU16Buffer
end

local function ensureIndexPackBufferU32(indexCount)
  if not ffi then
    return nil
  end
  if indexPackU32Capacity < indexCount then
    indexPackU32Buffer = ffi.new('uint32_t[?]', indexCount)
    indexPackU32Capacity = indexCount
  end
  return indexPackU32Buffer
end

local function writeVertex(pool, count, x, y, z, nx, ny, nz, r, g, b, a, light)
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
  vertex[11] = light or 15
  return count
end

local function emitQuad(pool, count, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz, r, g, b, a, light)
  count = writeVertex(pool, count, ax, ay, az, nx, ny, nz, r, g, b, a, light)
  count = writeVertex(pool, count, bx, by, bz, nx, ny, nz, r, g, b, a, light)
  count = writeVertex(pool, count, cx, cy, cz, nx, ny, nz, r, g, b, a, light)
  count = writeVertex(pool, count, ax, ay, az, nx, ny, nz, r, g, b, a, light)
  count = writeVertex(pool, count, cx, cy, cz, nx, ny, nz, r, g, b, a, light)
  count = writeVertex(pool, count, dx, dy, dz, nx, ny, nz, r, g, b, a, light)
  return count
end

local function emitQuadIndexed(vertexPool, vertexCount, indexPool, indexCount,
  ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz, r, g, b, a, light)
  local base = vertexCount + 1
  vertexCount = writeVertex(vertexPool, vertexCount, ax, ay, az, nx, ny, nz, r, g, b, a, light)
  vertexCount = writeVertex(vertexPool, vertexCount, bx, by, bz, nx, ny, nz, r, g, b, a, light)
  vertexCount = writeVertex(vertexPool, vertexCount, cx, cy, cz, nx, ny, nz, r, g, b, a, light)
  vertexCount = writeVertex(vertexPool, vertexCount, dx, dy, dz, nx, ny, nz, r, g, b, a, light)

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

local function shouldDrawFace(block, neighbor, blockInfo, airBlock)
  if block == airBlock then
    return false
  end

  local info = blockInfo[block]
  if not info then
    return false
  end
  local render = info.render
  if render == nil then
    render = info.solid and true or false
  end
  if not render then
    return false
  end

  if info.opaque then
    local nInfo = blockInfo[neighbor]
    local neighborOpaque = nInfo and nInfo.opaque or false
    return not neighborOpaque
  end

  if neighbor == block then
    return false
  end
  return neighbor == airBlock
end

local function newBlobFromString(raw, name)
  if not raw or raw == '' then
    return nil
  end
  if not (lovrData and lovrData.newBlob) then
    return nil
  end

  local ok, blob = pcall(lovrData.newBlob, raw, name)
  if ok and blob then
    return blob
  end

  ok, blob = pcall(lovrData.newBlob, raw)
  if ok and blob then
    return blob
  end

  return nil
end

local function packVertexBlob(vertices, vertexCount)
  if vertexCount <= 0 then
    return nil
  end
  if not ffi then
    return nil
  end

  local floatCount = vertexCount * VERTEX_FLOAT_STRIDE
  local buffer = ensureVertexPackBuffer(floatCount)
  if not buffer then
    return nil
  end
  local writeIndex = 0
  for i = 1, vertexCount do
    local v = vertices[i]
    if not v then
      return nil
    end
    buffer[writeIndex] = v[1] or 0
    buffer[writeIndex + 1] = v[2] or 0
    buffer[writeIndex + 2] = v[3] or 0
    buffer[writeIndex + 3] = v[4] or 0
    buffer[writeIndex + 4] = v[5] or 0
    buffer[writeIndex + 5] = v[6] or 0
    buffer[writeIndex + 6] = v[7] or 0
    buffer[writeIndex + 7] = v[8] or 0
    buffer[writeIndex + 8] = v[9] or 0
    buffer[writeIndex + 9] = v[10] or 0
    buffer[writeIndex + 10] = v[11] or 15
    writeIndex = writeIndex + VERTEX_FLOAT_STRIDE
  end

  local raw = ffi.string(buffer, floatCount * ffi.sizeof('float'))
  return newBlobFromString(raw, 'mesh_vertices')
end

local function packIndexBlob(indices, indexCount, vertexCount)
  if indexCount <= 0 then
    return nil, nil
  end
  if not ffi then
    return nil, nil
  end

  local useU16 = vertexCount <= 65535
  local indexType = useU16 and 'u16' or 'u32'
  local raw = nil

  if useU16 then
    local buffer = ensureIndexPackBufferU16(indexCount)
    if not buffer then
      return nil, nil
    end
    for i = 1, indexCount do
      local value = (indices[i] or 1) - 1
      if value < 0 or value > 65535 then
        return nil, nil
      end
      buffer[i - 1] = value
    end
    raw = ffi.string(buffer, indexCount * ffi.sizeof('uint16_t'))
  else
    local buffer = ensureIndexPackBufferU32(indexCount)
    if not buffer then
      return nil, nil
    end
    for i = 1, indexCount do
      local value = (indices[i] or 1) - 1
      if value < 0 then
        value = 0
      end
      buffer[i - 1] = value
    end
    raw = ffi.string(buffer, indexCount * ffi.sizeof('uint32_t'))
  end

  local blob = newBlobFromString(raw, 'mesh_indices')
  if not blob then
    return nil, nil
  end

  return blob, indexType
end

local function tryPackResultBlobs(result)
  if not ffi then
    return false
  end
  if not (lovrData and lovrData.newBlob) then
    return false
  end

  local opaqueVertexBlob = packVertexBlob(result.verticesOpaque, result.opaqueCount or 0)
  if (result.opaqueCount or 0) > 0 and not opaqueVertexBlob then
    return false
  end

  local alphaVertexBlob = packVertexBlob(result.verticesAlpha, result.alphaCount or 0)
  if (result.alphaCount or 0) > 0 and not alphaVertexBlob then
    return false
  end

  local opaqueIndexBlob, opaqueIndexType = nil, nil
  if (result.indexOpaqueCount or 0) > 0 then
    opaqueIndexBlob, opaqueIndexType = packIndexBlob(result.indicesOpaque, result.indexOpaqueCount, result.opaqueCount or 0)
    if not opaqueIndexBlob then
      return false
    end
  end

  local alphaIndexBlob, alphaIndexType = nil, nil
  if (result.indexAlphaCount or 0) > 0 then
    alphaIndexBlob, alphaIndexType = packIndexBlob(result.indicesAlpha, result.indexAlphaCount, result.alphaCount or 0)
    if not alphaIndexBlob then
      return false
    end
  end

  result.verticesOpaqueBlob = opaqueVertexBlob
  result.verticesAlphaBlob = alphaVertexBlob
  result.indicesOpaqueBlob = opaqueIndexBlob
  result.indicesAlphaBlob = alphaIndexBlob
  result.indicesOpaqueType = opaqueIndexType
  result.indicesAlphaType = alphaIndexType
  result.verticesOpaque = nil
  result.verticesAlpha = nil
  result.indicesOpaque = nil
  result.indicesAlpha = nil
  return true
end

local blockHaloScratch = {}
local skyHaloScratch = {}

local function decodeHaloBlob(blob, scratch)
  if not blob then
    return nil
  end

  local blobString = nil
  if blob.getString then
    local ok, value = pcall(function()
      return blob:getString()
    end)
    if ok and type(value) == 'string' then
      blobString = value
    end

    if not blobString and blob.getSize then
      local okSize, size = pcall(function()
        return blob:getSize()
      end)
      if okSize and type(size) == 'number' then
        ok, value = pcall(function()
          return blob:getString(0, size)
        end)
        if ok and type(value) == 'string' then
          blobString = value
        else
          ok, value = pcall(function()
            return blob:getString(1, size)
          end)
          if ok and type(value) == 'string' then
            blobString = value
          end
        end
      end
    end
  end

  if not blobString then
    return nil
  end

  local count = #blobString
  for i = 1, count do
    scratch[i] = string.byte(blobString, i)
  end
  for i = count + 1, #scratch do
    scratch[i] = nil
  end

  return scratch
end

local function getJobHalo(job, blobField, tableField, scratch)
  local blob = job[blobField]
  if blob then
    local halo = decodeHaloBlob(blob, scratch)
    if halo then
      return halo
    end
  end
  return job[tableField]
end

local function buildChunkNaive(job)
  local cs = job.chunkSize
  local blockInfo = job.blockInfo
  local halo = getJobHalo(job, 'haloBlob', 'halo', blockHaloScratch)
  local skyHalo = getJobHalo(job, 'skyHaloBlob', 'skyHalo', skyHaloScratch)
  local useIndexed = job.indexed and true or false
  local airBlock = job.airBlock
  if not halo then
    error('missing_halo_payload')
  end
  if not skyHalo then
    error('missing_sky_halo_payload')
  end

  local verticesOpaque = {}
  local verticesAlpha = {}
  local indicesOpaque = {}
  local indicesAlpha = {}
  local opaqueCount = 0
  local alphaCount = 0
  local indexOpaqueCount = 0
  local indexAlphaCount = 0

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
        if block ~= airBlock then
          local info = blockInfo[block]
          local render = info and info.render
          if render == nil and info then
            render = info.solid and true or false
          end
          if info and render then
            local color = info.color or {}
            local r = color[1] or 1
            local g = color[2] or 0
            local b = color[3] or 1
            local a = info.alpha or 1
            local isOpaqueBlock = info.opaque and true or false
            local out = isOpaqueBlock and verticesOpaque or verticesAlpha
            local outIndices = isOpaqueBlock and indicesOpaque or indicesAlpha
            local count = isOpaqueBlock and opaqueCount or alphaCount
            local indexCount = isOpaqueBlock and indexOpaqueCount or indexAlphaCount

            local function emit(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz, sky)
              if useIndexed then
                count, indexCount = emitQuadIndexed(out, count, outIndices, indexCount, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz, r, g, b, a, sky)
              else
                count = emitQuad(out, count, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz, r, g, b, a, sky)
              end
            end

            if shouldDrawFace(block, halo[index - 1], blockInfo, airBlock) then
              emit(x0, y0, z0, x0, y0, z1, x0, y1, z1, x0, y1, z0, -1, 0, 0, skyHalo[index - 1] or 0)
            end
            if shouldDrawFace(block, halo[index + 1], blockInfo, airBlock) then
              emit(x1, y0, z1, x1, y0, z0, x1, y1, z0, x1, y1, z1, 1, 0, 0, skyHalo[index + 1] or 0)
            end
            if shouldDrawFace(block, halo[index - strideY], blockInfo, airBlock) then
              emit(x0, y0, z0, x1, y0, z0, x1, y0, z1, x0, y0, z1, 0, -1, 0, skyHalo[index - strideY] or 0)
            end
            if shouldDrawFace(block, halo[index + strideY], blockInfo, airBlock) then
              emit(x0, y1, z1, x1, y1, z1, x1, y1, z0, x0, y1, z0, 0, 1, 0, skyHalo[index + strideY] or 0)
            end
            if shouldDrawFace(block, halo[index - strideZ], blockInfo, airBlock) then
              emit(x0, y0, z0, x0, y1, z0, x1, y1, z0, x1, y0, z0, 0, 0, -1, skyHalo[index - strideZ] or 0)
            end
            if shouldDrawFace(block, halo[index + strideZ], blockInfo, airBlock) then
              emit(x1, y0, z1, x1, y1, z1, x0, y1, z1, x0, y0, z1, 0, 0, 1, skyHalo[index + strideZ] or 0)
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
  end

  return verticesOpaque, verticesAlpha, opaqueCount, alphaCount, indicesOpaque, indicesAlpha, indexOpaqueCount, indexAlphaCount
end

local function buildChunkGreedy(job)
  local cs = job.chunkSize
  local blockInfo = job.blockInfo
  local halo = getJobHalo(job, 'haloBlob', 'halo', blockHaloScratch)
  local skyHalo = getJobHalo(job, 'skyHaloBlob', 'skyHalo', skyHaloScratch)
  local useIndexed = job.indexed and true or false
  local airBlock = job.airBlock
  if not halo then
    error('missing_halo_payload')
  end
  if not skyHalo then
    error('missing_sky_halo_payload')
  end

  local verticesOpaque = {}
  local verticesAlpha = {}
  local indicesOpaque = {}
  local indicesAlpha = {}
  local opaqueCount = 0
  local alphaCount = 0
  local indexOpaqueCount = 0
  local indexAlphaCount = 0

  local haloSize = cs + 2
  local strideZ = haloSize
  local strideY = haloSize * haloSize
  local mask = greedyMaskScratch
  local maskSize = cs * cs

  local function emitRect(direction, slice, u, v, width, height, mergeKey)
    local block = math.floor(mergeKey / 16)
    local sky = mergeKey - block * 16
    local info = blockInfo[block]
    if not info then
      return
    end

    local color = info.color or {}
    local r = color[1] or 1
    local g = color[2] or 0
    local b = color[3] or 1
    local a = info.alpha or 1
    local isOpaqueBlock = info.opaque and true or false
    local out = isOpaqueBlock and verticesOpaque or verticesAlpha
    local outIndices = isOpaqueBlock and indicesOpaque or indicesAlpha
    local count = isOpaqueBlock and opaqueCount or alphaCount
    local indexCount = isOpaqueBlock and indexOpaqueCount or indexAlphaCount

    local function emit(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz)
      if useIndexed then
        count, indexCount = emitQuadIndexed(out, count, outIndices, indexCount, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz, r, g, b, a, sky)
      else
        count = emitQuad(out, count, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz, r, g, b, a, sky)
      end
    end

    if direction == DIR_NEG_X then
      local x = slice - 1
      local y0 = v - 1
      local y1 = y0 + height
      local z0 = u - 1
      local z1 = z0 + width
      emit(x, y0, z0, x, y0, z1, x, y1, z1, x, y1, z0, -1, 0, 0)
    elseif direction == DIR_POS_X then
      local x = slice
      local y0 = v - 1
      local y1 = y0 + height
      local z0 = u - 1
      local z1 = z0 + width
      emit(x, y0, z1, x, y0, z0, x, y1, z0, x, y1, z1, 1, 0, 0)
    elseif direction == DIR_NEG_Y then
      local y = slice - 1
      local x0 = u - 1
      local x1 = x0 + width
      local z0 = v - 1
      local z1 = z0 + height
      emit(x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1, 0, -1, 0)
    elseif direction == DIR_POS_Y then
      local y = slice
      local x0 = u - 1
      local x1 = x0 + width
      local z0 = v - 1
      local z1 = z0 + height
      emit(x0, y, z1, x1, y, z1, x1, y, z0, x0, y, z0, 0, 1, 0)
    elseif direction == DIR_NEG_Z then
      local z = slice - 1
      local x0 = u - 1
      local x1 = x0 + width
      local y0 = v - 1
      local y1 = y0 + height
      emit(x0, y0, z, x0, y1, z, x1, y1, z, x1, y0, z, 0, 0, -1)
    else
      local z = slice
      local x0 = u - 1
      local x1 = x0 + width
      local y0 = v - 1
      local y1 = y0 + height
      emit(x1, y0, z, x1, y1, z, x0, y1, z, x0, y0, z, 0, 0, 1)
    end

    if isOpaqueBlock then
      opaqueCount = count
      indexOpaqueCount = indexCount
    else
      alphaCount = count
      indexAlphaCount = indexCount
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
          if shouldDrawFace(block, neighbor, blockInfo, airBlock) then
            local faceLight = skyHalo[index + neighborOffset] or 0
            mask[(v - 1) * cs + u] = block * 16 + faceLight
          end
        end
      end

      for v = 1, cs do
        local u = 1
        while u <= cs do
          local index = (v - 1) * cs + u
          local mergeKey = mask[index]
          if mergeKey == 0 then
            u = u + 1
          else
            local width = 1
            while (u + width) <= cs and mask[index + width] == mergeKey do
              width = width + 1
            end

            local height = 1
            local canGrow = true
            while (v + height) <= cs and canGrow do
              local row = (v + height - 1) * cs + u
              for k = 0, width - 1 do
                if mask[row + k] ~= mergeKey then
                  canGrow = false
                  break
                end
              end
              if canGrow then
                height = height + 1
              end
            end

            emitRect(direction, slice, u, v, width, height, mergeKey)

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

  return verticesOpaque, verticesAlpha, opaqueCount, alphaCount, indicesOpaque, indicesAlpha, indexOpaqueCount, indexAlphaCount
end

local function buildChunk(job)
  local verticesOpaque, verticesAlpha, opaqueCount, alphaCount
  local indicesOpaque, indicesAlpha, indexOpaqueCount, indexAlphaCount
  if job.useGreedy then
    verticesOpaque, verticesAlpha, opaqueCount, alphaCount, indicesOpaque, indicesAlpha, indexOpaqueCount, indexAlphaCount = buildChunkGreedy(job)
  else
    verticesOpaque, verticesAlpha, opaqueCount, alphaCount, indicesOpaque, indicesAlpha, indexOpaqueCount, indexAlphaCount = buildChunkNaive(job)
  end

  local result = {
    type = 'result',
    key = job.key,
    cx = job.cx,
    cy = job.cy,
    cz = job.cz,
    version = job.version,
    indexed = job.indexed and true or false,
    verticesOpaque = verticesOpaque,
    verticesAlpha = verticesAlpha,
    opaqueCount = opaqueCount,
    alphaCount = alphaCount,
    indicesOpaque = indicesOpaque,
    indicesAlpha = indicesAlpha,
    indexOpaqueCount = indexOpaqueCount,
    indexAlphaCount = indexAlphaCount
  }

  if job.resultBlob then
    if tryPackResultBlobs(result) then
      result.resultPayload = 'blob'
    else
      result.resultPayload = 'table'
    end
  else
    result.resultPayload = 'table'
  end

  return result
end

local jobsName, resultsName = ...
if not (lovrThread and lovrThread.getChannel) then
  return
end
local jobs = lovrThread.getChannel(jobsName)
local results = lovrThread.getChannel(resultsName)
if not jobs or not results then
  return
end

local function nextJob(channel)
  if not channel then
    return nil
  end

  if type(channel.demand) == 'function' then
    return channel:demand()
  end

  if type(channel.pop) == 'function' then
    while true do
      local job = channel:pop()
      if job ~= nil then
        return job
      end
      if lovrTimer and lovrTimer.sleep then
        lovrTimer.sleep(0.001)
      end
    end
  end

  return nil
end

while true do
  local job = nextJob(jobs)
  if not job then
    break
  end

  if job.type == 'shutdown' then
    break
  end

  if job.type == 'build' then
    local ok, resultOrErr = pcall(buildChunk, job)
    if ok then
      results:push(resultOrErr)
    else
      results:push({
        type = 'error',
        key = job.key,
        version = job.version,
        error = tostring(resultOrErr)
      })
    end
  end
end
