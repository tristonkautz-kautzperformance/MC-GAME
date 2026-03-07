local Player = {}
Player.__index = Player

local EPSILON = 1e-4
local MOVE_AXIS_COARSE_STEP = 0.24
local MOVE_AXIS_BLOCKED_STEP = 0.08

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
  self.lookSmoothing = config.lookSmoothing or 0.15
  self.headBobEnabled = config.headBobEnabled ~= false
  self.headBobAmplitude = config.headBobAmplitude or 0.06
  self.headBobFrequency = config.headBobFrequency or 10.5

  self.yaw = 0
  self.pitch = 0
  self._targetYaw = 0
  self._targetPitch = 0
  self.velocityY = 0
  self.onGround = false
  self._cameraYawQuat = lovr.math.newQuat(0, 0, 1, 0)
  self._cameraPitchQuat = lovr.math.newQuat(0, 1, 0, 0)

  -- Head bob state
  self._bobPhase = 0
  self._bobAmount = 0
  self._wasMoving = false

  return self
end

function Player:applyLook(mouseDx, mouseDy)
  self._targetYaw = self._targetYaw - mouseDx * self.lookSensitivity
  self._targetPitch = self._targetPitch - mouseDy * self.lookSensitivity
  self._targetPitch = clamp(self._targetPitch, -1.50, 1.50)
end

function Player:updateLook(dt)
  dt = dt or (1 / 60)
  -- Exponential decay smoothing: faster when further from target
  local smoothing = self.lookSmoothing or 0.15
  local factor = 1.0 - math.exp(-smoothing * 60 * dt)
  
  -- Handle yaw wrap-around for shortest-path interpolation
  local yawDiff = self._targetYaw - self.yaw
  while yawDiff > math.pi do
    yawDiff = yawDiff - 2 * math.pi
    self._targetYaw = self._targetYaw - 2 * math.pi
  end
  while yawDiff < -math.pi do
    yawDiff = yawDiff + 2 * math.pi
    self._targetYaw = self._targetYaw + 2 * math.pi
  end
  
  self.yaw = self.yaw + yawDiff * factor
  self.pitch = self.pitch + (self._targetPitch - self.pitch) * factor
end

function Player:getLookVector()
  local cosPitch = math.cos(self.pitch)
  local x = -math.sin(self.yaw) * cosPitch
  local y = math.sin(self.pitch)
  local z = -math.cos(self.yaw) * cosPitch
  return x, y, z
end

function Player:getCameraPosition()
  local bobOffset = self.headBobEnabled and self:_getHeadBobOffset() or 0
  return self.x, self.y + self.eyeHeight + bobOffset, self.z
end

function Player:_getHeadBobOffset()
  -- Smooth fade in/out of bob
  return self._bobAmount * math.sin(self._bobPhase)
end

function Player:updateHeadBob(dt, isMovingOnGround)
  if not self.headBobEnabled then
    self._bobAmount = 0
    return
  end

  dt = dt or (1 / 60)
  local targetAmount = isMovingOnGround and self.headBobAmplitude or 0
  
  -- Smoothly fade bob in/out when starting/stopping
  local fadeSpeed = 8.0
  local diff = targetAmount - self._bobAmount
  if math.abs(diff) < 0.001 then
    self._bobAmount = targetAmount
  else
    self._bobAmount = self._bobAmount + diff * math.min(1.0, fadeSpeed * dt)
  end

  -- Advance phase when moving or when bob hasn't settled
  if isMovingOnGround or self._bobAmount > 0.001 then
    self._bobPhase = self._bobPhase + self.headBobFrequency * dt * math.pi * 2
  end
  
  -- Keep phase bounded to prevent floating point issues
  if self._bobPhase > math.pi * 1000 then
    self._bobPhase = self._bobPhase % (math.pi * 2)
  end
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
  local getBlock = world.get
  local blockInfo = world.constants and world.constants.BLOCK_INFO or nil

  for x = startX, endX do
    for y = startY, endY do
      for z = startZ, endZ do
        if getBlock and blockInfo then
          local block = getBlock(world, x, y, z)
          local info = blockInfo[block]
          if info then
            local collidable = info.collidable
            if collidable ~= nil then
              if collidable then
                return true
              end
            elseif info.solid then
              return true
            end
          end
        elseif world:isSolidAt(x, y, z) then
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

  local direction = amount >= 0 and 1 or -1
  local remaining = math.abs(amount)
  local coarseStep = MOVE_AXIS_COARSE_STEP
  local blockedStepLimit = MOVE_AXIS_BLOCKED_STEP

  while remaining > 1e-6 do
    local stepMagnitude = math.min(remaining, coarseStep)
    local step = direction * stepMagnitude

    self[axis] = self[axis] + step
    if self:_collides(world) then
      self[axis] = self[axis] - step

      local microSteps = math.max(1, math.ceil(stepMagnitude / blockedStepLimit))
      local microStep = step / microSteps
      for _ = 1, microSteps do
        self[axis] = self[axis] + microStep
        if self:_collides(world) then
          self[axis] = self[axis] - microStep
          return true
        end
      end

      return true
    end

    remaining = remaining - stepMagnitude
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

  -- Update head bob based on movement
  local isMoving = (math.abs(forwardInput) > 0 or math.abs(rightInput) > 0)
  local isMovingOnGround = isMoving and self.onGround
  self:updateHeadBob(dt, isMovingOnGround)
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
