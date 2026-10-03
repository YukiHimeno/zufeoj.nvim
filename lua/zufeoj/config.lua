local M = {}

M.defaults = {
  -- Where downloaded problems, samples and judge test data live.
  -- {problem} and {contest} expand to the problem id / contest id.
  workdir = vim.fn.stdpath('data') .. '/zufeoj/workspace',
  -- curl cookie jar holding the ZUFEOJ session (Netscape format).
  cookie_file = vim.fn.stdpath('data') .. '/zufeoj/cookies.txt',
  -- Language used when the current file type does not map to one.
  default_language = 'C++',
  -- Poll interval (ms) while waiting for a verdict.
  poll_interval = 2000,
  -- Give up waiting for a verdict after this many seconds.
  judge_timeout = 180,
  -- List UI: 'auto' uses snacks/telescope/fzf-lua via vim.ui.select when one is
  -- loaded, 'builtin' always uses the bundled floating picker, 'ui' always
  -- defers to vim.ui.select (whatever provides it).
  picker = 'auto',
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  vim.fn.mkdir(vim.fn.fnamemodify(M.options.cookie_file, ':h'), 'p')
  vim.fn.mkdir(M.options.workdir, 'p')
  return M.options
end

function M.get()
  if vim.tbl_isempty(M.options) then
    M.setup()
  end
  return M.options
end

return M
