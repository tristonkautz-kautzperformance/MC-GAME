local World = require 'src.world'
local Player = require 'src.player'
local Inventory = require 'src.inventory'
local PlayerStats = require 'src.player.PlayerStats'

local MouseLock = require 'src.input.MouseLock'
local Input = require 'src.input.Input'
local Interaction = require 'src.interaction.Interaction'
local HUD = require 'src.ui.HUD'
local InventoryMenu = require 'src.ui.InventoryMenu'
local Sky = require 'src.sky.Sky'
local MobSystem = require 'src.mobs.MobSystem'
local ItemEntities = require 'src.items.ItemEntities'
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

local function newStackSlotArray(slotCount)
  local slots = {}
  for i = 1, slotCount do
    slots[i] = { block = nil, count = 0, durability = nil }
  end
  return slots
end

local function slotHasStack(slot)
  return slot and slot.block and slot.count and slot.count > 0
end

local function clearStackSlot(slot)
  if not slot then
    return
  end
  slot.block = nil
  slot.count = 0
  slot.durability = nil
end

local function isShiftDown()
  if not (lovr.system and lovr.system.isKeyDown) then
    return false
  end

  return lovr.system.isKeyDown('lshift') or lovr.system.isKeyDown('rshift')
end

local function checkMouseDown(fn)
  if not fn then
    return false
  end

  local ok, down = pcall(fn, 1)
  if ok and down then
    return true
  end

  ok, down = pcall(fn, 'l')
  if ok and down then
    return true
  end

  ok, down = pcall(fn, 'left')
  if ok and down then
    return true
  end

  return false
end

local function isPrimaryMouseDown()
  if lovr.system and checkMouseDown(lovr.system.isMouseDown) then
    return true
  end

  if lovr.mouse and checkMouseDown(lovr.mouse.isDown) then
    return true
  end

  return false
end

local function newStagePerfEntry()
  return {
    frameMs = 0,
    worstMs = 0,
    windowMax = 0,
    windowTime = 0
  }
end

local function getTimerNow()
  if lovr.timer and lovr.timer.getTime then
    return lovr.timer.getTime()
  end
  return nil
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
  self.inventoryMenuUi = nil
  self.sky = nil
  self.mobs = nil
  self.itemEntities = nil
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
  self._simulationChunkRadius = 4
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
  self._hudState = {}
  self._shaderStatusText = nil
  self._shaderStatusSkySubtract = nil
  self._shaderStatusError = nil
  self._mobSkipDirtyQueueAbove = 0

  self.showHelp = false
  self.showPerfHud = true
  self.rebuildMaxPerFrame = nil
  self.rebuildMaxMillisPerFrame = nil
  self.frameMs = 0
  self.worstFrameMs = 0
  self._worstFrameWindowMax = 0
  self._worstFrameWindowTime = 0
  self._stagePerf = {
    updateTotal = newStagePerfEntry(),
    updateSim = newStagePerfEntry(),
    updateLight = newStagePerfEntry(),
    updateRebuild = newStagePerfEntry(),
    drawWorld = newStagePerfEntry(),
    drawRenderer = newStagePerfEntry()
  }
  self._skyLightPassesLastFrame = 0
  self.relativeMouseReady = false
  self.inventoryMenuOpen = false
  self.inventoryMenuMode = 'bag'
  self.inventoryMenuCursorIndex = 1
  self._inventoryMenuReturnLock = false
  self._uiHover = { kind = nil, index = nil, source = nil, outputIndex = nil }
  self._uiMouseInsideMenu = false
  self._uiMenuMouseDebug = 'n/a'

  self.bagCraftSlots = {}
  self.workbenchCraftSlots = {}
  self.craftableOutputs = {}
  self._craftCounts = {}
  self._craftCountKeys = {}
  self._entityRayHitScratch = {}
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

function GameState:_recordStagePerf(name, stageMs, dt)
  local stages = self._stagePerf
  if not stages then
    self._stagePerf = {}
    stages = self._stagePerf
  end

  local entry = stages[name]
  if not entry then
    entry = newStagePerfEntry()
    stages[name] = entry
  end

  local ms = tonumber(stageMs) or 0
  if ms < 0 then
    ms = 0
  end

  entry.frameMs = ms
  if ms > entry.windowMax then
    entry.windowMax = ms
  end
  entry.worstMs = entry.windowMax

  local delta = tonumber(dt) or 0
  if delta < 0 then
    delta = 0
  end
  entry.windowTime = entry.windowTime + delta
  if entry.windowTime >= 1.0 then
    entry.windowTime = entry.windowTime - 1.0
    entry.windowMax = ms
  end
end

function GameState:_getStagePerf(name)
  local stages = self._stagePerf
  local entry = stages and stages[name]
  if not entry then
    return 0, 0
  end

  return tonumber(entry.frameMs) or 0, tonumber(entry.worstMs) or 0
end

function GameState:_recordUpdateStageMetrics(dt, updateStartTime, simMs, lightMs, rebuildMs)
  local totalMs = 0
  local now = getTimerNow()
  if now and updateStartTime then
    totalMs = (now - updateStartTime) * 1000
  end

  self:_recordStagePerf('updateSim', simMs or 0, dt)
  self:_recordStagePerf('updateLight', lightMs or 0, dt)
  self:_recordStagePerf('updateRebuild', rebuildMs or 0, dt)
  self:_recordStagePerf('updateTotal', totalMs, dt)
end

function GameState:_recordDrawStageMetrics(drawWorldMs, drawRendererMs)
  local dt = (tonumber(self.frameMs) or 0) * 0.001
  if dt <= 0 then
    dt = 1 / 60
  end

  self:_recordStagePerf('drawWorld', drawWorldMs or 0, dt)
  self:_recordStagePerf('drawRenderer', drawRendererMs or 0, dt)
end

function GameState:_getShaderStatusText()
  if self.voxelShader then
    local skySubtract = self.voxelShader:getSkySubtract()
    if self._shaderStatusText == nil or self._shaderStatusSkySubtract ~= skySubtract then
      self._shaderStatusSkySubtract = skySubtract
      self._shaderStatusError = nil
      self._shaderStatusText = 'On (SkySub ' .. tostring(skySubtract) .. ')'
    end
    return self._shaderStatusText
  end

  local errorText = tostring(self._voxelShaderError or 'unavailable')
  if self._shaderStatusText == nil or self._shaderStatusError ~= errorText then
    self._shaderStatusSkySubtract = nil
    self._shaderStatusError = errorText
    self._shaderStatusText = 'Off: ' .. errorText
  end
  return self._shaderStatusText
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

function GameState:_getCraftingConfig()
  return self.constants.CRAFTING or {}
end

function GameState:_resetCraftingSlots()
  local crafting = self:_getCraftingConfig()
  local bagCount = math.max(1, math.floor(tonumber(crafting.bagSlotCount) or 2))
  local workbenchCount = math.max(1, math.floor(tonumber(crafting.workbenchSlotCount) or 25))
  self.bagCraftSlots = newStackSlotArray(bagCount)
  self.workbenchCraftSlots = newStackSlotArray(workbenchCount)
  self.craftableOutputs = {}
end

function GameState:_getCraftSlotsForMode(mode)
  if mode == 'workbench' then
    return self.workbenchCraftSlots
  end
  return self.bagCraftSlots
end

function GameState:_getActiveCraftSlots()
  return self:_getCraftSlotsForMode(self.inventoryMenuMode)
end

function GameState:_spawnDroppedStackAt(x, y, z, block, count, durability)
  if not self.itemEntities then
    return 0
  end
  return self.itemEntities:dropStack(x, y, z, block, count, durability)
end

function GameState:_dropStackNearPlayer(block, count, durability)
  if not self.player then
    return
  end

  local lookX, lookY, lookZ = self.player:getLookVector()
  local dropX = self.player.x + lookX * 0.75
  local dropY = self.player.y + self.player.eyeHeight * 0.62
  local dropZ = self.player.z + lookZ * 0.75
  self:_spawnDroppedStackAt(dropX, dropY, dropZ, block, count, durability)
end

function GameState:_dropHeldStackNearPlayer()
  if not (self.inventory and self.inventory.dropHeldStack) then
    return false
  end

  local held = self.inventory:dropHeldStack()
  if not held then
    return false
  end

  self:_dropStackNearPlayer(held.block, held.count, held.durability)
  return true
end

function GameState:_returnCraftSlotsToInventory(slots)
  if not slots or not self.inventory then
    return
  end

  for i = 1, #slots do
    local slot = slots[i]
    if slotHasStack(slot) then
      local added = 0
      if self.inventory.addStack then
        added = self.inventory:addStack(slot.block, slot.count, slot.durability)
      end

      local remaining = slot.count - added
      if remaining > 0 then
        self:_dropStackNearPlayer(slot.block, remaining, slot.durability)
      end
      clearStackSlot(slot)
    end
  end
end

function GameState:_returnAllCraftingItems()
  self:_returnCraftSlotsToInventory(self.bagCraftSlots)
  self:_returnCraftSlotsToInventory(self.workbenchCraftSlots)
end

function GameState:_collectCraftCounts(slots)
  local counts = self._craftCounts
  local keys = self._craftCountKeys

  for i = 1, #keys do
    counts[keys[i]] = nil
    keys[i] = nil
  end

  local keyCount = 0
  for i = 1, #slots do
    local slot = slots[i]
    if slotHasStack(slot) then
      local id = slot.block
      if counts[id] == nil then
        keyCount = keyCount + 1
        keys[keyCount] = id
        counts[id] = slot.count
      else
        counts[id] = counts[id] + slot.count
      end
    end
  end

  return counts
end

function GameState:_refreshCraftableOutputs()
  local crafting = self:_getCraftingConfig()
  local recipes = self.inventoryMenuMode == 'workbench' and (crafting.workbenchRecipes or {}) or (crafting.bagRecipes or {})
  local slots = self:_getActiveCraftSlots()
  local counts = self:_collectCraftCounts(slots)
  local outputs = self.craftableOutputs

  local write = 0
  for i = 1, #recipes do
    local recipe = recipes[i]
    local ingredients = recipe.ingredients or {}
    local fullySatisfied = true
    for blockId, needed in pairs(ingredients) do
      if (counts[blockId] or 0) < needed then
        fullySatisfied = false
        break
      end
    end

    if fullySatisfied then
      write = write + 1
      local out = outputs[write]
      if not out then
        out = {}
        outputs[write] = out
      end

      local output = recipe.output or {}
      local outputId = output.id
      local info = self.constants.BLOCK_INFO[outputId]

      out.recipe = recipe
      out.outputId = outputId
      out.outputCount = math.max(1, math.floor(tonumber(output.count) or 1))
      out.outputDurability = output.durability
      out.name = (info and info.name) or ('Item ' .. tostring(outputId))
    end
  end

  for i = write + 1, #outputs do
    outputs[i] = nil
  end
end

function GameState:_computeIngredientCraftLimit(recipe, counts)
  local ingredients = recipe.ingredients or {}
  local limit = math.huge
  local hasIngredient = false

  for blockId, needed in pairs(ingredients) do
    hasIngredient = true
    local available = counts[blockId] or 0
    local maxByThis = math.floor(available / needed)
    if maxByThis < limit then
      limit = maxByThis
    end
  end

  if not hasIngredient or limit == math.huge then
    return 0
  end
  return math.max(0, limit)
end

function GameState:_computeInventoryCraftLimit(recipe, ingredientLimit)
  if ingredientLimit <= 0 or not self.inventory then
    return 0
  end

  local output = recipe.output or {}
  local outputId = output.id
  if not outputId then
    return 0
  end

  local outputCount = math.max(1, math.floor(tonumber(output.count) or 1))
  local outputDurability = output.durability
  local stackable = self.inventory.isStackable and self.inventory:isStackable(outputId) or true

  if stackable then
    if self.inventory.canAddStack and self.inventory:canAddStack(outputId, outputCount, outputDurability) then
      return ingredientLimit
    end
    return 0
  end

  local emptySlots = self.inventory.countEmptySlots and self.inventory:countEmptySlots() or 0
  local perCraft = outputCount
  if perCraft <= 0 then
    perCraft = 1
  end
  local maxByInventory = math.floor(emptySlots / perCraft)
  if maxByInventory < 0 then
    maxByInventory = 0
  end
  return math.min(ingredientLimit, maxByInventory)
end

function GameState:_consumeRecipeIngredients(slots, ingredients, craftCount)
  if craftCount <= 0 then
    return false
  end

  for _ = 1, craftCount do
    for blockId, needed in pairs(ingredients) do
      local remaining = needed
      for i = 1, #slots do
        local slot = slots[i]
        if remaining <= 0 then
          break
        end
        if slotHasStack(slot) and slot.block == blockId then
          if slot.count > remaining then
            slot.count = slot.count - remaining
            remaining = 0
          else
            remaining = remaining - slot.count
            clearStackSlot(slot)
          end
        end
      end

      if remaining > 0 then
        return false
      end
    end
  end

  return true
end

function GameState:_craftOutputAt(outputIndex, craftMax)
  local outputEntry = self.craftableOutputs[outputIndex]
  if not outputEntry then
    return false
  end

  local recipe = outputEntry.recipe
  if not recipe then
    return false
  end

  local slots = self:_getActiveCraftSlots()
  local counts = self:_collectCraftCounts(slots)
  local ingredientLimit = self:_computeIngredientCraftLimit(recipe, counts)
  if ingredientLimit <= 0 then
    return false
  end

  local desiredCraftCount = craftMax and ingredientLimit or 1
  local craftCount = self:_computeInventoryCraftLimit(recipe, desiredCraftCount)
  if craftCount <= 0 then
    return false
  end

  local ingredients = recipe.ingredients or {}
  if not self:_consumeRecipeIngredients(slots, ingredients, craftCount) then
    return false
  end

  local output = recipe.output or {}
  local outputId = output.id
  local outputCount = math.max(1, math.floor(tonumber(output.count) or 1))
  local outputDurability = output.durability
  local stackable = self.inventory.isStackable and self.inventory:isStackable(outputId) or true

  if stackable then
    local total = outputCount * craftCount
    local added = self.inventory:addStack(outputId, total, outputDurability)
    local remaining = total - added
    if remaining > 0 then
      self:_dropStackNearPlayer(outputId, remaining, outputDurability)
    end
  else
    for _ = 1, craftCount do
      local added = self.inventory:addStack(outputId, outputCount, outputDurability)
      local remaining = outputCount - added
      if remaining > 0 then
        self:_dropStackNearPlayer(outputId, remaining, outputDurability)
      end
    end
  end

  self:_refreshCraftableOutputs()
  return true
end

function GameState:_handleInventoryClick(button)
  if not self.inventory then
    return false
  end

  local hover = self._uiHover
  local clickButton = math.floor(tonumber(button) or 1)
  local handled = false

  if hover and hover.kind == 'inventory_slot' and hover.index then
    local slot = self.inventory:getSlot(hover.index)
    if slot and self.inventory.interactAnySlot then
      handled = self.inventory:interactAnySlot(slot, clickButton)
      if hover.index >= 1 and hover.index <= self.inventory:getHotbarCount() then
        self.inventory:setSelectedIndex(hover.index)
      end
    end
  elseif hover and hover.kind == 'ingredient_slot' and hover.index then
    local ingredientSlots = self:_getCraftSlotsForMode(hover.source)
    local slot = ingredientSlots and ingredientSlots[hover.index] or nil
    if slot and self.inventory.interactAnySlot then
      handled = self.inventory:interactAnySlot(slot, clickButton)
    end
  elseif hover and hover.kind == 'craft_output' and hover.outputIndex and clickButton == 1 then
    handled = self:_craftOutputAt(hover.outputIndex, isShiftDown())
  elseif not self._uiMouseInsideMenu then
    handled = self:_dropHeldStackNearPlayer()
  end

  if handled then
    self:_refreshCraftableOutputs()
  end
  return handled
end

function GameState:_tryConsumeBerry()
  if not (self.inventory and self.stats) then
    return false
  end

  local berryId = self.constants.ITEM and self.constants.ITEM.BERRY or nil
  if not berryId then
    return false
  end

  local selected = self.inventory:getSelectedBlock()
  if selected ~= berryId then
    return false
  end

  local maxHunger = tonumber(self.stats.maxHunger) or 20
  local currentHunger = tonumber(self.stats.hunger) or 0
  if currentHunger >= maxHunger then
    return false
  end

  local restoreAmount = maxHunger * 0.25
  if restoreAmount <= 0 then
    return false
  end

  if not self.inventory:consumeSelected(1) then
    return false
  end

  self.stats.hunger = clamp(currentHunger + restoreAmount, 0, maxHunger)
  return true
end

function GameState:_spawnBlockDrop(blockBreakResult)
  if not (self.itemEntities and blockBreakResult and blockBreakResult.block) then
    return
  end

  local block = blockBreakResult.block
  if block == self.constants.BLOCK.AIR then
    return
  end

  local halfSize = tonumber(self.itemEntities.itemHalfSize) or 0.11
  local groundY = (blockBreakResult.y - 1) + halfSize + 0.01
  self.itemEntities:spawn(block, blockBreakResult.x - 0.5, groundY, blockBreakResult.z - 0.5, 1)
end

function GameState:_spawnAmbientAroundChunk(cx, cz)
  if self.itemEntities and self.itemEntities.spawnAmbientAroundChunk then
    self.itemEntities:spawnAmbientAroundChunk(cx, cz)
  end
end

function GameState:_isEntityHitBlockedByBlock(entityHit, cameraX, cameraY, cameraZ)
  if not (entityHit and entityHit.distance and self.interaction and self.interaction.targetHit) then
    return false
  end

  local blockHit = self.interaction.targetHit
  local blockCenterX = blockHit.x - 0.5
  local blockCenterY = blockHit.y - 0.5
  local blockCenterZ = blockHit.z - 0.5
  local dx = blockCenterX - cameraX
  local dy = blockCenterY - cameraY
  local dz = blockCenterZ - cameraZ
  local blockDistanceSq = dx * dx + dy * dy + dz * dz
  local entityDistanceSq = entityHit.distance * entityHit.distance
  return blockDistanceSq < entityDistanceSq
end

function GameState:_saveNow()
  if not self.saveSystem or not self.world then
    return false, 'missing_session'
  end

  if self.inventory and self.inventory.stowHeldStack then
    local stowed = self.inventory:stowHeldStack()
    if not stowed then
      self:_dropHeldStackNearPlayer()
    end
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
  self.inventoryMenuUi = nil
  self.sky = nil
  self.mobs = nil
  self.itemEntities = nil
  if self.renderer and self.renderer.shutdown then
    self.renderer:shutdown()
  end
  self.renderer = nil
  self.voxelShader = nil
  self._voxelShaderError = nil
  self._shaderStatusText = nil
  self._shaderStatusSkySubtract = nil
  self._shaderStatusError = nil
  self._autosaveTimer = 0
  self._simulationChunkRadius = 4
  self._chunkDirtyRadius = 0
  self._activeMinChunkY = 1
  self._activeMaxChunkY = 1
  self._lastPlayerChunkX = nil
  self._lastPlayerChunkZ = nil
  self._enqueuedCount = 0
  self._enqueuedTimer = 0
  self.inventoryMenuOpen = false
  self.inventoryMenuMode = 'bag'
  self.inventoryMenuCursorIndex = 1
  self._inventoryMenuReturnLock = false
  self._uiHover = { kind = nil, index = nil, source = nil, outputIndex = nil }
  self._uiMouseInsideMenu = false
  self._uiMenuMouseDebug = 'n/a'
  self.bagCraftSlots = {}
  self.workbenchCraftSlots = {}
  self.craftableOutputs = {}

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
    self.constants.INVENTORY_START_COUNT,
    self.constants.HOTBAR_SLOT_COUNT,
    self.constants.BLOCK_INFO
  )
  self:_resetCraftingSlots()
  if savedInventoryState then
    self.inventory:applyState(savedInventoryState)
  end
  self.stats = PlayerStats.new(self.constants.STATS)
  if savedStatsState then
    self.stats:applyState(savedStatsState)
  end

  self.input = Input.new(self.mouseLock, self.inventory)
  if self.input and self.input.setInventoryMenuOpen then
    self.input:setInventoryMenuOpen(false)
  end
  self.inventoryMenuOpen = false
  self.inventoryMenuMode = 'bag'
  self.inventoryMenuCursorIndex = self.inventory:getSelectedIndex()
  self._inventoryMenuReturnLock = false
  self._uiHover = { kind = nil, index = nil, source = nil, outputIndex = nil }
  self._uiMouseInsideMenu = false
  self._uiMenuMouseDebug = 'n/a'
  self:_refreshCraftableOutputs()
  self.interaction = Interaction.new(self.constants, self.world, self.player, self.inventory)
  self.hud = HUD.new(self.constants)
  self.inventoryMenuUi = InventoryMenu.new(self.constants)
  self.sky = Sky.new(self.constants)
  self.mobs = MobSystem.new(self.constants, self.world, self.player, self.stats)
  self.itemEntities = ItemEntities.new(self.constants, self.world)
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
  local okShader, shaderOrErr = pcall(VoxelShader.new, self.constants)
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
    local simulationRadius = tonumber(cull.simulationRadiusChunks) or 4
    -- Locked for now: keep simulation chunk radius fixed at 4 chunks.
    if simulationRadius ~= 4 then
      simulationRadius = 4
    end
    self._simulationChunkRadius = simulationRadius

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
    self:_spawnAmbientAroundChunk(pcx, pcz)

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
      self:_setInventoryMenuOpen(false, true)
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

function GameState:_setInventoryMenuOpen(open, skipRelock, mode)
  local nextState = open and true or false
  local nextMode = mode == 'workbench' and 'workbench' or 'bag'

  if nextState and self.inventoryMenuOpen then
    self.inventoryMenuMode = nextMode
    self:_refreshCraftableOutputs()
    return
  end
  if not nextState and not self.inventoryMenuOpen then
    return
  end

  self.inventoryMenuOpen = nextState
  if self.input and self.input.setInventoryMenuOpen then
    self.input:setInventoryMenuOpen(nextState)
  end

  if nextState then
    self.inventoryMenuMode = nextMode
    self._inventoryMenuReturnLock = (self.mouseLock and self.mouseLock.isLocked and self.mouseLock:isLocked()) and true or false
    self._uiHover = { kind = nil, index = nil, source = nil, outputIndex = nil }
    self._uiMouseInsideMenu = false
    self._uiMenuMouseDebug = 'n/a'
    self:_refreshCraftableOutputs()
    if self.mouseLock then
      self.mouseLock:unlock()
    end
    return
  end

  local shouldRelock = self._inventoryMenuReturnLock and not skipRelock
  self._inventoryMenuReturnLock = false
  self.inventoryMenuMode = 'bag'

  self:_returnAllCraftingItems()
  if self.inventory and self.inventory.stowHeldStack then
    local stowed = self.inventory:stowHeldStack()
    if not stowed then
      self:_dropHeldStackNearPlayer()
    end
  end

  self._uiHover = { kind = nil, index = nil, source = nil, outputIndex = nil }
  self._uiMouseInsideMenu = false
  self._uiMenuMouseDebug = 'n/a'
  self:_refreshCraftableOutputs()

  if shouldRelock and self.mouseLock then
    self.mouseLock:lock()
  end
end

function GameState:_toggleInventoryMenu()
  if not self.inventory then
    return
  end

  if self.inventoryMenuOpen then
    self:_setInventoryMenuOpen(false)
  else
    self:_setInventoryMenuOpen(true, false, 'bag')
  end
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
  local updateStartTime = getTimerNow()
  local simMs = 0
  local lightMs = 0
  local rebuildCallMs = 0
  local simStartTime = nil

  if not self:_hasSession() or not self.input then
    self.mode = 'menu'
    self.menu:setMode('main')
    self:_refreshSaveState()
    self._skyLightPassesLastFrame = 0
    self:_recordUpdateStageMetrics(dt, updateStartTime, simMs, lightMs, rebuildCallMs)
    return
  end

  self:_updateFrameTiming(dt)
  self:_tickEnqueuedMetric(dt)
  if self.world and self.world.setFrameTiming then
    self.world:setFrameTiming(self.frameMs, self.worstFrameMs)
  end

  if self.inventoryMenuOpen and self.input.isInventoryMenuOpen and not self.input:isInventoryMenuOpen() then
    self:_setInventoryMenuOpen(false, true)
  end

  if self.input:consumeToggleInventoryMenu() then
    self:_toggleInventoryMenu()
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

  if self.inventoryMenuOpen then
    self:_refreshCraftableOutputs()
    if self.inventoryMenuUi and self.inventoryMenuUi.update then
      local menuState = {
        inventory = self.inventory,
        inventoryMenuMode = self.inventoryMenuMode,
        bagCraftSlots = self.bagCraftSlots,
        workbenchCraftSlots = self.workbenchCraftSlots,
        craftableOutputs = self.craftableOutputs,
        uiHover = self._uiHover,
        uiMouseInsideMenu = self._uiMouseInsideMenu,
        uiMouseDebug = self._uiMenuMouseDebug
      }
      self.inventoryMenuUi:update(menuState)
      self._uiHover = menuState.uiHover or self._uiHover
      self._uiMouseInsideMenu = menuState.uiMouseInsideMenu == true
      self._uiMenuMouseDebug = menuState.uiMouseDebug or self._uiMenuMouseDebug
    end

    if self.input:consumeInventoryLeftClick() then
      self:_handleInventoryClick(1)
    end
    if self.input:consumeInventoryRightClick() then
      self:_handleInventoryClick(2)
    end

    self.input:consumeOpenMenu()
    self.input:beginFrame()
    self._skyLightPassesLastFrame = 0
    self:_recordUpdateStageMetrics(dt, updateStartTime, simMs, lightMs, rebuildCallMs)
    return
  end
  simStartTime = getTimerNow()

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
    self:_spawnAmbientAroundChunk(pcx, pcz)
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
    self.mobs:update(
      dt,
      self.sky.timeOfDay,
      skipMobAi,
      pcx,
      pcz,
      self._simulationChunkRadius
    )
  end
  if self.stats then
    self.stats:update(dt)
  end
  if self.itemEntities then
    self.itemEntities:update(dt, cameraX, cameraY, cameraZ)
  end

  if self:_handleDeathRespawn() then
    local respawnCameraX, respawnCameraY, respawnCameraZ = self.player:getCameraPosition()
    self.renderer:setPriorityOriginWorld(respawnCameraX, respawnCameraY, respawnCameraZ)
    self.input:beginFrame()
    local simEndTime = getTimerNow()
    if simStartTime and simEndTime then
      simMs = (simEndTime - simStartTime) * 1000
    end
    self._skyLightPassesLastFrame = 0
    self:_recordUpdateStageMetrics(dt, updateStartTime, simMs, lightMs, rebuildCallMs)
    return
  end

  self.interaction:updateTarget()
  local lookX, lookY, lookZ = self.player:getLookVector()
  if self.mobs then
    self.mobs:updateTarget(cameraX, cameraY, cameraZ, lookX, lookY, lookZ, self.player.reach)
  end

  local entityHit = nil
  if self.itemEntities then
    entityHit = self.itemEntities:raycast(
      cameraX,
      cameraY,
      cameraZ,
      lookX,
      lookY,
      lookZ,
      self.player.reach,
      self._entityRayHitScratch
    )
  end
  if entityHit and self:_isEntityHitBlockedByBlock(entityHit, cameraX, cameraY, cameraZ) then
    entityHit = nil
  end

  local attackedMob = false
  if self.input:consumeBreak() then
    if self.mobs then
      local combat = self.constants.COMBAT or {}
      local handDamage = tonumber(combat.handDamage) or 1
      local swordDamage = tonumber(combat.swordDamage) or 4
      local selectedToolType = self.inventory and self.inventory.getSelectedToolType and self.inventory:getSelectedToolType() or nil
      local damage = (selectedToolType == 'sword') and swordDamage or handDamage
      attackedMob = self.mobs:tryAttackTarget(damage)
    end
  end

  local holdingBreak = false
  if self.mouseLock and self.mouseLock.isLocked and self.mouseLock:isLocked() then
    holdingBreak = isPrimaryMouseDown()
  end
  if attackedMob then
    holdingBreak = false
  end

  local brokenBlock = self.interaction:updateBreaking(dt, holdingBreak)
  if brokenBlock then
    self:_spawnBlockDrop(brokenBlock)
  end

  if self.input:consumePlace() then
    local handled = false

    if entityHit then
      if self.itemEntities then
        self.itemEntities:tryPickup(entityHit, self.inventory)
      end
      handled = true
    end

    if not handled then
      local hit = self.interaction.targetHit
      if hit and hit.block == self.constants.BLOCK.WORKBENCH and not isShiftDown() then
        self:_setInventoryMenuOpen(true, false, 'workbench')
        handled = true
      end
    end

    if not handled and self:_tryConsumeBerry() then
      handled = true
    end

    if not handled then
      self.interaction:tryPlace()
    end
  end

  if self.input:consumeOpenMenu() then
    self:_setInventoryMenuOpen(false, true)
    self.mode = 'menu'
    self.menu:setMode('pause')
    if self._saveStatusText and self._saveStatusTimer > 0 then
      self.menu:setStatusText(self._saveStatusText)
    else
      self.menu:setStatusText(nil)
    end
    self.input:onFocus(false)
    self.input:beginFrame()
    local simEndTime = getTimerNow()
    if simStartTime and simEndTime then
      simMs = (simEndTime - simStartTime) * 1000
    end
    self._skyLightPassesLastFrame = 0
    self:_recordUpdateStageMetrics(dt, updateStartTime, simMs, lightMs, rebuildCallMs)
    return
  end

  local simEndTime = getTimerNow()
  if simStartTime and simEndTime then
    simMs = (simEndTime - simStartTime) * 1000
  end

  self:_updateAutosave(dt)
  local rebuildMaxPerFrame = self.rebuildMaxPerFrame
  local rebuildMaxMillisPerFrame = self.rebuildMaxMillisPerFrame
  local skyLightPasses = 0
  local lightStartTime = getTimerNow()
  if self.world and self.world.updateSkyLight then
    local lightingConfig = self.constants.LIGHTING or {}
    local maxSkyLightPasses = math.floor(tonumber(lightingConfig.maxPassesPerFrame) or 1)
    if maxSkyLightPasses < 1 then
      maxSkyLightPasses = 1
    end

    self.world:updateSkyLight(nil, nil, 'main')
    skyLightPasses = skyLightPasses + 1

    local hasUrgentSkyWork = false
    if self.world.hasUrgentSkyLightWork then
      hasUrgentSkyWork = self.world:hasUrgentSkyLightWork() == true
    end

    local hasSkyWork = hasUrgentSkyWork
    if not hasSkyWork and self.world.hasSkyLightWork then
      hasSkyWork = self.world:hasSkyLightWork() == true
    end

    if hasUrgentSkyWork then
      -- Give lighting extra headroom and temporarily throttle meshing when urgent queues are active.
      if skyLightPasses < maxSkyLightPasses then
        self.world:updateSkyLight(nil, nil, 'main')
        skyLightPasses = skyLightPasses + 1
      end
      if rebuildMaxPerFrame ~= nil then
        rebuildMaxPerFrame = math.floor(rebuildMaxPerFrame * 0.25)
        if rebuildMaxPerFrame < 1 then
          rebuildMaxPerFrame = 1
        end
      end
      if rebuildMaxMillisPerFrame ~= nil and rebuildMaxMillisPerFrame > 0 then
        rebuildMaxMillisPerFrame = rebuildMaxMillisPerFrame * 0.5
      end
    elseif hasSkyWork then
      if skyLightPasses < maxSkyLightPasses then
        self.world:updateSkyLight(nil, nil, 'main')
        skyLightPasses = skyLightPasses + 1
      end
      if rebuildMaxPerFrame ~= nil then
        rebuildMaxPerFrame = math.floor(rebuildMaxPerFrame * 0.5)
        if rebuildMaxPerFrame < 1 then
          rebuildMaxPerFrame = 1
        end
      end
      if rebuildMaxMillisPerFrame ~= nil and rebuildMaxMillisPerFrame > 0 then
        rebuildMaxMillisPerFrame = rebuildMaxMillisPerFrame * 0.75
      end
    end
  end

  local lightEndTime = getTimerNow()
  if lightStartTime and lightEndTime then
    lightMs = (lightEndTime - lightStartTime) * 1000
  end
  self._skyLightPassesLastFrame = skyLightPasses

  local rebuildStartTime = getTimerNow()
  self.renderer:rebuildDirty(rebuildMaxPerFrame, rebuildMaxMillisPerFrame)
  local rebuildEndTime = getTimerNow()
  if rebuildStartTime and rebuildEndTime then
    rebuildCallMs = (rebuildEndTime - rebuildStartTime) * 1000
  end

  self.input:beginFrame()
  self:_recordUpdateStageMetrics(dt, updateStartTime, simMs, lightMs, rebuildCallMs)
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
    self:_recordDrawStageMetrics(0, 0)
    return
  end

  if not self:_hasSession() then
    self.menu:setMode('main')
    self.mode = 'menu'
    self.menu:draw(pass)
    self:_recordDrawStageMetrics(0, 0)
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

  local drawWorldMs = 0
  local drawRendererMs = 0
  local drawWorldStartTime = getTimerNow()

  self.sky:draw(pass, cameraX, cameraY, cameraZ, cameraOrientation)
  local drawRendererStartTime = getTimerNow()
  self.renderer:draw(pass, cameraX, cameraY, cameraZ, cameraOrientation, self.voxelShader, self.sky.timeOfDay)
  local drawRendererEndTime = getTimerNow()
  if drawRendererStartTime and drawRendererEndTime then
    drawRendererMs = (drawRendererEndTime - drawRendererStartTime) * 1000
  end
  if self.itemEntities then
    self.itemEntities:draw(pass)
  end
  if self.mobs then
    self.mobs:draw(pass)
  end
  if not self.inventoryMenuOpen then
    self.interaction:drawOutline(pass)
  end

  local drawWorldEndTime = getTimerNow()
  if drawWorldStartTime and drawWorldEndTime then
    drawWorldMs = (drawWorldEndTime - drawWorldStartTime) * 1000
  end
  self:_recordDrawStageMetrics(drawWorldMs, drawRendererMs)

  local visibleCount, rebuilds, dirtyDrained, dirtyQueued, rebuildMs, rebuildBudgetMs, pruneScanned, pruneRemoved, prunePendingFlag = self.renderer:getLastFrameStats()
  local dirtyQueue = self.renderer:getDirtyQueueSize()
  local threadCoreCount, threadWorkerCount, threadTargetWorkers, threadActiveMeshingThreads, threadPoolActive = 1, 0, 0, 1, false
  if self.renderer and self.renderer.getThreadingPerfStats then
    threadCoreCount, threadWorkerCount, threadTargetWorkers, threadActiveMeshingThreads, threadPoolActive = self.renderer:getThreadingPerfStats()
  end
  local threadQueuePrepOps, threadQueuePrepMs, threadQueuePrepDeferred, threadApplyResults, threadApplyMs = 0, 0, 0, 0, 0
  local threadPrepEnsureMs, threadPrepBlockHaloMs, threadPrepSkyHaloMs, threadPrepPackMs, threadPrepPushMs = 0, 0, 0, 0, 0
  if self.renderer and self.renderer.getThreadingFrameStats then
    threadQueuePrepOps, threadQueuePrepMs, threadQueuePrepDeferred, threadApplyResults, threadApplyMs,
      threadPrepEnsureMs, threadPrepBlockHaloMs, threadPrepSkyHaloMs, threadPrepPackMs, threadPrepPushMs = self.renderer:getThreadingFrameStats()
  end
  local lightStripOps, lightStripPending, lightStripTasks, chunkEnsureScale = 0, 0, 0, 1
  local lightUpdateMs, lightRegionMs = 0, 0
  local lightColumnOps, lightDarkOps, lightFloodOps = 0, 0, 0
  local lightQueueSkipColumns, lightQueueSkipDark, lightQueueSkipFlood = 0, 0, 0
  local lightQueueCapColumns, lightQueueCapDark, lightQueueCapFlood = 0, 0, 0
  local lightColumnPartialOps, lightMaxColumnMs, lightMaxDarkMs, lightMaxFloodMs = 0, 0, 0, 0
  local lightUpdateWorstMs, lightRegionWorstMs = 0, 0
  local lightMaxColumnWorstMs, lightMaxDarkWorstMs, lightMaxFloodWorstMs = 0, 0, 0
  local lightColumnPartialOpsWorst, lightFloodCapHits = 0, 0
  local lightEnsureCalls, lightEnsureUpdateMs = 0, 0
  local lightEnsureColumnOps, lightEnsureDarkOps, lightEnsureFloodOps = 0, 0, 0
  if self.world and self.world.getLightingPerfStats then
    lightStripOps, lightStripPending, lightStripTasks, chunkEnsureScale,
      lightUpdateMs, lightRegionMs, lightColumnOps, lightDarkOps, lightFloodOps,
      lightQueueSkipColumns, lightQueueSkipDark, lightQueueSkipFlood,
      lightQueueCapColumns, lightQueueCapDark, lightQueueCapFlood,
      lightColumnPartialOps, lightMaxColumnMs, lightMaxDarkMs, lightMaxFloodMs,
      lightUpdateWorstMs, lightRegionWorstMs,
      lightMaxColumnWorstMs, lightMaxDarkWorstMs, lightMaxFloodWorstMs,
      lightColumnPartialOpsWorst, lightFloodCapHits,
      lightEnsureCalls, lightEnsureUpdateMs,
      lightEnsureColumnOps, lightEnsureDarkOps, lightEnsureFloodOps = self.world:getLightingPerfStats()
  end
  local stats = self.stats
  local mobTargetName = self.mobs and self.mobs:getTargetName() or 'None'
  local entityTargetName = 'None'
  local entityTargetActive = false
  if self.itemEntities and self.player then
    local lookX, lookY, lookZ = self.player:getLookVector()
    local entityHit = self.itemEntities:raycast(
      cameraX,
      cameraY,
      cameraZ,
      lookX,
      lookY,
      lookZ,
      self.player.reach,
      self._entityRayHitScratch
    )
    if entityHit and self:_isEntityHitBlockedByBlock(entityHit, cameraX, cameraY, cameraZ) then
      entityHit = nil
    end
    if entityHit and entityHit.id then
      local info = self.constants.BLOCK_INFO[entityHit.id]
      entityTargetName = info and info.name or 'Item'
      entityTargetActive = true
    end
  end
  local blockTargetName = self.interaction:getTargetName()
  local targetName = blockTargetName
  if entityTargetActive then
    targetName = entityTargetName
  end
  if mobTargetName ~= 'None' then
    targetName = mobTargetName
  end
  local targetActive = mobTargetName ~= 'None' or entityTargetActive or self.interaction.targetHit ~= nil
  local shaderStatusText = self:_getShaderStatusText()
  local updateTotalMs, updateTotalWorstMs = self:_getStagePerf('updateTotal')
  local updateSimMs, updateSimWorstMs = self:_getStagePerf('updateSim')
  local updateLightMs, updateLightWorstMs = self:_getStagePerf('updateLight')
  local updateRebuildMs, updateRebuildWorstMs = self:_getStagePerf('updateRebuild')
  local drawWorldStageMs, drawWorldWorstMs = self:_getStagePerf('drawWorld')
  local drawRendererStageMs, drawRendererWorstMs = self:_getStagePerf('drawRenderer')
  if self.inventoryMenuOpen then
    targetName = 'None'
    targetActive = false
  end

  local hudState = self._hudState
  hudState.cameraX = cameraX
  hudState.cameraY = cameraY
  hudState.cameraZ = cameraZ
  hudState.cameraOrientation = cameraOrientation
  hudState.timeOfDay = self.sky.timeOfDay
  hudState.targetName = targetName
  hudState.targetActive = targetActive
  hudState.mouseStatusText = self.mouseLock:getStatusText()
  hudState.lightingMode = (self.constants.LIGHTING and self.constants.LIGHTING.mode) or 'off'
  hudState.shaderStatusText = shaderStatusText
  hudState.saveStatusText = self._saveStatusText
  hudState.saveStatusTimer = self._saveStatusTimer
  hudState.relativeMouseReady = self.relativeMouseReady
  hudState.meshingMode = self.renderer:getMeshingModeLabel()
  hudState.renderRadiusChunks = tonumber((self.constants.CULL and self.constants.CULL.drawRadiusChunks) or 0) or 0
  hudState.simulationRadiusChunks = tonumber(self._simulationChunkRadius) or 4
  hudState.inventory = self.inventory
  hudState.inventoryMenuOpen = self.inventoryMenuOpen
  hudState.inventoryMenuScreen = self.inventoryMenuOpen and self.inventoryMenuUi ~= nil
  hudState.inventoryMenuMode = self.inventoryMenuMode
  hudState.inventoryMenuCursor = self.inventoryMenuCursorIndex
  hudState.bagCraftSlots = self.bagCraftSlots
  hudState.workbenchCraftSlots = self.workbenchCraftSlots
  hudState.craftableOutputs = self.craftableOutputs
  hudState.uiHover = self._uiHover
  hudState.uiMouseInsideMenu = self._uiMouseInsideMenu
  hudState.uiMenuMouseDebug = self._uiMenuMouseDebug
  hudState.health = stats and stats.health or 20
  hudState.maxHealth = stats and stats.maxHealth or 20
  hudState.hunger = stats and stats.hunger or 20
  hudState.maxHunger = stats and stats.maxHunger or 20
  hudState.experience = stats and stats.experience or 0
  hudState.level = stats and stats.level or 0
  hudState.showHelp = self.showHelp
  hudState.showPerfHud = self.showPerfHud
  hudState.fps = fps
  hudState.frameMs = self.frameMs
  hudState.worstFrameMs = self.worstFrameMs
  hudState.visibleChunks = visibleCount
  hudState.rebuilds = rebuilds
  hudState.dirtyQueue = dirtyQueue
  hudState.dirtyDrained = dirtyDrained
  hudState.dirtyQueued = dirtyQueued
  hudState.rebuildMs = rebuildMs
  hudState.rebuildBudgetMs = rebuildBudgetMs
  hudState.stageUpdateTotalMs = updateTotalMs
  hudState.stageUpdateTotalWorstMs = updateTotalWorstMs
  hudState.stageUpdateSimMs = updateSimMs
  hudState.stageUpdateSimWorstMs = updateSimWorstMs
  hudState.stageUpdateLightMs = updateLightMs
  hudState.stageUpdateLightWorstMs = updateLightWorstMs
  hudState.stageUpdateRebuildMs = updateRebuildMs
  hudState.stageUpdateRebuildWorstMs = updateRebuildWorstMs
  hudState.stageDrawWorldMs = drawWorldStageMs
  hudState.stageDrawWorldWorstMs = drawWorldWorstMs
  hudState.stageDrawRendererMs = drawRendererStageMs
  hudState.stageDrawRendererWorstMs = drawRendererWorstMs
  hudState.skyLightPasses = self._skyLightPassesLastFrame or 0
  hudState.threadCoreCount = threadCoreCount
  hudState.threadWorkerCount = threadWorkerCount
  hudState.threadTargetWorkers = threadTargetWorkers
  hudState.threadActiveMeshingThreads = threadActiveMeshingThreads
  hudState.threadPoolActive = threadPoolActive
  hudState.threadQueuePrepOps = threadQueuePrepOps
  hudState.threadQueuePrepMs = threadQueuePrepMs
  hudState.threadQueuePrepDeferred = threadQueuePrepDeferred
  hudState.threadApplyResults = threadApplyResults
  hudState.threadApplyMs = threadApplyMs
  hudState.threadPrepEnsureMs = threadPrepEnsureMs
  hudState.threadPrepBlockHaloMs = threadPrepBlockHaloMs
  hudState.threadPrepSkyHaloMs = threadPrepSkyHaloMs
  hudState.threadPrepPackMs = threadPrepPackMs
  hudState.threadPrepPushMs = threadPrepPushMs
  hudState.pruneScanned = pruneScanned
  hudState.pruneRemoved = pruneRemoved
  hudState.prunePending = prunePendingFlag == 1
  hudState.lightStripOps = lightStripOps
  hudState.lightStripPending = lightStripPending
  hudState.lightStripTasks = lightStripTasks
  hudState.chunkEnsureScale = chunkEnsureScale
  hudState.lightUpdateMs = lightUpdateMs
  hudState.lightRegionMs = lightRegionMs
  hudState.lightColumnOps = lightColumnOps
  hudState.lightDarkOps = lightDarkOps
  hudState.lightFloodOps = lightFloodOps
  hudState.lightQueueSkipColumns = lightQueueSkipColumns
  hudState.lightQueueSkipDark = lightQueueSkipDark
  hudState.lightQueueSkipFlood = lightQueueSkipFlood
  hudState.lightQueueCapColumns = lightQueueCapColumns
  hudState.lightQueueCapDark = lightQueueCapDark
  hudState.lightQueueCapFlood = lightQueueCapFlood
  hudState.lightColumnPartialOps = lightColumnPartialOps
  hudState.lightMaxColumnMs = lightMaxColumnMs
  hudState.lightMaxDarkMs = lightMaxDarkMs
  hudState.lightMaxFloodMs = lightMaxFloodMs
  hudState.lightUpdateWorstMs = lightUpdateWorstMs
  hudState.lightRegionWorstMs = lightRegionWorstMs
  hudState.lightMaxColumnWorstMs = lightMaxColumnWorstMs
  hudState.lightMaxDarkWorstMs = lightMaxDarkWorstMs
  hudState.lightMaxFloodWorstMs = lightMaxFloodWorstMs
  hudState.lightColumnPartialOpsWorst = lightColumnPartialOpsWorst
  hudState.lightFloodCapHits = lightFloodCapHits
  hudState.lightEnsureCalls = lightEnsureCalls
  hudState.lightEnsureUpdateMs = lightEnsureUpdateMs
  hudState.lightEnsureColumnOps = lightEnsureColumnOps
  hudState.lightEnsureDarkOps = lightEnsureDarkOps
  hudState.lightEnsureFloodOps = lightEnsureFloodOps
  hudState.enqueuedCount = self._enqueuedCount
  hudState.enqueuedTimer = self._enqueuedTimer
  self.hud:draw(pass, hudState)
  self._uiHover = hudState.uiHover or self._uiHover
  self._uiMouseInsideMenu = hudState.uiMouseInsideMenu == true

  if self.inventoryMenuOpen and self.inventoryMenuUi and self.inventoryMenuUi.draw then
    local menuState = {
      inventory = self.inventory,
      inventoryMenuMode = self.inventoryMenuMode,
      bagCraftSlots = self.bagCraftSlots,
      workbenchCraftSlots = self.workbenchCraftSlots,
      craftableOutputs = self.craftableOutputs,
      uiHover = self._uiHover,
      uiMouseInsideMenu = self._uiMouseInsideMenu,
      uiMouseDebug = self._uiMenuMouseDebug
    }
    self.inventoryMenuUi:draw(pass, menuState)
    self._uiHover = menuState.uiHover or self._uiHover
    self._uiMouseInsideMenu = menuState.uiMouseInsideMenu == true
    self._uiMenuMouseDebug = menuState.uiMouseDebug or self._uiMenuMouseDebug
  end
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
    if not focused and self.inventoryMenuOpen then
      self:_setInventoryMenuOpen(false, true)
    end
    return
  end

  if not focused and self.mouseLock then
    self.mouseLock:unlock()
  end
end

return GameState
