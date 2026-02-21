local VoxelShader = {}
VoxelShader.__index = VoxelShader

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function computeSkySubtract(timeOfDay)
  local t = (tonumber(timeOfDay) or 0) % 1
  local daylight = math.sin(t * math.pi * 2) * 0.5 + 0.5
  local value = math.floor((1 - daylight) * 11 + 0.5)
  return clamp(value, 0, 15)
end

function VoxelShader.new()
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

vec4 lovrmain() {
  int skyLevel = int(clamp(floor(vSkyLight + 0.5) - floor(uSkySubtract + 0.5), 0.0, 15.0));
  float brightness = getBrightness(skyLevel);
  float faceShade = getFaceShade(normalize(vNormal));
  vec3 lit = vColor.rgb * brightness * faceShade;
  return vec4(lit, vColor.a);
}
  ]])
  self._skySubtract = 0
  return self
end

function VoxelShader:apply(pass, timeOfDay)
  if not self.shader then
    return
  end
  local skySubtract = computeSkySubtract(timeOfDay)
  self._skySubtract = skySubtract
  pass:setShader(self.shader)
  pass:send('uSkySubtract', skySubtract)
end

function VoxelShader:getSkySubtract()
  return self._skySubtract or 0
end

return VoxelShader
