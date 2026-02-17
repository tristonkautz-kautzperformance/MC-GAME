local Input = {}
Input.__index = Input

function Input.new(mouseLock, inventory)
  local self = setmetatable({}, Input)
  self.mouseLock = mouseLock
  self.inventory = inventory

  self.keysDown = {}
  self.lookDx = 0
  self.lookDy = 0

  self.wantJump = false
  self.wantBreak = false
  self.wantPlace = false
  self.wantToggleHelp = false
  self.wantTogglePerfHud = false
  self.wantToggleFullscreen = false
  self.wantOpenMenu = false
  self.wantQuit = false
  self.wantToggleInventoryMenu = false

  self.inventoryMenuOpen = false
  self.inventoryMoveX = 0
  self.inventoryMoveY = 0
  self.wantInventoryInteract = false

  return self
end

function Input:beginFrame()
  self.lookDx = 0
  self.lookDy = 0
  self.wantBreak = false
  self.wantPlace = false
  self.inventoryMoveX = 0
  self.inventoryMoveY = 0
  self.wantInventoryInteract = false
end

function Input:onKeyPressed(key)
  if key == 'f1' then
    self.wantToggleHelp = true
    return
  end

  if key == 'f3' then
    self.wantTogglePerfHud = true
    return
  end

  if key == 'f11' then
    self.wantToggleFullscreen = true
    return
  end

  if key == 'tab' then
    self.wantToggleInventoryMenu = true
    return
  end

  if self.inventoryMenuOpen then
    if key == 'escape' then
      self.wantToggleInventoryMenu = true
    elseif key == 'left' or key == 'a' then
      self.inventoryMoveX = self.inventoryMoveX - 1
    elseif key == 'right' or key == 'd' then
      self.inventoryMoveX = self.inventoryMoveX + 1
    elseif key == 'up' or key == 'w' then
      self.inventoryMoveY = self.inventoryMoveY - 1
    elseif key == 'down' or key == 's' then
      self.inventoryMoveY = self.inventoryMoveY + 1
    elseif key == 'space' or key == 'return' or key == 'kpenter' then
      self.wantInventoryInteract = true
    else
      local index = tonumber(key)
      if index and self.inventory then
        self.inventory:setSelectedIndex(index)
      end
    end
    return
  end

  self.keysDown[key] = true

  if key == 'space' then
    self.wantJump = true
  elseif key == 'escape' then
    if self.mouseLock and self.mouseLock:isLocked() then
      self.mouseLock:unlock()
    else
      self.wantOpenMenu = true
    end
  else
    local index = tonumber(key)
    if index and self.inventory then
      self.inventory:setSelectedIndex(index)
    end
  end
end

function Input:onKeyReleased(key)
  if self.inventoryMenuOpen then
    return
  end
  self.keysDown[key] = nil
end

function Input:onMouseMoved(dx, dy)
  if self.inventoryMenuOpen then
    return
  end

  if self.mouseLock and not self.mouseLock:isLocked() then
    return
  end

  self.lookDx = self.lookDx + dx
  self.lookDy = self.lookDy + dy
end

function Input:onMousePressed(button)
  if self.inventoryMenuOpen then
    if button == 1 then
      self.wantInventoryInteract = true
    end
    return
  end

  if not (self.mouseLock and self.mouseLock:isLocked()) then
    if self.mouseLock then
      self.mouseLock:lock()
    end
    return
  end

  if button == 1 then
    self.wantBreak = true
  elseif button == 2 then
    self.wantPlace = true
  end
end

function Input:onWheelMoved(dy)
  if dy == 0 then
    return
  end

  if self.inventoryMenuOpen then
    return
  end

  if self.mouseLock and self.mouseLock:isLocked() and self.inventory then
    self.inventory:cycle(dy > 0 and 1 or -1)
  end
end

function Input:onFocus(focused)
  if not focused then
    if self.mouseLock then
      self.mouseLock:unlock()
    end
    self.keysDown = {}
    self.wantJump = false
    self.wantBreak = false
    self.wantPlace = false
    self.wantToggleHelp = false
    self.wantTogglePerfHud = false
    self.wantToggleFullscreen = false
    self.wantOpenMenu = false
    self.wantQuit = false
    self.wantToggleInventoryMenu = false
    self.inventoryMenuOpen = false
    self.inventoryMoveX = 0
    self.inventoryMoveY = 0
    self.wantInventoryInteract = false
  end
end

function Input:setInventoryMenuOpen(open)
  local nextState = open and true or false
  self.inventoryMenuOpen = nextState
  self.keysDown = {}
  self.lookDx = 0
  self.lookDy = 0
  self.wantJump = false
  self.wantBreak = false
  self.wantPlace = false
  self.inventoryMoveX = 0
  self.inventoryMoveY = 0
  self.wantInventoryInteract = false
end

function Input:isInventoryMenuOpen()
  return self.inventoryMenuOpen
end

function Input:getLookDelta()
  return self.lookDx, self.lookDy
end

function Input:getMoveAxes()
  if self.inventoryMenuOpen then
    return 0, 0
  end

  local forward = 0
  local right = 0

  if self.keysDown['w'] then forward = forward + 1 end
  if self.keysDown['s'] then forward = forward - 1 end
  if self.keysDown['d'] then right = right + 1 end
  if self.keysDown['a'] then right = right - 1 end

  return forward, right
end

function Input:consumeJump()
  local v = self.wantJump
  self.wantJump = false
  return v
end

function Input:consumeBreak()
  local v = self.wantBreak
  self.wantBreak = false
  return v
end

function Input:consumePlace()
  local v = self.wantPlace
  self.wantPlace = false
  return v
end

function Input:consumeToggleHelp()
  local v = self.wantToggleHelp
  self.wantToggleHelp = false
  return v
end

function Input:consumeTogglePerfHud()
  local v = self.wantTogglePerfHud
  self.wantTogglePerfHud = false
  return v
end

function Input:consumeToggleFullscreen()
  local v = self.wantToggleFullscreen
  self.wantToggleFullscreen = false
  return v
end

function Input:consumeOpenMenu()
  local v = self.wantOpenMenu
  self.wantOpenMenu = false
  return v
end

function Input:consumeToggleInventoryMenu()
  local v = self.wantToggleInventoryMenu
  self.wantToggleInventoryMenu = false
  return v
end

function Input:consumeInventoryMove()
  local x = self.inventoryMoveX
  local y = self.inventoryMoveY
  self.inventoryMoveX = 0
  self.inventoryMoveY = 0
  return x, y
end

function Input:consumeInventoryInteract()
  local v = self.wantInventoryInteract
  self.wantInventoryInteract = false
  return v
end

function Input:consumeQuit()
  local v = self.wantQuit
  self.wantQuit = false
  return v
end

return Input
