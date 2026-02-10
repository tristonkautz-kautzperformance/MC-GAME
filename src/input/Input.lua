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
  self.wantQuit = false

  return self
end

function Input:beginFrame()
  self.lookDx = 0
  self.lookDy = 0
  self.wantBreak = false
  self.wantPlace = false
end

function Input:onKeyPressed(key)
  self.keysDown[key] = true

  if key == 'space' then
    self.wantJump = true
  elseif key == 'tab' then
    if self.mouseLock then
      self.mouseLock:toggle()
    end
  elseif key == 'f1' then
    self.wantToggleHelp = true
  elseif key == 'f3' then
    self.wantTogglePerfHud = true
  elseif key == 'f11' then
    self.wantToggleFullscreen = true
  elseif key == 'escape' then
    if self.mouseLock and self.mouseLock:isLocked() then
      self.mouseLock:unlock()
    else
      self.wantQuit = true
    end
  else
    local index = tonumber(key)
    if index and self.inventory then
      self.inventory:setSelectedIndex(index)
    end
  end
end

function Input:onKeyReleased(key)
  self.keysDown[key] = nil
end

function Input:onMouseMoved(dx, dy)
  if self.mouseLock and not self.mouseLock:isLocked() then
    return
  end

  self.lookDx = self.lookDx + dx
  self.lookDy = self.lookDy + dy
end

function Input:onMousePressed(button)
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
    self.wantQuit = false
  end
end

function Input:getLookDelta()
  return self.lookDx, self.lookDy
end

function Input:getMoveAxes()
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

function Input:consumeQuit()
  local v = self.wantQuit
  self.wantQuit = false
  return v
end

return Input
