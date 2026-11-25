local M = {}
local api, fn = vim.api, vim.fn
local names = { mermaid = "Mermaid", drawio = "draw.io" }

-- Pair Markdown fences inside each message so examples and incomplete replies stay literal.
function M.scan(lines, start, figures)
  local open
  for idx, line in ipairs(lines) do
    local indent, fence, tail = line:match("^( *)(`+)(.*)$")
    if not fence then indent, fence, tail = line:match("^( *)(~+)(.*)$") end
    if fence and #indent <= 3 and #fence >= 3 then
      if open then
        if fence:sub(1, 1) == open.marker and #fence >= open.width and tail:match("^%s*$") then
          if names[open.kind] and idx > open.idx + 1 then
            figures[#figures + 1] = {
              kind = open.kind, label = names[open.kind], lines = lines,
              first = start + open.idx - 1, last = start + idx - 1,
              body = open.idx + 1, count = idx - open.idx - 1,
            }
          end
          open = nil
        end
      elseif fence:sub(1, 1) == "~" or not tail:find("`", 1, true) then
        open = { idx = idx, marker = fence:sub(1, 1), width = #fence, kind = tail:match("^%s*(%S+)") }
      end
    end
  end
end

local function external(path, notify)
  local _, err = vim.ui.open(path)
  if err then notify("画像を開けませんでした。", vim.log.levels.ERROR, err) end
end

local function terminal_images()
  if #api.nvim_list_uis() == 0 or vim.env.TMUX then return end
  if vim.env.TERM_PROGRAM ~= "ghostty" and not vim.env.KITTY_WINDOW_ID then return end
  if vim.env.SPIDER_STANDALONE == "1" and not package.loaded.image then
    if fn.executable("magick") ~= 1 then return end
    -- --clean intentionally omits the user's package directory from 'packpath'.
    local local_packages = fn.stdpath("data") .. "/site"
    local plugin = fn.globpath(local_packages, "pack/*/opt/image.nvim", false, true)[1]
    if plugin then vim.opt.runtimepath:append(plugin) end
    pcall(vim.cmd.packadd, "image.nvim")
    local ok, image = pcall(require, "image")
    if not ok then return end
    local integrations = {}
    for _, name in ipairs({ "markdown", "asciidoc", "typst", "neorg", "syslang" }) do
      integrations[name] = { enabled = false }
    end
    image.setup({ integrations = integrations, hijack_file_patterns = {}, max_height_window_percentage = 100 })
  end
  local image = package.loaded.image
  if type(image) == "table" and image.is_enabled() then return image end
end

local function preview(path, title, notify)
  local image = terminal_images()
  local width, height = vim.o.columns - 10, vim.o.lines - vim.o.cmdheight - 7
  if not image or width < 24 or height < 8 then return external(path, notify) end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  local win = api.nvim_open_win(buf, true, {
    relative = "editor", row = 2, col = 4, width = width, height = height,
    style = "minimal", border = "rounded", title = " " .. title .. " ",
    footer = " q / Esc 閉じる   o 外部で開く ", footer_pos = "center",
  })
  local ok, picture = pcall(image.from_file, path, { window = win, buffer = buf, x = 0, y = 0 })
  if not ok or not picture then
    api.nvim_win_close(win, true)
    return external(path, notify)
  end
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true, callback = function() picture:clear() end,
  })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() api.nvim_win_close(win, true) end, { buffer = buf })
  end
  vim.keymap.set("n", "o", function() external(path, notify) end, { buffer = buf })
  picture:render()
end

local renderers = {
  graph = { command = "dot", hint = "Graphviz (dot)", extension = "dot" },
  mermaid = { command = "mmdc", hint = "@mermaid-js/mermaid-cli (mmdc)", extension = "mmd" },
  drawio = { command = "drawio", hint = "draw.io Desktop (drawio)", extension = "drawio" },
}

local function render(kind, title, content, path, notify, visible)
  local renderer = renderers[kind]
  if fn.executable(renderer.command) ~= 1 then
    notify("図の表示には " .. renderer.hint .. " が必要です。", vim.log.levels.WARN)
    return
  end
  if kind ~= "graph" and fn.executable("bwrap") ~= 1 then
    notify("図をオフラインで描画するには bubblewrap (bwrap) が必要です。", vim.log.levels.WARN)
    return
  end
  local base = fn.tempname()
  local output = base .. ".png"
  local source = path or (base .. "." .. renderer.extension)
  if not path and fn.writefile(content, source, "b") ~= 0 then
    notify("図の入力ファイルを作成できませんでした。", vim.log.levels.ERROR)
    return
  end
  local args, opts = {}, { text = true, timeout = 45000 }
  if kind == "graph" then
    args = { "dot", "-Tpng", "-o", output, source }
  else
    args = { "bwrap", "--die-with-parent", "--unshare-net", "--bind", "/", "/", "--dev-bind", "/dev", "/dev", "--proc", "/proc", "--" }
    if kind == "mermaid" then
      vim.list_extend(args, { "mmdc", "-i", source, "-o", output, "-s", "2" })
      if not vim.env.PUPPETEER_EXECUTABLE_PATH and fn.executable("chromium") == 1 then
        opts.env = { PUPPETEER_EXECUTABLE_PATH = fn.exepath("chromium") }
      end
    else
      vim.list_extend(args, { "drawio", "--export", "--format", "png", "--scale", "2", "--output", output, source })
    end
  end
  notify(title .. " を描画中…")
  local ok, err = pcall(vim.system, args, opts, vim.schedule_wrap(function(result)
    if not path then fn.delete(source) end
    if not visible() then return end
    if result.code ~= 0 or fn.getfsize(output) <= 0 then
      local detail = vim.trim(result.stderr or ""):sub(-320)
      notify(title .. " を描画できませんでした。", vim.log.levels.ERROR, detail)
      return
    end
    preview(output, title, notify)
  end))
  if not ok then
    if not path then fn.delete(source) end
    notify("画像レンダラーを起動できませんでした。", vim.log.levels.ERROR, err)
  end
end

local function figure_image(figure, notify, visible)
  local body = {}
  for idx = figure.body, figure.body + figure.count - 1 do body[#body + 1] = figure.lines[idx] end
  render(figure.kind, figure.label, body, nil, notify, visible)
end

function M.choose(figures, row, notify, visible)
  for _, figure in ipairs(figures) do
    if row >= figure.first and row <= figure.last then return figure_image(figure, notify, visible) end
  end
  local file = { label = "draw.io ファイルを開く…" }
  local choices = vim.list_extend(vim.list_extend({}, figures), { file })
  vim.ui.select(choices, {
    prompt = "画像にして表示する図：",
    format_item = function(item) return item.first and ("%s（行 %d）"):format(item.label, item.first) or item.label end,
  }, function(choice)
    if not choice or not visible() then return end
    if choice ~= file then return figure_image(choice, notify, visible) end
    vim.ui.input({ prompt = "draw.io ファイル：", completion = "file" }, function(value)
      if not value or value == "" or not visible() then return end
      local path = fn.fnamemodify(value, ":p")
      if fn.filereadable(path) ~= 1 then
        notify("draw.io ファイルが見つかりません。", vim.log.levels.WARN)
        return
      end
      render("drawio", "draw.io", nil, path, notify, visible)
    end)
  end)
end

function M.graph(state, notify, visible)
  local function quote(text)
    return '"' .. text:gsub("[%c]", " "):gsub('[\\"]', '\\%0') .. '"'
  end
  local dot = {
    "digraph {",
    'graph [bgcolor="#181d26", dpi=144, pad=0.25, nodesep=0.25, ranksep=0.65, rankdir=LR]',
    'node [shape=box, style="rounded,filled", color="#63728b", fillcolor="#252e3e", fontcolor="#e8eef8", fontname="sans-serif", margin="0.18,0.11"]',
    'edge [color="#8496b3", arrowsize=0.65]',
  }
  local parent = {}
  for idx, entry in ipairs(state.tree) do
    local selected = entry.id == state.node.id and ', color="#89d9c9", fillcolor="#24433f", penwidth=2' or ""
    dot[#dot + 1] = ("n%d [label=%s%s]"):format(idx, quote(entry.title), selected)
    if entry.depth > 0 then dot[#dot + 1] = ("n%d -> n%d"):format(parent[entry.depth], idx) end
    parent[entry.depth + 1] = idx
  end
  dot[#dot + 1] = "}"
  render("graph", "会話グラフ", dot, nil, notify, visible)
end

return M
