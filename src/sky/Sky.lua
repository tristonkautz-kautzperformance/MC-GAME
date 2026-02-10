local Sky = {}
Sky.__index = Sky

function Sky.new(constants)
  local self = setmetatable({}, Sky)
  self.constants = constants
  self.timeOfDay = .2
  self.daylight = 1
  return self
end

function Sky:setTime(timeOfDay)
  self.timeOfDay = timeOfDay % 1
  self.daylight = self:getDaylight()
end

function Sky:getDaylight()
  local t = self.timeOfDay
  local daylight = math.sin(t * math.pi * 2) * .5 + .5
  return daylight
end

function Sky:applyBackground(daylight)
  local day = self.constants.SKY_DAY
  local night = self.constants.SKY_NIGHT
  local r = night[1] + (day[1] - night[1]) * daylight
  local g = night[2] + (day[2] - night[2]) * daylight
  local b = night[3] + (day[3] - night[3]) * daylight
  lovr.graphics.setBackgroundColor(r, g, b)
end

function Sky:update(dt)
  local lengthSeconds = self.constants.DAY_LENGTH_SECONDS or 300
  self.timeOfDay = (self.timeOfDay + dt / lengthSeconds) % 1
  self.daylight = self:getDaylight()
  return self.timeOfDay, self.daylight
end

function Sky:draw(pass)
  local angle = self.timeOfDay * math.pi * 2
  local sunX = math.cos(angle) * 30
  local sunY = math.sin(angle) * 30
  local sunZ = -10

  pass:push('state')
  pass:setColor(1, 1, 0.8, 1)
  pass:sphere(sunX, sunY, sunZ, 1.2)
  pass:setColor(0.8, 0.8, 1.0, 1)
  pass:sphere(-sunX, -sunY, sunZ, 1.0)
  pass:pop('state')
end

return Sky
