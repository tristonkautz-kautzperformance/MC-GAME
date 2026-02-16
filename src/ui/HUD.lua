local HUD = {}
HUD.__index = HUD

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function sanitizeNumber(value, fallback)
  if type(value) ~= 'number' then
    return fallback
  end
  if value ~= value or value == math.huge or value == -math.huge then
    return fallback
  end
  return value
end

local function resetVec3(v, x, y, z)
  if v.set then
    v:set(x, y, z)
  else
    v.x, v.y, v.z = x, y, z
  end
end

function HUD.new(constants)
  local self = setmetatable({}, HUD)
  self.constants = constants

  self._forward = lovr.math.newVec3(0, 0, -1)
  self._right = lovr.math.newVec3(1, 0, 0)
  self._up = lovr.math.newVec3(0, 1, 0)
  self._drawPos = lovr.math.newVec3(0, 0, 0)

  self._lines = {}
  self._linesCount = 0
  self._hudLineCount = 0
  self._hudText = ''
  self._hudTextTimer = 0

  local perf = constants.PERF or {}
  self._hudTextInterval = perf.hudUpdateInterval or 0.10

  self._helpText = table.concat({
    'WASD move  Space jump  LMB attack/break  RMB place',
    'Wheel/1-8 select  Click capture  Tab lock',
    'F3 perf HUD  F11 fullscreen  Esc unlock/menu  F1 help'
  }, '\n')
  self._tipText = 'F1 help  |  F3 perf HUD'
  return self
end

function HUD:_setPoint(baseX, baseY, baseZ, right, up, forward, offsetX, offsetY, offsetZ)
  local depth = offsetZ or 0
  local p = self._drawPos
  p:set(
    baseX + right.x * offsetX + up.x * offsetY + forward.x * depth,
    baseY + right.y * offsetX + up.y * offsetY + forward.y * depth,
    baseZ + right.z * offsetX + up.z * offsetY + forward.z * depth
  )
  return p
end

function HUD:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, x, y, w, h, r, g, b, a, zOffset)
  pass:setColor(r, g, b, a or 1)
  pass:plane(self:_setPoint(baseX, baseY, baseZ, right, up, forward, x, y, zOffset), w, h, orientation)
end

function HUD:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, text, x, y, scale, r, g, b, a, halign, valign, wrap, zOffset)
  pass:setColor(r, g, b, a or 1)
  pass:text(
    text,
    self:_setPoint(baseX, baseY, baseZ, right, up, forward, x, y, zOffset or -0.0012),
    scale,
    orientation,
    wrap or 0,
    halign or 'center',
    valign or 'middle'
  )
end

function HUD:_drawPipRow(pass, orientation, baseX, baseY, baseZ, right, up, forward, centerX, centerY, current, maxValue, pipCount, bgR, bgG, bgB, fillR, fillG, fillB)
  local pips = pipCount or 10
  if pips < 1 then
    pips = 1
  end

  local currentValue = sanitizeNumber(current, 0)
  local maxValueSafe = sanitizeNumber(maxValue, pips * 2)
  if maxValueSafe <= 0 then
    maxValueSafe = pips * 2
  end

  local pipSize = 0.031
  local pipGap = 0.005
  local innerScale = 0.76
  local totalWidth = pips * pipSize + (pips - 1) * pipGap
  local startX = centerX - totalWidth * 0.5 + pipSize * 0.5
  local valuePerPip = maxValueSafe / pips
  if valuePerPip <= 0 then
    valuePerPip = 1
  end

  for i = 1, pips do
    local pipX = startX + (i - 1) * (pipSize + pipGap)
    self:_plane(
      pass,
      orientation,
      baseX,
      baseY,
      baseZ,
      right,
      up,
      forward,
      pipX,
      centerY,
      pipSize,
      pipSize,
      bgR,
      bgG,
      bgB,
      0.92,
      0.0003
    )

    local pipValue = currentValue - (i - 1) * valuePerPip
    local fill = clamp(pipValue / valuePerPip, 0, 1)
    if fill > 0 then
      local fillWidth = pipSize * innerScale * fill
      local fillX = pipX - (pipSize * innerScale - fillWidth) * 0.5
      self:_plane(
        pass,
        orientation,
        baseX,
        baseY,
        baseZ,
        right,
        up,
        forward,
        fillX,
        centerY,
        fillWidth,
        pipSize * innerScale,
        fillR,
        fillG,
        fillB,
        0.98,
        -0.0003
      )
    end
  end
end

function HUD:_drawCrosshair(pass, orientation, baseX, baseY, baseZ, right, up, forward, targeted)
  local innerR, innerG, innerB = 0.95, 0.95, 0.95
  if targeted then
    innerR, innerG, innerB = 1.00, 0.92, 0.35
  end

  local outerThickness = 0.0047
  local innerThickness = 0.0028
  local armLength = 0.0185
  local armGap = 0.0078

  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, armGap + armLength * 0.5, outerThickness, armLength, 0.06, 0.06, 0.07, 0.98, 0.0002)
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, -armGap - armLength * 0.5, outerThickness, armLength, 0.06, 0.06, 0.07, 0.98, 0.0002)
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, armGap + armLength * 0.5, 0, armLength, outerThickness, 0.06, 0.06, 0.07, 0.98, 0.0002)
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, -armGap - armLength * 0.5, 0, armLength, outerThickness, 0.06, 0.06, 0.07, 0.98, 0.0002)

  local innerLength = armLength - 0.0014
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, armGap + innerLength * 0.5, innerThickness, innerLength, innerR, innerG, innerB, 0.98, -0.0003)
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, -armGap - innerLength * 0.5, innerThickness, innerLength, innerR, innerG, innerB, 0.98, -0.0003)
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, armGap + innerLength * 0.5, 0, innerLength, innerThickness, innerR, innerG, innerB, 0.98, -0.0003)
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, -armGap - innerLength * 0.5, 0, innerLength, innerThickness, innerR, innerG, innerB, 0.98, -0.0003)

  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, 0, 0.0040, 0.0040, innerR, innerG, innerB, 0.98, -0.0004)
end

function HUD:_drawHotbar(pass, orientation, baseX, baseY, baseZ, right, up, forward, state)
  local inventory = state.inventory
  local slotCount = self.constants.INVENTORY_SLOT_COUNT or 8
  if inventory and type(inventory.slotCount) == 'number' then
    slotCount = inventory.slotCount
  end
  slotCount = math.max(1, math.floor(slotCount))

  local slotSize = 0.095
  local slotGap = 0.011
  local panelPad = 0.016
  local slotsWidth = slotCount * slotSize + (slotCount - 1) * slotGap
  local panelWidth = slotsWidth + panelPad * 2
  local panelHeight = slotSize + panelPad * 2
  local panelY = -0.600

  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, panelY, panelWidth + 0.008, panelHeight + 0.008, 0.16, 0.18, 0.22, 0.35, 0.0002)
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, panelY, panelWidth, panelHeight, 0.05, 0.06, 0.07, 0.82, 0.0001)

  local selected = 1
  if inventory and inventory.getSelectedIndex then
    selected = inventory:getSelectedIndex()
  end
  selected = math.max(1, math.min(slotCount, selected))

  local startX = -slotsWidth * 0.5 + slotSize * 0.5
  local pulse = 0
  if lovr.timer and lovr.timer.getTime then
    pulse = 0.5 + 0.5 * math.sin(lovr.timer.getTime() * 7.0)
  end

  local selectedName = 'Empty'
  for i = 1, slotCount do
    local slotX = startX + (i - 1) * (slotSize + slotGap)
    local isSelected = i == selected

    if isSelected then
      local glow = 0.75 + pulse * 0.25
      self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, slotX, panelY, slotSize + 0.010, slotSize + 0.010, glow, glow, glow * 0.95, 0.40, -0.0001)
    end

    local bgValue = isSelected and 0.30 or 0.14
    self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, slotX, panelY, slotSize, slotSize, bgValue, bgValue, bgValue, 0.95, 0)

    local slot = inventory and inventory.getSlot and inventory:getSlot(i) or nil
    local info = nil
    if slot and slot.block and slot.count > 0 then
      info = self.constants.BLOCK_INFO[slot.block]
      if isSelected and info and info.name then
        selectedName = info.name
      end
    end

    if info and info.color then
      local c = info.color
      self:_plane(
        pass,
        orientation,
        baseX,
        baseY,
        baseZ,
        right,
        up,
        forward,
        slotX,
        panelY,
        slotSize * 0.62,
        slotSize * 0.62,
        sanitizeNumber(c[1], 0.6),
        sanitizeNumber(c[2], 0.6),
        sanitizeNumber(c[3], 0.6),
        sanitizeNumber(info.alpha, 1),
        -0.0003
      )
    else
      self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, slotX, panelY, slotSize * 0.55, slotSize * 0.55, 0.08, 0.08, 0.09, 0.92, -0.0003)
    end

    self:_text(
      pass,
      orientation,
      baseX,
      baseY,
      baseZ,
      right,
      up,
      forward,
      tostring(i),
      slotX - slotSize * 0.36,
      panelY + slotSize * 0.37,
      0.015,
      0.66,
      0.71,
      0.76,
      0.88,
      'left',
      'top'
    )

    if slot and slot.count and slot.count > 1 then
      self:_text(
        pass,
        orientation,
        baseX,
        baseY,
        baseZ,
        right,
        up,
        forward,
        tostring(slot.count),
        slotX + slotSize * 0.35,
        panelY - slotSize * 0.36,
        0.019,
        0.95,
        0.95,
        0.92,
        0.98,
        'right',
        'bottom'
      )
    end
  end

  self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, selectedName, 0, panelY + panelHeight * 0.90, 0.024, 0.90, 0.92, 0.94, 0.93, 'center', 'middle')
  return panelWidth, panelY, panelHeight
end

function HUD:_drawVitals(pass, orientation, baseX, baseY, baseZ, right, up, forward, state, hotbarWidth, hotbarY, hotbarHeight)
  local health = sanitizeNumber(state.health, 20)
  local maxHealth = sanitizeNumber(state.maxHealth, 20)
  local hunger = sanitizeNumber(state.hunger, 20)
  local maxHunger = sanitizeNumber(state.maxHunger, 20)

  local width = sanitizeNumber(hotbarWidth, 0.80)
  local baseVitalsY = sanitizeNumber(hotbarY, -0.43) + sanitizeNumber(hotbarHeight, 0.12) * 1.00
  local leftCenterX = -width * 0.39
  local rightCenterX = width * 0.39
  local panelW = width * 0.44
  local panelH = 0.086

  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, leftCenterX, baseVitalsY, panelW, panelH, 0.05, 0.06, 0.07, 0.65, 0.0001)
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, rightCenterX, baseVitalsY, panelW, panelH, 0.05, 0.06, 0.07, 0.65, 0.0001)

  self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, 'HP', leftCenterX - panelW * 0.62, baseVitalsY, 0.015, 0.94, 0.70, 0.70, 0.94, 'left', 'middle')
  self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, 'FOOD', rightCenterX - panelW * 0.62, baseVitalsY, 0.015, 0.98, 0.84, 0.66, 0.94, 'left', 'middle')

  self:_drawPipRow(pass, orientation, baseX, baseY, baseZ, right, up, forward, leftCenterX + panelW * 0.12, baseVitalsY, health, maxHealth, 10, 0.20, 0.08, 0.09, 0.92, 0.16, 0.20)
  self:_drawPipRow(pass, orientation, baseX, baseY, baseZ, right, up, forward, rightCenterX + panelW * 0.12, baseVitalsY, hunger, maxHunger, 10, 0.20, 0.16, 0.08, 0.96, 0.60, 0.18)
end

function HUD:_rebuildHudText(state)
  local lines = self._lines
  local prevCount = self._linesCount or 0
  local count = 0

  count = count + 1
  lines[count] = string.format('Day %d%%  |  Target: %s', math.floor((state.timeOfDay or 0) * 100), state.targetName or 'None')
  count = count + 1
  lines[count] = string.format('Mouse: %s  |  Relative: %s', state.mouseStatusText or 'Unknown', state.relativeMouseReady and 'Yes' or 'No')
  count = count + 1
  lines[count] = string.format('Mesh: %s', state.meshingMode or 'Unknown')
  count = count + 1
  lines[count] = string.format('Light: %s  |  Shader: %s', state.lightingMode or 'off', state.shaderStatusText or 'Unknown')

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
    local rebuildBudgetMs = tonumber(state.rebuildBudgetMs) or 0
    local rebuildBudgetText = 'off'
    if rebuildBudgetMs > 0 then
      rebuildBudgetText = string.format('%.2f', rebuildBudgetMs)
    end
    count = count + 1
    lines[count] = string.format(
      'Rebuild: %.2f / %s ms',
      tonumber(state.rebuildMs) or 0,
      rebuildBudgetText
    )
    count = count + 1
    lines[count] = string.format(
      'DirtyIn: %d  Queued: %d',
      math.floor(tonumber(state.dirtyDrained) or 0),
      math.floor(tonumber(state.dirtyQueued) or 0)
    )
    count = count + 1
    lines[count] = string.format(
      'Prune: scanned %d  removed %d  pending %s',
      math.floor(tonumber(state.pruneScanned) or 0),
      math.floor(tonumber(state.pruneRemoved) or 0),
      state.prunePending and 'yes' or 'no'
    )
    if state.lightingMode == 'floodfill' then
      local ensureScale = tonumber(state.chunkEnsureScale) or 1
      local ensureSuffix = ''
      if ensureScale < 0.999 then
        ensureSuffix = string.format('  Ensure x%.2f', ensureScale)
      end
      count = count + 1
      lines[count] = string.format(
        'LightQ: Strip %d  Pending %d  Tasks %d%s',
        math.floor(tonumber(state.lightStripOps) or 0),
        math.floor(tonumber(state.lightStripPending) or 0),
        math.floor(tonumber(state.lightStripTasks) or 0),
        ensureSuffix
      )
    end
    if (state.enqueuedTimer or 0) > 0 then
      count = count + 1
      lines[count] = string.format('Stream: Enqueued %d', state.enqueuedCount or 0)
    end
  end

  for i = count + 1, prevCount do
    lines[i] = nil
  end

  self._linesCount = count
  self._hudLineCount = count
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

  local distance = 1.14
  local baseX = cameraX + forward.x * distance
  local baseY = cameraY + forward.y * distance
  local baseZ = cameraZ + forward.z * distance

  pass:push('state')
  pass:setDepthWrite(false)

  self:_drawCrosshair(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, state.targetActive)

  local targetName = state.targetName or 'None'
  if targetName ~= 'None' then
    self:_plane(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, 0, 0.102, 0.27, 0.047, 0.05, 0.06, 0.07, 0.72, 0.0002)
    self:_text(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, targetName, 0, 0.102, 0.022, 0.96, 0.96, 0.95, 0.96)
  end

  local hotbarWidth, hotbarY, hotbarHeight = self:_drawHotbar(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, state)
  self:_drawVitals(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, state, hotbarWidth, hotbarY, hotbarHeight)

  local debugText = self._hudText
  if debugText ~= '' then
    local panelW = 0.57
    local panelH = 0.024 + self._hudLineCount * 0.028
    local panelX = -0.70
    local panelY = 0.500
    self:_plane(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, panelX, panelY, panelW + 0.008, panelH + 0.008, 0.15, 0.18, 0.22, 0.32, 0.0002)
    self:_plane(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, panelX, panelY, panelW, panelH, 0.05, 0.06, 0.07, 0.74, 0.0001)

    self:_text(
      pass,
      cameraOrientation,
      baseX,
      baseY,
      baseZ,
      right,
      up,
      forward,
      debugText,
      panelX - panelW * 0.5 + 0.012,
      panelY + panelH * 0.5 - 0.012,
      0.018,
      0.93,
      0.95,
      0.96,
      0.97,
      'left',
      'top',
      panelW - 0.020
    )
  end

  if state.showHelp then
    local helpW = 0.57
    local helpH = 0.115
    local helpX = -0.27
    local helpY = -0.030
    self:_plane(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, helpX, helpY, helpW + 0.008, helpH + 0.008, 0.15, 0.18, 0.22, 0.32, 0.0002)
    self:_plane(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, helpX, helpY, helpW, helpH, 0.05, 0.06, 0.07, 0.74, 0.0001)
    self:_text(
      pass,
      cameraOrientation,
      baseX,
      baseY,
      baseZ,
      right,
      up,
      forward,
      self._helpText,
      helpX - helpW * 0.5 + 0.012,
      helpY + helpH * 0.5 - 0.010,
      0.017,
      0.90,
      0.93,
      0.95,
      0.95,
      'left',
      'top',
      helpW - 0.020
    )
  else
    self:_text(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, self._tipText, -0.30, -0.236, 0.016, 0.80, 0.84, 0.88, 0.92, 'left', 'middle')
  end

  if state.saveStatusTimer and state.saveStatusTimer > 0 and state.saveStatusText and state.saveStatusText ~= '' then
    self:_plane(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, 0, 0.285, 0.36, 0.040, 0.11, 0.08, 0.05, 0.78, 0.0001)
    self:_text(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, state.saveStatusText, 0, 0.285, 0.020, 1.00, 0.86, 0.56, 0.98)
  end

  pass:pop('state')
end

return HUD
