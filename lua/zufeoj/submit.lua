--- Submit the current solution and follow the verdict in a floating window.
local api = require('zufeoj.api')
local config = require('zufeoj.config')
local float = require('zufeoj.ui.float')
local history = require('zufeoj.history')
local runner = require('zufeoj.runner')
local workspace = require('zufeoj.workspace')

local M = {}

local function buffer_content(path)
  -- Prefer the live buffer (unsaved edits included), fall back to disk.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= '' and vim.fn.fnamemodify(name, ':p') == vim.fn.fnamemodify(path, ':p') then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return table.concat(lines, '\n') .. '\n'
    end
  end
  local fd = io.open(path, 'r')
  if not fd then
    return nil
  end
  local content = fd:read('*a')
  fd:close()
  return content
end

--- Submit `path` against the workspace's problem; cb(err, result).
--- progress(verdict_code) is called on every verdict change.
function M.submit(opts, progress, cb)
  local ws = opts.workspace or workspace.find(opts.file_path)
  if not ws then
    cb({ message = '未找到工作区（meta.json）：先用 :ZufeojPull 拉题' })
    return
  end

  local file = opts.file_path or workspace.find_source(ws.dir)
  if not file then
    cb({ message = '工作区内没有源码文件' })
    return
  end

  local language_name = opts.language or runner.language_of(file, vim.bo.filetype)
  if not language_name then
    cb({ message = '无法从文件类型判断语言，请用 :ZufeojSubmit <语言> 指定' })
    return
  end

  local source = buffer_content(file)
  if not source then
    cb({ message = '读取源码失败：' .. file })
    return
  end

  api.languages(function(lang_err, languages)
    if lang_err then
      cb(lang_err)
      return
    end
    local language
    for _, lang in ipairs(languages) do
      if lang.name == language_name then
        language = lang
        break
      end
    end
    if not language then
      local names = vim.tbl_map(function(l) return l.name end, languages)
      cb({ message = '服务端没有语言 ' .. language_name .. '（可用：' .. table.concat(names, ', ') .. '）' })
      return
    end

    api.submit({
      problem = ws.meta.submitProblem,
      language = language.id,
      source = source,
    }, function(err, data)
      if err then
        if err.error == 'Api.Submit.VCodeRequired' then
          cb({ message = '评测机要求验证码，请先在网页端提交一次' })
        else
          cb(err)
        end
        return
      end

      local sid = data.sid
      local deadline = os.time() + config.get().judge_timeout
      local last = -1

      local function tick()
        api.poll(sid, function(perr, poll)
          if perr then
            cb(perr, { sid = sid })
            return
          end
          if poll.result ~= last then
            last = poll.result
            if progress then progress(poll) end
          end
          if not api.is_pending(poll.result) then
            cb(nil, {
              sid = sid,
              result = poll.result,
              time = poll.time,
              memory = poll.memory,
              pass_rate = poll.pass_rate,
            })
            return
          end
          if os.time() > deadline then
            cb({ message = '等待判题超时（solution ' .. sid .. ' 仍在 ' .. api.verdict_name(poll.result) .. '）' }, { sid = sid })
            return
          end
          vim.defer_fn(tick, config.get().poll_interval)
        end)
      end

      tick()
    end)
  end)
end

local function is_auth_error(err)
  return err ~= nil and (err.code == 401 or err.error == 'Api.Auth.NotLoggedIn')
end

--- Ask for credentials with core prompts, log in, then report success.
local function prompt_login(cb)
  vim.ui.input({ prompt = 'ZUFEOJ 用户名: ' }, function(user)
    if user == nil or user == '' then
      cb(false)
      return
    end
    local password = vim.fn.inputsecret('ZUFEOJ 密码: ')
    if password == '' then
      cb(false)
      return
    end
    api.login(user, password, function(err)
      vim.schedule(function()
        if err then
          vim.notify('zufeoj 登录失败: ' .. (err.message or err.error or ''), vim.log.levels.ERROR)
          cb(false)
        else
          vim.notify('zufeoj: 已登录', vim.log.levels.INFO)
          cb(true)
        end
      end)
    end)
  end)
end

--- High level command body: float with progress, judge output on failure.
function M.run(file_path, retried)
  local file = file_path
  if file == nil or file == '' then
    local ws = workspace.find(vim.api.nvim_buf_get_name(0))
    if ws then
      file = workspace.find_source(ws.dir)
    end
    file = file or vim.api.nvim_buf_get_name(0)
  end
  if file == '' or vim.fn.filereadable(file) == 0 then
    vim.notify('zufeoj: 当前 buffer 不是文件，或工作区里没有源码', vim.log.levels.WARN)
    return
  end

  local ws = workspace.find(file)
  local title = ws and ws.meta.title or vim.fn.fnamemodify(file, ':t')
  local short = vim.fn.fnamemodify(file, ':t')

  -- Persist pending edits before submitting; the write is in-place.
  local saved = workspace.save_modified(ws and ws.dir or nil, file)

  local win = float.open({
    title = '提交 · ' .. short,
    width = 84,
    height = 14,
    lines = { '提交 ' .. short .. ' → ' .. title .. '', '', '  等待评测机…' },
    follow = true,
  })

  local log = { '提交 ' .. short .. ' → ' .. title }
  if #saved > 0 then
    log[#log + 1] = '已保存到磁盘'
  end
  log[#log + 1] = ''

  M.submit({ file_path = file }, function(poll)
    local line = string.format('  #%d  %s', poll.solution_id or 0, api.verdict_name(poll.result))
    log[#log] = line
    win.set(log)
  end, function(err, result)
    if is_auth_error(err) and not retried then
      log[#log] = '  需要登录…'
      win.set(log)
      prompt_login(function(ok)
        win.close()
        if ok then
          M.run(file_path, true)
        end
      end)
      return
    end
    if err and not result then
      log[#log] = '  ✗ ' .. (err.message or err.error or '提交失败')
      win.set(log)
      vim.notify('zufeoj: ' .. (err.message or '提交失败'), vim.log.levels.ERROR)
      return
    end
    if err then
      log[#log] = '  ✗ ' .. (err.message or err.code or '失败')
      win.set(log)
      return
    end

    local short_name = api.verdict_short(result.result)
    history.set_last_verdict(result.sid, short_name, api.verdict_name(result.result))
    local line = string.format('  #%d  %s %s', result.sid, short_name, api.verdict_name(result.result))
    if result.time then
      line = line .. string.format(' · %s ms · %s MB', result.time, result.memory and math.floor(result.memory / 1024) or '?')
    end
    log[#log] = line

    if result.result == 4 then
      vim.notify('zufeoj: #' .. result.sid .. ' AC', vim.log.levels.INFO)
      win.set(log)
      return
    end

    -- The judge reports the diff against its own data (WA) or compiler output (CE).
    vim.notify('zufeoj: #' .. result.sid .. ' ' .. short_name, vim.log.levels.WARN)
    api.result_output(result.sid, function(oerr, output)
      if not oerr and output and output ~= '' then
        log[#log + 1] = ''
        log[#log + 1] = '── 判题输出 ──────────────────────────'
        for _, out_line in ipairs(vim.split(output:gsub('%s+$', ''), '\n', { plain = true })) do
          log[#log + 1] = out_line
        end
      end
      win.set(log)
    end)
  end)
end

return M
