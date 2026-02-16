local World = require 'src.world'
local Player = require 'src.player'
local Inventory = require 'src.inventory'
local PlayerStats = require 'src.player.PlayerStats'

local MouseLock = require 'src.input.MouseLock'
local Input = require 'src.input.Input'
local Interaction = require 'src.interaction.Interaction'
local HUD = require 'src.ui.HUD'
local Sky = require 'src.sky.Sky'
local MobSystem = require 'src.mobs.MobSystem'
local ChunkRenderer = require 'src.render.ChunkRenderer'
local VoxelShader = require 'src.render.VoxelShader'
local SaveSystem = require 'src.save.SaveSystem'
local MainMenu = require 'src.ui.MainMenu'

local GameState = {}
GameState.__index = GameState

local FULLSCREEN_STATE_FILE = '.fullscreen'

local function readFullscreenState()
  local file = io.open(FULLSCREEN_STATE_FILE, 'r')
  if not file then
    return false
  end

  local value = file:read('*l')
  file:close()
  return value == '1' or value == 'true'
end

local function writeFullscreenState(enabled)
  local file = io.open(FULLSCREEN_STATE_FILE, 'w')
  if not file then
    return false
  end

  file:write(enabled and '1' or '0')
  file:close()
  return true
end

local function isFiniteNumber(value)
  return type(value) == 'number'
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
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

local function worldToChunk(value, chunkSize, maxChunks)
  local chunk = math.floor((value or 0) / chunkSize) + 1
  return clamp(chunk, 1, maxChunks)
end

function GameState.new(constants)
  local self = setmetatable({}, GameState)
  self.constants = constants

  self.world = nil
  self.player = nil
  self.inventory = nil
  self.stats = nil

  self.mouseLock = nil
  self.input = nil
  self.interaction = nil
  self.hud = nil
  self.sky = nil
  self.mobs = nil
  self.renderer = nil
  self.voxelShader = nil
  self._voxelShaderError = nil

  self.saveSystem = nil
  self.menu = nil
  self.mode = 'menu'
  self._hasSave = false
  self._canContinue = false
  self._saveMeta = nil
  self._autosaveTimer = 0
  self._saveStatusText = nil
  self._saveStatusTimer = 0
  self._chunkDirtyRadius = 0
  self._activeMinChunkY = 1
  self._activeMaxChunkY = 1
  self._lastPlayerChunkX = nil
  self._lastPlayerChunkZ = nil
  self._enqueueScratch = {}
  self._enqueuedCount = 0
  self._enqueuedTimer = 0
  self._enqueuedShowSeconds = 0.5
  self._cameraPosition = nil
  self._mobSkipDirtyQueueAbove = 0

  self.showHelp = false
  self.showPerfHud = true
  self.rebuildMaxPerFrame = nil
  self.rebuildMaxMillisPerFrame = nil
  self.frameMs = 0
  self.worstFrameMs = 0
  self._worstFrameWindowMax = 0
  self._worstFrameWindowTime = 0
  self.relativeMouseReady = false
  self._loaded = false

  return self
end

local function tryInitRelativeMouse()
  local ok, mouse = pcall(require, 'lovr-mouse')
  if ok and type(mouse) == 'table' then
    lovr.mouse = mouse
    return true
  end

  if ok and lovr.mouse and lovr.mouse.setRelativeMode then
    return true
  end

  if not lovr.mouse then
    lovr.mouse = {
      setRelativeMode = function() end,
      setVisible = function() end
    }
  end

  return false
end

function GameState:_hasSession()
  return self.world ~= nil and self.player ~= nil and self.renderer ~= nil
end

function GameState:_updateFrameTiming(dt)
  local frameMs = dt * 1000
  self.frameMs = frameMs
  if frameMs > self._worstFrameWindowMax then
    self._worstFrameWindowMax = frameMs
  end
  self.worstFrameMs = self._worstFrameWindowMax
  self._worstFrameWindowTime = self._worstFrameWindowTime + dt
  if self._worstFrameWindowTime >= 1.0 then
    self._worstFrameWindowTime = self._worstFrameWindowTime - 1.0
    self._worstFrameWindowMax = frameMs
  end
end

function GameState:_getSaveStatusDuration()
  local saveConfig = self.constants.SAVE or {}
  local duration = tonumber(saveConfig.autosaveShowHudSeconds)
  if not duration or duration <= 0 then
    return 1.5
  end
  return duration
end

function GameState:_setSaveStatus(text, durationSeconds)
  self._saveStatusText = text
  self._saveStatusTimer = durationSeconds or self:_getSaveStatusDuration()

  if self.menu then
    self.menu:setStatusText(text)
  end
end

function GameState:_tickSaveStatus(dt)
  if not self._saveStatusText or not self._saveStatusTimer or self._saveStatusTimer <= 0 then
    return
  end

  self._saveStatusTimer = self._saveStatusTimer - (dt or 0)
  if self._saveStatusTimer > 0 then
    return
  end

  local expiredText = self._saveStatusText
  self._saveStatusText = nil
  self._saveStatusTimer = 0

  if self.menu and self.menu.statusText == expiredText then
    self.menu:setStatusText(nil)
  end
end

function GameState:_setEnqueuedMetric(count)
  local value = tonumber(count) or 0
  if value < 0 then
    value = 0
  end

  self._enqueuedCount = math.floor(value + 0.5)
  self._enqueuedTimer = self._enqueuedShowSeconds or 0.5
end

function GameState:_tickEnqueuedMetric(dt)
  local timer = self._enqueuedTimer or 0
  if timer <= 0 then
    return
  end

  timer = timer - (dt or 0)
  if timer < 0 then
    timer = 0
  end
  self._enqueuedTimer = timer
end

function GameState:_saveNow()
  if not self.saveSystem or not self.world then
    return false, 'missing_session'
  end

  return self.saveSystem:save(self.world, self.constants, self.player, self.inventory, self.sky, self.stats)
end

function GameState:_updateAutosave(dt)
  local saveConfig = self.constants.SAVE or {}
  if saveConfig.enabled == false then
    return
  end

  local interval = tonumber(saveConfig.autosaveIntervalSeconds) or 60
  if interval <= 0 then
    return
  end

  self._autosaveTimer = (self._autosaveTimer or 0) + dt
  if self._autosaveTimer < interval then
    return
  end

  self._autosaveTimer = 0
  self:_setSaveStatus('Autosaving...')
  local ok, reason = self:_saveNow()
  self:_refreshSaveState()
  if ok then
    self:_setSaveStatus('Autosaved')
  else
    local suffix = reason and (': ' .. tostring(reason)) or ''
    self:_setSaveStatus('Autosave failed' .. suffix)
  end
end

function GameState:_refreshSaveState()
  if not self.saveSystem or not self.menu then
    return
  end

  local hasSave = self.saveSystem:exists()
  local canContinue = false
  local meta = nil

  if hasSave then
    meta = self.saveSystem:peek(self.constants)
    if meta and meta.ok then
      canContinue = true
    end
  end

  self._hasSave = hasSave
  self._canContinue = canContinue
  self._saveMeta = meta
  self.menu:setSaveState(hasSave, canContinue, nil)
  self.menu:setSaveMeta(meta)
end

function GameState:_teardownSession()
  self.world = nil
  self.player = nil
  self.inventory = nil
  self.stats = nil

  self.input = nil
  self.interaction = nil
  self.hud = nil
  self.sky = nil
  self.mobs = nil
  if self.renderer and self.renderer.shutdown then
    self.renderer:shutdown()
  end
  self.renderer = nil
  self.voxelShader = nil
  self._voxelShaderError = nil
  self._autosaveTimer = 0
  self._chunkDirtyRadius = 0
  self._activeMinChunkY = 1
  self._activeMaxChunkY = 1
  self._lastPlayerChunkX = nil
  self._lastPlayerChunkZ = nil
  self._enqueuedCount = 0
  self._enqueuedTimer = 0

  if self.mouseLock then
    self.mouseLock:unlock()
  end
end

function GameState:_startSession(loadSave)
  self:_teardownSession()
  self._saveStatusText = nil
  self._saveStatusTimer = 0

  self.world = World.new(self.constants)
  self.world:generate()
  local savedPlayerState = nil
  local savedInventoryState = nil
  local savedTimeOfDay = nil
  local savedStatsState = nil

  if loadSave then
    local edits, count, err, playerState, inventoryState, timeOfDay, _, _, statsState = self.saveSystem:load(self.constants)
    if edits then
      self.saveSystem:apply(self.world, edits, count)
      if playerState then
        savedPlayerState = playerState
      end
      if inventoryState then
        savedInventoryState = inventoryState
      end
      if timeOfDay ~= nil then
        savedTimeOfDay = timeOfDay
      end
      if statsState then
        savedStatsState = statsState
      end
    elseif err and err ~= 'missing' then
      self:_teardownSession()
      self.mode = 'menu'
      self.menu:setMode('main')
      self:_refreshSaveState()
      return false
    end
  end

  local spawnX, spawnY, spawnZ = self.world:getSpawnPoint()
  local startX = spawnX
  local startY = spawnY
  local startZ = spawnZ
  local startYaw = 0
  local startPitch = 0

  if savedPlayerState
    and isFiniteNumber(savedPlayerState.x)
    and isFiniteNumber(savedPlayerState.y)
    and isFiniteNumber(savedPlayerState.z)
    and isFiniteNumber(savedPlayerState.yaw)
    and isFiniteNumber(savedPlayerState.pitch) then
    startX = savedPlayerState.x
    startY = savedPlayerState.y
    startZ = savedPlayerState.z
    startYaw = savedPlayerState.yaw
    startPitch = clamp(savedPlayerState.pitch, -1.50, 1.50)
  end

  self.player = Player.new(self.constants.PLAYER, startX, startY, startZ)
  self.player.yaw = startYaw
  self.player.pitch = startPitch
  self.player.velocityY = 0
  self.player.onGround = false

  if savedPlayerState and self.player:_collides(self.world) then
    self.player.x = spawnX
    self.player.y = spawnY
    self.player.z = spawnZ
    self.player.yaw = 0
    self.player.pitch = 0
    self.player.velocityY = 0
    self.player.onGround = false
  end

  self.inventory = Inventory.new(
    self.constants.HOTBAR_DEFAULTS,
    self.constants.INVENTORY_SLOT_COUNT,
    self.constants.INVENTORY_START_COUNT
  )
  if savedInventoryState then
    self.inventory:applyState(savedInventoryState)
  end
  self.stats = PlayerStats.new(self.constants.STATS)
  if savedStatsState then
    self.stats:applyState(savedStatsState)
  end

  self.input = Input.new(self.mouseLock, self.inventory)
  self.interaction = Interaction.new(self.constants, self.world, self.player, self.inventory)
  self.hud = HUD.new(self.constants)
  self.sky = Sky.new(self.constants)
  self.mobs = MobSystem.new(self.constants, self.world, self.player, self.stats)
  do
    local mobConfig = self.constants.MOBS or {}
    local threshold = tonumber(mobConfig.skipAiWhenDirtyQueueAbove)
    if threshold and threshold >= 0 then
      self._mobSkipDirtyQueueAbove = math.floor(threshold)
    else
      self._mobSkipDirtyQueueAbove = 0
    end
  end
  if savedTimeOfDay ~= nil then
    self.sky:setTime(savedTimeOfDay)
  end
  self.renderer = ChunkRenderer.new(self.constants, self.world)
  local okShader, shaderOrErr = pcall(VoxelShader.new)
  if okShader then
    self.voxelShader = shaderOrErr
    self._voxelShaderError = nil
  else
    self.voxelShader = nil
    self._voxelShaderError = tostring(shaderOrErr)
  end

  local cameraX, cameraY, cameraZ = self.player:getCameraPosition()
  self.renderer:setPriorityOriginWorld(cameraX, cameraY, cameraZ)
  do
    local cull = self.constants.CULL or {}
    local rebuild = self.constants.REBUILD or {}
    local radius = tonumber(cull.drawRadiusChunks) or 4
    local pad = tonumber(cull.alwaysVisiblePaddingChunks) or 0

    -- Conservative square coverage (not FOV-based) so the initial view is mostly meshed.
    local r = math.max(0, radius + pad + 1)
    self._chunkDirtyRadius = r

    local minCy = 1
    local maxCy = self.world.chunksY
    if self.world.getActiveChunkYRange then
      minCy, maxCy = self.world:getActiveChunkYRange()
    end
    self._activeMinChunkY = minCy
    self._activeMaxChunkY = maxCy

    local pcx = worldToChunk(cameraX, self.world.chunkSize, self.world.chunksX)
    local pcz = worldToChunk(cameraZ, self.world.chunkSize, self.world.chunksZ)
    self._lastPlayerChunkX = pcx
    self._lastPlayerChunkZ = pcz

    local seedKeys = self._enqueueScratch
    local seedCount = self.world:enqueueChunkSquare(pcx, pcz, r, minCy, maxCy, seedKeys)
    local enqueued = self.renderer:enqueueMissingKeys(seedKeys, seedCount)
    self:_setEnqueuedMetric(enqueued)

    local target = enqueued
    local cap = tonumber(rebuild.initialBurstMax) or 0
    if cap > 0 then
      target = math.min(target, math.floor(cap))
    end

    local burstMillis = tonumber(rebuild.initialBurstMaxMillis)
    if not burstMillis or burstMillis <= 0 then
      local baseMillis = tonumber(rebuild.maxMillisPerFrame)
      if baseMillis and baseMillis > 0 then
        burstMillis = baseMillis * 4
      end
    end

    self.renderer:rebuildDirty(target, burstMillis)
  end

  self.mode = 'game'
  self.menu:setMode('pause')
  self.mouseLock:unlock()
  self._autosaveTimer = 0
  return true
end

function GameState:load()
  if self._loaded then
    return
  end
  self._loaded = true

  self.relativeMouseReady = tryInitRelativeMouse()

  local perfConfig = self.constants.PERF or {}
  self.showPerfHud = perfConfig.showHud ~= false
  local enqueuedShowSeconds = tonumber(perfConfig.enqueuedShowSeconds)
  if enqueuedShowSeconds and enqueuedShowSeconds > 0 then
    self._enqueuedShowSeconds = enqueuedShowSeconds
  else
    self._enqueuedShowSeconds = 0.5
  end

  local rebuildConfig = self.constants.REBUILD or {}
  local rebuildMaxPerFrame = tonumber(rebuildConfig.maxPerFrame)
  if rebuildMaxPerFrame and rebuildMaxPerFrame > 0 then
    self.rebuildMaxPerFrame = math.floor(rebuildMaxPerFrame)
  else
    self.rebuildMaxPerFrame = nil
  end
  self.rebuildMaxMillisPerFrame = tonumber(rebuildConfig.maxMillisPerFrame)

  self.mouseLock = MouseLock.new()
  self.mouseLock:unlock()

  self.saveSystem = SaveSystem.new()
  self.menu = MainMenu.new()
  self.mode = 'menu'
  self:_refreshSaveState()
end

function GameState:_handleMenuAction(action)
  if not action then
    return
  end

  local menuMode = self.menu:getMode()

  if menuMode == 'main' then
    if action == 'continue' then
      if self._hasSave and self._canContinue then
        self:_startSession(true)
      end
      return
    end

    if action == 'new_game' or action == 'new_game_confirmed' then
      if self._hasSave then
        self.saveSystem:delete()
      end
      self:_refreshSaveState()
      self:_startSession(false)
      return
    end

    if action == 'delete_save_confirmed' then
      self.saveSystem:delete()
      self:_refreshSaveState()
      return
    end

    if action == 'quit' then
      lovr.event.quit()
    end
    return
  end

  if action == 'resume' then
    if self:_hasSession() then
      self.menu:setStatusText(nil)
      self.mode = 'game'
    else
      self.menu:setMode('main')
      self.mode = 'menu'
    end
    return
  end

  if action == 'save' then
    if self.world then
      self:_setSaveStatus('Saving...')
      local ok, reason = self:_saveNow()
      self._autosaveTimer = 0
      self:_refreshSaveState()
      if ok then
        self:_setSaveStatus('World saved')
      else
        local suffix = reason and (': ' .. tostring(reason)) or ''
        self:_setSaveStatus('Save failed' .. suffix)
      end
    end
    return
  end

  if action == 'delete_save_confirmed' then
    self.saveSystem:delete()
    self:_teardownSession()
    self.mode = 'menu'
    self.menu:setMode('main')
    self:_refreshSaveState()
    return
  end

  if action == 'quit' then
    local savedOk = true
    local savedReason = nil
    if self.world then
      self:_setSaveStatus('Saving...')
      savedOk, savedReason = self:_saveNow()
    end
    self:_teardownSession()
    self.mode = 'menu'
    self.menu:setMode('main')
    self:_refreshSaveState()

    if savedOk then
      self.menu:setStatusText('Saved and returned to menu.')
    else
      local suffix = savedReason and (': ' .. tostring(savedReason)) or ''
      self.menu:setStatusText('Auto-save failed' .. suffix)
    end
    return
  end
end

function GameState:_updateMenu()
  local action = self.menu:consumeAction()
  self:_handleMenuAction(action)
end

function GameState:_placePlayerAtRespawn(spawnX, spawnY, spawnZ)
  local player = self.player
  local world = self.world
  if not player or not world then
    return
  end

  player.x = spawnX
  player.y = spawnY
  player.z = spawnZ
  player.yaw = 0
  player.pitch = 0
  player.velocityY = 0
  player.onGround = false

  local maxY = math.max(2, world.sizeY - 1)
  local startY = clamp(spawnY, 2, maxY)
  for offset = 0, 10 do
    local candidateY = startY + offset
    if candidateY > maxY then
      break
    end
    player.y = candidateY
    if not player:_collides(world) then
      return
    end
  end

  player.y = math.min(maxY, startY + 1)
end

function GameState:_handleDeathRespawn()
  if not (self.stats and self.player and self.world) then
    return false
  end
  if not self.stats.isDead or not self.stats:isDead() then
    return false
  end

  local spawnX, spawnY, spawnZ = self.world:getSpawnPoint()
  self:_placePlayerAtRespawn(spawnX, spawnY, spawnZ)
  if self.stats.respawn then
    self.stats:respawn()
  else
    self.stats.health = self.stats.maxHealth or 20
    self.stats.hunger = self.stats.maxHunger or 20
  end

  if self.mobs and self.mobs.onPlayerRespawn then
    self.mobs:onPlayerRespawn(spawnX, spawnY, spawnZ)
  end
  if self.interaction then
    self.interaction.targetHit = nil
  end

  self._lastPlayerChunkX = nil
  self._lastPlayerChunkZ = nil
  self:_setSaveStatus('You died. Respawned.', 2.0)
  return true
end

function GameState:_updateGame(dt)
  if not self:_hasSession() or not self.input then
    self.mode = 'menu'
    self.menu:setMode('main')
    self:_refreshSaveState()
    return
  end

  self:_updateFrameTiming(dt)
  self:_tickEnqueuedMetric(dt)
  if self.world and self.world.setFrameTiming then
    self.world:setFrameTiming(self.frameMs, self.worstFrameMs)
  end

  local dx, dy = self.input:getLookDelta()
  if dx ~= 0 or dy ~= 0 then
    self.player:applyLook(dx, dy)
  end

  local forward, right = self.input:getMoveAxes()
  local wantJump = self.input:consumeJump()

  self.player:update(dt, self.world, {
    forward = forward,
    right = right,
    jump = wantJump
  })

  local cameraX, cameraY, cameraZ = self.player:getCameraPosition()
  self.renderer:setPriorityOriginWorld(cameraX, cameraY, cameraZ)

  local pcx = worldToChunk(cameraX, self.world.chunkSize, self.world.chunksX)
  local pcz = worldToChunk(cameraZ, self.world.chunkSize, self.world.chunksZ)
  local oldPcx = self._lastPlayerChunkX
  local oldPcz = self._lastPlayerChunkZ
  if pcx ~= oldPcx or pcz ~= oldPcz then
    local minCy = self._activeMinChunkY
    local maxCy = self._activeMaxChunkY
    local queueKeys = self._enqueueScratch
    local queueCount = -1
    if oldPcx and oldPcz then
      queueCount = self.world:enqueueRingDelta(oldPcx, oldPcz, pcx, pcz, self._chunkDirtyRadius or 0, minCy, maxCy, queueKeys)
    end
    if queueCount == nil or queueCount < 0 then
      queueCount = self.world:enqueueChunkSquare(pcx, pcz, self._chunkDirtyRadius or 0, minCy, maxCy, queueKeys)
    end

    local enqueued = self.renderer:enqueueMissingKeys(queueKeys, queueCount)
    self:_setEnqueuedMetric(enqueued)

    self._lastPlayerChunkX = pcx
    self._lastPlayerChunkZ = pcz
  end

  local _, daylight = self.sky:update(dt)
  self.sky:applyBackground(daylight)
  local skipMobAi = false
  local mobSkipThreshold = self._mobSkipDirtyQueueAbove or 0
  if mobSkipThreshold > 0 then
    local dirtyQueueSize = self.renderer:getDirtyQueueSize()
    if dirtyQueueSize >= mobSkipThreshold then
      skipMobAi = true
    end
  end
  if self.mobs then
    self.mobs:update(dt, self.sky.timeOfDay, skipMobAi)
  end
  if self.stats then
    self.stats:update(dt)
  end

  if self:_handleDeathRespawn() then
    local respawnCameraX, respawnCameraY, respawnCameraZ = self.player:getCameraPosition()
    self.renderer:setPriorityOriginWorld(respawnCameraX, respawnCameraY, respawnCameraZ)
    self.input:beginFrame()
    return
  end

  self.interaction:updateTarget()
  local lookX, lookY, lookZ = self.player:getLookVector()
  if self.mobs then
    self.mobs:updateTarget(cameraX, cameraY, cameraZ, lookX, lookY, lookZ, self.player.reach)
  end
  if self.input:consumeBreak() then
    local attackedMob = false
    if self.mobs then
      local combat = self.constants.COMBAT or {}
      local handDamage = tonumber(combat.handDamage) or 1
      local swordDamage = tonumber(combat.swordDamage) or 4
      local selectedId = self.inventory and self.inventory:getSelectedBlock() or nil
      local swordId = self.constants.ITEM and self.constants.ITEM.SWORD or nil
      local damage = (selectedId == swordId) and swordDamage or handDamage
      attackedMob = self.mobs:tryAttackTarget(damage)
    end

    if not attackedMob then
      self.interaction:tryBreak()
    end
  end
  if self.input:consumePlace() then
    self.interaction:tryPlace()
  end

  if self.input:consumeToggleHelp() then
    self.showHelp = not self.showHelp
  end

  if self.input:consumeToggleFullscreen() then
    self:_toggleFullscreen()
  end

  if self.input:consumeTogglePerfHud() then
    self.showPerfHud = not self.showPerfHud
  end

  if self.input:consumeOpenMenu() then
    self.mode = 'menu'
    self.menu:setMode('pause')
    if self._saveStatusText and self._saveStatusTimer > 0 then
      self.menu:setStatusText(self._saveStatusText)
    else
      self.menu:setStatusText(nil)
    end
    self.input:onFocus(false)
    self.input:beginFrame()
    return
  end

  self:_updateAutosave(dt)
  if self.world and self.world.updateSkyLight then
    self.world:updateSkyLight()
  end
  self.renderer:rebuildDirty(self.rebuildMaxPerFrame, self.rebuildMaxMillisPerFrame)
  self.input:beginFrame()
end

function GameState:update(dt)
  if not self._loaded then
    self:load()
  end

  self:_tickSaveStatus(dt)

  if self.mode == 'menu' then
    self:_updateMenu()
    return
  end

  self:_updateGame(dt)
end

function GameState:draw(pass)
  if not self._loaded then
    self:load()
  end

  if self.mode == 'menu' then
    self.menu:draw(pass)
    return
  end

  if not self:_hasSession() then
    self.menu:setMode('main')
    self.mode = 'menu'
    self.menu:draw(pass)
    return
  end

  local cameraX, cameraY, cameraZ = self.player:getCameraPosition()
  local cameraOrientation = self.player:getCameraOrientation()
  local fps = 0
  if lovr.timer and lovr.timer.getFPS then
    fps = lovr.timer.getFPS() or 0
  end

  if not self._cameraPosition then
    self._cameraPosition = lovr.math.newVec3(0, 0, 0)
  end
  self._cameraPosition:set(cameraX, cameraY, cameraZ)
  pass:setViewPose(1, self._cameraPosition, cameraOrientation)

  self.sky:draw(pass)
  self.renderer:draw(pass, cameraX, cameraY, cameraZ, cameraOrientation, self.voxelShader, self.sky.timeOfDay)
  if self.mobs then
    self.mobs:draw(pass)
  end
  self.interaction:drawOutline(pass)

  local visibleCount, rebuilds, dirtyDrained, dirtyQueued, rebuildMs, rebuildBudgetMs, pruneScanned, pruneRemoved, prunePendingFlag = self.renderer:getLastFrameStats()
  local dirtyQueue = self.renderer:getDirtyQueueSize()
  local lightStripOps, lightStripPending, lightStripTasks, chunkEnsureScale = 0, 0, 0, 1
  if self.world and self.world.getLightingPerfStats then
    lightStripOps, lightStripPending, lightStripTasks, chunkEnsureScale = self.world:getLightingPerfStats()
  end
  local stats = self.stats
  local mobTargetName = self.mobs and self.mobs:getTargetName() or 'None'
  local blockTargetName = self.interaction:getTargetName()
  local targetName = mobTargetName ~= 'None' and mobTargetName or blockTargetName
  local targetActive = mobTargetName ~= 'None' or self.interaction.targetHit ~= nil

  self.hud:draw(pass, {
    cameraX = cameraX,
    cameraY = cameraY,
    cameraZ = cameraZ,
    cameraOrientation = cameraOrientation,
    timeOfDay = self.sky.timeOfDay,
    targetName = targetName,
    targetActive = targetActive,
    mouseStatusText = self.mouseLock:getStatusText(),
    lightingMode = (self.constants.LIGHTING and self.constants.LIGHTING.mode) or 'off',
    shaderStatusText = self.voxelShader and string.format('On (SkySub %d)', self.voxelShader:getSkySubtract()) or ('Off: ' .. tostring(self._voxelShaderError or 'unavailable')),
    saveStatusText = self._saveStatusText,
    saveStatusTimer = self._saveStatusTimer,
    relativeMouseReady = self.relativeMouseReady,
    meshingMode = self.renderer:getMeshingModeLabel(),
    inventory = self.inventory,
    health = stats and stats.health or 20,
    maxHealth = stats and stats.maxHealth or 20,
    hunger = stats and stats.hunger or 20,
    maxHunger = stats and stats.maxHunger or 20,
    experience = stats and stats.experience or 0,
    level = stats and stats.level or 0,
    showHelp = self.showHelp,
    showPerfHud = self.showPerfHud,
    fps = fps,
    frameMs = self.frameMs,
    worstFrameMs = self.worstFrameMs,
    visibleChunks = visibleCount,
    rebuilds = rebuilds,
    dirtyQueue = dirtyQueue,
    dirtyDrained = dirtyDrained,
    dirtyQueued = dirtyQueued,
    rebuildMs = rebuildMs,
    rebuildBudgetMs = rebuildBudgetMs,
    pruneScanned = pruneScanned,
    pruneRemoved = pruneRemoved,
    prunePending = prunePendingFlag == 1,
    lightStripOps = lightStripOps,
    lightStripPending = lightStripPending,
    lightStripTasks = lightStripTasks,
    chunkEnsureScale = chunkEnsureScale,
    enqueuedCount = self._enqueuedCount,
    enqueuedTimer = self._enqueuedTimer
  })
end

function GameState:_toggleFullscreen()
  local nextState = not readFullscreenState()
  if writeFullscreenState(nextState) then
    lovr.event.restart()
  end
end

function GameState:onQuit()
  if self.world and self.saveSystem then
    self:_saveNow()
  end
  return nil
end

function GameState:onKeyPressed(key)
  if self.mode == 'menu' then
    self.menu:onKeyPressed(key)
  elseif self.input then
    self.input:onKeyPressed(key)
  end
end

function GameState:onKeyReleased(key)
  if self.mode == 'game' and self.input then
    self.input:onKeyReleased(key)
  end
end

function GameState:onMouseMoved(dx, dy)
  if self.mode == 'game' and self.input then
    self.input:onMouseMoved(dx, dy)
  end
end

function GameState:onMousePressed(button)
  if self.mode == 'game' and self.input then
    self.input:onMousePressed(button)
  end
end

function GameState:onWheelMoved(dy)
  if self.mode == 'game' and self.input then
    self.input:onWheelMoved(dy)
  end
end

function GameState:onFocus(focused)
  if self.mode == 'game' and self.input then
    self.input:onFocus(focused)
    return
  end

  if not focused and self.mouseLock then
    self.mouseLock:unlock()
  end
end

return GameState
