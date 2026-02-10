local Constants = require 'src.constants'
local GameState = require 'src.game.GameState'

local game = GameState.new(Constants)

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

function lovr.mousepressed(x, y, button)
  game:onMousePressed(button)
end

function lovr.wheelmoved(dx, dy)
  game:onWheelMoved(dy)
end

function lovr.focus(focused)
  game:onFocus(focused)
end
