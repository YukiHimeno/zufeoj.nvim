# zufeoj.nvim

ZUFEOJ（[acm.ocrosoft.com](https://acm.ocrosoft.com)）在 Neovim 里。
```
┌───────────────────────────── ZUFEOJ 题库 ──────────────────────────────┐
│> 采药                                                                   │
│ 输入模糊过滤 · <C-n>/<C-p> 选择 · <CR> 打开 · <C-s> 拉取 · Esc 关闭      │
│ 1/200 · 第 1/1 页 <C-f>/<C-b>                                            │
│─────────────────────────────────────────────────────────────────────────│
│    P1003  小奇采药                                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

## 使用

一个命令进去，之后只用方向键：

```
:Zufeoj
```

面板分四段：操作（题库、比赛等入口）、当前工作区信息、最近题目、账号状态。`j/k` 移动，回车执行，`q` 关闭。

- 题库/比赛列表里回车 = 拉取（如需）并打开工作区：题面 buffer + 源码 + `tcd` 到题目目录；`<C-o>` 只看题面
- 本地测试和提交在浮动窗里跟进，提交未登录时会就地提示登录并重试
- 最近题目直接回车就能回到对应工作区
- 本地测试和提交前会自动保存工作区里未保存的修改：就地写入，不动窗口布局、标签页和焦点

插件不注册任何默认键位。想让一个键打开面板，自己绑一行即可：

```lua
vim.keymap.set('n', '<leader>z', '<cmd>Zufeoj<cr>', { desc = 'zufeoj' })
```

所有功能也是普通函数：`require('zufeoj').problems()`、`.contests()`、`.test()`、`.submit_cmd()`、`.watch()`。

### 列表界面

`picker = 'auto'`（默认）在检测到 snacks.nvim、telescope.nvim 或 fzf-lua 时把列表交给 `vim.ui.select`，由它们自己的界面渲染；一个都没有时用内置浮动选择器（中文子序列过滤，支持服务端分页）。想固定某一种：`picker = 'builtin'` 或 `picker = 'ui'`。

## 安装

**不依赖任何插件管理器，也不需要写 `setup()`，装上就能用**（默认配置会在首次使用时自动建目录）。

Neovim 0.12+ 内置的 `vim.pack`：

```lua
vim.pack.add({ 'https://github.com/YukiHimeno/zufeoj.nvim' })
```

手动安装（任意版本，零配置）：

```bash
git clone https://github.com/YukiHimeno/zufeoj.nvim \
  ~/.config/nvim/pack/zufe/start/zufeoj.nvim
```

或者直接把它放进 runtimepath：

```lua
vim.opt.rtp:prepend('~/src/zufeoj.nvim')
```

需要调整默认值时再调用一次：

```lua
require('zufeoj').setup({
  -- workdir = vim.fn.stdpath('data') .. '/zufeoj/workspace',
  -- cookie_file = vim.fn.stdpath('data') .. '/zufeoj/cookies.txt',
  -- poll_interval = 2000,
  -- judge_timeout = 180,
  -- picker = 'auto',   -- 'auto' | 'builtin' | 'ui'
})
```

外部依赖只有命令行工具：`curl`（必需）与 `unzip`（仅 `:ZufeojData` 需要）。

## 命令

| 命令 | 说明 |
| --- | --- |
| `:Zufeoj` | 浮动操作面板（推荐入口） |
| `:ZufeojLogin` / `:ZufeojLogout` | 登录 / 退出（对话式输入账号密码） |
| `:ZufeojStatus` | 账号、工作区、测试数据、源码一览 |
| `:ZufeojProblems` | 题库选择器（`<CR>` 开题面，`<C-s>` 拉到工作区） |
| `:ZufeojContests` | 比赛列表 → 题目列表 |
| `:ZufeojOpen [题号]` | 打开题面（`1001`、`6471 A`、`6471-A`、`6471:0`） |
| `:ZufeojPull [题号]` | 拉取到工作区并打开源码 |
| `:ZufeojTest` | 本地跑样例 + 评测数据 |
| `:ZufeojData` | 下载评测数据（admin/教师） |
| `:ZufeojSubmit [文件]` | 提交当前文件并跟踪判题 |
| `:ZufeojWatch [sid]` | 监视判题（缺省盯自己最新一次提交） |
| `:ZufeojHealth` | 环境自检（curl/编译器/cookie） |

## 工作区

```
<workdir>/
├── 1001-向屏幕上输出字符/            # 题库题
│   ├── statement.md                 # 题面（markdown）
│   ├── meta.json                    # 题目/提交所需信息
│   ├── main.cpp                     # 你的代码
│   ├── samples/1.in 1.out           # 样例（自动）
│   └── testdata/                    # 评测数据（:ZufeojData，可选）
└── contest-6471/A-立方数/            # 比赛题
```

在题目目录（或其子目录）里打开任意文件，`:ZufeojTest` / `:ZufeojSubmit` 都会自动找到工作区。

## 说明

- 会话走站点自身的 REST API（与网页前端同一套），登录后所有请求带 cookie
- 评测数据的导出接口仅管理员/题目所属教师可用；学生账号请用 `:ZufeojTest` 跑样例，提交后看判题输出（WA 会给出与期望数据的逐行对比）
- 判题码 < 4 表示排队/评测中；轮询间隔与超时可在 `opts` 里调整

## License

MIT
