--- HTTP client for the ZUFEOJ JSON API.
---
--- Talks to https://acm.ocrosoft.com through `curl` with a persistent Netscape
--- cookie jar, so the session survives restarts. Every request carries the
--- cookie jar (-b/-c), matching the web frontend's behavior.
local config = require('zufeoj.config')

local M = {}

M.base_url = 'https://acm.ocrosoft.com'

--- HUSTOJ verdict codes; < 4 means still judging.
local VERDICTS = {
  [0] = { short = 'WT', name = 'Waiting' },
  [1] = { short = 'CP', name = 'Compiling' },
  [2] = { short = 'RU', name = 'Running' },
  [3] = { short = 'JG', name = 'Judging' },
  [4] = { short = 'AC', name = 'Accepted' },
  [5] = { short = 'PE', name = 'Presentation Error' },
  [6] = { short = 'WA', name = 'Wrong Answer' },
  [7] = { short = 'TLE', name = 'Time Limit Exceed' },
  [8] = { short = 'MLE', name = 'Memory Limit Exceed' },
  [9] = { short = 'OLE', name = 'Output Limit Exceed' },
  [10] = { short = 'RE', name = 'Runtime Error' },
  [11] = { short = 'CE', name = 'Compile Error' },
}

function M.verdict_name(code)
  local v = VERDICTS[code]
  return v and v.name or ('Unknown (' .. tostring(code) .. ')')
end

function M.verdict_short(code)
  local v = VERDICTS[code]
  return v and v.short or ('R' .. tostring(code))
end

function M.is_pending(code)
  return code ~= nil and code >= 0 and code <= 3
end

-- ---------------------------------------------------------------------------
-- low level
-- ---------------------------------------------------------------------------

--- Turn an argv list into a readable error message for curl failures.
local function curl_argv(args)
  local argv = { 'curl', '-sS', '--max-time', '60', '-b', config.get().cookie_file, '-c', config.get().cookie_file }
  vim.list_extend(argv, args)
  return argv
end

--- Split "<body>\n<status>" (curl -w) into its parts.
local function split_status(stdout)
  local nl = stdout:match('.*()\n')
  if not nl then
    return stdout, nil
  end
  local body = stdout:sub(1, nl - 1)
  local status = tonumber(stdout:sub(nl + 1))
  return body, status
end

--- JSON null decodes to vim.NIL, which is truthy in Lua and breaks string
--- concatenation, `and` chains and vim.json.encode. Convert it (recursively)
--- to real nil so callers never see it.
local function clean_nil(value)
  if value == vim.NIL then
    return nil
  end
  if type(value) == 'table' then
    for key, item in pairs(value) do
      value[key] = clean_nil(item)
    end
  end
  return value
end

--- Parse one API envelope; returns (data, err).
--- err is a table { code, error, message } when the API reported failure.
local function unwrap(body, status)
  local ok, envelope = pcall(vim.json.decode, body)
  if not ok or type(envelope) ~= 'table' then
    -- Non-JSON body (HTML error page, empty response, ...)
    if status and status ~= 200 then
      return nil, { code = status, error = 'Http.' .. tostring(status), message = 'server returned HTTP ' .. status }
    end
    return nil, { code = -1, error = 'Api.InvalidResponse', message = 'unexpected (non-JSON) response' }
  end
  if envelope.code == 0 then
    return clean_nil(envelope.data), nil, envelope
  end
  return nil, {
    code = envelope.code,
    error = envelope.error,
    message = envelope.message or 'request failed',
    params = envelope.params,
  }, envelope
end

--- Async request. cb(err, data, envelope).
--- opts: { method, path, query, body, raw }
function M.request(opts, cb)
  local url = M.base_url .. opts.path
  if opts.query then
    local parts = {}
    for k, v in pairs(opts.query) do
      if v ~= nil and v ~= '' then
        parts[#parts + 1] = k .. '=' .. vim.uri_encode(tostring(v))
      end
    end
    if #parts > 0 then
      url = url .. '?' .. table.concat(parts, '&')
    end
  end

  local args = { '-w', '\n%{http_code}' }
  if opts.method == 'POST' then
    args[#args + 1] = '-X'
    args[#args + 1] = 'POST'
  end
  if opts.body then
    args[#args + 1] = '-H'
    args[#args + 1] = 'content-type: application/json'
    args[#args + 1] = '--data-raw'
    args[#args + 1] = vim.json.encode(opts.body)
  end
  args[#args + 1] = url

  vim.system(curl_argv(args), { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        cb({ code = result.code, error = 'Http.Curl', message = (result.stderr or ''):gsub('%s+$', '') }, nil)
        return
      end
      local body, status = split_status(result.stdout or '')
      local data, err, _ = unwrap(body, status)
      cb(err, data)
    end)
  end)
end

--- Synchronous request (blocking); returns (data, err).
function M.request_sync(opts)
  local url = M.base_url .. opts.path
  if opts.query then
    local parts = {}
    for k, v in pairs(opts.query) do
      if v ~= nil and v ~= '' then
        parts[#parts + 1] = k .. '=' .. vim.uri_encode(tostring(v))
      end
    end
    if #parts > 0 then
      url = url .. '?' .. table.concat(parts, '&')
    end
  end

  local args = { '-w', '\n%{http_code}' }
  if opts.method == 'POST' then
    args[#args + 1] = '-X'
    args[#args + 1] = 'POST'
  end
  if opts.body then
    args[#args + 1] = '-H'
    args[#args + 1] = 'content-type: application/json'
    args[#args + 1] = '--data-raw'
    args[#args + 1] = vim.json.encode(opts.body)
  end
  args[#args + 1] = url

  local result = vim.system(curl_argv(args), { text = true }):wait()
  if result.code ~= 0 then
    return nil, { code = result.code, error = 'Http.Curl', message = (result.stderr or ''):gsub('%s+$', '') }
  end
  local body, status = split_status(result.stdout or '')
  return unwrap(body, status)
end

--- Download a binary body (statement images, exported test data) carrying cookies.
function M.download_sync(url, dest)
  local argv = curl_argv({ '-L', '-o', dest, url })
  local result = vim.system(argv, { text = true }):wait()
  if result.code ~= 0 then
    return false, (result.stderr or ''):gsub('%s+$', '')
  end
  return true
end

-- ---------------------------------------------------------------------------
-- endpoints
-- ---------------------------------------------------------------------------

function M.login(user_id, password, cb)
  M.request({ method = 'POST', path = '/api/auth/login', body = { user_id = user_id, password = password } }, cb)
end

function M.me(cb)
  M.request({ path = '/api/auth/me' }, cb)
end

function M.logout(cb)
  M.request({ method = 'POST', path = '/api/auth/logout' }, function(err, data)
    -- The jar keeps a stale cookie otherwise; drop the file regardless.
    vim.fn.delete(config.get().cookie_file)
    if cb then
      cb(err, data)
    end
  end)
end

function M.languages(cb)
  M.request({ path = '/api/meta/languages' }, function(err, data)
    cb(err, data and data.languages or {})
  end)
end

function M.problem_list(page, search, cb)
  M.request({ path = '/api/problems', query = { page = page, search = search } }, cb)
end

function M.problem(id, cb)
  M.request({ path = '/api/problems/' .. id }, cb)
end

function M.contest_list(page, cb)
  M.request({ path = '/api/contests', query = { page = page } }, cb)
end

function M.contest(id, cb)
  M.request({ path = '/api/contests/' .. id }, cb)
end

function M.contest_problem(cid, num, cb)
  M.request({ path = '/api/contests/' .. cid .. '/problems/' .. num }, cb)
end

--- Which problem a submission targets. Mirrors the web frontend's payload.
function M.submit_meta(ref, cb)
  local query
  if ref.mode == 'Public' then
    query = { mode = 'Public', id = ref.id }
  else
    query = { mode = 'Contest', cid = ref.cid, num = ref.num }
  end
  M.request({ path = '/api/problems/submit-meta', query = query }, cb)
end

--- Post source code; cb(err, { sid }).
function M.submit(payload, cb)
  M.request({ method = 'POST', path = '/api/solutions', body = payload }, cb)
end

function M.poll(sid, cb)
  M.request({ path = '/api/solutions/' .. sid .. '/poll' }, cb)
end

function M.solution(sid, cb)
  M.request({ path = '/api/solutions/' .. sid }, cb)
end

function M.result_output(sid, cb)
  M.request({ path = '/api/solutions/' .. sid .. '/result-output' }, function(err, data)
    cb(err, data and data.output or '')
  end)
end

function M.solutions_list(filter, cb)
  M.request({ path = '/api/solutions/list', query = filter }, cb)
end

function M.join_contest(id, password, cb)
  M.request({ method = 'POST', path = '/api/contests/' .. id .. '/join', body = { password = password or '' } }, cb)
end

--- Contest problem labels: A-Z, then AA-ZZ (matches the web UI).
function M.problem_letter(index)
  if index < 26 then
    return string.char(65 + index)
  end
  if index < 702 then
    local rest = index - 26
    return string.char(65 + math.floor(rest / 26)) .. string.char(65 + (rest % 26))
  end
  return tostring(index)
end

return M
