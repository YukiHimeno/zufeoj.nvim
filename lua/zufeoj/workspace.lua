--- Workspaces: pulled problems on disk (statement.md, meta.json, samples/, testdata/).
local config = require('zufeoj.config')
local api = require('zufeoj.api')

local M = {}

local function slug(title, max_len)
  local cleaned = vim.trim((title or ''):gsub('[/\\:*?"<>|`\']', ' '):gsub('%s+', ' '))
  if cleaned == '' then
    cleaned = 'untitled'
  end
  return vim.fn.strcharpart(cleaned, 0, max_len or 60)
end

--- Where a problem's workspace lives; `id_label` is "1001" or "A" for contest problems.
function M.dir_for(ref, id_label, title)
  local root = config.get().workdir
  if ref.mode == 'Public' then
    return string.format('%s/%s-%s', root, id_label, slug(title))
  end
  return string.format('%s/contest-%d/%s-%s', root, ref.cid, id_label, slug(title))
end

--- meta.json content; mirrors what the CLI wrote so both can share workspaces.
function M.meta_for(ref, problem, id_label, url)
  return {
    version = 1,
    ref = ref.mode == 'Public' and { kind = 'public', id = ref.id }
      or { kind = 'contest', cid = ref.cid, num = ref.num },
    submitProblem = ref,
    title = vim.trim(problem.title or ''),
    timeLimit = problem.time_limit,
    memoryLimit = problem.memory_limit,
    spj = problem.spj or false,
    url = url,
    pulledAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
end

function M.write(dir, markdown, meta, samples)
  vim.fn.mkdir(dir .. '/samples', 'p')

  local statement_path = dir .. '/statement.md'
  local out = io.open(statement_path, 'w')
  if not out then
    return false, 'cannot write ' .. statement_path
  end
  out:write(markdown)
  out:close()

  local meta_path = dir .. '/meta.json'
  out = io.open(meta_path, 'w')
  if not out then
    return false, 'cannot write ' .. meta_path
  end
  out:write(vim.json.encode(meta))
  out:close()

  for i, sample in ipairs(samples or {}) do
    local fin = io.open(string.format('%s/samples/%d.in', dir, i), 'w')
    if fin then
      fin:write(((sample.input or ''):gsub('\r\n', '\n')))
      fin:close()
    end
    local fout = io.open(string.format('%s/samples/%d.out', dir, i), 'w')
    if fout then
      fout:write(((sample.output or ''):gsub('\r\n', '\n')))
      fout:close()
    end
  end

  return true
end

--- Find meta.json walking up from `start` (a file or directory path).
function M.find(start)
  local dir = vim.fn.fnamemodify(start or vim.api.nvim_buf_get_name(0), ':p:h')
  if dir == '' then
    dir = vim.fn.getcwd()
  end
  local meta_path = vim.fs.find('meta.json', { upward = true, path = dir, type = 'file' })[1]
  if not meta_path then
    return nil
  end
  local ok, meta = pcall(function()
    local fd = io.open(meta_path, 'r')
    local content = fd:read('*a')
    fd:close()
    return vim.json.decode(content)
  end)
  if not ok or type(meta) ~= 'table' or meta.submitProblem == nil then
    return nil
  end
  return { dir = vim.fn.fnamemodify(meta_path, ':h'), meta = meta, meta_path = meta_path }
end

function M.read_samples(ws_dir)
  local samples = {}
  for i = 1, 99 do
    local in_path = string.format('%s/samples/%d.in', ws_dir, i)
    local out_path = string.format('%s/samples/%d.out', ws_dir, i)
    if vim.fn.filereadable(in_path) == 0 then
      break
    end
    local fin = io.open(in_path, 'r')
    local input = fin and fin:read('*a') or ''
    if fin then fin:close() end
    local fout = io.open(out_path, 'r')
    local output = fout and fout:read('*a') or ''
    if fout then fout:close() end
    samples[#samples + 1] = {
      input = (input:gsub('\r\n', '\n')),
      output = (output:gsub('\r\n', '\n')),
      name = string.format('样例 %d', i),
    }
  end
  return samples
end

--- Judge data downloaded by `:ZufeojData` (admin/teacher export), as `*.in`/`*.out` pairs.
function M.read_testdata(ws_dir)
  local pairs_found = {}
  local testdata_dir = ws_dir .. '/testdata'
  if vim.fn.isdirectory(testdata_dir) == 0 then
    return pairs_found
  end

  local files = vim.fn.globpath(testdata_dir, '**/*.in', false, true)
  table.sort(files, function(a, b)
    return a < b
  end)
  for _, in_path in ipairs(files) do
    local out_path = in_path:sub(1, -4) .. '.out'
    if vim.fn.filereadable(out_path) == 1 then
      local fin = io.open(in_path, 'r')
      local input = fin and fin:read('*a') or ''
      if fin then fin:close() end
      local fout = io.open(out_path, 'r')
      local output = fout and fout:read('*a') or ''
      if fout then fout:close() end
      pairs_found[#pairs_found + 1] = {
        input = input,
        output = output,
        name = vim.fn.fnamemodify(in_path, ':t'),
      }
    end
  end
  return pairs_found
end

--- Save modified buffers that belong to the workspace (plus an explicit extra
--- path) before an action reads files from disk. Runs in place: the window
--- layout, tab pages and focus are left exactly as they were, and autocmds are
--- skipped so a save hook can never rearrange the editor mid-action.
function M.save_modified(ws_dir, extra_path)
  local saved = {}
  -- fnamemodify(':p') already appends a trailing slash for existing directories
  local ws_root = ws_dir and (vim.fn.fnamemodify(ws_dir, ':p'):gsub('/+$', '')) or nil
  local ws_prefix = ws_root and (ws_root .. '/') or nil
  local target = extra_path and vim.fn.fnamemodify(extra_path, ':p') or nil

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].modified
      and vim.bo[bufnr].buftype == ''
      and not vim.bo[bufnr].readonly
    then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' then
        local path = vim.fn.fnamemodify(name, ':p')
        local relevant = (target ~= nil and path == target)
          or (ws_prefix ~= nil and vim.startswith(path, ws_prefix))
        if relevant then
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd('silent noautocmd update')
          end)
          saved[#saved + 1] = path
        end
      end
    end
  end
  return saved
end

--- Pick the source file to build/submit: main.* first, else the only candidate.
function M.find_source(dir)
  local extensions = { 'cpp', 'cc', 'cxx', 'c', 'java', 'py', 'php', 'go', 'rs' }
  local candidates = {}
  for _, ext in ipairs(extensions) do
    local found = vim.fn.glob(dir .. '/*.' .. ext, false, true)
    vim.list_extend(candidates, found)
  end
  if #candidates == 0 then
    return nil
  end
  for _, path in ipairs(candidates) do
    if vim.fn.fnamemodify(path, ':t'):match('^main%.') then
      return path
    end
  end
  return #candidates == 1 and candidates[1] or nil
end

--- Fetch + pull a problem into its workspace. cb(err, { dir, markdown, meta }).
--- `ref` is { mode = 'Public', id = n } or { mode = 'Contest', cid = n, num = n, label = 'A' }.
function M.pull(ref, cb)
  local statement = require('zufeoj.statement')

  local function got(err, problem)
    if err then
      cb(err)
      return
    end
    local id_label
    if ref.mode == 'Public' then
      id_label = tostring(problem.problem_id or ref.id)
    else
      id_label = ref.label or api.problem_letter(ref.num)
    end

    local url = ref.mode == 'Public'
      and ('https://acm.ocrosoft.com/problem.php?id=' .. ref.id)
      or ('https://acm.ocrosoft.com/problem.php?cid=' .. ref.cid .. '&pid=' .. ref.num)

    local markdown = statement.render(problem, { id_label = id_label, url = url })
    local meta = M.meta_for(ref, problem, id_label, url)
    local dir = M.dir_for(ref, id_label, problem.title)
    local ok, werr = M.write(dir, markdown, meta, problem.samples)
    if not ok then
      cb({ message = werr })
      return
    end
    cb(nil, { dir = dir, markdown = markdown, meta = meta, problem = problem })
  end

  if ref.mode == 'Public' then
    api.problem(ref.id, got)
  else
    api.contest_problem(ref.cid, ref.num, got)
  end
end

return M
