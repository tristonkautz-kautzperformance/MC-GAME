local MouseLock = {}
MouseLock.__index = MouseLock

function MouseLock.new()
  local self = setmetatable({}, MouseLock)
  self.locked = false
  return self
end

function MouseLock:isLocked()
  return self.locked
end

function MouseLock:getStatusText()
  if self.locked then
    return 'Locked (relative)'
  end
  return 'Unlocked'
end

function MouseLock:_setRelativeMode(enabled)
  if lovr.mouse and lovr.mouse.setRelativeMode then
    lovr.mouse.setRelativeMode(enabled)
    if lovr.mouse.setVisible then
      lovr.mouse.setVisible(not enabled)
    end
  end
end

function MouseLock:lock()
  self.locked = true
  self:_setRelativeMode(true)
end

function MouseLock:unlock()
  self.locked = false
  self:_setRelativeMode(false)
end

function MouseLock:toggle()
  if self.locked then
    self:unlock()
  else
    self:lock()
  end
end

return MouseLock
