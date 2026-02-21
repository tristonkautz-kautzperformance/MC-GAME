local Sky = {}
Sky.__index = Sky

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

function Sky.new(constants)
  local self = setmetatable({}, Sky)
  self.constants = constants
  self.timeOfDay = .2
  self.daylight = 1
  local bodyConfig = constants.SKY_BODIES or {}
  local distance = tonumber(bodyConfig.distance) or 260
  if distance < 40 then
    distance = 40
  end

  local sunSize = tonumber(bodyConfig.sunSize) or 18
  if sunSize < 0.5 then
    sunSize = 0.5
  end

  local moonSize = tonumber(bodyConfig.moonSize)
  if moonSize == nil then
    moonSize = sunSize * 0.9
  end
  if moonSize < 0.5 then
    moonSize = 0.5
  end

  local orbitTilt = tonumber(bodyConfig.orbitTiltDegrees)
  if orbitTilt == nil then
    orbitTilt = 22
  end
  orbitTilt = clamp(orbitTilt, -75, 75)

  local moonAlpha = clamp(tonumber(bodyConfig.moonAlpha) or 0.96, 0, 1)

  self._bodiesEnabled = bodyConfig.enabled ~= false
  self._bodyDistance = distance
  self._sunSize = sunSize
  self._moonSize = moonSize
  self._orbitTiltRadians = math.rad(orbitTilt)
  self._moonAlpha = moonAlpha
  self._drawPos = lovr and lovr.math and lovr.math.newVec3 and lovr.math.newVec3(0, 0, 0) or nil
  return self
end

function Sky:setTime(timeOfDay)
  if type(timeOfDay) ~= 'number'
    or timeOfDay ~= timeOfDay
    or timeOfDay == math.huge
    or timeOfDay == -math.huge then
    return
  end
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

function Sky:_computeOrbitDirection(angle)
  local flatX = math.cos(angle)
  local flatY = math.sin(angle)
  local ct = math.cos(self._orbitTiltRadians)
  local st = math.sin(self._orbitTiltRadians)
  return flatX * ct, flatY, flatX * st
end

function Sky:_drawSkyBody(pass, x, y, z, size, orientation)
  local pos = self._drawPos
  if pos and orientation then
    pos:set(x, y, z)
    pass:plane(pos, size, size, orientation)
    return
  end
  -- Fallback if orientation/vec3 is unavailable.
  pass:sphere(x, y, z, size * 0.32)
end

function Sky:draw(pass, cameraX, cameraY, cameraZ, cameraOrientation)
  if not self._bodiesEnabled then
    return
  end

  local angle = self.timeOfDay * math.pi * 2
  local dirX, dirY, dirZ = self:_computeOrbitDirection(angle)
  local baseX = tonumber(cameraX) or 0
  local baseY = tonumber(cameraY) or 0
  local baseZ = tonumber(cameraZ) or 0
  local distance = self._bodyDistance
  local sunX = baseX + dirX * distance
  local sunY = baseY + dirY * distance
  local sunZ = baseZ + dirZ * distance
  local moonX = baseX - dirX * distance
  local moonY = baseY - dirY * distance
  local moonZ = baseZ - dirZ * distance

  pass:push('state')
  pass:setColor(1.00, 0.97, 0.78, 1)
  self:_drawSkyBody(pass, sunX, sunY, sunZ, self._sunSize, cameraOrientation)

  pass:setColor(0.90, 0.94, 1.00, self._moonAlpha)
  self:_drawSkyBody(pass, moonX, moonY, moonZ, self._moonSize, cameraOrientation)
  pass:pop('state')
end

return Sky
