local HUD = {}
HUD.__index = HUD

function HUD.new(constants)
  local self = setmetatable({}, HUD)
  self.constants = constants
  return self
end

local function cameraForward(cameraOrientation)
  local forward = lovr.math.vec3(0, 0, -1)
  forward:rotate(cameraOrientation)
  return forward
end

function HUD:draw(pass, state)
  local cameraX = state.cameraX
  local cameraY = state.cameraY
  local cameraZ = state.cameraZ
  local cameraOrientation = state.cameraOrientation

  local forward = cameraForward(cameraOrientation)
  local right = lovr.math.vec3(1, 0, 0)
  right:rotate(cameraOrientation)
  local up = lovr.math.vec3(0, 1, 0)
  up:rotate(cameraOrientation)

  local distance = 1.4
  local baseX = cameraX + forward.x * distance
  local baseY = cameraY + forward.y * distance
  local baseZ = cameraZ + forward.z * distance

  pass:push('state')
  pass:setColor(.98, .98, .95, 1)

  local lines = {
    string.format('Voxel Clone  |  Day %d%%', math.floor((state.timeOfDay or 0) * 100)),
    string.format('Target: %s', state.targetName or 'None'),
    string.format('Mouse: %s  |  Relative: %s', state.mouseStatusText or 'Unknown', state.relativeMouseReady and 'Yes' or 'No'),
    string.format('Mesh: %s', state.meshingMode or 'Unknown')
  }

  if state.showPerfHud ~= false then
    lines[#lines + 1] = string.format('Perf: FPS %d  |  Frame %.2f ms  |  Worst(1s) %.2f ms', math.floor((state.fps or 0) + 0.5), state.frameMs or 0, state.worstFrameMs or 0)
    lines[#lines + 1] = string.format('World: Chunks %d  |  Rebuilds %d  |  Dirty %d', state.visibleChunks or 0, state.rebuilds or 0, state.dirtyQueue or 0)
  end

  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Hotbar'

  local inventory = state.inventory
  if inventory then
    for i = 1, inventory.slotCount do
      local slot = inventory:getSlot(i)
      local label = 'Empty'
      if slot and slot.block and slot.count > 0 then
        local info = self.constants.BLOCK_INFO[slot.block]
        label = string.format('%s x%d', info.name, slot.count)
      end
      local prefix = (i == inventory:getSelectedIndex()) and '>' or ' '
      lines[#lines + 1] = string.format('%s %d: %s', prefix, i, label)
    end
  end

  local text = table.concat(lines, '\n')
  local hudX = baseX - right.x * 0.52 + up.x * 0.34
  local hudY = baseY - right.y * 0.52 + up.y * 0.34
  local hudZ = baseZ - right.z * 0.52 + up.z * 0.34
  pass:text(text, hudX, hudY, hudZ, 0.06, cameraOrientation)

  if state.showHelp then
    local helpX = baseX - right.x * 0.52 - up.x * 0.44
    local helpY = baseY - right.y * 0.52 - up.y * 0.44
    local helpZ = baseZ - right.z * 0.52 - up.z * 0.44
    local help = table.concat({
      'WASD move  Space jump  LMB break  RMB place',
      'Wheel/1-8 select  Click capture  Tab lock',
      'F3 perf HUD  F11 fullscreen  Esc unlock/quit  F1 help'
    }, '\n')
    pass:text(help, helpX, helpY, helpZ, 0.048, cameraOrientation)
  else
    local tipX = baseX - right.x * 0.52 - up.x * 0.44
    local tipY = baseY - right.y * 0.52 - up.y * 0.44
    local tipZ = baseZ - right.z * 0.52 - up.z * 0.44
    pass:text('F1 help  |  F3 perf HUD', tipX, tipY, tipZ, 0.048, cameraOrientation)
  end

  local crossX = cameraX + forward.x * 1.2
  local crossY = cameraY + forward.y * 1.2
  local crossZ = cameraZ + forward.z * 1.2
  pass:text('+', crossX, crossY, crossZ, 0.11, cameraOrientation)

  pass:pop('state')
end

return HUD
