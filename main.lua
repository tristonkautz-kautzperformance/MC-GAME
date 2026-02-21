local Constants = require 'src.constants'
local GameState = require 'src.game.GameState'

local game = GameState.new(Constants)

local function extractMouseButton(...)
  local argc = select('#', ...)
  local fallback = nil

  for i = 1, argc do
    local value = select(i, ...)
    if value == 'l' or value == 'left' or value == 'r' or value == 'right' or value == 'm' or value == 'middle' then
      if i >= 3 then
        return value
      end
      if fallback == nil then
        fallback = value
      end
    else
      local n = tonumber(value)
      if n and n % 1 == 0 and n >= 1 and n <= 8 then
        if i >= 3 then
          return n
        end
        if fallback == nil then
          fallback = n
        end
      end
    end
  end

  return fallback
end

function lovr.load()
  game:load()
end

function lovr.update(dt)
  game:update(dt)
end

function lovr.draw(pass)
  game:draw(pass)
end

function lovr.keypressed(key)
  game:onKeyPressed(key)
end

function lovr.keyreleased(key)
  game:onKeyReleased(key)
end

function lovr.mousemoved(x, y, dx, dy)
  game:onMouseMoved(dx, dy)
end

function lovr.mousepressed(...)
  local button = extractMouseButton(...)
  game:onMousePressed(button)
end

function lovr.wheelmoved(dx, dy)
  game:onWheelMoved(dy)
end

function lovr.focus(focused)
  game:onFocus(focused)
end

function lovr.quit()
  return game:onQuit()
end
