--- zufe.nvim: ZUFEOJ (acm.ocrosoft.com) inside Neovim.
---
--- 题面进 buffer、样例题测进浮动窗、提交带实时判题进度，全部走站点自身的
--- JSON API（与网页前端同一套接口），会话保存在 curl cookie jar 里。
local api = require('zufeoj.api')
local config = require('zufeoj.config')
local float = require('zufeoj.ui.float')
local history = require('zufeoj.history')
local picker = require('zufeoj.ui.picker')
local runner = require('zufeoj.runner')
local statement = require('zufeoj.statement')
local submit = require('zufeoj.submit')
local workspace = require('zufeoj.workspace')

local M = {}

function M.setup(opts)
  return config.setup(opts)
end

-- ---------------------------------------------------------------------------
-- refs
-- ---------------------------------------------------------------------------

--- Parse "1001", "6471 A", "6471-A", "6471:0" into a ref table.
function M.parse_ref(id_text, letter)
  if id_text == nil or id_text == '' then
    return nil
  end
  local id, label = id_text:match('^(%d+)[%-:/]?([%w]*)$')
  if not id then
    return nil
  end
  label = letter or (label ~= '' and label or nil)
  if label then
    local num
    if label:match('^%d+$') then
      num = tonumber(label)
    else
      num = 0
      for ch in label:upper():gmatch('.') do
        num = num * 26 + (ch:byte() - 64)
      end
      num = num - 1
    end
    return { mode = 'Contest', cid = tonumber(id), num = num, label = label:upper() }
  end
  return { mode = 'Public', id = tonumber(id) }
end

local function ref_of_workspace()
  local ws = workspace.find(vim.api.nvim_buf_get_name(0)) or workspace.find(vim.fn.getcwd())
  return ws
end

-- ---------------------------------------------------------------------------
-- session
-- ---------------------------------------------------------------------------

function M.login()
  local user = vim.fn.input('ZUFEOJ 用户名: ')
  if user == '' then
    return
  end
  local password = vim.fn.inputsecret('ZUFEOJ 密码: ')
  if password == '' then
    return
  end
  api.login(user, password, function(err, data)
    if err then
      vim.notify('zufeoj 登录失败: ' .. (err.message or err.error), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format('zufeoj 已登录：%s（%s）', data.user_id, data.nick), vim.log.levels.INFO)
  end)
end

function M.logout()
  api.logout(function()
    vim.notify('zufeoj 已退出登录', vim.log.levels.INFO)
  end)
end

function M.status()
  local lines = {}
  local me, err = api.request_sync({ path = '/api/auth/me' })
  if err then
    lines[#lines + 1] = '账号: 未登录（:ZufeojLogin）'
  else
    lines[#lines + 1] = string.format('账号: %s（%s）', me.user_id, me.nick)
  end
  lines[#lines + 1] = '工作区根目录: ' .. config.get().workdir
  local ws = ref_of_workspace()
  if ws then
    lines[#lines + 1] = string.format('当前工作区: %s', ws.dir)
    lines[#lines + 1] = string.format('题目: %s（%s s / %s MB）', ws.meta.title, ws.meta.timeLimit, ws.meta.memoryLimit)
    local samples = workspace.read_samples(ws.dir)
    local testdata = workspace.read_testdata(ws.dir)
    lines[#lines + 1] = string.format('测试数据: 样例 %d 组 · 评测数据 %d 组', #samples, #testdata)
    local source = workspace.find_source(ws.dir)
    lines[#lines + 1] = '源码: ' .. (source or '（无）')
  else
    lines[#lines + 1] = '当前目录不在任何题目工作区内'
  end
  float.open({ title = 'zufeoj 状态', lines = lines, width = 72, height = #lines + 2 })
end

-- ---------------------------------------------------------------------------
-- browse & open
-- ---------------------------------------------------------------------------

local function open_problem(ref, opts)
  opts = opts or {}
  local function show(err, problem)
    if err then
      vim.notify('zufeoj: ' .. (err.message or err.error), vim.log.levels.ERROR)
      return
    end
    local id_label = ref.mode == 'Public' and tostring(problem.problem_id or ref.id) or (ref.label or api.problem_letter(ref.num))
    local url = ref.mode == 'Public'
      and ('https://acm.ocrosoft.com/problem.php?id=' .. ref.id)
      or ('https://acm.ocrosoft.com/problem.php?cid=' .. ref.cid .. '&pid=' .. ref.num)
    local markdown = statement.render(problem, { id_label = id_label, url = url })
    statement.open(id_label, problem.title, markdown)
    history.record(ref, vim.trim(problem.title), workspace.dir_for(ref, id_label, problem.title))
    vim.notify(string.format('zufeoj: %s %s（:ZufeojPull 拉取工作区）', id_label, vim.trim(problem.title)), vim.log.levels.INFO)
  end

  if ref.mode == 'Public' then
    api.problem(ref.id, show)
  else
    api.contest_problem(ref.cid, ref.num, show)
  end
end

function M.open(id_text, letter)
  local ref = M.parse_ref(id_text, letter)
  if ref then
    open_problem(ref)
    return
  end
  -- no argument: pick from the problemset
  M.problems()
end

--- Pull a ref into its workspace and open statement + source, ready to code.
local function pull_and_open(ref)
  workspace.pull(ref, function(err, result)
    if err then
      vim.notify('zufeoj 拉取失败: ' .. (err.message or err.error), vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format('zufeoj: 已拉取 %s → %s', result.meta.title, result.dir), vim.log.levels.INFO)
    history.record(ref, result.meta.title, result.dir)

    -- open statement + source (create a skeleton if the workspace has none)
    statement.open(vim.fn.fnamemodify(result.dir, ':t'), result.meta.title, result.markdown)
    local source = workspace.find_source(result.dir)
    if not source then
      source = result.dir .. '/main.cpp'
      local fd = io.open(source, 'w')
      if fd then
        fd:write('#include <bits/stdc++.h>\nusing namespace std;\n\nint main() {\n    return 0;\n}\n')
        fd:close()
      end
    end
    vim.cmd('tcd ' .. vim.fn.fnameescape(result.dir))
    if vim.fn.filereadable(source) == 1 then
      vim.cmd('split ' .. vim.fn.fnameescape(source))
    end
  end)
end

--- Open (pulling if needed) the workspace for a ref table — used by the
--- dashboard's recent list and by the pickers' <CR>.
function M.open_workspace(ref)
  if ref == nil then
    return
  end
  pull_and_open(ref)
end

--- Pull into the workspace and open the working files.
function M.pull(id_text, letter)
  local ref = M.parse_ref(id_text, letter)
  if not ref then
    local ws = ref_of_workspace()
    if ws then
      local meta_ref = ws.meta.submitProblem
      ref = meta_ref.mode == 'Public'
        and { mode = 'Public', id = meta_ref.id }
        or { mode = 'Contest', cid = meta_ref.cid, num = meta_ref.num, label = api.problem_letter(meta_ref.num) }
    end
  end
  if not ref then
    vim.notify('zufeoj: 用法 :ZufeojPull <题号|比赛题>，例如 :ZufeojPull 1001 或 :ZufeojPull 6471 A', vim.log.levels.WARN)
    return
  end
  pull_and_open(ref)
end

function M.problems()
  local function fetch(page, cb)
    api.problem_list(page, nil, function(err, data)
      if err then
        vim.notify('zufeoj: ' .. (err.message or err.error), vim.log.levels.ERROR)
        return
      end
      local items = {}
      for _, row in ipairs(data.items or {}) do
        local mark = row.user_status == 1 and '✓' or (row.user_status == 0 and '✗' or ' ')
        items[#items + 1] = {
          label = string.format('%s P%-5d %s', mark, row.problem_id, vim.trim(row.title)),
          data = { ref = { mode = 'Public', id = row.problem_id } },
        }
      end
      cb(items, data.total_pages or 1)
    end)
  end

  -- first page loads asynchronously, then the picker opens
  fetch(1, function(items, max_page)
    picker.select({
      title = 'ZUFEOJ 题库',
      hint = '输入模糊过滤（子序列匹配）',
      items = items,
      width = 92,
      height = 24,
      fetch_page = fetch,
      on_select = function(item)
        M.open_workspace(item.data.ref)
      end,
      secondary_key = '<C-o>',
      on_secondary = function(item)
        open_problem(item.data.ref)
      end,
      secondary_label = '<C-o> 只看题面',
    })
    _ = max_page
  end)
end

function M.contests()
  api.contest_list(1, function(err, data)
    if err then
      vim.notify('zufeoj: ' .. (err.message or err.error), vim.log.levels.ERROR)
      return
    end
    local items = {}
    for _, row in ipairs(data.rows or {}) do
      items[#items + 1] = {
        label = string.format('C%-5d %s %s  %s ~ %s', row.contest_id, row.private and '私' or '公',
          vim.trim(row.title), (row.start_time or ''):sub(1, 10), (row.end_time or ''):sub(1, 10)),
        data = { contest_id = row.contest_id },
      }
    end
    picker.select({
      title = 'ZUFEOJ 比赛',
      hint = 'CR 查看题目列表',
      items = items,
      width = 100,
      height = 22,
      on_select = function(item)
        M.contest_problems(item.data.contest_id)
      end,
    })
  end)
end

function M.contest_problems(cid)
  api.contest(cid, function(err, detail)
    if err then
      vim.notify('zufeoj: ' .. (err.message or err.error), vim.log.levels.ERROR)
      return
    end
    local items = {}
    for _, entry in ipairs(detail.problems or {}) do
      local problem = entry.problem
      local label = api.problem_letter(problem.num)
      local id = problem.problem_id and ('#' .. problem.problem_id) or ''
      items[#items + 1] = {
        label = string.format('%s  %s  %s/%s  %s', label, vim.trim(problem.title),
          entry.c_accepted or 0, entry.c_submit or 0, id),
        data = { ref = { mode = 'Contest', cid = cid, num = problem.num, label = label } },
      }
    end
    picker.select({
      title = string.format('Contest %d · %s', cid, vim.trim(detail.contest.title)),
      hint = string.format('%s · %s · %s', detail.stage, detail.contest.private and '私有' or '公开', detail.joined and '已参加' or '未参加'),
      items = items,
      width = 96,
      height = 20,
      on_select = function(item)
        M.open_workspace(item.data.ref)
      end,
      secondary_key = '<C-o>',
      on_secondary = function(item)
        open_problem(item.data.ref)
      end,
      secondary_label = '<C-o> 只看题面',
    })
  end)
end

-- ---------------------------------------------------------------------------
-- local testing
-- ---------------------------------------------------------------------------

local function format_result_line(entry)
  if entry.error then
    return string.format('  ✗ %s  %s', entry.name, entry.error)
  end
  return string.format('  %s %s  (%d ms)', entry.pass and '✓' or '✗', entry.name, entry.elapsed_ms)
end

function M.test()
  local ws = ref_of_workspace()
  if not ws then
    vim.notify('zufeoj: 当前目录不在题目工作区（先 :ZufeojPull）', vim.log.levels.WARN)
    return
  end

  local file = workspace.find_source(ws.dir)
  if not file then
    vim.notify('zufeoj: 工作区内没有源码文件', vim.log.levels.WARN)
    return
  end

  local samples = workspace.read_samples(ws.dir)
  local testdata = workspace.read_testdata(ws.dir)
  local tests = {}
  vim.list_extend(tests, samples)
  vim.list_extend(tests, testdata)
  if #tests == 0 then
    vim.notify('zufeoj: 没有测试数据（:ZufeojPull 拉样例，或 :ZufeojData 下载评测数据）', vim.log.levels.WARN)
    return
  end

  local language = runner.language_of(file, vim.bo.filetype) or config.get().default_language

  local log = {
    string.format('本地运行 %s · %s', vim.fn.fnamemodify(file, ':t'), ws.meta.title),
    string.format('样例 %d 组%s', #samples, #testdata > 0 and string.format(' · 评测数据 %d 组', #testdata) or ''),
    '',
  }
  local win = float.open({ title = 'zufeoj 本地测试', lines = log, width = 88, height = 18 })

  runner.run({
    ws_dir = ws.dir,
    file_path = file,
    language = language,
    tests = tests,
    time_limit = ws.meta.timeLimit,
  }, {
    on_compile = function()
      log[#log + 1] = '  编译中…'
      win.set(log)
    end,
    on_result = function(_, entry)
      log[#log] = format_result_line(entry)
      if not entry.pass and not entry.error then
        log[#log + 1] = '    期望: ' .. vim.inspect(entry.expected):sub(1, 160)
        log[#log + 1] = '    实际: ' .. vim.inspect(entry.actual):sub(1, 160)
      end
      log[#log + 1] = ''
      win.set(log)
    end,
    on_done = function(results, compile_output)
      if compile_output then
        log[#log + 1] = '  编译失败：'
        for _, line in ipairs(vim.split(compile_output, '\n', { plain = true })) do
          log[#log + 1] = '    ' .. line
        end
        win.set(log)
        return
      end
      local passed = 0
      for _, entry in ipairs(results) do
        if entry.pass then
          passed = passed + 1
        end
      end
      log[#log + 1] = string.format('  %d/%d 通过', passed, #results)
      win.set(log)
      vim.notify(string.format('zufeoj: 本地测试 %d/%d 通过', passed, #results),
        passed == #results and vim.log.levels.INFO or vim.log.levels.WARN)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- judge data (admin/teacher export)
-- ---------------------------------------------------------------------------

function M.data(id_text)
  local ws = ref_of_workspace()
  if not ws then
    vim.notify('zufeoj: 当前目录不在题目工作区（先 :ZufeojPull）', vim.log.levels.WARN)
    return
  end
  local ref = ws.meta.submitProblem
  local problem_id = nil
  local id = id_text or (ref.mode == 'Public' and tostring(ref.id) or nil)

  local function proceed()
    local url = string.format('%s/api/admin/problems/%s/export', api.base_url, problem_id)
    local zip = ws.dir .. '/testdata.zip'
    local ok, err = api.download_sync(url, zip)
    if not ok then
      vim.notify('zufeoj: 下载失败（可能需要管理员/教师权限）：' .. err, vim.log.levels.WARN)
      return
    end
    local unzip = vim.fn.executable('unzip') == 1
    if not unzip then
      vim.notify('zufeoj: 已保存 ' .. zip .. '（未找到 unzip，请手动解压到 testdata/）', vim.log.levels.WARN)
      return
    end
    vim.system({ 'unzip', '-o', zip, '-d', ws.dir .. '/testdata' }, { text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          vim.notify('zufeoj: 解压失败: ' .. (result.stderr or ''), vim.log.levels.ERROR)
          return
        end
        local testdata = workspace.read_testdata(ws.dir)
        vim.notify(string.format('zufeoj: 评测数据 %d 组 → testdata/（:ZufeojTest 运行）', #testdata), vim.log.levels.INFO)
      end)
    end)
  end

  if id then
    problem_id = id
    proceed()
    return
  end
  -- contest problem: resolve its real problem id first
  api.contest_problem(ref.cid, ref.num, function(err, problem)
    if err then
      vim.notify('zufeoj: ' .. (err.message or err.error), vim.log.levels.ERROR)
      return
    end
    if not problem.problem_id then
      vim.notify('zufeoj: 进行中的比赛题没有独立题号，无法导出评测数据', vim.log.levels.WARN)
      return
    end
    problem_id = problem.problem_id
    proceed()
  end)
end

-- ---------------------------------------------------------------------------
-- submit & watch
-- ---------------------------------------------------------------------------

function M.submit_cmd(file)
  submit.run(file)
end

function M.watch(sid_text)
  local function poll(sid)
    local deadline = os.time() + config.get().judge_timeout
    local log = { '监视 solution ' .. sid, '' }
    local win = float.open({ title = 'zufeoj 判题', lines = log, width = 88, height = 16 })
    local last = -1
    local function tick()
      api.poll(sid, function(err, poll_data)
        if err then
          log[#log + 1] = '  ✗ ' .. (err.message or err.error)
          win.set(log)
          return
        end
        if poll_data.result ~= last then
          last = poll_data.result
          log[#log] = string.format('  %s %s', api.verdict_short(poll_data.result), api.verdict_name(poll_data.result))
          if not api.is_pending(poll_data.result) and poll_data.time then
            log[#log] = log[#log] .. string.format(' · %s ms · %s MB', poll_data.time,
              poll_data.memory and math.floor(poll_data.memory / 1024) or '?')
          end
          win.set(log)
        end
        if not api.is_pending(poll_data.result) then
          if poll_data.result ~= 4 then
            api.result_output(sid, function(oerr, output)
              if not oerr and output ~= '' then
                log[#log + 1] = ''
                log[#log + 1] = '── 判题输出 ──────────────────────────'
                for _, line in ipairs(vim.split(output:gsub('%s+$', ''), '\n', { plain = true })) do
                  log[#log + 1] = line
                end
              end
              win.set(log)
            end)
          end
          return
        end
        if os.time() > deadline then
          log[#log + 1] = '  ✗ 等待超时'
          win.set(log)
          return
        end
        vim.defer_fn(tick, config.get().poll_interval)
      end)
    end
    tick()
  end

  if sid_text and sid_text ~= '' then
    poll(tonumber(sid_text))
    return
  end
  api.me(function(_, me)
    if not me then
      vim.notify('zufeoj: 未登录', vim.log.levels.WARN)
      return
    end
    api.solutions_list({ user_id = me.user_id }, function(err, data)
      if err or not data.rows or #data.rows == 0 then
        vim.notify('zufeoj: 没有找到提交记录', vim.log.levels.WARN)
        return
      end
      poll(data.rows[1].solution_id)
    end)
  end)
end

--- The floating hub behind `:Zufeoj`.
function M.dashboard()
  require('zufeoj.ui.dashboard').open({
    login = M.login,
    logout = M.logout,
    problems = M.problems,
    contests = M.contests,
    test = M.test,
    submit = M.submit_cmd,
    watch = M.watch,
    data = M.data,
    status = M.status,
    health = M.health,
    open_workspace = M.open_workspace,
  })
end

function M.health()
  local lines = { 'zufeoj.nvim health', '' }
  lines[#lines + 1] = 'curl: ' .. (vim.fn.executable('curl') == 1 and 'ok' or '缺少（必需）')
  lines[#lines + 1] = 'unzip: ' .. (vim.fn.executable('unzip') == 1 and 'ok' or '未安装（:ZufeojData 需要）')
  for _, tool in ipairs({ 'g++', 'gcc', 'javac', 'python3', 'php', 'go' }) do
    lines[#lines + 1] = tool .. ': ' .. (vim.fn.executable(tool) == 1 and 'ok' or '未安装')
  end
  lines[#lines + 1] = 'session: ' .. (vim.fn.filereadable(config.get().cookie_file) == 1 and 'exists' or '未登录')
  float.open({ title = 'zufeoj health', lines = lines, width = 64, height = #lines + 2 })
end

return M
