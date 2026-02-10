local FULLSCREEN_STATE_FILE = '.fullscreen'

local function readFullscreenState()
  local file = io.open(FULLSCREEN_STATE_FILE, 'r')
  if not file then
    return false
  end

  local value = file:read('*l')
  file:close()
  return value == '1' or value == 'true'
end

function lovr.conf(t)
  t.modules = t.modules or {}
  t.modules.headset = false

  t.graphics = t.graphics or {}
  t.graphics.vsync = false -- Uncapped FPS for performance testing.

  t.window = t.window or {}
  t.window.title = 'LOVR Voxel Clone'
  t.window.width = 1280
  t.window.height = 720
  t.window.centered = true
  t.window.resizable = true
  t.window.fullscreen = readFullscreenState()

  -- Desktop-first for now.
  t.headset = t.headset or {}
  t.headset.drivers = {}
end
