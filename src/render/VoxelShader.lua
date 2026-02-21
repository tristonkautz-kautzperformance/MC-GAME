local VoxelShader = {}
VoxelShader.__index = VoxelShader

local DEFAULT_SKY_DAY = { .53, .78, .96 }
local DEFAULT_SKY_NIGHT = { .03, .04, .09 }

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function getColorComponent(color, index, fallback)
  local value = color and tonumber(color[index])
  if value == nil then
    return fallback
  end
  return clamp(value, 0, 1)
end

local function computeDaylight(timeOfDay)
  local t = (tonumber(timeOfDay) or 0) % 1
  local daylight = math.sin(t * math.pi * 2) * 0.5 + 0.5
  return clamp(daylight, 0, 1)
end

local function computeSkySubtract(daylight)
  local value = math.floor((1 - daylight) * 11 + 0.5)
  return clamp(value, 0, 15)
end

local function resolveFogConfig(constants)
  local fogConfig = (constants and constants.FOG) or {}
  local cullConfig = (constants and constants.CULL) or {}

  local chunkSize = tonumber(constants and constants.CHUNK_SIZE) or 16
  if chunkSize < 1 then
    chunkSize = 16
  end

  local drawRadiusChunks = tonumber(cullConfig.drawRadiusChunks) or 0
  if drawRadiusChunks < 0 then
    drawRadiusChunks = 0
  end
  local drawRadiusWorld = drawRadiusChunks * chunkSize

  local endPaddingBlocks = tonumber(fogConfig.endPaddingBlocks)
  if endPaddingBlocks == nil then
    endPaddingBlocks = chunkSize * 0.5
  end
  if endPaddingBlocks < 0 then
    endPaddingBlocks = 0
  end

  local endDistance = tonumber(fogConfig.endDistance)
  if endDistance == nil then
    endDistance = drawRadiusWorld - endPaddingBlocks
  end
  if endDistance < 0 then
    endDistance = 0
  end

  local startRatio = tonumber(fogConfig.startRatio)
  if startRatio == nil then
    startRatio = 0.72
  end
  startRatio = clamp(startRatio, 0, 1)

  local startDistance = tonumber(fogConfig.startDistance)
  if startDistance == nil then
    startDistance = endDistance * startRatio
  end
  if startDistance < 0 then
    startDistance = 0
  end
  if startDistance > endDistance then
    startDistance = endDistance
  end

  local strength = clamp(tonumber(fogConfig.strength) or 1, 0, 1)
  local enabled = fogConfig.enabled ~= false
    and strength > 0
    and endDistance > startDistance

  local skyDay = constants and constants.SKY_DAY or DEFAULT_SKY_DAY
  local skyNight = constants and constants.SKY_NIGHT or DEFAULT_SKY_NIGHT

  local dayColor = {
    getColorComponent(skyDay, 1, DEFAULT_SKY_DAY[1]),
    getColorComponent(skyDay, 2, DEFAULT_SKY_DAY[2]),
    getColorComponent(skyDay, 3, DEFAULT_SKY_DAY[3])
  }
  local nightColor = {
    getColorComponent(skyNight, 1, DEFAULT_SKY_NIGHT[1]),
    getColorComponent(skyNight, 2, DEFAULT_SKY_NIGHT[2]),
    getColorComponent(skyNight, 3, DEFAULT_SKY_NIGHT[3])
  }

  return {
    enabled = enabled,
    startDistance = startDistance,
    endDistance = endDistance,
    strength = strength,
    dayColor = dayColor,
    nightColor = nightColor
  }
end

function VoxelShader.new(constants)
  local self = setmetatable({}, VoxelShader)
  self.shader = lovr.graphics.newShader([[
in float VertexLight;

out vec3 vNormal;
out vec4 vColor;
out float vSkyLight;

vec4 lovrmain() {
  vNormal = normalize(NormalMatrix * VertexNormal);
  vColor = Color * VertexColor;
  vSkyLight = VertexLight;
  return DefaultPosition;
}
  ]], [[
uniform float uSkySubtract;
uniform float uFogEnabled;
uniform float uFogStartDistance;
uniform float uFogEndDistance;
uniform float uFogStrength;
uniform vec3 uFogColor;

in vec3 vNormal;
in vec4 vColor;
in float vSkyLight;

const float BRIGHTNESS_LUT[16] = float[16](
  0.03, 0.05, 0.07, 0.09,
  0.12, 0.15, 0.19, 0.24,
  0.30, 0.38, 0.47, 0.57,
  0.68, 0.79, 0.90, 1.00
);

float getFaceShade(vec3 n) {
  if (n.y > 0.5) return 1.0;
  if (n.y < -0.5) return 0.5;
  if (abs(n.x) > abs(n.z)) return 0.8;
  return 0.6;
}

float getBrightness(int level) {
  int clamped = int(clamp(float(level), 0.0, 15.0));
  return BRIGHTNESS_LUT[clamped];
}

float getFogFactor() {
  float fogEnabled = clamp(uFogEnabled, 0.0, 1.0);
  float fogRange = max(uFogEndDistance - uFogStartDistance, 0.001);
  vec2 delta = PositionWorld.xz - CameraPositionWorld.xz;
  float distanceToCamera = length(delta);
  float t = clamp((distanceToCamera - uFogStartDistance) / fogRange, 0.0, 1.0);
  float fog = t * t * (3.0 - 2.0 * t);
  return fog * fogEnabled * clamp(uFogStrength, 0.0, 1.0);
}

vec4 lovrmain() {
  int skyLevel = int(clamp(floor(vSkyLight + 0.5) - floor(uSkySubtract + 0.5), 0.0, 15.0));
  float brightness = getBrightness(skyLevel);
  float faceShade = getFaceShade(normalize(vNormal));
  vec3 lit = vColor.rgb * brightness * faceShade;
  float fogFactor = getFogFactor();
  vec3 finalColor = mix(lit, uFogColor, fogFactor);
  return vec4(finalColor, vColor.a);
}
  ]])

  local fog = resolveFogConfig(constants)
  self._skySubtract = 0
  self._fogEnabled = fog.enabled
  self._fogStartDistance = fog.startDistance
  self._fogEndDistance = fog.endDistance
  self._fogStrength = fog.strength
  self._fogDayColor = fog.dayColor
  self._fogNightColor = fog.nightColor
  self._fogColorUniform = { fog.dayColor[1], fog.dayColor[2], fog.dayColor[3] }
  return self
end

function VoxelShader:_updateFogColor(daylight)
  local dayColor = self._fogDayColor
  local nightColor = self._fogNightColor
  local fogColor = self._fogColorUniform
  fogColor[1] = nightColor[1] + (dayColor[1] - nightColor[1]) * daylight
  fogColor[2] = nightColor[2] + (dayColor[2] - nightColor[2]) * daylight
  fogColor[3] = nightColor[3] + (dayColor[3] - nightColor[3]) * daylight
end

function VoxelShader:apply(pass, timeOfDay)
  if not self.shader then
    return
  end

  local daylight = computeDaylight(timeOfDay)
  local skySubtract = computeSkySubtract(daylight)
  self._skySubtract = skySubtract
  self:_updateFogColor(daylight)

  pass:setShader(self.shader)
  pass:send('uSkySubtract', skySubtract)
  pass:send('uFogEnabled', self._fogEnabled and 1 or 0)
  pass:send('uFogStartDistance', self._fogStartDistance)
  pass:send('uFogEndDistance', self._fogEndDistance)
  pass:send('uFogStrength', self._fogStrength)
  pass:send('uFogColor', self._fogColorUniform)
end

function VoxelShader:getSkySubtract()
  return self._skySubtract or 0
end

return VoxelShader
