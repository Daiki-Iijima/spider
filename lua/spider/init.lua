local M = {}
local api = vim.api
local fn = vim.fn
local diagrams = require("spider.diagrams")
local headings = api.nvim_create_namespace("spider.headings")
local sources = api.nvim_create_namespace("spider.sources")
local branch_marks = api.nvim_create_namespace("spider.branches")
local transcript_colors = api.nvim_create_namespace("spider.transcript.colors")
local module_path = debug.getinfo(1, "S").source:sub(2)
local root = fn.fnamemodify(vim.uv.fs_realpath(module_path) or module_path, ":p:h:h:h")
local backend = root .. "/dist/spider-tui.cjs"
local leader = vim.env.SPIDER_STANDALONE == "1" and not vim.g.mapleader and "<Space>" or "<leader>"
local leader_hint = (leader == "<Space>" or vim.g.mapleader == " ") and "Space" or "<Leader>"
local help_key, help_hint = leader .. "?", leader_hint .. " ?"
local command_prefix, command_hint = leader .. "s", leader_hint .. " s "
local providers = { "codex", "claude", "omp" }
local provider_labels = { codex = "Codex", claude = "Claude", omp = "omp" }
local role_labels = { system = "会話の指示", user = "質問", assistant = "AI の回答" }
local role_colors = { system = "Comment", user = "SpiderQuestion", assistant = "SpiderAnswer" }
local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local frame_ms = 150
local active

local function label(text)
  return (text:gsub("[%c]+", " "))
end

local function notify(text, level, detail)
  if detail and detail ~= "" then text = text .. " " .. tostring(detail) end
  vim.notify("Spider: " .. label(text), level or vim.log.levels.INFO)
end

local function live(session)
  return active == session and api.nvim_tabpage_is_valid(session.tab)
end

local function owns_window(win, buf)
  return win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf
end

local function scratch(name, editable)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, "spider://" .. name .. "/" .. buf)
  local bo = vim.bo[buf]
  bo.bufhidden = editable and "wipe" or "hide"
  bo.modifiable = editable
  if not editable then bo.undolevels = -1 end
  return buf
end

local function define_colors()
  local function foreground(name, fallback)
    return api.nvim_get_hl(0, { name = name, link = false }).fg or fallback
  end
  local dark = vim.o.background == "dark"
  local fg = foreground("Normal", dark and 0xe0e2ea or 0x20242c)
  local bg = api.nvim_get_hl(0, { name = "Normal", link = false }).bg or (dark and 0x14161b or 0xf7f8fa)
  local function tint(weight)
    local color = 0
    for _, shift in ipairs({ 16, 8, 0 }) do
      local a, b = bit.band(bit.rshift(bg, shift), 255), bit.band(bit.rshift(fg, shift), 255)
      color = color + bit.lshift(math.floor(a + (b - a) * weight), shift)
    end
    return color
  end
  local info = foreground("DiagnosticInfo", fg)
  local accent = foreground("DiagnosticOk", fg)
  local strong = foreground("DiagnosticWarn", fg)
  api.nvim_set_hl(0, "SpiderAnswer", { fg = accent, bold = true })
  api.nvim_set_hl(0, "SpiderQuestion", { fg = info, bold = true })
  api.nvim_set_hl(0, "SpiderEmphasis", { fg = strong, bold = true })
  api.nvim_set_hl(0, "SpiderSection", { fg = info, bold = true })
  api.nvim_set_hl(0, "SpiderBranchSource", { underline = true, sp = info })
  api.nvim_set_hl(0, "SpiderCode", { bg = tint(0.08) })
  api.nvim_set_hl(0, "SpiderCodeInline", { fg = accent, bg = tint(0.09) })
  api.nvim_set_hl(0, "SpiderMuted", { fg = tint(0.67) })
  api.nvim_set_hl(transcript_colors, "@markup.strong.markdown_inline", { link = "SpiderEmphasis" })
  api.nvim_set_hl(transcript_colors, "@markup.raw.markdown_inline", { link = "SpiderCodeInline" })
  api.nvim_set_hl(transcript_colors, "@markup.quote.markdown", { link = "SpiderMuted" })
  for level = 1, 6 do
    api.nvim_set_hl(transcript_colors, "@markup.heading." .. level .. ".markdown", { link = "SpiderSection" })
  end
end

local function setup_standalone_markdown()
  require("render-markdown").setup({
    heading = {
      icons = { "◆ ", "◇ ", "▸ " },
      backgrounds = { "" },
      foregrounds = { "SpiderSection" },
    },
    code = {
      width = "block", right_pad = 2, highlight = "SpiderCode", highlight_border = "SpiderCode",
      highlight_language = "SpiderMuted", highlight_inline = "SpiderCodeInline",
    },
    quote = { highlight = "SpiderMuted" },
    pipe_table = { head = "SpiderSection", row = "Normal" },
  })
end

local function load_standalone_markdown()
  if vim.env.SPIDER_STANDALONE ~= "1" or vim.env.MYVIMRC or vim.g.loaded_render_markdown then return end
  if #api.nvim_get_runtime_file("plugin/render-markdown.lua", false) == 0 then
    local dir = vim.env.SPIDER_MARKDOWN_RUNTIME or (fn.stdpath("data") .. "/lazy/render-markdown.nvim")
    if vim.uv.fs_stat(dir .. "/plugin/render-markdown.lua") then
      vim.opt.runtimepath:append(dir)
    end
  end
  vim.cmd.runtime("plugin/render-markdown.lua")
  if vim.g.loaded_render_markdown then setup_standalone_markdown() end
end

local function configure(win, tree)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.foldenable = false
  wo.spell = false
  wo.list = false
  wo.conceallevel = 0
  wo.wrap = not tree
  wo.linebreak = not tree
  wo.cursorline = tree
end

local function configure_transcript(win)
  configure(win, false)
  vim.wo[win].breakindent = true
  vim.wo[win].colorcolumn = ""
  vim.wo[win].sidescrolloff = 0
  api.nvim_win_set_hl_ns(win, transcript_colors)
end

local function replace_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, headings, 0, -1)
end

local function heading(buf, row)
  api.nvim_buf_set_extmark(buf, headings, row - 1, 0, { line_hl_group = "Title" })
end

local function toggle_help(session)
  if session.help_win and api.nvim_win_is_valid(session.help_win) then
    api.nvim_win_close(session.help_win, true)
    return
  end
  local ok, doc = pcall(fn.readfile, root .. "/README.md")
  local start = ok and fn.index(doc, "<!-- spider-keys:start -->") or -1
  local finish = ok and fn.index(doc, "<!-- spider-keys:end -->") or -1
  if start == -1 or finish <= start + 1 then
    notify("操作表を読み込めませんでした。", vim.log.levels.ERROR)
    return
  end
  local width = math.min(80, vim.o.columns - 6)
  local lines, spans, key_width = {}, {}, 0
  for index = start + 4, finish do
    local action, keys = doc[index]:match("^|%s*(.-)%s*|%s*(.-)%s*|$")
    if action and keys then
      keys = keys:gsub("`", ""):gsub("Space", leader_hint)
      key_width = math.max(key_width, fn.strdisplaywidth(keys))
      spans[#spans + 1] = #keys
      lines[#lines + 1] = { keys, action }
    end
  end
  local height = math.min(#lines, vim.o.lines - vim.o.cmdheight - 6)
  if width < 26 or height < 3 then return notify("操作表を表示するには端末を広げてください。") end
  for index, item in ipairs(lines) do
    local padding = math.max(2, math.min(key_width, math.floor(width / 2)) - fn.strdisplaywidth(item[1]) + 2)
    lines[index] = item[1] .. string.rep(" ", padding) .. item[2]
  end
  local buf = scratch("help", false)
  vim.bo[buf].bufhidden = "wipe"
  replace_lines(buf, lines)
  for index, bytes in ipairs(spans) do
    api.nvim_buf_set_extmark(buf, headings, index - 1, 0, { end_col = bytes, hl_group = "SpiderSection" })
  end
  local win = api.nvim_open_win(buf, true, {
    relative = "editor", row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2) - 1, width = width, height = height,
    style = "minimal", border = "rounded", title = " Spider の操作 ",
    footer = " Esc 閉じる ", footer_pos = "center",
  })
  session.help_win = win
  configure(win, false)
  vim.wo[win].scrolloff = 0
  for _, key in ipairs({ "<Esc>", help_key }) do
    vim.keymap.set("n", key, function() api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  end
end

local function bind_help(session, buf)
  vim.keymap.set("n", help_key, function() toggle_help(session) end, { buffer = buf, desc = "Spider の操作一覧" })
end

local function draw_status(session)
  if not owns_window(session.transcript_win, session.transcript) then return end
  local state = session.state
  local provider = state and provider_labels[state.provider]
  local activity, hint
  if session.progress_started then
    local ms = (vim.uv.hrtime() - session.progress_started) / 1e6
    local frame = spinner[math.floor(ms / frame_ms) % #spinner + 1]
    local phase = session.cancelling and "中止中" or "AI の応答待ち"
    activity = "%#DiagnosticInfo#" .. frame .. " " .. phase .. (" · %d秒"):format(math.floor(ms / 1000)) .. "%*"
    hint = session.cancelling and "" or " %=%<" .. command_hint .. "x で中止 "
  else
    activity = not session.job and "停止中" or not state and "起動中" or session.waiting and "処理中" or "待機中"
    hint = " %=%<" .. command_hint .. "i 質問を書く  Tab 分岐  " .. help_hint .. " 操作 "
  end
  vim.wo[session.transcript_win].winbar = " Spider · " .. (provider and provider .. " · " or "") .. activity .. hint
end

local function status(session)
  local busy = session.job and session.state and (session.pending or session.state.busy)
  if busy and not session.progress_timer then
    session.progress_started = vim.uv.hrtime()
    local timer = assert(vim.uv.new_timer())
    session.progress_timer = timer
    timer:start(frame_ms, frame_ms, vim.schedule_wrap(function()
      if session.progress_timer == timer and live(session) then draw_status(session) end
    end))
  elseif not busy and session.progress_timer then
    session.progress_timer:close()
    session.progress_timer, session.progress_started, session.cancelling = nil, nil, nil
  end
  draw_status(session)
end

local function render_tree(session)
  local state, lines = session.state, {}
  local ids, selected, continuation = {}, nil, {}
  if state then
    for _, entry in ipairs(state.tree) do
      local current = entry.id == state.node.id
      local prefix = {}
      if entry.depth > 0 then
        for depth = 1, entry.depth - 1 do prefix[depth] = continuation[depth] end
        prefix[entry.depth] = entry.last and "└─ " or "├─ "
        continuation[entry.depth] = entry.last and "   " or "│  "
      end
      lines[#lines + 1] = table.concat(prefix) .. (current and "› " or "  ") .. label(entry.title)
      ids[#lines] = entry.id
      if current then selected = #lines end
    end
  end
  replace_lines(session.tree, lines)
  session.tree_ids = ids
  session.tree_selected = selected
  if selected then
    heading(session.tree, selected)
    if owns_window(session.tree_win, session.tree) then
      api.nvim_win_set_cursor(session.tree_win, { selected, 0 })
    end
  end
  if selected and owns_window(session.graph_win, session.tree) then
    api.nvim_win_set_cursor(session.graph_win, { selected, 0 })
  end
end

local function byte_position(block, byte)
  for index, line in ipairs(block.lines) do
    if byte <= #line then return block.first + index - 1, byte end
    byte = byte - #line - 1
  end
end

local function source_position(blocks, source)
  local block = blocks[source.messageId]
  if not block then return end
  local content = block.message.content
  local first = vim.str_byteindex(content, "utf-16", source.start, false)
  local last = vim.str_byteindex(content, "utf-16", source["end"], false)
  if first >= last then return end
  local row, col = byte_position(block, first)
  local end_row, end_col = byte_position(block, last)
  return row, col, end_row, end_col
end

local function mark_branches(buf, blocks, branch_sources)
  api.nvim_buf_clear_namespace(buf, branch_marks, 0, -1)
  local icons = {}
  for _, source in ipairs(branch_sources) do
    local row, col, end_row, end_col = source_position(blocks, source)
    if row then
      local key = row .. ":" .. col
      local opts = { end_row = end_row - 1, end_col = end_col, hl_group = "SpiderBranchSource" }
      if not icons[key] then
        opts.virt_text = { { "↳ ", "SpiderSection" } }
        opts.virt_text_pos = "inline"
        icons[key] = true
      end
      api.nvim_buf_set_extmark(buf, branch_marks, row - 1, col, opts)
    end
  end
end

local function render_transcript(session, scroll_end)
  local buf = session.transcript
  local node = session.state and session.state.node
  local prompt = session.pending and session.pending.text
  local lines = { node and label(node.title) or "Spider を起動中…" }
  if node and node.parentId then
    lines[2] = node.sourceMessageId and "↳ 元の回答へ  Shift+Tab" or "↳ 親の会話へ  Shift+Tab"
  end
  lines[#lines + 1] = ""
  local blocks, captions, figures = {}, {}, {}
  local last_message_line = 1
  if node then
    if node.anchorText and vim.trim((node.anchorText:gsub("%s+", " "))) ~= node.title then
      for _, line in ipairs(vim.split(node.anchorText, "\n", { plain = true })) do
        lines[#lines + 1] = "> " .. line
      end
      lines[#lines + 1] = ""
    end
    for _, message in ipairs(node.messages) do
      local first = #lines + 1
      local body = vim.split(message.content, "\n", { plain = true })
      blocks[message.id] = { first = first, lines = body, message = message }
      captions[first] = message.role
      vim.list_extend(lines, body)
      diagrams.scan(body, first, figures)
      last_message_line = #lines
      lines[#lines + 1] = ""
    end
    if prompt then
      captions[#lines + 1] = "user"
      vim.list_extend(lines, vim.split(prompt, "\n", { plain = true }))
      last_message_line = #lines
    elseif #node.messages == 0 then
      lines[#lines + 1] = node.parentId
        and ("この分岐はまだ始まっていません。" .. command_hint .. "i で質問できます。")
        or ("このマップにはまだ発言がありません。" .. command_hint .. "i で質問できます。")
    end
  end
  replace_lines(buf, lines)
  api.nvim_buf_clear_namespace(buf, sources, 0, -1)
  mark_branches(buf, blocks, session.state and session.state.branchSources or {})
  heading(buf, 1)
  if node and node.parentId then
    api.nvim_buf_set_extmark(buf, headings, 1, 0, { line_hl_group = "SpiderMuted" })
  end
  -- Virtual captions keep headings out of the Markdown and source ranges.
  for row, role in pairs(captions) do
    api.nvim_buf_set_extmark(buf, headings, row - 1, 0, {
      virt_lines = { { { "▎ " .. (role_labels[role] or label(role)), role_colors[role] or "SpiderMuted" } } },
      virt_lines_above = true,
    })
  end
  for _, figure in ipairs(figures) do
    api.nvim_buf_set_extmark(buf, headings, figure.first - 1, 0, {
      virt_lines = { { { "◇ " .. figure.label .. "  ·  " .. command_hint .. "d で画像を表示", "SpiderSection" } } },
      virt_lines_above = true,
    })
  end
  session.figures = figures
  session.blocks = blocks
  session.shown_prompt = prompt
  if owns_window(session.transcript_win, buf) then
    api.nvim_win_set_cursor(session.transcript_win, { scroll_end and last_message_line or 1, 0 })
  end
end

local function show_source(session, jump)
  local row, col, end_row, end_col = source_position(session.blocks, jump)
  if not row then return end
  local buf, win = session.transcript, session.transcript_win
  api.nvim_buf_clear_namespace(buf, sources, 0, -1)
  api.nvim_buf_set_extmark(buf, sources, row - 1, col, {
    end_row = end_row - 1,
    end_col = end_col,
    hl_group = "Visual",
  })
  if owns_window(win, buf) then
    if api.nvim_get_current_tabpage() == session.tab then api.nvim_set_current_win(win) end
    api.nvim_win_set_cursor(win, { row, col })
  end
end

local replies = {
  ["goto"] = "state", parent = "state", branch = "state", provider = "state",
  ["copy-history"] = "state",
  maps = "maps", open = "state", new = "state", import = "state", export = "notice",
}

local function ready(session)
  if not live(session) or not session.job then notify("バックエンドが起動していません。")
  elseif not session.state then notify("バックエンドを起動中です。")
  elseif session.pending or session.state.busy then notify("応答を待つか、" .. command_hint .. "x で中止してください。")
  elseif session.waiting then notify("処理が終わるまでお待ちください。")
  else return true end
  return false
end

local function send(session, request)
  if request.op == "cancel" then
    if session.cancelling or not session.job or not (session.pending or (session.state and session.state.busy)) then return false end
  elseif not ready(session) then
    return false
  end
  local ok, bytes = pcall(fn.chansend, session.job, vim.json.encode(request) .. "\n")
  if not ok or bytes == 0 then
    notify("バックエンドに送信できませんでした。", vim.log.levels.ERROR)
    return false
  end
  if request.op == "cancel" then
    session.cancelling = true
  else
    session.waiting = replies[request.op] and request.op or nil
  end
  status(session)
  return true
end

local function show_tree(session)
  if owns_window(session.tree_win, session.tree) then return end
  local width = math.min(34, math.max(14, math.floor(vim.o.columns / 3)))
  local win = api.nvim_open_win(session.tree, false, { split = "left", win = -1, width = width })
  session.tree_win = win
  configure(win, true)
  vim.wo[win].winbar = " 分岐 %=%<" .. help_hint .. " 操作 "
  vim.wo[win].winfixwidth = true
  if session.tree_selected then api.nvim_win_set_cursor(win, { session.tree_selected, 0 }) end
  return win
end

local function toggle_graph(session)
  if owns_window(session.graph_win, session.tree) then
    api.nvim_win_close(session.graph_win, true)
    return
  end
  local width = math.min(104, vim.o.columns - 4)
  local height = math.min(math.max(3, api.nvim_buf_line_count(session.tree)), vim.o.lines - vim.o.cmdheight - 5)
  if width < 16 or height < 3 then
    notify("グラフを表示するには端末を広げてください。")
    return
  end
  local win = api.nvim_open_win(session.tree, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height - 2) / 2),
    col = math.floor((vim.o.columns - width - 2) / 2),
    border = "rounded",
    title = " 会話グラフ · Enter で開く / " .. leader_hint .. " g で戻る ",
    title_pos = "center",
  })
  session.graph_win = win
  configure(win, true)
  if session.tree_selected then api.nvim_win_set_cursor(win, { session.tree_selected, 0 }) end
end

local function bind_panes(session, buf)
  vim.keymap.set("n", leader .. "g", function() toggle_graph(session) end, {
    buffer = buf, desc = "Spider の会話グラフを拡大",
  })
  vim.keymap.set("n", "<C-n>", function()
    if owns_window(session.tree_win, session.tree) then
      local focused = api.nvim_get_current_win() == session.tree_win
      api.nvim_win_close(session.tree_win, true)
      session.tree_hidden = true
      if focused and owns_window(session.transcript_win, session.transcript) then
        api.nvim_set_current_win(session.transcript_win)
      end
    else
      local ok, win = pcall(show_tree, session)
      if ok then
        session.tree_hidden = false
        api.nvim_set_current_win(win)
      else
        notify("分岐ツリーを開けませんでした。", vim.log.levels.ERROR, win)
      end
    end
  end, { buffer = buf, desc = "Spider の分岐ツリーを表示／非表示" })
  for dir, name in pairs({ h = "左", j = "下", k = "上", l = "右" }) do
    vim.keymap.set("n", leader .. dir, "<Cmd>wincmd " .. dir .. "<CR>", {
      buffer = buf, desc = "Spider の" .. name .. "のペインへ",
    })
  end
end

local function close_composer(session)
  local composer = session.composer
  if composer and owns_window(composer.win, composer.buf) then
    api.nvim_win_close(composer.win, true)
  end
end

local function compose(session)
  if not ready(session) then return end
  if session.composer and owns_window(session.composer.win, session.composer.buf) then
    api.nvim_set_current_win(session.composer.win)
    return
  end
  local state = session.state
  local drafts = session.drafts[state.map.id] or {}
  session.drafts[state.map.id] = drafts
  local node = state.node.id
  local lines = drafts[node] or { "" }
  local buf = scratch("compose", true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local base = owns_window(session.transcript_win, session.transcript) and session.transcript_win
    or api.nvim_get_current_win()
  local ok, win = pcall(api.nvim_open_win, buf, true, { split = "below", win = base, height = 8 })
  if not ok then
    api.nvim_buf_delete(buf, { force = true })
    notify("入力欄を開けませんでした。", vim.log.levels.ERROR, win)
    return
  end
  local composer = { buf = buf, win = win, drafts = drafts, node = node }
  session.composer = composer
  configure(win, false)
  vim.wo[win].winbar = " 質問を入力 · Esc → Enter で送信 · " .. command_hint .. "q で下書きを残して閉じる "
  bind_help(session, buf)
  bind_panes(session, buf)
  api.nvim_create_autocmd("BufWinLeave", {
    buffer = buf,
    callback = function()
      if session.composer ~= composer then return end
      local draft = api.nvim_buf_get_lines(buf, 0, -1, false)
      drafts[node] = (#draft > 1 or draft[1] ~= "") and draft or nil
      session.composer = nil
    end,
  })
  vim.keymap.set("n", command_prefix .. "q", function() close_composer(session) end,
    { buffer = buf, desc = "Spider の下書きを残して閉じる" })
  vim.keymap.set("n", "<CR>", function()
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if not text:find("%S") then notify("送信する内容を入力してください。"); return end
    if not send(session, { op = "ask", text = text }) then return end
    composer.text = vim.trim(text)
    session.pending = composer
    close_composer(session)
    render_transcript(session, true)
    status(session)
  end, { buffer = buf, desc = "Spider の入力内容を送信" })
  api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  vim.cmd.startinsert({ bang = true })
end

local function visual_branch(session)
  local kind = fn.mode()
  if kind ~= "v" and kind ~= "V" then
    notify("1 件の応答内で、文字単位または行単位で選択してください。")
    return
  end
  local a, b = fn.getpos("v"), fn.getpos(".")
  local opts = { type = kind, exclusive = vim.o.selection == "exclusive" }
  local region = fn.getregionpos(a, b, vim.tbl_extend("force", opts, { eol = true }))
  local selected = fn.getregion(a, b, opts)
  if #region == 0 then return end
  local first, last = region[1][1][2], region[#region][2][2]
  for id, block in pairs(session.blocks) do
    if block.message.role == "assistant" and first >= block.first and last < block.first + #block.lines then
      local start_byte, end_byte, line_start = nil, nil, 0
      for index, line in ipairs(block.lines) do
        local row = block.first + index - 1
        if row >= first and row <= last then
          local segment = row - first + 1
          local col = region[segment][1][3] - 1
          local text = selected[segment]
          -- getregion returns the whole final UTF-8 character, not just its first byte.
          if col < 0 or col > #line or not text or line:sub(col + 1, col + #text) ~= text then
            notify("行末の外側は含めず、応答の本文を選択してください。")
            return
          end
          start_byte = start_byte or (line_start + col)
          end_byte = line_start + col + #text
        end
        if row == last then break end
        line_start = line_start + #line + 1
      end
      local content = block.message.content
      if start_byte and end_byte > start_byte and content:sub(start_byte + 1, end_byte):find("%S") then
        local source = {
          messageId = id,
          start = vim.str_utfindex(content, "utf-16", start_byte),
          ["end"] = vim.str_utfindex(content, "utf-16", end_byte),
        }
        if send(session, { op = "branch", source = source }) then
          api.nvim_feedkeys(vim.keycode("<Esc>"), "ni", false)
        end
        return
      end
    end
  end
  notify("1 件の応答内で、空白以外の文字を選択してください。")
end

local function visible(session)
  return live(session) and api.nvim_get_current_tabpage() == session.tab
end

local function copy_history(session)
  if not ready(session) then return end
  if fn.mode() ~= "V" then
    notify("V で会話の範囲を行選択してから " .. command_hint .. "h を押してください。")
    return
  end
  local first_row, last_row = fn.line("v"), fn.line(".")
  if first_row > last_row then first_row, last_row = last_row, first_row end
  local node = session.state.node
  local first, last
  for _, message in ipairs(node.messages) do
    local block = session.blocks[message.id]
    if block.first <= last_row and block.first + #block.lines - 1 >= first_row then
      first = first or message.id
      last = message.id
    end
  end
  if not first then
    notify("コピーしたい発言を含む行を選択してください。")
    return
  end
  local children, choices = {}, {}
  for _, id in ipairs(node.children) do children[id] = true end
  for _, entry in ipairs(session.state.tree) do
    if children[entry.id] and entry.empty then choices[#choices + 1] = entry end
  end
  if #choices == 0 then
    notify("コピー先にできる空の子分岐がありません。")
    return
  end
  vim.ui.select(choices, { prompt = "会話履歴のコピー先：", format_item = function(entry) return label(entry.title) end }, function(choice)
    if choice and visible(session) and session.state.node.id == node.id
      and send(session, { op = "copy-history", childId = choice.id, first = first, last = last }) then
      api.nvim_feedkeys(vim.keycode("<Esc>"), "ni", false)
    end
  end)
end

local function receive(session, event)
  local completed = event.type == replies[session.waiting] and session.waiting
  if completed or event.type == "error" then session.waiting = nil end
  if event.type == "state" then
    local old = session.state
    local same_node = old and old.map.id == event.map.id and old.node.id == event.node.id
    if not same_node then close_composer(session) end
    session.state = event
    if not event.busy then session.pending = nil end
    if not same_node or old.map.title ~= event.map.title or not vim.deep_equal(old.tree, event.tree) then render_tree(session) end
    if not same_node or not vim.deep_equal(old.node, event.node) or not vim.deep_equal(old.branchSources, event.branchSources)
      or session.shown_prompt ~= (session.pending and session.pending.text) then
      render_transcript(session, same_node)
    end
    if event.jump then show_source(session, event.jump) end
    local queued = session.startup_request
    if queued then
      session.startup_request = nil
      send(session, queued)
    elseif completed == "branch" and visible(session) and old and event.node.parentId == old.node.id then
      if owns_window(session.graph_win, session.tree) then api.nvim_win_close(session.graph_win, true) end
      compose(session)
    end
  elseif event.type == "submitted" then
    local draft = session.pending
    if draft then draft.drafts[draft.node] = nil end
    session.pending = nil
  elseif event.type == "error" then
    session.pending = nil
    if session.shown_prompt then render_transcript(session, true) end
    notify(event.message, vim.log.levels.ERROR)
  elseif event.type == "notice" then
    notify(event.message)
  elseif event.type == "maps" and visible(session) then
    vim.ui.select(event.maps, { prompt = "Spider マップを選択：", format_item = function(item) return label(item.title) end }, function(item)
      if item and visible(session) then send(session, { op = "open", id = item.id }) end
    end)
  end
  status(session)
end

local function start(session, cwd)
  local tail, stderr = "", ""
  local ok, job = pcall(fn.jobstart, { "node", backend }, {
    cwd = cwd,
    stdin = "pipe",
    on_stdout = function(channel, data)
      if not data then return end
      data[1] = tail .. data[1]
      tail = data[#data]
      for index = 1, #data - 1 do
        local line = data[index]
        vim.schedule(function()
          if not live(session) or session.job ~= channel then return end
          local ok, event = pcall(vim.json.decode, line)
          if ok and type(event) == "table" then
            receive(session, event)
          else
            notify("バックエンドから不正な JSON を受信しました。", vim.log.levels.ERROR)
          end
        end)
      end
    end,
    on_stderr = function(_, data)
      if data then stderr = (stderr .. table.concat(data, "\n")):sub(-2048) end
    end,
    on_exit = function(exited, code)
      vim.schedule(function()
        if not live(session) or session.job ~= exited then return end
        session.job, session.pending, session.waiting = nil, nil, nil
        if session.shown_prompt then render_transcript(session, true) end
        status(session)
        notify(("バックエンドが終了しました（終了コード %d）。Spider を開き直してください。"):format(code),
          vim.log.levels.ERROR, vim.trim(stderr))
      end)
    end,
  })
  if ok and job > 0 then
    session.job = job
  else
    notify("Node.js を起動できませんでした。", vim.log.levels.ERROR, not ok and job)
  end
  status(session)
end

local function bind(session, buf)
  bind_help(session, buf)
  bind_panes(session, buf)
  local function key(lhs, action, desc)
    vim.keymap.set("n", lhs, action, { buffer = buf, desc = desc })
  end
  local function parent()
    if session.state and session.state.node.parentId then send(session, { op = "parent" }) end
  end
  local function input(prompt, completion, request, default)
    if not ready(session) then return end
    vim.ui.input({ prompt = prompt, completion = completion, default = default }, function(value)
      if value and visible(session) then send(session, request(value)) end
    end)
  end
  key("<Tab>", function() send(session, { op = "branch" }) end, "Spider に空の分岐を作成")
  key("<S-Tab>", parent, "Spider の親分岐に移動")
  key(command_prefix .. "l", function()
    local child = session.state and session.state.node.children[1]
    if child then send(session, { op = "goto", id = child }) end
  end, "Spider の最初の子分岐に移動")
  key(command_prefix .. "i", function() compose(session) end, "Spider へのメッセージを入力")
  key(command_prefix .. "p", function()
    if not visible(session) or not ready(session) then return end
    vim.ui.select(providers, {
      prompt = "AI の接続先を選択：",
      format_item = function(provider) return provider_labels[provider] end,
    }, function(provider)
      if provider and visible(session) then send(session, { op = "provider", provider = provider }) end
    end)
  end, "Spider の AI 接続先を選択")
  key(command_prefix .. "m", function() send(session, { op = "maps" }) end, "Spider マップを選択")
  key(command_prefix .. "n", function()
    input("新しい Spider マップの名前：", nil, function(title) return { op = "new", title = title } end)
  end, "Spider マップを作成")
  key(command_prefix .. "I", function()
    input("取り込む会話ファイル：", "file", function(path)
      return { op = "import", path = fn.fnamemodify(path, ":p") }
    end)
  end, "会話を Spider に取り込み")
  key(command_prefix .. "e", function()
    local workspace = session.state and session.state.workspace
    input("マップの書き出し先：", "file", function(path)
      return { op = "export", path = path }
    end, workspace and workspace .. "/")
  end, "Spider マップを書き出し")
  key(command_prefix .. "d", function()
    local state = session.state
    if not state then return end
    local function still_here()
      return visible(session) and session.state.map.id == state.map.id and session.state.node.id == state.node.id
    end
    if buf == session.tree then
      diagrams.graph(state, notify, still_here)
    else
      diagrams.choose(session.figures, api.nvim_win_get_cursor(0)[1], notify, still_here)
    end
  end, "Spider の図を画像で表示")
  key(command_prefix .. "r", function()
    if not vim.g.loaded_render_markdown then
      notify("Markdown の装飾には render-markdown.nvim が必要です。")
      return
    end
    api.nvim_buf_call(session.transcript, require("render-markdown").buf_toggle)
  end, "Spider の Markdown 表示を切替")
  key(command_prefix .. "x", function() send(session, { op = "cancel" }) end, "Spider へのリクエストを中止")
  key(command_prefix .. "q", function()
    if not live(session) then return end
    if api.nvim_get_current_win() == session.graph_win then
      api.nvim_win_close(session.graph_win, true)
      return
    end
    local ok, err
    if vim.env.SPIDER_STANDALONE == "1" then
      ok, err = pcall(vim.cmd.qall)
    else
      if #api.nvim_list_tabpages() == 1 then vim.cmd.tabnew() end
      ok, err = pcall(vim.cmd, api.nvim_tabpage_get_number(session.tab) .. "tabclose")
    end
    if not ok then notify("Spider を閉じられませんでした。", vim.log.levels.ERROR, err) end
  end, "Spider を閉じる")
  if buf == session.tree then
    key("<CR>", function()
      local id = session.tree_ids[api.nvim_win_get_cursor(0)[1]]
      if not id or not send(session, { op = "goto", id = id }) then return end
      if api.nvim_get_current_win() == session.graph_win then api.nvim_win_close(session.graph_win, true) end
      if owns_window(session.transcript_win, session.transcript) then api.nvim_set_current_win(session.transcript_win) end
    end, "Spider の分岐に移動")
  else
    vim.keymap.set("x", "<Tab>", function() visual_branch(session) end, { buffer = buf, desc = "Spider の応答を引用して分岐" })
    vim.keymap.set("x", command_prefix .. "h", function() copy_history(session) end,
      { buffer = buf, desc = "選択した会話を空の子分岐にコピー" })
  end
end

local function ensure_panes(session)
  if not owns_window(session.transcript_win, session.transcript) then
    local win = api.nvim_open_win(session.transcript, true, { split = "right" })
    session.transcript_win = win
    configure_transcript(win)
  end
  if not session.tree_hidden then show_tree(session) end
  status(session)
end

local function stop(session)
  local job = session.job
  session.job = nil
  status(session)
  if job then pcall(fn.jobstop, job) end
end

function M.open()
  if fn.has("nvim-0.11") ~= 1 then
    notify("Neovim 0.11 以降が必要です。", vim.log.levels.ERROR)
    return
  end
  if active and live(active) then
    if api.nvim_get_current_tabpage() ~= active.tab then api.nvim_set_current_tabpage(active.tab) end
    local ok, err = pcall(ensure_panes, active)
    if not ok then notify("Spider のペインを開けませんでした。", vim.log.levels.ERROR, err) end
    return active
  end
  if fn.filereadable(backend) ~= 1 or fn.executable("node") ~= 1 then
    notify("Node.js とビルド済みの dist/spider-tui.cjs が必要です。", vim.log.levels.ERROR)
    return
  end
  local cwd = fn.getcwd()
  local session = { transcript = scratch("transcript", false), tree = scratch("tree", false), drafts = {} }
  local opened, err = pcall(vim.cmd, "tab sbuffer " .. session.transcript)
  if not opened then
    api.nvim_buf_delete(session.transcript, { force = true })
    api.nvim_buf_delete(session.tree, { force = true })
    notify("Spider のタブを開けませんでした。", vim.log.levels.ERROR, err)
    return
  end
  session.tab = api.nvim_get_current_tabpage()
  session.transcript_win = api.nvim_get_current_win()
  active = session
  define_colors()
  configure_transcript(session.transcript_win)
  load_standalone_markdown()
  vim.bo[session.transcript].filetype = "markdown"
  pcall(vim.treesitter.start, session.transcript, "markdown")
  render_tree(session)
  render_transcript(session)
  bind(session, session.tree)
  bind(session, session.transcript)
  local group = api.nvim_create_augroup("SpiderTab" .. session.tab, { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_colors })
  api.nvim_create_autocmd("TabClosed", { group = group, callback = function()
    if api.nvim_tabpage_is_valid(session.tab) then return end
    if active == session then active = nil end
    stop(session)
    api.nvim_del_augroup_by_id(group)
    for _, buf in ipairs({ session.transcript, session.tree }) do
      if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
    end
  end })
  api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() stop(session) end })
  local panes_ok, panes_error = pcall(ensure_panes, session)
  if not panes_ok then notify("Spider のペインを開けませんでした。", vim.log.levels.ERROR, panes_error) end
  start(session, cwd)
  return session
end

local function open_with_request(request)
  local session = M.open()
  if not session then return end
  if session.job and not session.state and not session.startup_request then
    session.startup_request = request
  else
    send(session, request)
  end
end

function M.import(path)
  open_with_request({ op = "import", path = fn.fnamemodify(path, ":p") })
end

function M.branch(first, last)
  local buf = api.nvim_get_current_buf()
  if active and (buf == active.tree or buf == active.transcript or (active.composer and buf == active.composer.buf)) then
    notify("応答を引用して分岐するには、Spider で選択して Tab を押してください。")
    return
  end
  local anchor = table.concat(api.nvim_buf_get_lines(buf, first - 1, last, true), "\n")
  if not anchor:find("%S") then notify("引用するには、空白以外の文字を含む行を選択してください。"); return end
  open_with_request({ op = "branch", anchor = anchor })
end

return M
