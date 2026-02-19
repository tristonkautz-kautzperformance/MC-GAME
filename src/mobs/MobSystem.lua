local MobSystem = {}
MobSystem.__index = MobSystem

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function isFiniteNumber(value)
  return type(value) == 'number'
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function parseNumber(value, fallback)
  local n = tonumber(value)
  if not isFiniteNumber(n) then
    return fallback
  end
  return n
end

local function raySphere(originX, originY, originZ, dirX, dirY, dirZ, centerX, centerY, centerZ, radius)
  local mx = originX - centerX
  local my = originY - centerY
  local mz = originZ - centerZ

  local b = mx * dirX + my * dirY + mz * dirZ
  local c = mx * mx + my * my + mz * mz - radius * radius
  if c > 0 and b > 0 then
    return nil
  end

  local discriminant = b * b - c
  if discriminant < 0 then
    return nil
  end

  local t = -b - math.sqrt(discriminant)
  if t < 0 then
    t = 0
  end
  return t
end

function MobSystem.new(constants, world, player, stats)
  local self = setmetatable({}, MobSystem)
  self.constants = constants
  self.world = world
  self.player = player
  self.stats = stats

  local cfg = constants.MOBS or {}
  self.enabled = cfg.enabled ~= false
  self.maxSheep = math.max(0, math.floor(parseNumber(cfg.maxSheep, 4)))
  self.maxGhosts = math.max(0, math.floor(parseNumber(cfg.maxGhosts, 2)))
  self.sheepSpawnInterval = math.max(0.1, parseNumber(cfg.sheepSpawnIntervalSeconds, 8))
  self.ghostSpawnInterval = math.max(0.1, parseNumber(cfg.ghostSpawnIntervalSeconds, 12))
  self.spawnMinDistance = math.max(2, parseNumber(cfg.spawnMinDistance, 10))
  self.spawnMaxDistance = math.max(self.spawnMinDistance, parseNumber(cfg.spawnMaxDistance, 24))
  self.despawnDistance = math.max(self.spawnMaxDistance, parseNumber(cfg.despawnDistance, 52))
  self.sheepSpeed = math.max(0.1, parseNumber(cfg.sheepSpeed, 1.2))
  self.ghostSpeed = math.max(0.1, parseNumber(cfg.ghostSpeed, 2.2))
  self.ghostAttackRange = math.max(0.5, parseNumber(cfg.ghostAttackRange, 1.25))
  self.ghostAttackDamage = math.max(0, parseNumber(cfg.ghostAttackDamage, 2))
  self.ghostAttackCooldown = math.max(0.1, parseNumber(cfg.ghostAttackCooldownSeconds, 1.4))
  self.aiTickSeconds = math.max(0.05, parseNumber(cfg.aiTickSeconds, 0.20))
  self.maxAiTicksPerFrame = math.max(1, math.floor(parseNumber(cfg.maxAiTicksPerFrame, 2)))
  self.nightDaylightThreshold = clamp(parseNumber(cfg.nightDaylightThreshold, 0.30), 0, 1)

  self._sheepTimer = 0
  self._ghostTimer = 0
  self._time = 0
  self._timeOfDay = 0
  self._aiAccumulator = 0
  self._nextId = 1

  self.mobs = {}
  self._sheepCount = 0
  self._ghostCount = 0
  self.targetMob = nil
  self._simulationCenterCx = nil
  self._simulationCenterCz = nil
  self._simulationRadiusChunks = nil
  self._simulationMinCx = nil
  self._simulationMaxCx = nil
  self._simulationMinCz = nil
  self._simulationMaxCz = nil
  self._simulationMinX = nil
  self._simulationMaxX = nil
  self._simulationMinZ = nil
  self._simulationMaxZ = nil
  self._groundCacheY = {}
  self._groundCacheRevision = {}

  return self
end

function MobSystem:_countByKind(kind)
  if kind == 'sheep' then
    return self._sheepCount or 0
  end
  if kind == 'ghost' then
    return self._ghostCount or 0
  end

  local count = 0
  for i = 1, #self.mobs do
    local mob = self.mobs[i]
    if mob.kind == kind then
      count = count + 1
    end
  end
  return count
end

function MobSystem:_computeDaylight(timeOfDay)
  local t = (parseNumber(timeOfDay, 0) or 0) % 1
  return math.sin(t * math.pi * 2) * 0.5 + 0.5
end

function MobSystem:_isNight(timeOfDay)
  return self:_computeDaylight(timeOfDay) <= self.nightDaylightThreshold
end

function MobSystem:_adjustKindCount(kind, delta)
  local amount = math.floor(tonumber(delta) or 0)
  if amount == 0 then
    return
  end

  if kind == 'sheep' then
    self._sheepCount = math.max(0, (self._sheepCount or 0) + amount)
  elseif kind == 'ghost' then
    self._ghostCount = math.max(0, (self._ghostCount or 0) + amount)
  end
end

function MobSystem:_removeMobAt(index)
  local mobs = self.mobs
  local lastIndex = #mobs
  if index < 1 or index > lastIndex then
    return nil
  end

  local removed = mobs[index]
  local lastMob = mobs[lastIndex]
  mobs[lastIndex] = nil
  if index < lastIndex then
    mobs[index] = lastMob
  end

  if removed then
    if self.targetMob == removed then
      self.targetMob = nil
    end
    self:_adjustKindCount(removed.kind, -1)
  end
  return removed
end

function MobSystem:_setSimulationWindow(centerCx, centerCz, radiusChunks)
  local radius = tonumber(radiusChunks)
  if not radius or radius < 0 then
    self._simulationCenterCx = nil
    self._simulationCenterCz = nil
    self._simulationRadiusChunks = nil
    self._simulationMinCx = nil
    self._simulationMaxCx = nil
    self._simulationMinCz = nil
    self._simulationMaxCz = nil
    self._simulationMinX = nil
    self._simulationMaxX = nil
    self._simulationMinZ = nil
    self._simulationMaxZ = nil
    return
  end

  local world = self.world
  local centerChunkX = clamp(math.floor(tonumber(centerCx) or 1), 1, world.chunksX)
  local centerChunkZ = clamp(math.floor(tonumber(centerCz) or 1), 1, world.chunksZ)
  local radiusChunksInt = math.floor(radius)

  local minChunkX = clamp(centerChunkX - radiusChunksInt, 1, world.chunksX)
  local maxChunkX = clamp(centerChunkX + radiusChunksInt, 1, world.chunksX)
  local minChunkZ = clamp(centerChunkZ - radiusChunksInt, 1, world.chunksZ)
  local maxChunkZ = clamp(centerChunkZ + radiusChunksInt, 1, world.chunksZ)
  local chunkSize = world.chunkSize

  self._simulationCenterCx = centerChunkX
  self._simulationCenterCz = centerChunkZ
  self._simulationRadiusChunks = radiusChunksInt
  self._simulationMinCx = minChunkX
  self._simulationMaxCx = maxChunkX
  self._simulationMinCz = minChunkZ
  self._simulationMaxCz = maxChunkZ
  self._simulationMinX = (minChunkX - 1) * chunkSize
  self._simulationMaxX = maxChunkX * chunkSize
  self._simulationMinZ = (minChunkZ - 1) * chunkSize
  self._simulationMaxZ = maxChunkZ * chunkSize
end

function MobSystem:_isInsideSimulationWindow(worldX, worldZ)
  local minX = self._simulationMinX
  if minX == nil then
    return true
  end

  local x = tonumber(worldX) or 0
  if x < minX or x >= (self._simulationMaxX or 0) then
    return false
  end

  local z = tonumber(worldZ) or 0
  if z < (self._simulationMinZ or 0) or z >= (self._simulationMaxZ or 0) then
    return false
  end

  return true
end

function MobSystem:_getWorldEditRevision()
  local world = self.world
  if not world then
    return 0
  end

  if world.getEditRevision then
    local revision = tonumber(world:getEditRevision())
    if revision then
      return revision
    end
  end

  if world.getEditCount then
    return tonumber(world:getEditCount()) or 0
  end

  return 0
end

function MobSystem:_findGroundY(worldX, worldZ)
  local world = self.world
  local ix = math.floor(worldX) + 1
  local iz = math.floor(worldZ) + 1
  if not world:isInside(ix, 2, iz) then
    return nil
  end

  if world.prepareChunk then
    local chunkSize = world.chunkSize
    local cx = math.floor((ix - 1) / chunkSize) + 1
    local cz = math.floor((iz - 1) / chunkSize) + 1
    world:prepareChunk(cx, 1, cz)
  end

  local key = ix + (iz - 1) * world.sizeX
  local revision = self:_getWorldEditRevision()
  local cachedRevision = self._groundCacheRevision[key]
  if cachedRevision == revision then
    local cachedY = self._groundCacheY[key]
    if cachedY == false then
      return nil
    end
    return cachedY
  end

  local foundY = nil
  for y = world.sizeY - 1, 2, -1 do
    if world:isSolidAt(ix, y, iz) and not world:isSolidAt(ix, y + 1, iz) then
      foundY = y
      break
    end
  end

  self._groundCacheRevision[key] = revision
  self._groundCacheY[key] = foundY or false
  return foundY
end

function MobSystem:_createSheep(x, y, z)
  return {
    id = self._nextId,
    kind = 'sheep',
    x = x,
    y = y,
    z = z,
    size = 0.9,
    health = 6,
    maxHealth = 6,
    speed = self.sheepSpeed,
    dirX = 0,
    dirZ = 0,
    wanderTimer = 0,
    hurtTimer = 0
  }
end

function MobSystem:_createGhost(x, y, z)
  return {
    id = self._nextId,
    kind = 'ghost',
    x = x,
    y = y,
    z = z,
    size = 0.8,
    health = 8,
    maxHealth = 8,
    speed = self.ghostSpeed,
    baseY = y,
    bobPhase = math.random() * math.pi * 2,
    attackCooldown = 0,
    hurtTimer = 0
  }
end

function MobSystem:_spawn(kind)
  local playerX, _, playerZ = self.player:getCameraPosition()
  for _ = 1, 24 do
    local angle = math.random() * math.pi * 2
    local distance = self.spawnMinDistance + math.random() * (self.spawnMaxDistance - self.spawnMinDistance)
    local x = playerX + math.cos(angle) * distance
    local z = playerZ + math.sin(angle) * distance

    if x > 1.5 and x < self.world.sizeX - 0.5 and z > 1.5 and z < self.world.sizeZ - 0.5 then
      local groundY = self:_findGroundY(x, z)
      if groundY then
        local mob = nil
        if kind == 'sheep' then
          mob = self:_createSheep(x, groundY + 0.45, z)
        elseif kind == 'ghost' then
          mob = self:_createGhost(x, groundY + 2.2 + math.random() * 1.4, z)
        end

        if mob then
          self._nextId = self._nextId + 1
          self.mobs[#self.mobs + 1] = mob
          self:_adjustKindCount(mob.kind, 1)
          return true
        end
      end
    end
  end

  return false
end

function MobSystem:_updateSheep(mob, dt)
  mob.wanderTimer = (mob.wanderTimer or 0) - dt
  if mob.wanderTimer <= 0 then
    local angle = math.random() * math.pi * 2
    mob.dirX = math.cos(angle)
    mob.dirZ = math.sin(angle)
    mob.wanderTimer = 1.8 + math.random() * 3.2
  end

  local move = mob.speed * dt
  local nextX = mob.x + mob.dirX * move
  local nextZ = mob.z + mob.dirZ * move
  local groundY = self:_findGroundY(nextX, nextZ)
  if not groundY then
    mob.wanderTimer = 0
    return
  end

  mob.x = nextX
  mob.z = nextZ
  mob.y = groundY + mob.size * 0.5
end

function MobSystem:_updateGhost(mob, dt, playerX, playerY, playerZ)
  local dx = playerX - mob.x
  local dz = playerZ - mob.z
  local distXZSq = dx * dx + dz * dz

  if distXZSq > 1e-10 then
    local distXZ = math.sqrt(distXZSq)
    local step = math.min(distXZ, mob.speed * dt)
    mob.x = mob.x + (dx / distXZ) * step
    mob.z = mob.z + (dz / distXZ) * step
  end

  local groundY = self:_findGroundY(mob.x, mob.z)
  if groundY then
    mob.baseY = groundY + 2.2
  end
  mob.y = (mob.baseY or mob.y) + math.sin(self._time * 2.2 + (mob.bobPhase or 0)) * 0.16

  local dy = (playerY - 0.7) - mob.y
  local attackRange = self.ghostAttackRange
  local distSq = dx * dx + dy * dy + dz * dz
  if distSq <= attackRange * attackRange and mob.attackCooldown <= 0 then
    if self.stats and self.stats.applyDamage then
      self.stats:applyDamage(self.ghostAttackDamage)
    end
    mob.attackCooldown = self.ghostAttackCooldown
  end
end

function MobSystem:updateTarget(originX, originY, originZ, dirX, dirY, dirZ, reach)
  self.targetMob = nil
  if not self.enabled or #self.mobs == 0 then
    return nil
  end

  local maxDistance = parseNumber(reach, 6) or 6
  local bestDistance = maxDistance + 1
  local bestMob = nil

  for i = 1, #self.mobs do
    local mob = self.mobs[i]
    if self:_isInsideSimulationWindow(mob.x, mob.z) then
      local radius = math.max(0.35, mob.size * 0.55)
      local t = raySphere(originX, originY, originZ, dirX, dirY, dirZ, mob.x, mob.y, mob.z, radius)
      if t and t <= maxDistance and t < bestDistance then
        bestDistance = t
        bestMob = mob
      end
    end
  end

  self.targetMob = bestMob
  return bestMob
end

function MobSystem:tryAttackTarget(damage)
  local mob = self.targetMob
  if not mob then
    return false
  end

  local hitDamage = math.max(0, parseNumber(damage, 0) or 0)
  if hitDamage <= 0 then
    return false
  end

  mob.health = mob.health - hitDamage
  mob.hurtTimer = 0.16
  if mob.health <= 0 then
    mob.dead = true
  end
  return true
end

function MobSystem:getTargetName()
  local mob = self.targetMob
  if not mob then
    return 'None'
  end
  if mob.kind == 'sheep' then
    return 'Sheep'
  end
  if mob.kind == 'ghost' then
    return 'Ghost'
  end
  return 'Mob'
end

function MobSystem:onPlayerRespawn()
  local i = 1
  while i <= #self.mobs do
    local mob = self.mobs[i]
    if mob and mob.kind == 'ghost' then
      self:_removeMobAt(i)
    else
      i = i + 1
    end
  end
  self.targetMob = nil
  self._ghostTimer = 0
end

function MobSystem:_decayTimers(delta)
  local i = 1
  while i <= #self.mobs do
    local mob = self.mobs[i]
    if mob.dead then
      self:_removeMobAt(i)
    else
      mob.hurtTimer = math.max(0, (mob.hurtTimer or 0) - delta)
      if mob.kind == 'ghost' then
        mob.attackCooldown = math.max(0, (mob.attackCooldown or 0) - delta)
      end
      i = i + 1
    end
  end
end

function MobSystem:_updateAiStep(delta)
  local night = self:_isNight(self._timeOfDay)
  self._sheepTimer = self._sheepTimer + delta
  if self._sheepTimer >= self.sheepSpawnInterval and (self._sheepCount or 0) < self.maxSheep then
    self._sheepTimer = 0
    self:_spawn('sheep')
  end

  self._ghostTimer = self._ghostTimer + delta
  if night and self._ghostTimer >= self.ghostSpawnInterval and (self._ghostCount or 0) < self.maxGhosts then
    self._ghostTimer = 0
    self:_spawn('ghost')
  end

  local playerX, playerY, playerZ = self.player:getCameraPosition()
  local despawnDistance2 = self.despawnDistance * self.despawnDistance

  local i = 1
  while i <= #self.mobs do
    local mob = self.mobs[i]
    local removed = false
    if mob.dead then
      self:_removeMobAt(i)
      removed = true
    else
      local insideSimulation = self:_isInsideSimulationWindow(mob.x, mob.z)
      if mob.kind == 'sheep' then
        if insideSimulation then
          self:_updateSheep(mob, delta)
        end
      elseif mob.kind == 'ghost' then
        if not night then
          self:_removeMobAt(i)
          removed = true
        elseif insideSimulation then
          self:_updateGhost(mob, delta, playerX, playerY, playerZ)
        end
      end

      if not removed then
        local dx = mob.x - playerX
        local dz = mob.z - playerZ
        if dx * dx + dz * dz > despawnDistance2 then
          self:_removeMobAt(i)
          removed = true
        end
      end
    end

    if not removed then
      i = i + 1
    end
  end
end

function MobSystem:update(dt, timeOfDay, skipAi, simulationCenterCx, simulationCenterCz, simulationRadiusChunks)
  if not self.enabled then
    self.targetMob = nil
    self._aiAccumulator = 0
    self:_setSimulationWindow(nil, nil, nil)
    return
  end

  self:_setSimulationWindow(simulationCenterCx, simulationCenterCz, simulationRadiusChunks)

  local delta = parseNumber(dt, 0)
  if delta <= 0 then
    return
  end

  self._time = self._time + delta
  self._timeOfDay = parseNumber(timeOfDay, self._timeOfDay) or self._timeOfDay
  self:_decayTimers(delta)

  if skipAi then
    self._aiAccumulator = 0
    return
  end

  local step = self.aiTickSeconds
  local maxTicks = self.maxAiTicksPerFrame
  local maxCarry = step * maxTicks
  self._aiAccumulator = math.min(maxCarry, self._aiAccumulator + delta)

  local ticks = 0
  while self._aiAccumulator >= step and ticks < maxTicks do
    self._aiAccumulator = self._aiAccumulator - step
    self:_updateAiStep(step)
    ticks = ticks + 1
  end

  if ticks >= maxTicks and self._aiAccumulator >= step then
    self._aiAccumulator = 0
  end
end

function MobSystem:draw(pass)
  if not self.enabled or #self.mobs == 0 then
    return
  end

  pass:push('state')
  for i = 1, #self.mobs do
    local mob = self.mobs[i]
    local hurt = (mob.hurtTimer or 0) > 0

    if mob.kind == 'sheep' then
      if hurt then
        pass:setColor(1.0, 0.42, 0.42, 1)
      else
        pass:setColor(0.95, 0.95, 0.95, 1)
      end
      pass:cube(mob.x, mob.y, mob.z, mob.size)
      pass:setColor(0.22, 0.22, 0.22, 1)
      pass:cube(mob.x, mob.y - mob.size * 0.24, mob.z + mob.size * 0.34, mob.size * 0.28)
    elseif mob.kind == 'ghost' then
      if hurt then
        pass:setColor(1.0, 0.36, 0.36, 0.92)
      else
        pass:setColor(0.82, 0.94, 1.0, 0.82)
      end
      pass:cube(mob.x, mob.y, mob.z, mob.size)
      pass:setColor(0.12, 0.18, 0.22, 0.95)
      pass:cube(mob.x - mob.size * 0.16, mob.y + mob.size * 0.10, mob.z + mob.size * 0.32, mob.size * 0.13)
      pass:cube(mob.x + mob.size * 0.16, mob.y + mob.size * 0.10, mob.z + mob.size * 0.32, mob.size * 0.13)
    end

    if self.targetMob == mob then
      pass:push('state')
      pass:setWireframe(true)
      pass:setColor(1, 1, 0.8, 1)
      pass:cube(mob.x, mob.y, mob.z, mob.size * 1.12)
      pass:pop('state')
    end
  end
  pass:pop('state')
end

return MobSystem
