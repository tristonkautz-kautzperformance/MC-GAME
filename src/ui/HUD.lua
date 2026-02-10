local HUD = {}
HUD.__index = HUD

function HUD.new(constants)
  local self = setmetatable({}, HUD)
  self.constants = constants

  self._forward = lovr.math.newVec3(0, 0, -1)
  self._right = lovr.math.newVec3(1, 0, 0)
  self._up = lovr.math.newVec3(0, 1, 0)

  self._lines = {}
  self._linesCount = 0
  self._hudText = ''
  self._hudTextTimer = 0

  local perf = constants.PERF or {}
  self._hudTextInterval = perf.hudUpdateInterval or 0.10

  self._helpText = table.concat({
    'WASD move  Space jump  LMB break  RMB place',
    'Wheel/1-8 select  Click capture  Tab lock',
    'F3 perf HUD  F11 fullscreen  Esc unlock/quit  F1 help'
  }, '\n')
  self._tipText = 'F1 help  |  F3 perf HUD'
  return self
end

local function resetVec3(v, x, y, z)
  if v.set then
    v:set(x, y, z)
  else
    v.x, v.y, v.z = x, y, z
  end
end

function HUD:_rebuildHudText(state)
  local lines = self._lines
  local prevCount = self._linesCount or 0
  local count = 0

  count = count + 1
  lines[count] = string.format('Voxel Clone  |  Day %d%%', math.floor((state.timeOfDay or 0) * 100))
  count = count + 1
  lines[count] = string.format('Target: %s', state.targetName or 'None')
  count = count + 1
  lines[count] = string.format('Mouse: %s  |  Relative: %s', state.mouseStatusText or 'Unknown', state.relativeMouseReady and 'Yes' or 'No')
  count = count + 1
  lines[count] = string.format('Mesh: %s', state.meshingMode or 'Unknown')

  if state.showPerfHud ~= false then
    count = count + 1
    lines[count] = string.format(
      'Perf: FPS %d  |  Frame %.2f ms  |  Worst(1s) %.2f ms',
      math.floor((state.fps or 0) + 0.5),
      state.frameMs or 0,
      state.worstFrameMs or 0
    )
    count = count + 1
    lines[count] = string.format(
      'World: Chunks %d  |  Rebuilds %d  |  Dirty %d',
      state.visibleChunks or 0,
      state.rebuilds or 0,
      state.dirtyQueue or 0
    )
  end

  count = count + 1
  lines[count] = ''
  count = count + 1
  lines[count] = 'Hotbar'

  local inventory = state.inventory
  if inventory then
    for i = 1, inventory.slotCount do
      local slot = inventory:getSlot(i)
      local label = 'Empty'
      if slot and slot.block and slot.count > 0 then
        local info = self.constants.BLOCK_INFO[slot.block]
        label = string.format('%s x%d', (info and info.name) or 'Unknown', slot.count)
      end
      local prefix = (i == inventory:getSelectedIndex()) and '>' or ' '
      count = count + 1
      lines[count] = string.format('%s %d: %s', prefix, i, label)
    end
  end

  for i = count + 1, prevCount do
    lines[i] = nil
  end
  self._linesCount = count
  self._hudText = table.concat(lines, '\n', 1, count)
end

function HUD:draw(pass, state)
  local cameraX = state.cameraX
  local cameraY = state.cameraY
  local cameraZ = state.cameraZ
  local cameraOrientation = state.cameraOrientation

  local dt = ((state.frameMs or 0) * 0.001)
  local interval = self._hudTextInterval or 0
  if interval <= 0 then
    self:_rebuildHudText(state)
  else
    self._hudTextTimer = (self._hudTextTimer or 0) + dt
    if self._hudTextTimer >= interval or self._hudText == '' then
      self._hudTextTimer = self._hudTextTimer - interval
      self:_rebuildHudText(state)
    end
  end

  local forward = self._forward
  resetVec3(forward, 0, 0, -1)
  forward:rotate(cameraOrientation)
  local right = self._right
  resetVec3(right, 1, 0, 0)
  right:rotate(cameraOrientation)
  local up = self._up
  resetVec3(up, 0, 1, 0)
  up:rotate(cameraOrientation)

  local distance = 1.4
  local baseX = cameraX + forward.x * distance
  local baseY = cameraY + forward.y * distance
  local baseZ = cameraZ + forward.z * distance

  pass:push('state')
  pass:setColor(.98, .98, .95, 1)

  local text = self._hudText
  local hudX = baseX - right.x * 0.52 + up.x * 0.34
  local hudY = baseY - right.y * 0.52 + up.y * 0.34
  local hudZ = baseZ - right.z * 0.52 + up.z * 0.34
  pass:text(text, hudX, hudY, hudZ, 0.06, cameraOrientation)

  if state.showHelp then
    local helpX = baseX - right.x * 0.52 - up.x * 0.44
    local helpY = baseY - right.y * 0.52 - up.y * 0.44
    local helpZ = baseZ - right.z * 0.52 - up.z * 0.44
    pass:text(self._helpText, helpX, helpY, helpZ, 0.048, cameraOrientation)
  else
    local tipX = baseX - right.x * 0.52 - up.x * 0.44
    local tipY = baseY - right.y * 0.52 - up.y * 0.44
    local tipZ = baseZ - right.z * 0.52 - up.z * 0.44
    pass:text(self._tipText, tipX, tipY, tipZ, 0.048, cameraOrientation)
  end

  local crossX = cameraX + forward.x * 1.2
  local crossY = cameraY + forward.y * 1.2
  local crossZ = cameraZ + forward.z * 1.2
  pass:text('+', crossX, crossY, crossZ, 0.11, cameraOrientation)

  pass:pop('state')
end

return HUD
