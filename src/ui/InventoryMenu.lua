local InventoryMenu = {}
InventoryMenu.__index = InventoryMenu

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

local function pointInRect(px, py, rect)
  return px >= rect.x
    and px <= rect.x + rect.w
    and py >= rect.y
    and py <= rect.y + rect.h
end

local function isFiniteNumber(value)
  return type(value) == 'number'
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function drawRect(pass, rect, r, g, b, a)
  pass:setColor(r, g, b, a or 1)
  pass:plane(rect.x + rect.w * 0.5, rect.y + rect.h * 0.5, 0, rect.w, rect.h)
end

local function drawText(pass, text, x, y, size, r, g, b, a, halign, valign)
  pass:setColor(r, g, b, a or 1)
  pass:text(
    text,
    x,
    y,
    0,
    size,
    0,
    0,
    1,
    0,
    0,
    halign or 'left',
    valign or 'top'
  )
end

function InventoryMenu.new(constants)
  local self = setmetatable({}, InventoryMenu)
  self.constants = constants
  self._projection = lovr.math.newMat4()
  self._cameraPosition = lovr.math.newVec3(0, 0, 0)
  self._cameraOrientation = lovr.math.newQuat()
  self._layout = nil
  self._mouseDebug = 'n/a'
  return self
end

function InventoryMenu:_getWindowDimensions()
  if lovr.system and lovr.system.getWindowDimensions then
    local w, h = lovr.system.getWindowDimensions()
    w, h = tonumber(w), tonumber(h)
    if w and h and w > 0 and h > 0 then
      return w, h
    end
  end

  if lovr.system and lovr.system.getWindowWidth and lovr.system.getWindowHeight then
    local w = tonumber(lovr.system.getWindowWidth())
    local h = tonumber(lovr.system.getWindowHeight())
    if w and h and w > 0 and h > 0 then
      return w, h
    end
  end

  return nil, nil
end

function InventoryMenu:_getMousePosition()
  if lovr.system and lovr.system.getMousePosition then
    local x, y = lovr.system.getMousePosition()
    x, y = tonumber(x), tonumber(y)
    if x and y then
      return x, y
    end
  end

  if lovr.mouse and lovr.mouse.getPosition then
    local x, y = lovr.mouse.getPosition()
    x, y = tonumber(x), tonumber(y)
    if x and y then
      return x, y
    end
  end

  return nil, nil
end

function InventoryMenu:_resolveMouse(layout, width, height)
  local rawSamples = {}
  local rawCount = 0

  if lovr.system and lovr.system.getMousePosition then
    local x, y = lovr.system.getMousePosition()
    x, y = tonumber(x), tonumber(y)
    if isFiniteNumber(x) and isFiniteNumber(y) then
      rawCount = rawCount + 1
      rawSamples[rawCount] = { x = x, y = y, source = 'system' }
    end
  end

  if lovr.mouse and lovr.mouse.getPosition then
    local x, y = lovr.mouse.getPosition()
    x, y = tonumber(x), tonumber(y)
    if isFiniteNumber(x) and isFiniteNumber(y) then
      rawCount = rawCount + 1
      rawSamples[rawCount] = { x = x, y = y, source = 'mouse' }
    end
  end

  if rawCount == 0 then
    self._mouseDebug = 'no-mouse'
    return nil, nil
  end

  local density = nil
  if lovr.system and lovr.system.getWindowDensity then
    density = tonumber(lovr.system.getWindowDensity())
    if not density or density <= 0 then
      density = nil
    end
  end

  local scaleX, scaleY = nil, nil
  if lovr.system and lovr.system.getWindowWidth and lovr.system.getWindowHeight then
    local pxW = tonumber(lovr.system.getWindowWidth())
    local pxH = tonumber(lovr.system.getWindowHeight())
    if pxW and pxH and pxW > 0 and pxH > 0 and width > 0 and height > 0 then
      scaleX = pxW / width
      scaleY = pxH / height
      if scaleX <= 0 or scaleY <= 0 then
        scaleX, scaleY = nil, nil
      end
    end
  end

  local candidates = {}
  local candidateCount = 0
  local function pushCandidate(x, y, label)
    if not (isFiniteNumber(x) and isFiniteNumber(y)) then
      return
    end
    candidateCount = candidateCount + 1
    candidates[candidateCount] = { x = x, y = y, label = label }
  end

  for i = 1, rawCount do
    local sample = rawSamples[i]
    pushCandidate(sample.x, sample.y, sample.source .. '.raw')
    if density then
      pushCandidate(sample.x / density, sample.y / density, sample.source .. '.divDensity')
      pushCandidate(sample.x * density, sample.y * density, sample.source .. '.mulDensity')
    end
    if scaleX and scaleY then
      pushCandidate(sample.x / scaleX, sample.y / scaleY, sample.source .. '.divScale')
      pushCandidate(sample.x * scaleX, sample.y * scaleY, sample.source .. '.mulScale')
    end
  end

  local rect = layout.panelRect
  local bestScore = -math.huge
  local bestX = nil
  local bestY = nil
  local bestLabel = 'none'

  for i = 1, candidateCount do
    local c = candidates[i]
    local dx = 0
    if c.x < rect.x then
      dx = rect.x - c.x
    elseif c.x > rect.x + rect.w then
      dx = c.x - (rect.x + rect.w)
    end

    local dy = 0
    if c.y < rect.y then
      dy = rect.y - c.y
    elseif c.y > rect.y + rect.h then
      dy = c.y - (rect.y + rect.h)
    end

    local score = -(dx + dy)
    if dx == 0 and dy == 0 then
      score = score + 20
    end
    if c.label == 'system.raw' then
      score = score + 0.6
    elseif c.label == 'mouse.divScale' then
      score = score + 0.4
    end

    if score > bestScore then
      bestScore = score
      bestX = c.x
      bestY = c.y
      bestLabel = c.label
    end
  end

  self._mouseDebug = string.format('%s @ %.1f,%.1f', bestLabel, tonumber(bestX) or -1, tonumber(bestY) or -1)
  return bestX, bestY
end

function InventoryMenu:_computeLayout(state, width, height)
  local inventory = state.inventory
  if not inventory then
    return nil
  end

  local defaultHotbar = self.constants.HOTBAR_SLOT_COUNT or self.constants.INVENTORY_SLOT_COUNT or 8
  local hotbarCount, slotCount, storageCount = getInventoryCounts(inventory, defaultHotbar)
  local storageRows = math.ceil(storageCount / hotbarCount)

  local mode = state.inventoryMenuMode == 'workbench' and 'workbench' or 'bag'
  local ingredientCols = mode == 'workbench' and 5 or 2
  local ingredientRows = mode == 'workbench' and 5 or 1
  local craftables = state.craftableOutputs or {}
  local outputsShown = math.min(#craftables, 5)
  local outputRows = math.max(1, outputsShown)

  local slotSize = 46
  local slotGap = 6
  local sectionGap = 16
  local titleHeight = 56
  local hintHeight = 34
  local outputRowHeight = 34

  local invWidth = hotbarCount * slotSize + (hotbarCount - 1) * slotGap
  local invHeight = (storageRows + 1) * slotSize + storageRows * slotGap + (storageRows > 0 and sectionGap or 0)
  local ingredientWidth = ingredientCols * slotSize + (ingredientCols - 1) * slotGap
  local ingredientHeight = ingredientRows * slotSize + (ingredientRows - 1) * slotGap
  local outputsHeight = outputRows * outputRowHeight

  local leftWidth = invWidth + 44
  local rightWidth = math.max(360, ingredientWidth + 110)
  local contentHeight = math.max(invHeight + 80, ingredientHeight + outputsHeight + 126)
  local panelWidth = leftWidth + rightWidth + 62
  local panelHeight = contentHeight + titleHeight + hintHeight + 24

  local scaleX = (width - 28) / panelWidth
  local scaleY = (height - 28) / panelHeight
  local scale = math.min(1, scaleX, scaleY)
  scale = clamp(scale, 0.62, 1)

  slotSize = slotSize * scale
  slotGap = slotGap * scale
  sectionGap = sectionGap * scale
  titleHeight = titleHeight * scale
  hintHeight = hintHeight * scale
  outputRowHeight = outputRowHeight * scale

  invWidth = hotbarCount * slotSize + (hotbarCount - 1) * slotGap
  invHeight = (storageRows + 1) * slotSize + storageRows * slotGap + (storageRows > 0 and sectionGap or 0)
  ingredientWidth = ingredientCols * slotSize + (ingredientCols - 1) * slotGap
  ingredientHeight = ingredientRows * slotSize + (ingredientRows - 1) * slotGap
  outputsHeight = outputRows * outputRowHeight

  leftWidth = invWidth + 44 * scale
  rightWidth = math.max(360 * scale, ingredientWidth + 110 * scale)
  contentHeight = math.max(invHeight + 80 * scale, ingredientHeight + outputsHeight + 126 * scale)
  panelWidth = leftWidth + rightWidth + 62 * scale
  panelHeight = contentHeight + titleHeight + hintHeight + 24 * scale

  local panelX = math.floor((width - panelWidth) * 0.5)
  local panelY = math.floor((height - panelHeight) * 0.5)

  local panelRect = { x = panelX, y = panelY, w = panelWidth, h = panelHeight }
  local leftX = panelX + 20 * scale
  local rightX = panelX + leftWidth + 40 * scale
  local contentTop = panelY + titleHeight + 16 * scale

  local invStartX = leftX + (leftWidth - invWidth) * 0.5
  local storageLabelY = contentTop + 4 * scale
  local storageStartY = storageLabelY + 20 * scale
  local hotbarLabelY = storageStartY + storageRows * (slotSize + slotGap) + (storageRows > 0 and sectionGap or 0) + 4 * scale
  local hotbarY = hotbarLabelY + 20 * scale

  local ingredientLabelY = contentTop + 4 * scale
  local ingredientStartX = rightX + (rightWidth - ingredientWidth) * 0.5
  local ingredientStartY = ingredientLabelY + 20 * scale
  local outputLabelY = ingredientStartY + ingredientHeight + 14 * scale
  local outputStartY = outputLabelY + 18 * scale
  local outputWidth = rightWidth - 28 * scale

  local inventorySlotRects = {}
  for row = 1, storageRows do
    local y = storageStartY + (row - 1) * (slotSize + slotGap)
    for col = 1, hotbarCount do
      local storageOrdinal = (row - 1) * hotbarCount + col
      local slotIndex = hotbarCount + storageOrdinal
      if slotIndex <= slotCount then
        local x = invStartX + (col - 1) * (slotSize + slotGap)
        inventorySlotRects[slotIndex] = { x = x, y = y, w = slotSize, h = slotSize }
      end
    end
  end

  for i = 1, hotbarCount do
    local x = invStartX + (i - 1) * (slotSize + slotGap)
    inventorySlotRects[i] = { x = x, y = hotbarY, w = slotSize, h = slotSize }
  end

  local ingredientSlotRects = {}
  for row = 1, ingredientRows do
    local y = ingredientStartY + (row - 1) * (slotSize + slotGap)
    for col = 1, ingredientCols do
      local index = (row - 1) * ingredientCols + col
      local x = ingredientStartX + (col - 1) * (slotSize + slotGap)
      ingredientSlotRects[index] = { x = x, y = y, w = slotSize, h = slotSize }
    end
  end

  local outputRects = {}
  for i = 1, outputRows do
    outputRects[i] = {
      x = rightX + 14 * scale,
      y = outputStartY + (i - 1) * outputRowHeight,
      w = outputWidth,
      h = outputRowHeight - 2 * scale
    }
  end

  return {
    width = width,
    height = height,
    panelRect = panelRect,
    panelX = panelX,
    panelY = panelY,
    panelWidth = panelWidth,
    panelHeight = panelHeight,
    titleHeight = titleHeight,
    hintHeight = hintHeight,
    scale = scale,
    mode = mode,
    hotbarCount = hotbarCount,
    slotCount = slotCount,
    storageRows = storageRows,
    craftables = craftables,
    outputsShown = outputsShown,
    outputRows = outputRows,
    leftX = leftX,
    rightX = rightX,
    leftWidth = leftWidth,
    rightWidth = rightWidth,
    invStartX = invStartX,
    storageLabelY = storageLabelY,
    hotbarLabelY = hotbarLabelY,
    ingredientLabelY = ingredientLabelY,
    outputLabelY = outputLabelY,
    inventorySlotRects = inventorySlotRects,
    ingredientSlotRects = ingredientSlotRects,
    outputRects = outputRects
  }
end

function InventoryMenu:update(state)
  if type(state) ~= 'table' then
    return
  end

  local hover = state.uiHover
  if type(hover) ~= 'table' then
    hover = {}
    state.uiHover = hover
  end
  hover.kind = nil
  hover.index = nil
  hover.source = nil
  hover.outputIndex = nil
  state.uiMouseInsideMenu = false

  local width, height = self:_getWindowDimensions()
  if not width or not height then
    self._layout = nil
    return
  end

  local layout = self:_computeLayout(state, width, height)
  self._layout = layout
  if not layout then
    state.uiMouseDebug = 'no-layout'
    return
  end

  local mx, my = self:_resolveMouse(layout, width, height)
  state.uiMouseDebug = self._mouseDebug
  if not mx or not my then
    return
  end

  if not pointInRect(mx, my, layout.panelRect) then
    return
  end

  state.uiMouseInsideMenu = true
  local mode = layout.mode

  for i = 1, layout.outputsShown do
    local rect = layout.outputRects[i]
    if rect and pointInRect(mx, my, rect) then
      hover.kind = 'craft_output'
      hover.source = mode
      hover.outputIndex = i
      return
    end
  end

  for i = 1, #layout.ingredientSlotRects do
    local rect = layout.ingredientSlotRects[i]
    if rect and pointInRect(mx, my, rect) then
      hover.kind = 'ingredient_slot'
      hover.index = i
      hover.source = mode
      return
    end
  end

  for i = 1, layout.slotCount do
    local rect = layout.inventorySlotRects[i]
    if rect and pointInRect(mx, my, rect) then
      hover.kind = 'inventory_slot'
      hover.index = i
      return
    end
  end
end

function InventoryMenu:draw(pass, state)
  if not pass or type(state) ~= 'table' or not state.inventory then
    return
  end

  local width, height = self:_getWindowDimensions()
  if not width or not height then
    return
  end

  local layout = self._layout
  if not layout or layout.width ~= width or layout.height ~= height then
    layout = self:_computeLayout(state, width, height)
    self._layout = layout
  end
  if not layout then
    return
  end

  local inventory = state.inventory
  local mode = layout.mode
  local ingredientSlots = mode == 'workbench' and (state.workbenchCraftSlots or {}) or (state.bagCraftSlots or {})
  local hover = state.uiHover or {}
  local selected = inventory and inventory.getSelectedIndex and inventory:getSelectedIndex() or 1
  selected = clamp(selected, 1, layout.hotbarCount)

  -- Match LÖVR's 2D example convention: screen-space (0, 0) at top-left.
  self._projection:orthographic(0, width, 0, height, -10, 10)

  pass:push('state')
  pass:setViewPose(1, self._cameraPosition, self._cameraOrientation)
  pass:setProjection(1, self._projection)
  pass:setDepthWrite(false)

  drawRect(pass, { x = 0, y = 0, w = width, h = height }, 0.02, 0.03, 0.04, 0.70)
  drawRect(pass, { x = layout.panelX - 2, y = layout.panelY - 2, w = layout.panelWidth + 4, h = layout.panelHeight + 4 }, 0.17, 0.20, 0.25, 0.72)
  drawRect(pass, layout.panelRect, 0.06, 0.07, 0.08, 0.94)

  local title = mode == 'workbench' and 'Workbench' or 'Bag'
  drawText(
    pass,
    title,
    layout.panelX + layout.panelWidth * 0.5,
    layout.panelY + layout.titleHeight * 0.53,
    26 * layout.scale,
    0.95,
    0.97,
    0.99,
    1,
    'center',
    'middle'
  )

  local function drawStackRect(slot, rect, isSelected, slotIndex, showSlotNumber, hoverKind, hoverIndex)
    local isHovered = hover and hover.kind == hoverKind and hoverIndex and hover.index == hoverIndex
    if isHovered then
      drawRect(pass, { x = rect.x - 3 * layout.scale, y = rect.y - 3 * layout.scale, w = rect.w + 6 * layout.scale, h = rect.h + 6 * layout.scale }, 0.96, 0.87, 0.50, 0.33)
    end
    if isSelected then
      drawRect(pass, { x = rect.x - 2 * layout.scale, y = rect.y - 2 * layout.scale, w = rect.w + 4 * layout.scale, h = rect.h + 4 * layout.scale }, 0.68, 0.83, 0.98, 0.28)
    end

    drawRect(pass, rect, 0.14, 0.14, 0.15, 0.97)

    local hasStack = slot and slot.block and slot.count and slot.count > 0
    if hasStack then
      local info = self.constants.BLOCK_INFO[slot.block]
      local color = info and info.color or nil
      drawRect(
        pass,
        {
          x = rect.x + rect.w * 0.19,
          y = rect.y + rect.h * 0.19,
          w = rect.w * 0.62,
          h = rect.h * 0.62
        },
        sanitizeNumber(color and color[1], 0.6),
        sanitizeNumber(color and color[2], 0.6),
        sanitizeNumber(color and color[3], 0.6),
        sanitizeNumber(info and info.alpha, 1)
      )

      if slot.count and slot.count > 1 then
        drawText(pass, tostring(slot.count), rect.x + rect.w - 3 * layout.scale, rect.y + rect.h - 2 * layout.scale, 14 * layout.scale, 0.96, 0.96, 0.93, 0.98, 'right', 'bottom')
      elseif slot.durability and slot.durability > 0 then
        drawText(pass, tostring(math.floor(slot.durability)), rect.x + rect.w - 3 * layout.scale, rect.y + rect.h - 2 * layout.scale, 12 * layout.scale, 0.96, 0.82, 0.58, 0.98, 'right', 'bottom')
      end
    else
      drawRect(
        pass,
        {
          x = rect.x + rect.w * 0.23,
          y = rect.y + rect.h * 0.23,
          w = rect.w * 0.54,
          h = rect.h * 0.54
        },
        0.08,
        0.08,
        0.09,
        0.92
      )
    end

    if showSlotNumber then
      drawText(pass, tostring(slotIndex), rect.x + 2 * layout.scale, rect.y + 2 * layout.scale, 12 * layout.scale, 0.66, 0.71, 0.76, 0.88, 'left', 'top')
    end
  end

  if layout.storageRows > 0 then
    drawText(pass, 'Storage', layout.leftX + layout.leftWidth * 0.5, layout.storageLabelY, 15 * layout.scale, 0.90, 0.92, 0.95, 0.95, 'center', 'top')
  end
  drawText(pass, 'Hotbar', layout.leftX + layout.leftWidth * 0.5, layout.hotbarLabelY, 15 * layout.scale, 0.90, 0.92, 0.95, 0.95, 'center', 'top')
  drawText(pass, mode == 'workbench' and 'Workbench Ingredients' or 'Bag Ingredients', layout.rightX + layout.rightWidth * 0.5, layout.ingredientLabelY, 15 * layout.scale, 0.90, 0.95, 0.92, 0.95, 'center', 'top')
  drawText(pass, 'Craftable', layout.rightX + layout.rightWidth * 0.5, layout.outputLabelY, 15 * layout.scale, 0.90, 0.95, 0.92, 0.95, 'center', 'top')

  for i = 1, layout.slotCount do
    local rect = layout.inventorySlotRects[i]
    if rect then
      local slot = inventory:getSlot(i)
      local showNumber = i <= layout.hotbarCount
      drawStackRect(slot, rect, i == selected and showNumber, i, showNumber, 'inventory_slot', i)
    end
  end

  for i = 1, #layout.ingredientSlotRects do
    local rect = layout.ingredientSlotRects[i]
    local slot = ingredientSlots[i]
    drawStackRect(slot, rect, false, i, false, 'ingredient_slot', i)
  end

  if layout.outputsShown == 0 then
    drawText(pass, 'No fully satisfied recipes', layout.rightX + layout.rightWidth * 0.5, layout.outputLabelY + 46 * layout.scale, 14 * layout.scale, 0.70, 0.74, 0.78, 0.95, 'center', 'top')
  else
    for i = 1, layout.outputsShown do
      local rect = layout.outputRects[i]
      local recipe = layout.craftables[i]
      local isHovered = hover and hover.kind == 'craft_output' and hover.outputIndex == i
      drawRect(pass, rect, isHovered and 0.20 or 0.09, isHovered and 0.16 or 0.10, isHovered and 0.09 or 0.12, 0.95)

      local outputId = recipe and (recipe.outputId or (recipe.output and recipe.output.id)) or nil
      local outputInfo = outputId and self.constants.BLOCK_INFO[outputId] or nil
      local outputColor = outputInfo and outputInfo.color or nil
      drawRect(
        pass,
        {
          x = rect.x + 8 * layout.scale,
          y = rect.y + rect.h * 0.5 - 9 * layout.scale,
          w = 18 * layout.scale,
          h = 18 * layout.scale
        },
        sanitizeNumber(outputColor and outputColor[1], 0.75),
        sanitizeNumber(outputColor and outputColor[2], 0.75),
        sanitizeNumber(outputColor and outputColor[3], 0.75),
        sanitizeNumber(outputInfo and outputInfo.alpha, 1)
      )

      local name = recipe and (recipe.name or recipe.label) or 'Recipe'
      local outCount = recipe and (recipe.outputCount or (recipe.output and recipe.output.count)) or 1
      drawText(pass, string.format('%s x%d', name, outCount), rect.x + 32 * layout.scale, rect.y + rect.h * 0.5, 14 * layout.scale, 0.94, 0.95, 0.96, 0.97, 'left', 'middle')
    end
  end

  local held = inventory and inventory.getHeldStack and inventory:getHeldStack() or nil
  if held and held.block and held.count and held.count > 0 then
    local heldInfo = self.constants.BLOCK_INFO[held.block]
    local heldName = heldInfo and heldInfo.name or 'Unknown'
    local heldRect = {
      x = layout.panelX + layout.panelWidth * 0.5 - 220 * layout.scale,
      y = layout.panelY + layout.panelHeight - layout.hintHeight - 38 * layout.scale,
      w = 440 * layout.scale,
      h = 30 * layout.scale
    }
    drawRect(pass, heldRect, 0.11, 0.12, 0.15, 0.88)
    drawText(pass, string.format('Holding: %s x%d', heldName, held.count), heldRect.x + heldRect.w * 0.5, heldRect.y + heldRect.h * 0.5, 14 * layout.scale, 0.97, 0.90, 0.66, 0.98, 'center', 'middle')
  end

  local hint = mode == 'workbench'
    and 'LMB move stack  RMB move one  Shift+Click output: craft max  Esc/Tab close'
    or 'LMB move stack  RMB move one  Click output to craft  Shift+Click output: craft max'
  drawText(pass, hint, layout.panelX + layout.panelWidth * 0.5, layout.panelY + layout.panelHeight - 10 * layout.scale, 12 * layout.scale, 0.80, 0.84, 0.90, 0.92, 'center', 'bottom')

  pass:pop('state')
end

return InventoryMenu
