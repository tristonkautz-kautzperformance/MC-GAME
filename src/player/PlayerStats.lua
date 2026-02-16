local PlayerStats = {}
PlayerStats.__index = PlayerStats

local function isFiniteNumber(value)
  return type(value) == 'number'
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function parseNumber(value, fallback)
  local n = tonumber(value)
  if not isFiniteNumber(n) then
    return fallback
  end
  return n
end

local function parsePositive(value, fallback)
  local n = parseNumber(value, fallback)
  if not n or n <= 0 then
    return fallback
  end
  return n
end

local function parseInteger(value, fallback)
  local n = tonumber(value)
  if not n or n % 1 ~= 0 then
    return fallback
  end
  return n
end

function PlayerStats.new(config)
  config = config or {}

  local self = setmetatable({}, PlayerStats)

  self.maxHealth = parsePositive(config.maxHealth, 20)
  self.maxHunger = parsePositive(config.maxHunger, 20)
  self.health = clamp(parseNumber(config.startHealth, self.maxHealth), 0, self.maxHealth)
  self.hunger = clamp(parseNumber(config.startHunger, self.maxHunger), 0, self.maxHunger)
  self.experience = clamp(parseNumber(config.startExperience, 0), 0, 1)
  self.level = math.max(0, parseInteger(config.startLevel, 0))

  self.hungerDrainPerSecond = math.max(0, parseNumber(config.hungerDrainPerSecond, 0))
  self.healthRegenThreshold = clamp(parseNumber(config.healthRegenThreshold, self.maxHunger), 0, self.maxHunger)
  self.healthRegenIntervalSeconds = math.max(0, parseNumber(config.healthRegenIntervalSeconds, 0))
  self.healthRegenAmount = math.max(0, parseNumber(config.healthRegenAmount, 0))
  self.respawnInvulnerabilitySeconds = math.max(0, parseNumber(config.respawnInvulnerabilitySeconds, 2.0))

  self._regenTimer = 0
  self._damageImmunityTimer = 0

  return self
end

function PlayerStats:update(dt)
  local delta = parseNumber(dt, 0)
  if delta <= 0 then
    return
  end

  if self._damageImmunityTimer > 0 then
    self._damageImmunityTimer = math.max(0, self._damageImmunityTimer - delta)
  end

  if self.hungerDrainPerSecond > 0 and self.hunger > 0 then
    self.hunger = clamp(self.hunger - self.hungerDrainPerSecond * delta, 0, self.maxHunger)
  end

  local canRegen = self.healthRegenIntervalSeconds > 0
    and self.healthRegenAmount > 0
    and self.health < self.maxHealth
    and self.hunger >= self.healthRegenThreshold

  if not canRegen then
    self._regenTimer = 0
    return
  end

  self._regenTimer = self._regenTimer + delta
  while self._regenTimer >= self.healthRegenIntervalSeconds do
    self._regenTimer = self._regenTimer - self.healthRegenIntervalSeconds
    self.health = clamp(self.health + self.healthRegenAmount, 0, self.maxHealth)
    if self.health >= self.maxHealth then
      self._regenTimer = 0
      break
    end
  end
end

function PlayerStats:applyDamage(amount)
  if self._damageImmunityTimer > 0 or self.health <= 0 then
    return false
  end

  local damage = parseNumber(amount, 0)
  if damage <= 0 then
    return false
  end

  local previous = self.health
  self.health = clamp(self.health - damage, 0, self.maxHealth)
  return self.health < previous
end

function PlayerStats:heal(amount)
  local value = parseNumber(amount, 0)
  if value <= 0 then
    return false
  end

  local previous = self.health
  self.health = clamp(self.health + value, 0, self.maxHealth)
  return self.health > previous
end

function PlayerStats:isDead()
  return self.health <= 0
end

function PlayerStats:setDamageImmunity(seconds)
  local value = math.max(0, parseNumber(seconds, 0))
  self._damageImmunityTimer = value
end

function PlayerStats:respawn()
  self.health = self.maxHealth
  self.hunger = self.maxHunger
  self._regenTimer = 0
  self._damageImmunityTimer = self.respawnInvulnerabilitySeconds
end

function PlayerStats:getState(out)
  if type(out) ~= 'table' then
    out = {}
  end

  out.health = self.health
  out.maxHealth = self.maxHealth
  out.hunger = self.hunger
  out.maxHunger = self.maxHunger
  out.experience = self.experience
  out.level = self.level
  return out
end

function PlayerStats:applyState(state)
  if type(state) ~= 'table' then
    return false
  end

  self.maxHealth = parsePositive(state.maxHealth, self.maxHealth)
  self.maxHunger = parsePositive(state.maxHunger, self.maxHunger)
  self.health = clamp(parseNumber(state.health, self.health), 0, self.maxHealth)
  self.hunger = clamp(parseNumber(state.hunger, self.hunger), 0, self.maxHunger)
  self.experience = clamp(parseNumber(state.experience, self.experience), 0, 1)
  self.level = math.max(0, parseInteger(state.level, self.level))
  self._regenTimer = 0
  self._damageImmunityTimer = 0
  return true
end

return PlayerStats
