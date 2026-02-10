local World = require 'src.world'
local Player = require 'src.player'
local Inventory = require 'src.inventory'

local MouseLock = require 'src.input.MouseLock'
local Input = require 'src.input.Input'
local Interaction = require 'src.interaction.Interaction'
local HUD = require 'src.ui.HUD'
local Sky = require 'src.sky.Sky'
local ChunkRenderer = require 'src.render.ChunkRenderer'

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

function GameState.new(constants)
  local self = setmetatable({}, GameState)
  self.constants = constants

  self.world = nil
  self.player = nil
  self.inventory = nil

  self.mouseLock = nil
  self.input = nil
  self.interaction = nil
  self.hud = nil
  self.sky = nil
  self.renderer = nil

  self.showHelp = false
  self.showPerfHud = true
  self.rebuildMaxPerFrame = 3
  self.frameMs = 0
  self.worstFrameMs = 0
  self._worstFrameWindowMax = 0
  self._worstFrameWindowTime = 0
  self.relativeMouseReady = false
  self._loaded = false

  return self
end

local function tryInitRelativeMouse()
  -- Vendored module sets `lovr.mouse` for relative input + visibility.
  local ok, mouse = pcall(require, 'lovr-mouse')
  if ok and type(mouse) == 'table' then
    lovr.mouse = mouse
    return true
  end

  if ok and lovr.mouse and lovr.mouse.setRelativeMode then
    return true
  end

  -- Fallback: define a tiny stub so MouseLock doesn't explode.  Relative mode won't work.
  if not lovr.mouse then
    lovr.mouse = {
      setRelativeMode = function() end,
      setVisible = function() end
    }
  end

  return false
end

function GameState:load()
  if self._loaded then
    return
  end
  self._loaded = true

  self.relativeMouseReady = tryInitRelativeMouse()

  local perfConfig = self.constants.PERF or {}
  self.showPerfHud = perfConfig.showHud ~= false

  local rebuildConfig = self.constants.REBUILD or {}
  self.rebuildMaxPerFrame = rebuildConfig.maxPerFrame or 3

  self.world = World.new(self.constants)
  self.world:generate()

  local spawnX, spawnY, spawnZ = self.world:getSpawnPoint()
  self.player = Player.new(self.constants.PLAYER, spawnX, spawnY, spawnZ)

  self.inventory = Inventory.new(self.constants.HOTBAR_DEFAULTS, self.constants.INVENTORY_SLOT_COUNT, self.constants.INVENTORY_START_COUNT)

  self.mouseLock = MouseLock.new()
  self.input = Input.new(self.mouseLock, self.inventory)
  self.interaction = Interaction.new(self.constants, self.world, self.player, self.inventory)
  self.hud = HUD.new(self.constants)
  self.sky = Sky.new(self.constants)
  self.renderer = ChunkRenderer.new(self.constants, self.world)

  local cameraX, cameraY, cameraZ = self.player:getCameraPosition()
  self.renderer:setPriorityOriginWorld(cameraX, cameraY, cameraZ)

  -- Build initial meshes.
  self.renderer:rebuildDirty(999)
end

function GameState:update(dt)
  if not self._loaded then
    self:load()
  end

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

  local timeOfDay, daylight = self.sky:update(dt)
  self.sky:applyBackground(daylight)

  self.interaction:updateTarget()
  if self.input:consumeBreak() then
    self.interaction:tryBreak()
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

  if self.input:consumeQuit() then
    lovr.event.quit()
  end

  -- Keep rebuild work bounded to avoid spikes.
  self.renderer:rebuildDirty(self.rebuildMaxPerFrame)

  self.input:beginFrame()
end

function GameState:draw(pass)
  if not self._loaded then
    self:load()
  end

  local cameraX, cameraY, cameraZ = self.player:getCameraPosition()
  local cameraOrientation = self.player:getCameraOrientation()
  local fps = 0
  if lovr.timer and lovr.timer.getFPS then
    fps = lovr.timer.getFPS() or 0
  end

  pass:setViewPose(1, lovr.math.vec3(cameraX, cameraY, cameraZ), cameraOrientation)

  self.sky:draw(pass)
  self.renderer:draw(pass, cameraX, cameraY, cameraZ, cameraOrientation)
  self.interaction:drawOutline(pass)

  local visibleCount, rebuilds = self.renderer:getLastFrameStats()
  local dirtyQueue = self.renderer:getDirtyQueueSize()
  self.hud:draw(pass, {
    cameraX = cameraX,
    cameraY = cameraY,
    cameraZ = cameraZ,
    cameraOrientation = cameraOrientation,
    timeOfDay = self.sky.timeOfDay,
    targetName = self.interaction:getTargetName(),
    mouseStatusText = self.mouseLock:getStatusText(),
    relativeMouseReady = self.relativeMouseReady,
    meshingMode = self.renderer:getMeshingModeLabel(),
    inventory = self.inventory,
    showHelp = self.showHelp,
    showPerfHud = self.showPerfHud,
    fps = fps,
    frameMs = self.frameMs,
    worstFrameMs = self.worstFrameMs,
    visibleChunks = visibleCount,
    rebuilds = rebuilds,
    dirtyQueue = dirtyQueue
  })
end

function GameState:_toggleFullscreen()
  local nextState = not readFullscreenState()
  if writeFullscreenState(nextState) then
    lovr.event.restart()
  end
end

function GameState:onKeyPressed(key)
  self.input:onKeyPressed(key)
end

function GameState:onKeyReleased(key)
  self.input:onKeyReleased(key)
end

function GameState:onMouseMoved(dx, dy)
  self.input:onMouseMoved(dx, dy)
end

function GameState:onMousePressed(button)
  self.input:onMousePressed(button)
end

function GameState:onWheelMoved(dy)
  self.input:onWheelMoved(dy)
end

function GameState:onFocus(focused)
  self.input:onFocus(focused)
end

return GameState
