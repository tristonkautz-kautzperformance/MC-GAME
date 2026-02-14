local Player = {}
Player.__index = Player

local EPSILON = 1e-4

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  elseif value > maxValue then
    return maxValue
  end

  return value
end

function Player.new(config, x, y, z)
  local self = setmetatable({}, Player)
  self.x = x
  self.y = y
  self.z = z

  self.radius = config.radius
  self.height = config.height
  self.eyeHeight = config.eyeHeight
  self.speed = config.speed
  self.gravity = config.gravity
  self.jumpSpeed = config.jumpSpeed
  self.reach = config.reach
  self.lookSensitivity = config.lookSensitivity

  self.yaw = 0
  self.pitch = 0
  self.velocityY = 0
  self.onGround = false
  self._cameraYawQuat = lovr.math.newQuat(0, 0, 1, 0)
  self._cameraPitchQuat = lovr.math.newQuat(0, 1, 0, 0)

  return self
end

function Player:applyLook(mouseDx, mouseDy)
  self.yaw = self.yaw - mouseDx * self.lookSensitivity
  self.pitch = self.pitch - mouseDy * self.lookSensitivity
  self.pitch = clamp(self.pitch, -1.50, 1.50)
end

function Player:getLookVector()
  local cosPitch = math.cos(self.pitch)
  local x = -math.sin(self.yaw) * cosPitch
  local y = math.sin(self.pitch)
  local z = -math.cos(self.yaw) * cosPitch
  return x, y, z
end

function Player:getCameraPosition()
  return self.x, self.y + self.eyeHeight, self.z
end

function Player:getCameraOrientation()
  local yaw = self._cameraYawQuat
  local pitch = self._cameraPitchQuat
  yaw:set(self.yaw, 0, 1, 0)
  pitch:set(self.pitch, 1, 0, 0)
  yaw:mul(pitch)
  return yaw
end

function Player:_collides(world)
  local minX = self.x - self.radius
  local maxX = self.x + self.radius
  local minY = self.y
  local maxY = self.y + self.height
  local minZ = self.z - self.radius
  local maxZ = self.z + self.radius

  -- Finite world bounds: keep the player inside the playable volume.
  if minX < 0 or maxX > world.sizeX or minY < 0 or maxY > world.sizeY or minZ < 0 or maxZ > world.sizeZ then
    return true
  end

  local startX = math.floor(minX + EPSILON) + 1
  local endX = math.floor(maxX - EPSILON) + 1
  local startY = math.floor(minY + EPSILON) + 1
  local endY = math.floor(maxY - EPSILON) + 1
  local startZ = math.floor(minZ + EPSILON) + 1
  local endZ = math.floor(maxZ - EPSILON) + 1

  for x = startX, endX do
    for y = startY, endY do
      for z = startZ, endZ do
        if world:isSolidAt(x, y, z) then
          return true
        end
      end
    end
  end

  return false
end

function Player:_moveAxis(world, axis, amount)
  if amount == 0 then
    return false
  end

  local steps = math.max(1, math.ceil(math.abs(amount) / .08))
  local step = amount / steps

  for _ = 1, steps do
    self[axis] = self[axis] + step

    if self:_collides(world) then
      self[axis] = self[axis] - step
      return true
    end
  end

  return false
end

function Player:update(dt, world, input)
  local forwardInput = input.forward or 0
  local rightInput = input.right or 0
  local jump = input.jump or false

  local length = math.sqrt(forwardInput * forwardInput + rightInput * rightInput)
  if length > 0 then
    forwardInput = forwardInput / length
    rightInput = rightInput / length
  end

  local sinYaw = math.sin(self.yaw)
  local cosYaw = math.cos(self.yaw)
  local wishX = cosYaw * rightInput - sinYaw * forwardInput
  local wishZ = -sinYaw * rightInput - cosYaw * forwardInput

  local moveX = wishX * self.speed * dt
  local moveZ = wishZ * self.speed * dt

  self:_moveAxis(world, 'x', moveX)
  self:_moveAxis(world, 'z', moveZ)

  if jump and self.onGround then
    self.velocityY = self.jumpSpeed
    self.onGround = false
  end

  self.velocityY = self.velocityY - self.gravity * dt
  local hitVertical = self:_moveAxis(world, 'y', self.velocityY * dt)

  if hitVertical then
    if self.velocityY < 0 then
      self.onGround = true
    end

    self.velocityY = 0
  else
    self.onGround = false
  end
end

function Player:overlapsBlock(x, y, z)
  local playerMinX = self.x - self.radius
  local playerMaxX = self.x + self.radius
  local playerMinY = self.y
  local playerMaxY = self.y + self.height
  local playerMinZ = self.z - self.radius
  local playerMaxZ = self.z + self.radius

  local blockMinX = x - 1
  local blockMaxX = x
  local blockMinY = y - 1
  local blockMaxY = y
  local blockMinZ = z - 1
  local blockMaxZ = z

  return playerMinX < blockMaxX and playerMaxX > blockMinX
    and playerMinY < blockMaxY and playerMaxY > blockMinY
    and playerMinZ < blockMaxZ and playerMaxZ > blockMinZ
end

return Player
