---@meta

---@class Vec3
---@field x number
---@field y number
---@field z number
local Vec3 = {}

---@param q Quat
function Vec3:rotate(q) end

---@class Quat
local Quat = {}

---@operator mul(Quat): Quat

---@class Mesh
local Mesh = {}

---@param mode string
function Mesh:setDrawMode(mode) end

---@class Pass
local Pass = {}

---@param state? string
function Pass:push(state) end

---@param state? string
function Pass:pop(state) end

---@param view number
---@param position Vec3
---@param orientation Quat
function Pass:setViewPose(view, position, orientation) end

---@param r number
---@param g number
---@param b number
---@param a? number
function Pass:setColor(r, g, b, a) end

---@param mode string
function Pass:setCullMode(mode) end

---@param enabled boolean
function Pass:setWireframe(enabled) end

---@param drawable any
---@param x? number
---@param y? number
---@param z? number
function Pass:draw(drawable, x, y, z) end

---@param text string
---@param x number
---@param y number
---@param z number
---@param scale? number
---@param orientation? Quat
function Pass:text(text, x, y, z, scale, orientation) end

---@param x number
---@param y number
---@param z number
---@param size number
function Pass:cube(x, y, z, size) end

---@param x number
---@param y number
---@param z number
---@param radius number
function Pass:sphere(x, y, z, radius) end

---@class lovr.graphics
lovr = lovr or {}
lovr.graphics = lovr.graphics or {}

---@param format? table
---@param verticesOrCount? table|number
---@param storage? string
---@return Mesh
function lovr.graphics.newMesh(format, verticesOrCount, storage) end

---@param r number
---@param g number
---@param b number
---@param a? number
function lovr.graphics.setBackgroundColor(r, g, b, a) end

---@class lovr.math
lovr.math = lovr.math or {}

---@param angle number
---@param ax number
---@param ay number
---@param az number
---@return Quat
function lovr.math.newQuat(angle, ax, ay, az) end

---@param x? number
---@param y? number
---@param z? number
---@return Vec3
function lovr.math.vec3(x, y, z) end

---@class lovr.event
lovr.event = lovr.event or {}

function lovr.event.quit() end
function lovr.event.restart() end

---@class lovr.system
lovr.system = lovr.system or {}

---@return number
function lovr.system.getWindowWidth() end

---@return number
function lovr.system.getWindowHeight() end

---@class lovr.mouse
lovr.mouse = lovr.mouse or {}

---@param enabled boolean
function lovr.mouse.setRelativeMode(enabled) end

---@param visible boolean
function lovr.mouse.setVisible(visible) end

---@param arg? table
function lovr.load(arg) end

---@param dt number
function lovr.update(dt) end

---@param pass Pass
function lovr.draw(pass) end

---@param key string
function lovr.keypressed(key) end

---@param key string
function lovr.keyreleased(key) end

---@param x number
---@param y number
---@param dx number
---@param dy number
function lovr.mousemoved(x, y, dx, dy) end

---@param x number
---@param y number
---@param button number
function lovr.mousepressed(x, y, button) end

---@param dx number
---@param dy number
function lovr.wheelmoved(dx, dy) end

---@param focused boolean
function lovr.focus(focused) end
