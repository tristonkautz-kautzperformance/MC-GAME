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
  return math.sin(t * math.pi * 2) * 0.5 + 0.5
end

local function computeSkySubtractFromDaylight(daylight)
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
  local worldSizeY = tonumber(constants and constants.WORLD_SIZE_Y) or 64
  if worldSizeY < 1 then
    worldSizeY = 64
  end

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

  local startRatioOfEnd = tonumber(fogConfig.startRatioOfEnd)
  if startRatioOfEnd == nil then
    startRatioOfEnd = 0.72
  end
  startRatioOfEnd = clamp(startRatioOfEnd, 0, 1)

  local startDistance = tonumber(fogConfig.startDistance)
  if startDistance == nil then
    startDistance = endDistance * startRatioOfEnd
  end
  if startDistance < 0 then
    startDistance = 0
  end
  if startDistance > endDistance then
    startDistance = endDistance
  end

  local strength = clamp(tonumber(fogConfig.strength) or 1, 0, 1)
  local densityExponent = tonumber(fogConfig.densityExponent)
  if densityExponent == nil then
    densityExponent = 0.72
  end
  if densityExponent < 0.01 then
    densityExponent = 0.01
  end

  local baseAmount = clamp(tonumber(fogConfig.baseAmount) or 0.04, 0, 1)

  local heightStart = tonumber(fogConfig.heightStart)
  if heightStart == nil then
    local heightStartRatio = tonumber(fogConfig.heightStartRatio)
    if heightStartRatio == nil then
      heightStartRatio = 0.75
    end
    heightStart = worldSizeY * clamp(heightStartRatio, 0, 2)
  end
  if heightStart < 0 then
    heightStart = 0
  end

  local heightFalloff = tonumber(fogConfig.heightFalloff)
  if heightFalloff == nil then
    heightFalloff = 1 / math.max(worldSizeY * 0.9, 1)
  end
  if heightFalloff < 0 then
    heightFalloff = 0
  end

  local heightStrength = clamp(tonumber(fogConfig.heightStrength) or 0.22, 0, 1)

  local enabled = fogConfig.enabled ~= false
  if strength <= 0 then
    enabled = false
  end
  if endDistance <= startDistance and baseAmount <= 0 and heightStrength <= 0 then
    enabled = false
  end

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
    densityExponent = densityExponent,
    baseAmount = baseAmount,
    heightStart = heightStart,
    heightFalloff = heightFalloff,
    heightStrength = heightStrength,
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
uniform float uFogDensityExponent;
uniform float uFogBaseAmount;
uniform float uFogHeightStart;
uniform float uFogHeightFalloff;
uniform float uFogHeightStrength;
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
  if (uFogEnabled < 0.5) {
    return 0.0;
  }

  float fogRange = max(uFogEndDistance - uFogStartDistance, 0.001);
  vec2 delta = PositionWorld.xz - CameraPositionWorld.xz;
  float distanceToCamera = length(delta);
  float distanceFog = clamp((distanceToCamera - uFogStartDistance) / fogRange, 0.0, 1.0);
  distanceFog = pow(distanceFog, max(uFogDensityExponent, 0.01));

  float heightFog = 0.0;
  if (uFogHeightStrength > 0.0 && uFogHeightFalloff > 0.0) {
    heightFog = clamp((uFogHeightStart - PositionWorld.y) * uFogHeightFalloff, 0.0, 1.0);
    heightFog *= clamp(uFogHeightStrength, 0.0, 1.0);
  }

  float fog = max(distanceFog, heightFog);
  fog = max(fog, clamp(uFogBaseAmount, 0.0, 1.0));
  return clamp(fog * clamp(uFogStrength, 0.0, 1.0), 0.0, 1.0);
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
  self._fogDensityExponent = fog.densityExponent
  self._fogBaseAmount = fog.baseAmount
  self._fogHeightStart = fog.heightStart
  self._fogHeightFalloff = fog.heightFalloff
  self._fogHeightStrength = fog.heightStrength
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
  local skySubtract = computeSkySubtractFromDaylight(daylight)
  self._skySubtract = skySubtract
  self:_updateFogColor(daylight)

  pass:setShader(self.shader)
  pass:send('uSkySubtract', skySubtract)
  pass:send('uFogEnabled', self._fogEnabled and 1 or 0)
  pass:send('uFogStartDistance', self._fogStartDistance)
  pass:send('uFogEndDistance', self._fogEndDistance)
  pass:send('uFogStrength', self._fogStrength)
  pass:send('uFogDensityExponent', self._fogDensityExponent)
  pass:send('uFogBaseAmount', self._fogBaseAmount)
  pass:send('uFogHeightStart', self._fogHeightStart)
  pass:send('uFogHeightFalloff', self._fogHeightFalloff)
  pass:send('uFogHeightStrength', self._fogHeightStrength)
  pass:send('uFogColor', self._fogColorUniform)
end

function VoxelShader:getSkySubtract()
  return self._skySubtract or 0
end

return VoxelShader
