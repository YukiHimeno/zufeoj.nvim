--- Command surface for zufe.nvim. Everything is also reachable via require('zufeoj').
if vim.g.loaded_zufeoj == 1 then
  return
end
vim.g.loaded_zufeoj = 1

local function zufe()
  return require('zufeoj')
end

local commands = {
  Zufeoj = { desc = 'zufeoj: 打开操作面板', fn = function() zufe().dashboard() end },
  ZufeojSetup = { desc = 'zufeoj: 应用配置', fn = function() zufe().setup() end },
  ZufeojLogin = { desc = 'zufeoj: 登录', fn = function() zufe().login() end },
  ZufeojLogout = { desc = 'zufeoj: 退出登录', fn = function() zufe().logout() end },
  ZufeojStatus = { desc = 'zufeoj: 账号与工作区状态', fn = function() zufe().status() end },
  ZufeojProblems = { desc = 'zufeoj: 题库选择器', fn = function() zufe().problems() end },
  ZufeojContests = { desc = 'zufeoj: 比赛列表', fn = function() zufe().contests() end },
  ZufeojOpen = { desc = 'zufeoj: 打开题面', nargs = '*', fn = function(args) zufe().open(args[1], args[2]) end },
  ZufeojPull = { desc = 'zufeoj: 拉取题目到工作区', nargs = '*', fn = function(args) zufe().pull(args[1], args[2]) end },
  ZufeojTest = { desc = 'zufeoj: 本地运行样例/评测数据', fn = function() zufe().test() end },
  ZufeojData = { desc = 'zufeoj: 下载评测数据（admin/教师）', nargs = '*', fn = function(args) zufe().data(args[1]) end },
  ZufeojSubmit = { desc = 'zufeoj: 提交当前文件', nargs = '*', fn = function(args) zufe().submit_cmd(args[1]) end },
  ZufeojWatch = { desc = 'zufeoj: 监视判题结果', nargs = '*', fn = function(args) zufe().watch(args[1]) end },
  ZufeojHealth = { desc = 'zufeoj: 环境自检', fn = function() zufe().health() end },
}

for name, spec in pairs(commands) do
  vim.api.nvim_create_user_command(name, function(args)
    spec.fn(args.fargs)
  end, { desc = spec.desc, nargs = spec.nargs or 0 })
end
