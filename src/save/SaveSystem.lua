local SaveSystem = {}
SaveSystem.__index = SaveSystem

local SAVE_DIR = 'saves'
local SAVE_FILE = SAVE_DIR .. '/world_v2.txt'
local SAVE_FILE_BACKUP = SAVE_DIR .. '/world_v2.bak'
local SAVE_FILE_TEMP = SAVE_DIR .. '/world_v2.tmp'
local SAVE_FILE_LEGACY = SAVE_DIR .. '/world_v1.txt'
local SAVE_READ_ORDER = { SAVE_FILE, SAVE_FILE_BACKUP, SAVE_FILE_LEGACY }
local SAVE_DELETE_ORDER = { SAVE_FILE_TEMP, SAVE_FILE_BACKUP, SAVE_FILE, SAVE_FILE_LEGACY }
local SAVE_MAGIC_V1 = 'MC_SAVE_V1'
local SAVE_MAGIC_V2 = 'MC_SAVE_V2'

function SaveSystem.new()
  local self = setmetatable({}, SaveSystem)
  self._linesScratch = {}
  self._editsScratch = {}
  self._loadLinesScratch = {}
  self._inventoryScratch = { slots = {} }
  self._statsScratch = {}
  return self
end

local function getFilesystem()
  if lovr and lovr.filesystem then
    return lovr.filesystem
  end
  return nil
end

local function clearArray(array)
  for i = #array, 1, -1 do
    array[i] = nil
  end
end

local function isFiniteNumber(value)
  return type(value) == 'number'
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function parseInteger(token)
  local value = tonumber(token)
  if not value or value % 1 ~= 0 then
    return nil
  end
  return value
end

local function parseFiniteNumber(token)
  local value = tonumber(token)
  if not isFiniteNumber(value) then
    return nil
  end
  return value
end

local function parsePlayerLine(line)
  local px, py, pz, yaw, pitch = (line or ''):match(
    '^player%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)$'
  )
  if not px or not py or not pz or not yaw or not pitch then
    return nil
  end

  local x = parseFiniteNumber(px)
  local y = parseFiniteNumber(py)
  local z = parseFiniteNumber(pz)
  local yawValue = parseFiniteNumber(yaw)
  local pitchValue = parseFiniteNumber(pitch)
  if not x or not y or not z or not yawValue or not pitchValue then
    return nil
  end

  return {
    x = x,
    y = y,
    z = z,
    yaw = yawValue,
    pitch = pitchValue
  }
end

local function parseEditLine(line)
  local xToken, yToken, zToken, blockToken = (line or ''):match(
    '^(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)$'
  )
  if not xToken or not yToken or not zToken or not blockToken then
    return nil
  end

  local x = parseInteger(xToken)
  local y = parseInteger(yToken)
  local z = parseInteger(zToken)
  local block = parseInteger(blockToken)
  if not x or not y or not z or not block then
    return nil
  end

  return x, y, z, block
end

local function parseStatsLine(line)
  local healthToken, maxHealthToken, hungerToken, maxHungerToken, xpToken, levelToken = (line or ''):match(
    '^stats%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)$'
  )
  if not healthToken or not maxHealthToken or not hungerToken or not maxHungerToken or not xpToken or not levelToken then
    return nil
  end

  local health = parseFiniteNumber(healthToken)
  local maxHealth = parseFiniteNumber(maxHealthToken)
  local hunger = parseFiniteNumber(hungerToken)
  local maxHunger = parseFiniteNumber(maxHungerToken)
  local experience = parseFiniteNumber(xpToken)
  local level = parseInteger(levelToken)

  if not health or not maxHealth or not hunger or not maxHunger or not experience or not level then
    return nil
  end

  if maxHealth <= 0 or maxHunger <= 0 or level < 0 then
    return nil
  end

  return {
    health = math.max(0, math.min(maxHealth, health)),
    maxHealth = maxHealth,
    hunger = math.max(0, math.min(maxHunger, hunger)),
    maxHunger = maxHunger,
    experience = math.max(0, math.min(1, experience)),
    level = level
  }
end

local function parseCoreHeaders(lines, constants)
  local seed = parseInteger((lines[2] or ''):match('^seed%s+(-?%d+)$'))
  local sizeX, sizeY, sizeZ = (lines[3] or ''):match('^world%s+(%d+)%s+(%d+)%s+(%d+)$')
  local chunkSize = parseInteger((lines[4] or ''):match('^chunk%s+(%d+)$'))
  if not seed or not sizeX or not sizeY or not sizeZ or not chunkSize then
    return nil, 'corrupt'
  end

  sizeX = parseInteger(sizeX)
  sizeY = parseInteger(sizeY)
  sizeZ = parseInteger(sizeZ)

  if seed ~= (constants.WORLD_SEED or 0)
    or sizeX ~= (constants.WORLD_SIZE_X or 0)
    or sizeY ~= (constants.WORLD_SIZE_Y or 0)
    or sizeZ ~= (constants.WORLD_SIZE_Z or 0)
    or chunkSize ~= (constants.CHUNK_SIZE or 0) then
    return nil, 'incompatible'
  end

  return {
    seed = seed,
    sizeX = sizeX,
    sizeY = sizeY,
    sizeZ = sizeZ,
    chunkSize = chunkSize
  }, nil
end

local function buildErrorInfo(version, savedAt, editCount)
  local info = { version = version }
  if savedAt ~= nil then
    info.savedAt = savedAt
  end
  if editCount ~= nil then
    info.editCount = editCount
  end
  return info
end

local function parseSave(lines, constants, options)
  options = options or {}
  local includeEdits = options.includeEdits == true
  local includeInventory = options.includeInventory == true
  local includeStats = options.includeStats == true

  local magic = lines[1]
  local version = nil
  if magic == SAVE_MAGIC_V1 then
    version = 1
  elseif magic == SAVE_MAGIC_V2 then
    version = 2
  else
    if type(magic) == 'string' and magic:match('^MC_SAVE_') then
      return nil, 'incompatible', buildErrorInfo(nil)
    end
    return nil, 'corrupt', buildErrorInfo(nil)
  end

  local core, coreErr = parseCoreHeaders(lines, constants)
  if not core then
    return nil, coreErr, buildErrorInfo(version)
  end

  local result = {
    version = version,
    seed = core.seed,
    sizeX = core.sizeX,
    sizeY = core.sizeY,
    sizeZ = core.sizeZ,
    chunkSize = core.chunkSize,
    savedAt = 0,
    timeOfDay = nil,
    player = nil,
    inventory = nil,
    stats = nil,
    editCount = 0,
    edits = includeEdits and {} or nil
  }

  local index = 5
  if version == 1 then
    local editCount = parseInteger((lines[index] or ''):match('^edits%s+(%-?%d+)$'))
    if not editCount or editCount < 0 then
      return nil, 'corrupt', buildErrorInfo(version)
    end
    result.editCount = editCount
    index = index + 1

    local playerLine = lines[index]
    if playerLine and playerLine:match('^player%s+') then
      local player = parsePlayerLine(playerLine)
      if not player then
        return nil, 'corrupt', buildErrorInfo(version, 0, editCount)
      end
      result.player = player
      index = index + 1
    end

    for i = 1, editCount do
      local x, y, z, block = parseEditLine(lines[index + i - 1])
      if not x then
        return nil, 'corrupt', buildErrorInfo(version, 0, editCount)
      end
      if includeEdits then
        result.edits[i] = { x, y, z, block }
      end
    end

    return result, nil, nil
  end

  local savedAt = parseInteger((lines[index] or ''):match('^savedAt%s+(-?%d+)$'))
  if not savedAt or savedAt < 0 then
    return nil, 'corrupt', buildErrorInfo(version)
  end
  result.savedAt = savedAt
  index = index + 1

  local timeToken = (lines[index] or ''):match('^time%s+([^%s]+)$')
  local timeOfDay = parseFiniteNumber(timeToken)
  if not timeOfDay then
    return nil, 'corrupt', buildErrorInfo(version, savedAt)
  end
  result.timeOfDay = timeOfDay % 1
  index = index + 1

  local player = parsePlayerLine(lines[index])
  if not player then
    return nil, 'corrupt', buildErrorInfo(version, savedAt)
  end
  result.player = player
  index = index + 1

  local slotCountToken, selectedToken = (lines[index] or ''):match('^inv%s+(%-?%d+)%s+(%-?%d+)$')
  local slotCount = parseInteger(slotCountToken)
  local selected = parseInteger(selectedToken)
  if not slotCount or slotCount < 0 or not selected then
    return nil, 'corrupt', buildErrorInfo(version, savedAt)
  end
  index = index + 1

  local inventoryState = nil
  if includeInventory then
    inventoryState = {
      slotCount = slotCount,
      selected = selected,
      slots = {}
    }
    result.inventory = inventoryState
  end

  local seenSlot = {}
  for i = 1, slotCount do
    local slotIndexToken, blockToken, countToken = (lines[index] or ''):match(
      '^slot%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)$'
    )
    local slotIndex = parseInteger(slotIndexToken)
    local blockId = parseInteger(blockToken)
    local count = parseInteger(countToken)
    if not slotIndex or slotIndex < 1 or slotIndex > slotCount or seenSlot[slotIndex] or not blockId or not count then
      return nil, 'corrupt', buildErrorInfo(version, savedAt)
    end

    seenSlot[slotIndex] = true
    if inventoryState then
      inventoryState.slots[slotIndex] = {
        block = blockId,
        count = count
      }
    end
    index = index + 1
  end

  local statsLine = lines[index]
  if statsLine and statsLine:match('^stats%s+') then
    local statsState = parseStatsLine(statsLine)
    if not statsState then
      return nil, 'corrupt', buildErrorInfo(version, savedAt)
    end
    if includeStats then
      result.stats = statsState
    end
    index = index + 1
  end

  local editCount = parseInteger((lines[index] or ''):match('^edits%s+(%-?%d+)$'))
  if not editCount or editCount < 0 then
    return nil, 'corrupt', buildErrorInfo(version, savedAt)
  end
  result.editCount = editCount
  index = index + 1

  if lines[index] ~= 'BEGIN_EDITS' then
    return nil, 'corrupt', buildErrorInfo(version, savedAt, editCount)
  end
  index = index + 1

  for i = 1, editCount do
    local x, y, z, block = parseEditLine(lines[index + i - 1])
    if not x then
      return nil, 'corrupt', buildErrorInfo(version, savedAt, editCount)
    end
    if includeEdits then
      result.edits[i] = { x, y, z, block }
    end
  end

  if includeInventory and inventoryState then
    for i = 1, slotCount do
      if inventoryState.slots[i] == nil then
        inventoryState.slots[i] = { block = 0, count = 0 }
      end
    end
  end

  return result, nil, nil
end

local function getCurrentUnixSeconds()
  if not os or not os.time then
    return 0
  end

  local ok, value = pcall(os.time)
  if not ok then
    return 0
  end

  local seconds = parseInteger(value)
  if not seconds or seconds < 0 then
    return 0
  end
  return seconds
end

local function normalizeReadResult(a, b)
  local data = a
  if type(data) == 'boolean' then
    if not data then
      return nil
    end
    data = b
  end
  if data and type(data) ~= 'string' and data.getString then
    data = data:getString()
  end
  return data
end

local function fileExists(filesystem, path)
  if not filesystem then
    return false
  end

  if filesystem.getInfo then
    return filesystem.getInfo(path) ~= nil
  end

  if filesystem.read then
    local data = normalizeReadResult(filesystem.read(path))
    return type(data) == 'string'
  end

  return false
end

local function readFileString(filesystem, path)
  if not filesystem or not filesystem.read then
    return nil
  end

  local data = normalizeReadResult(filesystem.read(path))
  if type(data) ~= 'string' then
    return nil
  end
  return data
end

local function parseSaveFromData(saveSystem, data, constants, options)
  if type(data) ~= 'string' or data == '' then
    return nil, 'corrupt', buildErrorInfo(nil)
  end

  local lines = saveSystem._loadLinesScratch
  clearArray(lines)
  for line in data:gmatch('[^\r\n]+') do
    lines[#lines + 1] = line
  end
  return parseSave(lines, constants, options)
end

local function parseFirstAvailableSave(saveSystem, filesystem, constants, options)
  local sawAny = false
  local firstErr = nil
  local firstInfo = nil

  for i = 1, #SAVE_READ_ORDER do
    local path = SAVE_READ_ORDER[i]
    if fileExists(filesystem, path) then
      sawAny = true
      local data = readFileString(filesystem, path)
      local parsed, err, info = parseSaveFromData(saveSystem, data, constants, options)
      if parsed then
        return parsed, nil, nil, path
      end

      if not firstErr then
        firstErr = err or 'corrupt'
        firstInfo = info
      end
    end
  end

  if not sawAny then
    return nil, 'missing', nil, nil
  end
  return nil, firstErr or 'corrupt', firstInfo, nil
end

function SaveSystem:exists()
  local filesystem = getFilesystem()
  if not filesystem then
    return false
  end

  for i = 1, #SAVE_READ_ORDER do
    if fileExists(filesystem, SAVE_READ_ORDER[i]) then
      return true
    end
  end

  return false
end

function SaveSystem:delete()
  local filesystem = getFilesystem()
  if not filesystem or not filesystem.remove then
    return false
  end

  local allRemoved = true
  for i = 1, #SAVE_DELETE_ORDER do
    local path = SAVE_DELETE_ORDER[i]
    if fileExists(filesystem, path) then
      local ok = filesystem.remove(path)
      if not ok and fileExists(filesystem, path) then
        allRemoved = false
      end
    end
  end

  return allRemoved
end

function SaveSystem:save(world, constants, player, inventory, sky, stats)
  local filesystem = getFilesystem()
  if not filesystem or not filesystem.write then
    return false, 'filesystem_unavailable'
  end
  if not world or not constants then
    return false, 'invalid_arguments'
  end

  if filesystem.createDirectory then
    filesystem.createDirectory(SAVE_DIR)
  end

  local edits = self._editsScratch
  local editCount = world:collectEdits(edits)
  local lines = self._linesScratch
  clearArray(lines)

  lines[1] = SAVE_MAGIC_V2
  lines[2] = string.format('seed %d', constants.WORLD_SEED or 0)
  lines[3] = string.format(
    'world %d %d %d',
    constants.WORLD_SIZE_X or 0,
    constants.WORLD_SIZE_Y or 0,
    constants.WORLD_SIZE_Z or 0
  )
  lines[4] = string.format('chunk %d', constants.CHUNK_SIZE or 0)

  local savedAt = getCurrentUnixSeconds()
  lines[5] = string.format('savedAt %d', savedAt)

  local timeOfDay = 0
  if sky and isFiniteNumber(sky.timeOfDay) then
    timeOfDay = sky.timeOfDay % 1
  end
  lines[6] = string.format('time %.6f', timeOfDay)

  local playerX = 0
  local playerY = 0
  local playerZ = 0
  local playerYaw = 0
  local playerPitch = 0
  if player then
    playerX = tonumber(player.x) or 0
    playerY = tonumber(player.y) or 0
    playerZ = tonumber(player.z) or 0
    playerYaw = tonumber(player.yaw) or 0
    playerPitch = tonumber(player.pitch) or 0
  end
  lines[7] = string.format('player %.6f %.6f %.6f %.6f %.6f', playerX, playerY, playerZ, playerYaw, playerPitch)

  local inventoryState = self._inventoryScratch
  inventoryState.slotCount = 0
  inventoryState.selected = 1
  clearArray(inventoryState.slots)
  if inventory and inventory.getState then
    inventory:getState(inventoryState)
  end

  local slotCount = parseInteger(inventoryState.slotCount) or 0
  local selectedIndex = parseInteger(inventoryState.selected) or 1
  lines[8] = string.format('inv %d %d', slotCount, selectedIndex)

  local lineCount = 8
  local slotLines = inventoryState.slots or {}
  for i = 1, slotCount do
    local slot = slotLines[i]
    local blockId = 0
    local count = 0
    if slot then
      blockId = parseInteger(slot.block) or 0
      count = parseInteger(slot.count) or 0
      if blockId <= 0 or count <= 0 then
        blockId = 0
        count = 0
      end
    end
    lineCount = lineCount + 1
    lines[lineCount] = string.format('slot %d %d %d', i, blockId, count)
  end

  local statsState = self._statsScratch
  statsState.health = 20
  statsState.maxHealth = 20
  statsState.hunger = 20
  statsState.maxHunger = 20
  statsState.experience = 0
  statsState.level = 0
  if stats and stats.getState then
    stats:getState(statsState)
  end

  local maxHealth = parseFiniteNumber(statsState.maxHealth) or 20
  local maxHunger = parseFiniteNumber(statsState.maxHunger) or 20
  if maxHealth <= 0 then
    maxHealth = 20
  end
  if maxHunger <= 0 then
    maxHunger = 20
  end

  local health = parseFiniteNumber(statsState.health) or maxHealth
  local hunger = parseFiniteNumber(statsState.hunger) or maxHunger
  local experience = parseFiniteNumber(statsState.experience) or 0
  local level = parseInteger(statsState.level) or 0
  if level < 0 then
    level = 0
  end

  health = math.max(0, math.min(maxHealth, health))
  hunger = math.max(0, math.min(maxHunger, hunger))
  experience = math.max(0, math.min(1, experience))

  lineCount = lineCount + 1
  lines[lineCount] = string.format('stats %.6f %.6f %.6f %.6f %.6f %d', health, maxHealth, hunger, maxHunger, experience, level)

  lineCount = lineCount + 1
  lines[lineCount] = string.format('edits %d', editCount)
  lineCount = lineCount + 1
  lines[lineCount] = 'BEGIN_EDITS'

  for i = 1, editCount do
    local entry = edits[i]
    lineCount = lineCount + 1
    lines[lineCount] = string.format('%d %d %d %d', entry[1], entry[2], entry[3], entry[4])
  end

  local payload = table.concat(lines, '\n', 1, lineCount)
  local previousData = readFileString(filesystem, SAVE_FILE)

  local wroteTemp = filesystem.write(SAVE_FILE_TEMP, payload)
  if wroteTemp == false or wroteTemp == nil then
    return false, 'write_failed'
  end

  local tempData = readFileString(filesystem, SAVE_FILE_TEMP)
  if tempData ~= payload then
    if filesystem.remove then
      filesystem.remove(SAVE_FILE_TEMP)
    end
    return false, 'write_verify_failed'
  end

  if previousData ~= nil then
    local wroteBackup = filesystem.write(SAVE_FILE_BACKUP, previousData)
    if wroteBackup == false or wroteBackup == nil then
      if filesystem.remove then
        filesystem.remove(SAVE_FILE_TEMP)
      end
      return false, 'backup_write_failed'
    end
  end

  local wrotePrimary = filesystem.write(SAVE_FILE, payload)
  if wrotePrimary == false or wrotePrimary == nil then
    if previousData ~= nil then
      filesystem.write(SAVE_FILE, previousData)
    end
    if filesystem.remove then
      filesystem.remove(SAVE_FILE_TEMP)
    end
    return false, 'write_failed'
  end

  local verifyData = readFileString(filesystem, SAVE_FILE)
  if verifyData ~= payload then
    if previousData ~= nil then
      filesystem.write(SAVE_FILE, previousData)
    end
    if filesystem.remove then
      filesystem.remove(SAVE_FILE_TEMP)
    end
    return false, 'write_verify_failed'
  end

  if filesystem.remove then
    filesystem.remove(SAVE_FILE_TEMP)
    if SAVE_FILE_LEGACY ~= SAVE_FILE and fileExists(filesystem, SAVE_FILE_LEGACY) then
      filesystem.remove(SAVE_FILE_LEGACY)
    end
  end

  if editCount <= 0 then
    return true, 'saved_empty'
  end
  return true, 'saved'
end

function SaveSystem:load(constants)
  local filesystem = getFilesystem()
  if not filesystem or not filesystem.read then
    return nil, 0, 'filesystem_unavailable'
  end
  if not constants then
    return nil, 0, 'invalid_arguments'
  end

  local parsed, err = parseFirstAvailableSave(self, filesystem, constants, {
    includeEdits = true,
    includeInventory = true,
    includeStats = true
  })
  if not parsed then
    return nil, 0, err or 'corrupt'
  end

  return parsed.edits or {}, parsed.editCount or 0, nil, parsed.player, parsed.inventory, parsed.timeOfDay, parsed.savedAt, parsed.version, parsed.stats
end

function SaveSystem:peek(constants)
  local filesystem = getFilesystem()
  if not filesystem or not filesystem.read then
    return { ok = false, err = 'filesystem_unavailable' }
  end
  if not constants then
    return { ok = false, err = 'invalid_arguments' }
  end

  local parsed, err, info = parseFirstAvailableSave(self, filesystem, constants, {
    includeEdits = false,
    includeInventory = false,
    includeStats = false
  })

  if not parsed then
    return {
      ok = false,
      err = err or 'corrupt',
      version = info and info.version or nil,
      savedAt = info and info.savedAt or nil,
      editCount = info and info.editCount or nil
    }
  end

  return {
    ok = true,
    version = parsed.version,
    savedAt = parsed.savedAt or 0,
    editCount = parsed.editCount or 0,
    player = parsed.player,
    timeOfDay = parsed.timeOfDay
  }
end

function SaveSystem:apply(world, edits, count)
  if not world or not edits then
    return false
  end

  local limit = math.floor(tonumber(count) or #edits)
  if limit < 0 then
    limit = 0
  end

  if world.applyEditsBulk then
    local ok = world:applyEditsBulk(edits, limit)
    if ok ~= false then
      return true
    end
  end

  for i = 1, limit do
    local entry = edits[i]
    if entry then
      world:set(entry[1], entry[2], entry[3], entry[4])
    end
  end

  return true
end

return SaveSystem
