local MainMenu = {}
MainMenu.__index = MainMenu

local function parseInteger(value)
  local n = tonumber(value)
  if not n or n % 1 ~= 0 then
    return nil
  end
  return n
end

local function formatSavedAt(savedAt)
  local seconds = parseInteger(savedAt)
  if not seconds or seconds <= 0 or not os or not os.date then
    return 'Unknown'
  end

  local ok, formatted = pcall(os.date, '%Y-%m-%d %H:%M:%S', seconds)
  if not ok or type(formatted) ~= 'string' or formatted == '' then
    return 'Unknown'
  end
  return formatted
end

function MainMenu.new()
  local self = setmetatable({}, MainMenu)
  self.mode = 'main'
  self.hasSave = false
  self.canContinue = false
  self.saveMeta = nil
  self.statusText = nil
  self.items = {}
  self.selected = 1
  self.confirmAction = nil
  self._nextAction = nil
  self._cameraPosition = lovr.math.newVec3(0, 1.6, 0)
  self._cameraOrientation = lovr.math.newQuat()
  self._textOrientation = lovr.math.newQuat()
  self:_rebuildItems()
  return self
end

function MainMenu:getMode()
  return self.mode
end

function MainMenu:setMode(mode)
  if mode ~= 'main' and mode ~= 'pause' then
    return
  end
  if self.mode == mode then
    return
  end

  self.mode = mode
  self.confirmAction = nil
  self._nextAction = nil
  self:_rebuildItems()
end

function MainMenu:setSaveState(hasSave, canContinue, statusText)
  self.hasSave = hasSave and true or false
  self.canContinue = canContinue and true or false
  self.statusText = statusText
  self.confirmAction = nil
  self:_rebuildItems()
end

function MainMenu:setSaveMeta(meta)
  self.saveMeta = meta
end

function MainMenu:setStatusText(statusText)
  self.statusText = statusText
end

function MainMenu:_rebuildItems()
  local selectedAction = nil
  local current = self.items[self.selected]
  if current then
    selectedAction = current.action
  end

  local items = {}
  if self.mode == 'main' then
    items[1] = {
      label = 'Continue',
      action = 'continue',
      enabled = self.hasSave and self.canContinue
    }
    items[2] = {
      label = 'New Game',
      action = 'new_game',
      enabled = true
    }
    items[3] = {
      label = 'Delete Save',
      action = 'delete_save',
      enabled = self.hasSave
    }
    items[4] = {
      label = 'Quit',
      action = 'quit',
      enabled = true
    }
  else
    items[1] = {
      label = 'Resume',
      action = 'resume',
      enabled = true
    }
    items[2] = {
      label = 'Save',
      action = 'save',
      enabled = true
    }
    items[3] = {
      label = 'Delete Save',
      action = 'delete_save',
      enabled = true
    }
    items[4] = {
      label = 'Quit',
      action = 'quit',
      enabled = true
    }
  end

  self.items = items
  self.selected = 1

  if selectedAction then
    for i = 1, #self.items do
      if self.items[i].action == selectedAction then
        self.selected = i
        break
      end
    end
  end

  if not self.items[self.selected].enabled then
    self:_moveSelection(1)
  end
end

function MainMenu:_moveSelection(delta)
  if #self.items == 0 then
    return
  end

  local index = self.selected
  for _ = 1, #self.items do
    index = index + delta
    if index < 1 then
      index = #self.items
    elseif index > #self.items then
      index = 1
    end

    if self.items[index].enabled then
      self.selected = index
      return
    end
  end
end

function MainMenu:_activateSelected()
  local item = self.items[self.selected]
  if not item or not item.enabled then
    return
  end

  if item.action == 'new_game' then
    if self.hasSave then
      if self.confirmAction == 'new_game' then
        self.confirmAction = nil
        self._nextAction = 'new_game_confirmed'
      else
        self.confirmAction = 'new_game'
        self.statusText = 'Press Enter again to overwrite save.'
      end
    else
      self.confirmAction = nil
      self._nextAction = 'new_game_confirmed'
    end
    return
  end

  if item.action == 'delete_save' then
    if self.confirmAction == 'delete_save' then
      self.confirmAction = nil
      self._nextAction = 'delete_save_confirmed'
    else
      self.confirmAction = 'delete_save'
    end
    return
  end

  self.confirmAction = nil
  self._nextAction = item.action
end

function MainMenu:onKeyPressed(key)
  if key == 'up' or key == 'w' then
    if self.confirmAction == 'new_game' then
      self.statusText = nil
    end
    self.confirmAction = nil
    self:_moveSelection(-1)
    return
  end

  if key == 'down' or key == 's' then
    if self.confirmAction == 'new_game' then
      self.statusText = nil
    end
    self.confirmAction = nil
    self:_moveSelection(1)
    return
  end

  if key == 'return' or key == 'kpenter' then
    self:_activateSelected()
    return
  end

  if key == 'escape' then
    if self.confirmAction then
      if self.confirmAction == 'new_game' then
        self.statusText = nil
      end
      self.confirmAction = nil
      return
    end
    if self.mode == 'pause' then
      self._nextAction = 'resume'
    else
      self._nextAction = 'quit'
    end
  end
end

function MainMenu:consumeAction()
  local action = self._nextAction
  self._nextAction = nil
  return action
end

function MainMenu:draw(pass)
  pass:setViewPose(1, self._cameraPosition, self._cameraOrientation)
  pass:push('state')

  local title = self.mode == 'main' and 'Voxel Clone' or 'Paused'
  local subtitle = self.mode == 'main'
    and 'Enter: Select  Up/Down: Navigate  Esc: Quit'
    or 'Enter: Select  Up/Down: Navigate  Esc: Resume'

  pass:setColor(0.95, 0.96, 0.98, 1)
  pass:text(title, -0.90, 2.10, -2.6, 0.14, self._textOrientation)
  pass:setColor(0.75, 0.80, 0.86, 1)
  pass:text(subtitle, -0.90, 1.95, -2.6, 0.05, self._textOrientation)

  local y = 1.72
  for i = 1, #self.items do
    local item = self.items[i]
    local isSelected = (i == self.selected)
    local prefix = isSelected and '> ' or '  '
    local label = prefix .. item.label
    if not item.enabled then
      label = label .. ' (Unavailable)'
    end

    if item.enabled then
      if isSelected then
        pass:setColor(1.00, 0.95, 0.72, 1)
      else
        pass:setColor(0.92, 0.92, 0.92, 1)
      end
    else
      pass:setColor(0.48, 0.50, 0.53, 1)
    end

    pass:text(label, -0.90, y, -2.6, 0.07, self._textOrientation)
    y = y - 0.12
  end

  local messageY = y - 0.06
  if self.mode == 'main' then
    local saveMeta = self.saveMeta
    local saveSummary = 'Save: None'
    local lastSaved = 'Last saved: Unknown'
    local editsText = 'Edits: 0'

    if self.hasSave then
      if saveMeta and saveMeta.ok then
        local versionLabel = saveMeta.version == 2 and 'V2' or (saveMeta.version == 1 and 'V1' or '?')
        saveSummary = string.format('Save: Available (%s)', versionLabel)
        lastSaved = string.format('Last saved: %s', formatSavedAt(saveMeta.savedAt))
        local editCount = parseInteger(saveMeta.editCount) or 0
        editsText = string.format('Edits: %d', math.max(0, editCount))
      elseif saveMeta and saveMeta.err == 'incompatible' then
        saveSummary = 'Save: Incompatible'
        local versionLabel = saveMeta.version == 2 and 'V2' or (saveMeta.version == 1 and 'V1' or '?')
        editsText = string.format('Version: %s', versionLabel)
      elseif saveMeta and saveMeta.err == 'corrupt' then
        saveSummary = 'Save: Corrupt'
        local versionLabel = saveMeta.version == 2 and 'V2' or (saveMeta.version == 1 and 'V1' or '?')
        editsText = string.format('Version: %s', versionLabel)
      else
        saveSummary = 'Save: Unavailable'
      end
    end

    local metaY = y - 0.02
    pass:setColor(0.70, 0.76, 0.82, 1)
    pass:text(saveSummary, -0.90, metaY, -2.6, 0.048, self._textOrientation)
    pass:text(lastSaved, -0.90, metaY - 0.08, -2.6, 0.048, self._textOrientation)
    pass:text(editsText, -0.90, metaY - 0.16, -2.6, 0.048, self._textOrientation)
    messageY = metaY - 0.28
  end

  if self.confirmAction == 'delete_save' then
    pass:setColor(1.00, 0.72, 0.65, 1)
    pass:text('Press Enter again to confirm delete.', -0.90, messageY, -2.6, 0.05, self._textOrientation)
    messageY = messageY - 0.12
  end

  if self.statusText and self.statusText ~= '' then
    pass:setColor(1.00, 0.84, 0.55, 1)
    pass:text(self.statusText, -0.90, messageY, -2.6, 0.05, self._textOrientation)
  end

  pass:pop('state')
end

return MainMenu
