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

local function isFiniteNumber(value)
  return type(value) == 'number'
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function resetVec3(v, x, y, z)
  if v.set then
    v:set(x, y, z)
  else
    v.x, v.y, v.z = x, y, z
  end
end

local function getMouseAndWindowSpace()
  local hasLovrMouse = lovr.mouse and lovr.mouse.getPosition
  local hasSystemMouse = lovr.system and lovr.system.getMousePosition
  local hasWindowPx = lovr.system and lovr.system.getWindowWidth and lovr.system.getWindowHeight
  local hasWindowDims = lovr.system and lovr.system.getWindowDimensions

  if hasLovrMouse then
    local mx, my = lovr.mouse.getPosition()
    -- lovr-mouse can report framebuffer-scaled coordinates; pair with pixel window size first.
    if hasWindowPx then
      return mx, my, lovr.system.getWindowWidth(), lovr.system.getWindowHeight()
    end
    if hasWindowDims then
      return mx, my, lovr.system.getWindowDimensions()
    end
    return mx, my, nil, nil
  end

  if hasSystemMouse then
    local mx, my = lovr.system.getMousePosition()
    if hasWindowDims then
      return mx, my, lovr.system.getWindowDimensions()
    end
    if hasWindowPx then
      return mx, my, lovr.system.getWindowWidth(), lovr.system.getWindowHeight()
    end
    return mx, my, nil, nil
  end

  return nil, nil, nil, nil
end

local function getInventoryCounts(inventory, fallbackHotbar)
  local defaultHotbar = math.max(1, math.floor(tonumber(fallbackHotbar) or 8))
  local totalSlots = defaultHotbar
  if inventory and type(inventory.slotCount) == 'number' then
    totalSlots = math.max(1, math.floor(inventory.slotCount))
  end

  local hotbarCount = defaultHotbar
  if inventory and inventory.getHotbarCount then
    hotbarCount = math.floor(tonumber(inventory:getHotbarCount()) or defaultHotbar)
  end
  hotbarCount = clamp(hotbarCount, 1, totalSlots)

  local storageCount = math.max(0, totalSlots - hotbarCount)
  return hotbarCount, totalSlots, storageCount
end

local function areViewAnglesValid(leftAngle, rightAngle, upAngle, downAngle)
  return isFiniteNumber(leftAngle)
    and isFiniteNumber(rightAngle)
    and isFiniteNumber(upAngle)
    and isFiniteNumber(downAngle)
    and leftAngle < 0
    and rightAngle > 0
    and upAngle > 0
    and downAngle < 0
    and leftAngle < rightAngle
    and downAngle < upAngle
    and math.abs(leftAngle) < 1.56
    and math.abs(rightAngle) < 1.56
    and math.abs(upAngle) < 1.56
    and math.abs(downAngle) < 1.56
end

local function areTanFrustumValid(leftTan, rightTan, upTan, downTan)
  return isFiniteNumber(leftTan)
    and isFiniteNumber(rightTan)
    and isFiniteNumber(upTan)
    and isFiniteNumber(downTan)
    and leftTan < 0
    and rightTan > 0
    and upTan > 0
    and downTan < 0
    and leftTan < rightTan
    and downTan < upTan
    and math.abs(leftTan) < 50
    and math.abs(rightTan) < 50
    and math.abs(upTan) < 50
    and math.abs(downTan) < 50
end

local function coerceViewAngles(leftAngle, rightAngle, upAngle, downAngle)
  if areViewAnglesValid(leftAngle, rightAngle, upAngle, downAngle) then
    return leftAngle, rightAngle, upAngle, downAngle
  end

  if not (isFiniteNumber(leftAngle) and isFiniteNumber(rightAngle) and isFiniteNumber(upAngle) and isFiniteNumber(downAngle)) then
    return nil
  end
  if not (leftAngle < 0 and rightAngle > 0 and upAngle > 0 and downAngle < 0) then
    return nil
  end

  local maxAbs = math.max(math.abs(leftAngle), math.abs(rightAngle), math.abs(upAngle), math.abs(downAngle))
  if maxAbs > math.pi and maxAbs <= 180 then
    local degToRad = math.pi / 180
    local l = leftAngle * degToRad
    local r = rightAngle * degToRad
    local u = upAngle * degToRad
    local d = downAngle * degToRad
    if areViewAnglesValid(l, r, u, d) then
      return l, r, u, d
    end
  end

  return nil
end

local function anglesToTanFrustum(leftAngle, rightAngle, upAngle, downAngle)
  leftAngle, rightAngle, upAngle, downAngle = coerceViewAngles(leftAngle, rightAngle, upAngle, downAngle)
  if not leftAngle then
    return nil
  end

  local leftTan = math.tan(leftAngle)
  local rightTan = math.tan(rightAngle)
  local upTan = math.tan(upAngle)
  local downTan = math.tan(downAngle)
  if not areTanFrustumValid(leftTan, rightTan, upTan, downTan) then
    return nil
  end

  return leftTan, rightTan, upTan, downTan
end

local function projectionToTanFrustum(projection)
  local leftValue = tonumber(projection[1])
  local rightValue = tonumber(projection[2])
  local upValue = tonumber(projection[3])
  local downValue = tonumber(projection[4])
  if not leftValue or not rightValue or not upValue or not downValue then
    return nil
  end

  local nearValue = tonumber(projection[5])
  if nearValue and nearValue > 1e-6 then
    local leftTan = leftValue / nearValue
    local rightTan = rightValue / nearValue
    local upTan = upValue / nearValue
    local downTan = downValue / nearValue
    if areTanFrustumValid(leftTan, rightTan, upTan, downTan) then
      return leftTan, rightTan, upTan, downTan, 'pass.getProjection.frustum'
    end
  end

  local leftTan, rightTan, upTan, downTan = anglesToTanFrustum(leftValue, rightValue, upValue, downValue)
  if leftTan then
    return leftTan, rightTan, upTan, downTan, 'pass.getProjection.angles'
  end

  if areTanFrustumValid(leftValue, rightValue, upValue, downValue) then
    return leftValue, rightValue, upValue, downValue, 'pass.getProjection.tangent'
  end

  return nil
end

local function projectionAnglesFromMatrix(values, offsetXIndex, offsetYIndex)
  local m00 = tonumber(values[1])
  local m11 = tonumber(values[6])
  local m02 = tonumber(values[offsetXIndex]) or 0
  local m12 = tonumber(values[offsetYIndex]) or 0
  if not m00 or not m11 or math.abs(m00) < 1e-6 or math.abs(m11) < 1e-6 then
    return nil
  end

  local tanLeft = (-1 - m02) / m00
  local tanRight = (1 - m02) / m00
  local tanDown = (-1 - m12) / m11
  local tanUp = (1 - m12) / m11

  if not isFiniteNumber(tanLeft)
    or not isFiniteNumber(tanRight)
    or not isFiniteNumber(tanUp)
    or not isFiniteNumber(tanDown) then
    return nil
  end

  local leftAngle = math.atan(tanLeft)
  local rightAngle = math.atan(tanRight)
  local upAngle = math.atan(tanUp)
  local downAngle = math.atan(tanDown)
  if not areViewAnglesValid(leftAngle, rightAngle, upAngle, downAngle) then
    return nil
  end

  return leftAngle, rightAngle, upAngle, downAngle
end

local function resolveViewAngles(pass, width, height, constants)
  if pass then
    if pass.getViewAngles then
      local leftAngle, rightAngle, upAngle, downAngle = pass:getViewAngles(1)
      local leftTan, rightTan, upTan, downTan = anglesToTanFrustum(leftAngle, rightAngle, upAngle, downAngle)
      if leftTan then
        return leftTan, rightTan, upTan, downTan, 'pass.getViewAngles'
      end
    end

    if pass.getProjection then
      local projection = { pass:getProjection(1) }
      if #projection >= 4 then
        local leftTan, rightTan, upTan, downTan, source = projectionToTanFrustum(projection)
        if leftTan then
          return leftTan, rightTan, upTan, downTan, source
        end
      end

      local projectionMatrix = nil
      if #projection >= 16 then
        projectionMatrix = projection
      elseif #projection == 1 and projection[1] and projection[1].unpack then
        local ok, unpacked = pcall(function()
          return { projection[1]:unpack() }
        end)
        if ok and unpacked and #unpacked >= 16 then
          projectionMatrix = unpacked
        end
      end

      if projectionMatrix then
        local leftAngle, rightAngle, upAngle, downAngle = projectionAnglesFromMatrix(projectionMatrix, 9, 10)
        if areViewAnglesValid(leftAngle, rightAngle, upAngle, downAngle) then
          local leftTan, rightTan, upTan, downTan = anglesToTanFrustum(leftAngle, rightAngle, upAngle, downAngle)
          if leftTan then
            return leftTan, rightTan, upTan, downTan, 'projectionMatrix(9,10)'
          end
        end

        leftAngle, rightAngle, upAngle, downAngle = projectionAnglesFromMatrix(projectionMatrix, 3, 7)
        if areViewAnglesValid(leftAngle, rightAngle, upAngle, downAngle) then
          local leftTan, rightTan, upTan, downTan = anglesToTanFrustum(leftAngle, rightAngle, upAngle, downAngle)
          if leftTan then
            return leftTan, rightTan, upTan, downTan, 'projectionMatrix(3,7)'
          end
        end
      end
    end
  end

  if lovr.headset and lovr.headset.getViewAngles then
    local leftAngle, rightAngle, upAngle, downAngle = lovr.headset.getViewAngles(1)
    local leftTan, rightTan, upTan, downTan = anglesToTanFrustum(leftAngle, rightAngle, upAngle, downAngle)
    if leftTan then
      return leftTan, rightTan, upTan, downTan, 'headset.getViewAngles'
    end
  end

  local cull = (constants and constants.CULL) or {}
  local fovDegrees = tonumber(cull.fovDegrees) or 90
  fovDegrees = clamp(fovDegrees, 50, 130)
  local halfVertical = math.rad(fovDegrees) * 0.5
  local aspect = width / height
  local halfHorizontal = math.atan(math.tan(halfVertical) * aspect)
  return -math.tan(halfHorizontal), math.tan(halfHorizontal), math.tan(halfVertical), -math.tan(halfVertical), 'constants.fallback'
end

function HUD.new(constants)
  local self = setmetatable({}, HUD)
  self.constants = constants
  self._hudDistance = 1.14

  self._forward = lovr.math.newVec3(0, 0, -1)
  self._right = lovr.math.newVec3(1, 0, 0)
  self._up = lovr.math.newVec3(0, 1, 0)
  self._drawPos = lovr.math.newVec3(0, 0, 0)

  self._lines = {}
  self._linesCount = 0
  self._hudLineCount = 0
  self._hudText = ''
  self._hudTextTimer = 0
  self._uiRayDebug = 'n/a'

  local perf = constants.PERF or {}
  self._hudTextInterval = perf.hudUpdateInterval or 0.10

  self._helpText = table.concat({
    'WASD move  Space jump  Hold LMB break',
    'RMB: pickup/workbench/berry/place  Wheel/1-8 select',
    'Bag/Workbench: LMB move stack  RMB split/place-1',
    'Shift+RMB on workbench places block normally',
    'F3 perf HUD  F11 fullscreen  Esc unlock/menu  F1 help'
  }, '\n')
  self._tipText = 'F1 help  |  F3 perf HUD  |  Tab bag'
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
  local defaultHotbar = self.constants.HOTBAR_SLOT_COUNT or self.constants.INVENTORY_SLOT_COUNT or 8
  local slotCount = getInventoryCounts(inventory, defaultHotbar)
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
    elseif slot and slot.durability and slot.durability > 0 then
      self:_text(
        pass,
        orientation,
        baseX,
        baseY,
        baseZ,
        right,
        up,
        forward,
        tostring(math.floor(slot.durability)),
        slotX + slotSize * 0.35,
        panelY - slotSize * 0.36,
        0.014,
        0.96,
        0.82,
        0.58,
        0.98,
        'right',
        'bottom'
      )
    end
  end

  self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, selectedName, 0, panelY + panelHeight * 0.90, 0.024, 0.90, 0.92, 0.94, 0.93, 'center', 'middle')
  return panelWidth, panelY, panelHeight
end

function HUD:_buildMouseRay(pass, panelY, panelWidth, panelHeight, outRay)
  local mouseSamples = {}
  local mouseSampleCount = 0
  if lovr.mouse and lovr.mouse.getPosition then
    local mx, my = lovr.mouse.getPosition()
    if mx and my then
      mouseSampleCount = mouseSampleCount + 1
      mouseSamples[mouseSampleCount] = { x = mx, y = my, source = 'lovr.mouse' }
    end
  end
  if lovr.system and lovr.system.getMousePosition then
    local mx, my = lovr.system.getMousePosition()
    if mx and my then
      mouseSampleCount = mouseSampleCount + 1
      mouseSamples[mouseSampleCount] = { x = mx, y = my, source = 'lovr.system' }
    end
  end
  if mouseSampleCount == 0 then
    self._uiRayDebug = 'invalid.mouse'
    return false
  end

  local dims = {}
  local dimCount = 0
  local function pushDims(w, h, label)
    w, h = tonumber(w), tonumber(h)
    if not w or not h or w <= 0 or h <= 0 then
      return
    end
    for i = 1, dimCount do
      local d = dims[i]
      if math.abs(d.w - w) < 0.5 and math.abs(d.h - h) < 0.5 then
        return
      end
    end
    dimCount = dimCount + 1
    dims[dimCount] = { w = w, h = h, label = label }
  end

  if pass and pass.getDimensions then
    pushDims(pass:getDimensions(), 'passDims')
  end
  if lovr.system then
    if lovr.system.getWindowWidth and lovr.system.getWindowHeight then
      pushDims(lovr.system.getWindowWidth(), lovr.system.getWindowHeight(), 'windowPx')
    end
    if lovr.system.getWindowDimensions then
      pushDims(lovr.system.getWindowDimensions(), 'windowDims')
    end
  end

  if dimCount == 0 then
    local mx, my, w, h = getMouseAndWindowSpace()
    if mx and my and w and h and w > 0 and h > 0 then
      pushDims(w, h, 'fallbackDims')
      if mouseSampleCount == 0 then
        mouseSampleCount = mouseSampleCount + 1
        mouseSamples[mouseSampleCount] = { x = mx, y = my, source = 'fallbackMouse' }
      end
    end
  end

  if dimCount == 0 then
    self._uiRayDebug = 'invalid.window'
    return false
  end

  local referenceW = dims[1].w
  local referenceH = dims[1].h
  local tanLeft, tanRight, tanUp, tanDown, angleSource = resolveViewAngles(pass, referenceW, referenceH, self.constants)
  if not areTanFrustumValid(tanLeft, tanRight, tanUp, tanDown) then
    self._uiRayDebug = 'invalid.angles'
    return false
  end

  local distance = self._hudDistance or 1.14
  local panelHalfW = panelWidth * 0.5
  local panelHalfH = panelHeight * 0.5

  local bestScore = -math.huge
  local bestX = nil
  local bestY = nil
  local bestSource = nil

  local function evaluate(sample, d, useTopLeft)
    local mx = sample.x
    local my = sample.y
    if mx < -1 or my < -1 or mx > d.w + 1 or my > d.h + 1 then
      return
    end

    local ndcX = (mx / d.w) * 2 - 1
    local ndcY
    if useTopLeft then
      ndcY = 1 - (my / d.h) * 2
    else
      ndcY = (my / d.h) * 2 - 1
    end

    local tx = (ndcX + 1) * 0.5
    local ty = (ndcY + 1) * 0.5
    local tanX = tanLeft + (tanRight - tanLeft) * tx
    local tanY = tanDown + (tanUp - tanDown) * ty
    local localX = tanX * distance
    local localY = tanY * distance
    if not (isFiniteNumber(localX) and isFiniteNumber(localY)) then
      return
    end

    local dxOutside = math.max(math.abs(localX) - panelHalfW, 0)
    local dyOutside = math.max(math.abs(localY - panelY) - panelHalfH, 0)
    local score = -(dxOutside + dyOutside)
    if dxOutside == 0 and dyOutside == 0 then
      score = score + 10
    end

    if sample.source == 'lovr.mouse' and d.label == 'windowPx' then
      score = score + 0.40
    elseif sample.source == 'lovr.system' and d.label == 'windowDims' then
      score = score + 0.40
    end
    if useTopLeft then
      score = score + 0.20
    end

    if score > bestScore then
      bestScore = score
      bestX = localX
      bestY = localY
      bestSource = string.format('%s/%s/%s', sample.source, d.label, useTopLeft and 'top' or 'bottom')
    end
  end

  for si = 1, mouseSampleCount do
    local sample = mouseSamples[si]
    for di = 1, dimCount do
      local d = dims[di]
      evaluate(sample, d, true)
      evaluate(sample, d, false)
    end
  end

  if not bestX or not bestY then
    self._uiRayDebug = 'invalid.mapping'
    return false
  end

  outRay.localX = bestX
  outRay.localY = bestY
  self._uiRayDebug = string.format('%s | %s', tostring(angleSource or 'unknown'), tostring(bestSource or 'unknown'))
  return true
end

function HUD:_drawBagMenu(pass, orientation, baseX, baseY, baseZ, right, up, forward, state)
  local inventory = state.inventory
  if not inventory then
    return
  end

  local defaultHotbar = self.constants.HOTBAR_SLOT_COUNT or self.constants.INVENTORY_SLOT_COUNT or 8
  local hotbarCount, slotCount, storageCount = getInventoryCounts(inventory, defaultHotbar)
  local storageRows = math.ceil(storageCount / hotbarCount)
  local sectionGap = (storageRows > 0) and 0.038 or 0

  local mode = state.inventoryMenuMode == 'workbench' and 'workbench' or 'bag'
  local ingredientSlots = mode == 'workbench' and (state.workbenchCraftSlots or {}) or (state.bagCraftSlots or {})
  local ingredientCols = mode == 'workbench' and 5 or 2
  local ingredientRows = mode == 'workbench' and 5 or 1
  local craftables = state.craftableOutputs or {}

  local slotSize = 0.082
  local slotGap = 0.010
  local titleHeight = 0.072
  local hintHeight = 0.040
  local outputRowHeight = 0.060

  local invWidth = hotbarCount * slotSize + (hotbarCount - 1) * slotGap
  local invHeight = (storageRows + 1) * slotSize + storageRows * slotGap + sectionGap
  local ingredientWidth = ingredientCols * slotSize + (ingredientCols - 1) * slotGap
  local ingredientHeight = ingredientRows * slotSize + (ingredientRows - 1) * slotGap
  local outputsVisible = math.max(1, math.min(#craftables, 6))
  local outputsHeight = outputsVisible * outputRowHeight

  local leftWidth = invWidth + 0.06
  local rightWidth = math.max(0.58, ingredientWidth + 0.16)
  local contentHeight = math.max(invHeight + 0.07, ingredientHeight + outputsHeight + 0.20)
  local panelWidth = leftWidth + rightWidth + 0.08
  local panelHeight = contentHeight + titleHeight + hintHeight + 0.04
  local panelY = -0.065

  local panelLeft = -panelWidth * 0.5
  local panelTop = panelY + panelHeight * 0.5
  local leftCenterX = panelLeft + leftWidth * 0.5 + 0.02
  local rightLeft = panelLeft + leftWidth + 0.05
  local rightCenterX = rightLeft + rightWidth * 0.5
  local contentTopY = panelTop - titleHeight - 0.025

  local hover = state.uiHover
  if type(hover) ~= 'table' then
    hover = {}
    state.uiHover = hover
  end
  hover.kind = nil
  hover.index = nil
  hover.source = nil
  hover.outputIndex = nil

  local ray = self._uiRay
  if type(ray) ~= 'table' then
    ray = {}
    self._uiRay = ray
  end

  local mouseLocalX = nil
  local mouseLocalY = nil
  if self:_buildMouseRay(pass, panelY, panelWidth, panelHeight, ray) then
    mouseLocalX = ray.localX
    mouseLocalY = ray.localY
  end

  local function pointInRect(cx, cy, width, height)
    if not mouseLocalX or not mouseLocalY then
      return false
    end
    return mouseLocalX >= cx - width * 0.5
      and mouseLocalX <= cx + width * 0.5
      and mouseLocalY >= cy - height * 0.5
      and mouseLocalY <= cy + height * 0.5
  end

  state.uiMouseInsideMenu = pointInRect(0, panelY, panelWidth, panelHeight)

  local function setHover(kind, index, source, outputIndex)
    hover.kind = kind
    hover.index = index
    hover.source = source
    hover.outputIndex = outputIndex
  end

  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, 0, 1.95, 1.16, 0.02, 0.02, 0.03, 0.58, 0.0006)
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, panelY, panelWidth + 0.010, panelHeight + 0.010, 0.18, 0.21, 0.26, 0.58, 0.0002)
  self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, panelY, panelWidth, panelHeight, 0.05, 0.06, 0.07, 0.92, 0.0001)

  local title = mode == 'workbench' and 'Workbench' or 'Bag'
  self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, title, 0, panelTop - titleHeight * 0.50, 0.031, 0.94, 0.96, 0.98, 0.98)

  local selected = inventory and inventory.getSelectedIndex and inventory:getSelectedIndex() or 1
  selected = clamp(selected, 1, hotbarCount)

  local function drawStackSlot(slot, x, y, isSelected, showNumber, slotIndex, hoverKind, hoverSource)
    local hovered = pointInRect(x, y, slotSize, slotSize)
    if hovered then
      setHover(hoverKind, slotIndex, hoverSource, nil)
    end

    if hovered then
      self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, x, y, slotSize + 0.010, slotSize + 0.010, 0.98, 0.89, 0.52, 0.30, -0.0002)
    end
    if isSelected then
      self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, x, y, slotSize + 0.006, slotSize + 0.006, 0.66, 0.82, 0.98, 0.22, -0.0001)
    end

    local bg = 0.14
    self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, x, y, slotSize, slotSize, bg, bg, bg + 0.01, 0.97, 0)

    local hasStack = slot and slot.block and slot.count and slot.count > 0
    if hasStack then
      local info = self.constants.BLOCK_INFO[slot.block]
      local color = info and info.color or nil
      self:_plane(
        pass,
        orientation,
        baseX,
        baseY,
        baseZ,
        right,
        up,
        forward,
        x,
        y,
        slotSize * 0.62,
        slotSize * 0.62,
        sanitizeNumber(color and color[1], 0.6),
        sanitizeNumber(color and color[2], 0.6),
        sanitizeNumber(color and color[3], 0.6),
        sanitizeNumber(info and info.alpha, 1),
        -0.0003
      )

      if slot.count > 1 then
        self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, tostring(slot.count), x + slotSize * 0.35, y - slotSize * 0.34, 0.018, 0.96, 0.96, 0.93, 0.98, 'right', 'bottom')
      elseif slot.durability and slot.durability > 0 then
        self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, tostring(math.floor(slot.durability)), x + slotSize * 0.35, y - slotSize * 0.34, 0.0135, 0.96, 0.82, 0.58, 0.98, 'right', 'bottom')
      end
    else
      self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, x, y, slotSize * 0.55, slotSize * 0.55, 0.08, 0.08, 0.09, 0.92, -0.0003)
    end

    if showNumber then
      self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, tostring(slotIndex), x - slotSize * 0.35, y + slotSize * 0.37, 0.0135, 0.66, 0.71, 0.76, 0.88, 'left', 'top')
    end
  end

  local invStartX = leftCenterX - invWidth * 0.5 + slotSize * 0.5
  local invTopY = contentTopY - 0.010
  local firstStorageRowY = invTopY - slotSize * 0.5

  if storageRows > 0 then
    self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, 'Storage', leftCenterX, firstStorageRowY + slotSize * 0.78, 0.017, 0.90, 0.92, 0.95, 0.92)
  end

  for row = 1, storageRows do
    local slotY = firstStorageRowY - (row - 1) * (slotSize + slotGap)
    for col = 1, hotbarCount do
      local storageOrdinal = (row - 1) * hotbarCount + col
      local slotIndex = hotbarCount + storageOrdinal
      if slotIndex <= slotCount then
        local slotX = invStartX + (col - 1) * (slotSize + slotGap)
        drawStackSlot(inventory:getSlot(slotIndex), slotX, slotY, false, false, slotIndex, 'inventory_slot', nil)
      end
    end
  end

  local hotbarY = firstStorageRowY - storageRows * (slotSize + slotGap) - sectionGap
  self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, 'Hotbar', leftCenterX, hotbarY + slotSize * 0.78, 0.017, 0.90, 0.92, 0.95, 0.92)
  for i = 1, hotbarCount do
    local slotX = invStartX + (i - 1) * (slotSize + slotGap)
    drawStackSlot(inventory:getSlot(i), slotX, hotbarY, i == selected, true, i, 'inventory_slot', nil)
  end

  local ingredientLabel = mode == 'workbench' and 'Workbench Ingredients' or 'Bag Ingredients'
  local ingredientStartX = rightCenterX - ingredientWidth * 0.5 + slotSize * 0.5
  local ingredientStartY = invTopY - slotSize * 0.5
  self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, ingredientLabel, rightCenterX, ingredientStartY + slotSize * 0.90, 0.017, 0.90, 0.95, 0.92, 0.94)

  for row = 1, ingredientRows do
    local slotY = ingredientStartY - (row - 1) * (slotSize + slotGap)
    for col = 1, ingredientCols do
      local ingredientIndex = (row - 1) * ingredientCols + col
      local slotX = ingredientStartX + (col - 1) * (slotSize + slotGap)
      drawStackSlot(ingredientSlots[ingredientIndex], slotX, slotY, false, false, ingredientIndex, 'ingredient_slot', mode)
    end
  end

  local ingredientBottomY = ingredientStartY - (ingredientRows - 1) * (slotSize + slotGap) - slotSize * 0.5
  local outputTopY = ingredientBottomY - 0.045
  self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, 'Craftable', rightCenterX, outputTopY + 0.028, 0.017, 0.90, 0.95, 0.92, 0.94)

  local outputWidth = rightWidth - 0.060
  local outputStartY = outputTopY - 0.034
  local shown = math.min(#craftables, 6)
  if shown == 0 then
    local emptyY = outputStartY - outputRowHeight * 0.5
    self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, rightCenterX, emptyY, outputWidth, outputRowHeight - 0.006, 0.08, 0.09, 0.10, 0.92, 0)
    self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, 'No fully satisfied recipes', rightCenterX, emptyY, 0.0145, 0.70, 0.74, 0.78, 0.95)
  else
    for i = 1, shown do
      local recipe = craftables[i]
      local rowY = outputStartY - (i - 1) * outputRowHeight
      local hovered = pointInRect(rightCenterX, rowY, outputWidth, outputRowHeight - 0.006)
      if hovered then
        setHover('craft_output', nil, mode, i)
      end

      local bgR, bgG, bgB, bgA = 0.09, 0.10, 0.12, 0.94
      if hovered then
        bgR, bgG, bgB, bgA = 0.20, 0.16, 0.09, 0.95
      end

      self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, rightCenterX, rowY, outputWidth, outputRowHeight - 0.006, bgR, bgG, bgB, bgA, 0)

      local outputId = recipe and (recipe.outputId or (recipe.output and recipe.output.id)) or nil
      local outputInfo = outputId and self.constants.BLOCK_INFO[outputId] or nil
      local outputColor = outputInfo and outputInfo.color or nil
      self:_plane(
        pass,
        orientation,
        baseX,
        baseY,
        baseZ,
        right,
        up,
        forward,
        rightCenterX - outputWidth * 0.45,
        rowY,
        0.034,
        0.034,
        sanitizeNumber(outputColor and outputColor[1], 0.75),
        sanitizeNumber(outputColor and outputColor[2], 0.75),
        sanitizeNumber(outputColor and outputColor[3], 0.75),
        sanitizeNumber(outputInfo and outputInfo.alpha, 1),
        -0.0002
      )

      local name = recipe and (recipe.name or recipe.label) or 'Recipe'
      local outCount = recipe and (recipe.outputCount or (recipe.output and recipe.output.count)) or 1
      local label = string.format('%s x%d', name, outCount)
      self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, label, rightCenterX - outputWidth * 0.40, rowY, 0.0145, 0.94, 0.95, 0.96, 0.97, 'left', 'middle')
    end
  end

  local held = inventory and inventory.getHeldStack and inventory:getHeldStack() or nil
  if held and held.block and held.count and held.count > 0 then
    local heldInfo = self.constants.BLOCK_INFO[held.block]
    local heldName = heldInfo and heldInfo.name or 'Unknown'
    local heldText = string.format('Holding: %s x%d', heldName, held.count)
    local heldY = panelY - panelHeight * 0.5 + hintHeight + 0.040
    self:_plane(pass, orientation, baseX, baseY, baseZ, right, up, forward, 0, heldY, panelWidth * 0.44, 0.040, 0.11, 0.12, 0.15, 0.86, 0)
    self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, heldText, 0, heldY, 0.016, 0.97, 0.90, 0.66, 0.98, 'center', 'middle')
  end

  local hintText = mode == 'workbench'
    and 'LMB move stack  RMB move one  Shift+Click output: craft max  Esc/Tab close'
    or 'LMB move stack  RMB move one  Click output to craft  Shift+Click output: craft max'
  self:_text(pass, orientation, baseX, baseY, baseZ, right, up, forward, hintText, 0, panelY - panelHeight * 0.5 + 0.017, 0.0138, 0.80, 0.84, 0.90, 0.92)
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
  local craftUiText = 'Closed'
  if state.inventoryMenuOpen then
    craftUiText = state.inventoryMenuMode == 'workbench' and 'Workbench' or 'Bag'
  end
  lines[count] = string.format('Craft UI: %s', craftUiText)
  if state.inventoryMenuOpen then
    local hoverKind = 'none'
    local hover = state.uiHover
    if type(hover) == 'table' and hover.kind then
      hoverKind = tostring(hover.kind)
    end
    count = count + 1
    lines[count] = string.format('UI Hover: %s  |  Inside: %s', hoverKind, state.uiMouseInsideMenu and 'yes' or 'no')
    count = count + 1
    local uiMapping = self._uiRayDebug or 'n/a'
    if state.inventoryMenuScreen and state.uiMenuMouseDebug and state.uiMenuMouseDebug ~= '' then
      uiMapping = state.uiMenuMouseDebug
    end
    lines[count] = string.format('UI Ray: %s', tostring(uiMapping))
  end
  count = count + 1
  lines[count] = string.format('Mesh: %s', state.meshingMode or 'Unknown')
  count = count + 1
  lines[count] = string.format(
    'Distance: Render %d  |  Sim %d',
    math.floor(tonumber(state.renderRadiusChunks) or 0),
    math.floor(tonumber(state.simulationRadiusChunks) or 0)
  )
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
    local coreCount = math.max(1, math.floor(tonumber(state.threadCoreCount) or 1))
    local activeMeshingThreads = math.max(1, math.floor(tonumber(state.threadActiveMeshingThreads) or 1))
    local workerCount = math.max(0, math.floor(tonumber(state.threadWorkerCount) or 0))
    local targetWorkers = math.max(0, math.floor(tonumber(state.threadTargetWorkers) or 0))
    local threadSuffix = state.threadPoolActive and '' or '  (fallback)'
    count = count + 1
    lines[count] = string.format(
      'CPU: meshing threads %d/%d logical  |  Mesh workers %d/%d%s',
      activeMeshingThreads,
      coreCount,
      workerCount,
      targetWorkers,
      threadSuffix
    )
    count = count + 1
    lines[count] = string.format(
      'Thread: Prep %d (%.2f ms, defer %d)  |  Apply %d (%.2f ms)',
      math.floor(tonumber(state.threadQueuePrepOps) or 0),
      tonumber(state.threadQueuePrepMs) or 0,
      math.floor(tonumber(state.threadQueuePrepDeferred) or 0),
      math.floor(tonumber(state.threadApplyResults) or 0),
      tonumber(state.threadApplyMs) or 0
    )
    count = count + 1
    lines[count] = string.format(
      'PrepMs: Ens %.2f Blk %.2f Sky %.2f Pack %.2f Push %.2f',
      tonumber(state.threadPrepEnsureMs) or 0,
      tonumber(state.threadPrepBlockHaloMs) or 0,
      tonumber(state.threadPrepSkyHaloMs) or 0,
      tonumber(state.threadPrepPackMs) or 0,
      tonumber(state.threadPrepPushMs) or 0
    )
    count = count + 1
    lines[count] = string.format(
      'StageU: Total %.2f (W %.2f)  Sim %.2f (W %.2f)',
      tonumber(state.stageUpdateTotalMs) or 0,
      tonumber(state.stageUpdateTotalWorstMs) or 0,
      tonumber(state.stageUpdateSimMs) or 0,
      tonumber(state.stageUpdateSimWorstMs) or 0
    )
    count = count + 1
    lines[count] = string.format(
      'StageU: Light %.2f (W %.2f) Pass %d  Rebuild %.2f (W %.2f)',
      tonumber(state.stageUpdateLightMs) or 0,
      tonumber(state.stageUpdateLightWorstMs) or 0,
      math.floor(tonumber(state.skyLightPasses) or 0),
      tonumber(state.stageUpdateRebuildMs) or 0,
      tonumber(state.stageUpdateRebuildWorstMs) or 0
    )
    count = count + 1
    lines[count] = string.format(
      'StageD: World %.2f (W %.2f)  Render %.2f (W %.2f)',
      tonumber(state.stageDrawWorldMs) or 0,
      tonumber(state.stageDrawWorldWorstMs) or 0,
      tonumber(state.stageDrawRendererMs) or 0,
      tonumber(state.stageDrawRendererWorstMs) or 0
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
      count = count + 1
      lines[count] = string.format(
        'LPerf: U %.2f (W %.2f)  R %.2f (W %.2f)  Ops C/D/F %d/%d/%d',
        tonumber(state.lightUpdateMs) or 0,
        tonumber(state.lightUpdateWorstMs) or 0,
        tonumber(state.lightRegionMs) or 0,
        tonumber(state.lightRegionWorstMs) or 0,
        math.floor(tonumber(state.lightColumnOps) or 0),
        math.floor(tonumber(state.lightDarkOps) or 0),
        math.floor(tonumber(state.lightFloodOps) or 0)
      )
      count = count + 1
      lines[count] = string.format(
        'LEns: Calls %d  U %.2f  Ops C/D/F %d/%d/%d',
        math.floor(tonumber(state.lightEnsureCalls) or 0),
        tonumber(state.lightEnsureUpdateMs) or 0,
        math.floor(tonumber(state.lightEnsureColumnOps) or 0),
        math.floor(tonumber(state.lightEnsureDarkOps) or 0),
        math.floor(tonumber(state.lightEnsureFloodOps) or 0)
      )
      count = count + 1
      lines[count] = string.format(
        'LSkip: C/D/F %d/%d/%d  Cap %d/%d/%d  FCap %d',
        math.floor(tonumber(state.lightQueueSkipColumns) or 0),
        math.floor(tonumber(state.lightQueueSkipDark) or 0),
        math.floor(tonumber(state.lightQueueSkipFlood) or 0),
        math.floor(tonumber(state.lightQueueCapColumns) or 0),
        math.floor(tonumber(state.lightQueueCapDark) or 0),
        math.floor(tonumber(state.lightQueueCapFlood) or 0),
        math.floor(tonumber(state.lightFloodCapHits) or 0)
      )
      count = count + 1
      lines[count] = string.format(
        'LMax: C %.2f (W %.2f) D %.2f (W %.2f) F %.2f (W %.2f)  Partial %d (W %d)',
        tonumber(state.lightMaxColumnMs) or 0,
        tonumber(state.lightMaxColumnWorstMs) or 0,
        tonumber(state.lightMaxDarkMs) or 0,
        tonumber(state.lightMaxDarkWorstMs) or 0,
        tonumber(state.lightMaxFloodMs) or 0,
        tonumber(state.lightMaxFloodWorstMs) or 0,
        math.floor(tonumber(state.lightColumnPartialOps) or 0),
        math.floor(tonumber(state.lightColumnPartialOpsWorst) or 0)
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

  local distance = self._hudDistance or 1.14
  local baseX = cameraX + forward.x * distance
  local baseY = cameraY + forward.y * distance
  local baseZ = cameraZ + forward.z * distance

  pass:push('state')
  pass:setDepthWrite(false)

  if not state.inventoryMenuOpen then
    if type(state.uiHover) == 'table' then
      state.uiHover.kind = nil
      state.uiHover.index = nil
      state.uiHover.source = nil
      state.uiHover.outputIndex = nil
    end
    state.uiMouseInsideMenu = false
  end

  if state.inventoryMenuOpen and not state.inventoryMenuScreen then
    self:_drawBagMenu(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, state)
  elseif not state.inventoryMenuOpen then
    self:_drawCrosshair(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, state.targetActive)

    local targetName = state.targetName or 'None'
    if targetName ~= 'None' then
      self:_plane(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, 0, 0.102, 0.27, 0.047, 0.05, 0.06, 0.07, 0.72, 0.0002)
      self:_text(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, targetName, 0, 0.102, 0.022, 0.96, 0.96, 0.95, 0.96)
    end

    local hotbarWidth, hotbarY, hotbarHeight = self:_drawHotbar(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, state)
    self:_drawVitals(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, state, hotbarWidth, hotbarY, hotbarHeight)
  end

  local debugText = self._hudText
  if debugText ~= '' then
    local lineCount = math.max(1, math.floor(tonumber(self._hudLineCount) or 1))
    local showPerfHud = state.showPerfHud ~= false

    local panelW = showPerfHud and 0.90 or 0.62
    panelW = panelW + math.min(0.06, math.max(0, (lineCount - 16) * 0.01))
    panelW = clamp(panelW, 0.62, 0.96)

    local textScale = showPerfHud and 0.0155 or 0.0175
    local lineHeight = textScale * 1.44
    local panelPadY = 0.014
    local panelH = panelPadY * 2 + lineCount * lineHeight

    local panelTop = 0.705
    local panelBottomLimit = -0.66
    local maxPanelH = panelTop - panelBottomLimit
    if panelH > maxPanelH then
      lineHeight = math.max(0.0150, (maxPanelH - panelPadY * 2) / lineCount)
      textScale = math.max(0.0110, math.min(textScale, lineHeight / 1.44))
      panelH = panelPadY * 2 + lineCount * lineHeight
    end

    local panelLeft = -0.985
    local panelX = panelLeft + panelW * 0.5
    local panelY = panelTop - panelH * 0.5
    if panelY - panelH * 0.5 < panelBottomLimit then
      panelY = panelBottomLimit + panelH * 0.5
    end

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
      panelY + panelH * 0.5 - panelPadY + 0.002,
      textScale,
      0.93,
      0.95,
      0.96,
      0.97,
      'left',
      'top',
      0
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
  elseif not state.inventoryMenuOpen then
    self:_text(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, self._tipText, -0.30, -0.236, 0.016, 0.80, 0.84, 0.88, 0.92, 'left', 'middle')
  end

  if state.saveStatusTimer and state.saveStatusTimer > 0 and state.saveStatusText and state.saveStatusText ~= '' then
    self:_plane(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, 0, 0.285, 0.36, 0.040, 0.11, 0.08, 0.05, 0.78, 0.0001)
    self:_text(pass, cameraOrientation, baseX, baseY, baseZ, right, up, forward, state.saveStatusText, 0, 0.285, 0.020, 1.00, 0.86, 0.56, 0.98)
  end

  pass:pop('state')
end

return HUD
