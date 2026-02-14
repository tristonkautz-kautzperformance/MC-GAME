local MeshWorker = {}
MeshWorker.__index = MeshWorker

local function makeUniqueChannelName(prefix)
  local suffix = tostring({})
  suffix = suffix:gsub('table:%s*', '')
  suffix = suffix:gsub('[^%w]', '')
  if #suffix == 0 then
    local t = 0
    if lovr.timer and lovr.timer.getTime then
      t = lovr.timer.getTime()
    end
    suffix = tostring(math.floor(t * 1000000))
  end
  return prefix .. '_' .. suffix
end

function MeshWorker.new(threadPath)
  if not lovr.thread or not lovr.thread.newThread or not lovr.thread.getChannel then
    return nil, 'thread_api_unavailable'
  end

  local self = setmetatable({}, MeshWorker)
  self._jobsName = makeUniqueChannelName('mesh_jobs')
  self._resultsName = makeUniqueChannelName('mesh_results')
  self._jobs = lovr.thread.getChannel(self._jobsName)
  self._results = lovr.thread.getChannel(self._resultsName)
  self._thread = lovr.thread.newThread(threadPath or 'src/render/mesher_thread.lua')
  self._alive = false
  self._error = nil

  local ok, err = pcall(function()
    self._thread:start(self._jobsName, self._resultsName)
  end)
  if not ok then
    self._error = tostring(err)
    return nil, self._error
  end

  self._alive = true
  return self
end

function MeshWorker:isAlive()
  if not self._alive then
    return false
  end
  if not self._thread then
    self._alive = false
    return false
  end

  local threadError = nil
  if self._thread.getError then
    threadError = self._thread:getError()
  end
  if threadError then
    self._error = tostring(threadError)
    self._alive = false
    return false
  end

  if self._thread.isRunning and not self._thread:isRunning() then
    self._alive = false
    if not self._error and self._thread.getError then
      local err = self._thread:getError()
      if err then
        self._error = tostring(err)
      end
    end
    return false
  end

  return true
end

function MeshWorker:getError()
  return self._error
end

function MeshWorker:push(job)
  if not self:isAlive() then
    return false, self._error or 'worker_not_running'
  end

  local ok, err = pcall(function()
    self._jobs:push(job)
  end)
  if not ok then
    self._alive = false
    self._error = tostring(err)
    return false, self._error
  end

  return true
end

function MeshWorker:pop()
  if not self._results then
    return nil
  end

  local ok, result = pcall(function()
    return self._results:pop()
  end)
  if not ok then
    self._alive = false
    self._error = tostring(result)
    return nil
  end

  return result
end

function MeshWorker:shutdown()
  if self._jobs then
    pcall(function()
      self._jobs:push({ type = 'shutdown' })
    end)
  end

  if self._thread and self._thread.wait then
    pcall(function()
      self._thread:wait()
    end)
  end

  self._alive = false
end

return MeshWorker
