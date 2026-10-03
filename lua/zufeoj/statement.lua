--- Problem statements: HTML → markdown → buffer.
---
--- ZUFEOJ descriptions are Word-era HTML with KaTeX spans and inline styles.
--- We convert to markdown (headings, lists, code, tables, images, links),
--- keeping a readable buffer that plays well with treesitter markdown and
--- render-markdown.nvim when the user has them.
local M = {}

local ENTITIES = {
  nbsp = ' ', lt = '<', gt = '>', amp = '&', quot = '"', apos = "'",
  ['#39'] = "'", ['#44'] = ',', ldquo = '“', rdquo = '”', hellip = '…', mdash = '—', ndash = '–',
  times = '×', le = '≤', ge = '≥', ne = '≠', middot = '·', minus = '−',
}

local function decode_entities(text)
  text = text:gsub('&#(%d+);', function(n)
    local code = tonumber(n)
    if code and code > 0 and code < 0x110000 then
      return vim.fn.nr2char(code)
    end
    return ''
  end)
  text = text:gsub('&#[xX](%x+);', function(n)
    return vim.fn.nr2char(tonumber(n, 16))
  end)
  text = text:gsub('&(%a+#?%d*);', function(name)
    return ENTITIES[name] or ('&' .. name .. ';')
  end)
  return text
end

local function absolutize(src)
  if src:sub(1, 5) == 'data:' then
    return nil
  end
  if src:match('^https?://') then
    return src
  end
  if src:sub(1, 1) == '/' then
    return 'https://acm.ocrosoft.com' .. src
  end
  return 'https://acm.ocrosoft.com/' .. src
end

--- KaTeX inline markup → $latex$ using the embedded TeX annotation.
local function katex_to_tex(html)
  return html:gsub('<span class="katex".-</span>%s*</span>', function(block)
    local tex = block:match('<annotation encoding="application/x%-tex">(.-)</annotation>')
    if tex then
      return '$' .. vim.trim(decode_entities(tex)) .. '$'
    end
    return ''
  end):gsub('<span class="katex.-</annotation></semantics></math></span>', function(block)
    local tex = block:match('<annotation encoding="application/x%-tex">(.-)</annotation>')
    return tex and ('$' .. vim.trim(decode_entities(tex)) .. '$') or ''
  end)
end

--- Convert a statement HTML fragment to markdown.
function M.html_to_markdown(html)
  if html == nil or html == '' then
    return ''
  end

  local text = html
  -- normalize line endings first: stray \r renders as ^M in buffers
  text = text:gsub('\r\n', '\n'):gsub('\r', '\n')
  -- drop junk produced by Word / editors
  text = text:gsub('<script.->.-</script>', '')
  text = text:gsub('<style.->.-</style>', '')
  text = text:gsub('<xml.->.-</xml>', '')
  text = text:gsub('<w:[^>]->.-</w:[^>]->', '')
  text = text:gsub('<div class="open_grepper_editor".-</div>', '')
  text = katex_to_tex(text)

  -- code blocks first so their content is not touched by inline rules
  text = text:gsub('<pre[^>]*>(.-)</pre>', function(code)
    code = decode_entities(code):gsub('<br%s*/?>', '\n'):gsub('^%s*\n', ''):gsub('\n%s*$', '')
    return '\n```\n' .. code .. '\n```\n'
  end)
  text = text:gsub('<code[^>]*>(.-)</code>', function(code)
    return '`' .. decode_entities(code) .. '`'
  end)

  -- images (keep markdown syntax so editors/renderers can act on them)
  text = text:gsub('<img[^>]-src="([^"]-)"[^>]->', function(src)
    local abs = absolutize(decode_entities(src))
    return abs and ('![](' .. abs .. ')') or ''
  end)
  text = text:gsub("<img[^>]-src='([^']-)'[^>]->", function(src)
    local abs = absolutize(decode_entities(src))
    return abs and ('![](' .. abs .. ')') or ''
  end)

  -- links
  text = text:gsub('<a[^>]-href="([^"]-)"[^>]*>(.-)</a>', function(href, label)
    return '[' .. decode_entities(label) .. '](' .. decode_entities(href) .. ')'
  end)

  -- emphasis
  text = text:gsub('<strong[^>]*>(.-)</strong>', '**%1**')
  text = text:gsub('<b[^>]*>(.-)</b>', '**%1**')
  text = text:gsub('<em[^>]*>(.-)</em>', '*%1*')
  text = text:gsub('<i[^>]*>(.-)</i>', '*%1*')

  -- headings
  for level = 1, 6 do
    text = text:gsub('<h' .. level .. '[^>]*>(.-)</h' .. level .. '>', function(inner)
      return '\n' .. string.rep('#', level) .. ' ' .. decode_entities(inner) .. '\n'
    end)
  end

  -- lists
  text = text:gsub('<li[^>]*>(.-)</li>', function(item)
    return '\n- ' .. decode_entities(item):gsub('%s+$', '')
  end)
  text = text:gsub('</?[ou]l[^>]*>', '\n')

  -- tables: rows/cells become markdown-ish lines; ZUFEOJ uses them mostly for samples
  text = text:gsub('<tr[^>]*>', '\n| ')
  text = text:gsub('</tr>', ' |')
  text = text:gsub('<t[dh][^>]*>', ' | ')
  text = text:gsub('<table[^>]*>', '\n')
  text = text:gsub('</table>', '\n')

  -- block breaks
  text = text:gsub('<br%s*/?>', '\n')
  text = text:gsub('</p>', '\n\n')
  text = text:gsub('<p[^>]*>', '\n')
  text = text:gsub('</div>', '\n')
  text = text:gsub('<hr%s*/?>', '\n---\n')

  -- strip whatever tags remain, then entities
  text = text:gsub('<[^>]->', '')
  text = decode_entities(text)

  -- tidy whitespace
  text = text:gsub('[ \t]+\n', '\n')
  text = text:gsub('\n\n\n+', '\n\n')
  text = text:gsub('^\n+', '')
  return vim.trim(text)
end

local function sample_block(label, content)
  content = (content or ''):gsub('\r\n', '\n'):gsub('\r', '\n'):gsub('\n+$', '')
  return '**' .. label .. '**\n\n```\n' .. content .. '\n```\n'
end

--- Full statement markdown for a problem (public or contest).
function M.render(problem, opts)
  local id_label = opts.id_label
  local lines = {}

  lines[#lines + 1] = '# ' .. id_label .. '. ' .. vim.trim(problem.title or '')
  local meta = string.format('> 时间限制 **%ss** · 内存限制 **%sMB**%s', problem.time_limit, problem.memory_limit, problem.spj and ' · SPJ' or '')
  lines[#lines + 1] = meta
  if opts.url then
    lines[#lines + 1] = '> ' .. opts.url
  end

  local sections = {
    { '题目描述', problem.description },
    { '输入格式', problem.input },
    { '输出格式', problem.output },
  }
  for _, section in ipairs(sections) do
    local body = M.html_to_markdown(section[2])
    if body ~= '' then
      lines[#lines + 1] = '## ' .. section[1]
      lines[#lines + 1] = body
    end
  end

  local samples = problem.samples or {}
  if #samples > 0 then
    lines[#lines + 1] = '## 样例'
    for i, sample in ipairs(samples) do
      local suffix = #samples == 1 and '' or (' ' .. i)
      lines[#lines + 1] = sample_block('输入' .. suffix, sample.input)
      lines[#lines + 1] = sample_block('输出' .. suffix, sample.output)
    end
  end

  local hint = M.html_to_markdown(problem.hint)
  if hint ~= '' then
    lines[#lines + 1] = '## 提示'
    lines[#lines + 1] = hint
  end
  if problem.source and vim.trim(problem.source) ~= '' then
    lines[#lines + 1] = '## 来源'
    lines[#lines + 1] = vim.trim(problem.source)
  end

  return table.concat(lines, '\n\n') .. '\n'
end

--- Open (or focus) a statement in a scratch buffer named zufe://problem/<key>.
function M.open(key, title, markdown)
  local bufname = 'zufe://problem/' .. key
  local bufnr = vim.fn.bufnr('^' .. vim.fn.escape(bufname, '\\') .. '$')
  if bufnr == -1 then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, bufname)
  end

  local content = vim.split(markdown, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].filetype = 'markdown'
  vim.bo[bufnr].swapfile = false

  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'q', '', {
    callback = function()
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end,
    desc = '关闭题面',
  })

  vim.cmd('sbuffer ' .. bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return bufnr
end

return M
