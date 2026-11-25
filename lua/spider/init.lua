local M = {}
local api = vim.api
local fn = vim.fn
local headings = api.nvim_create_namespace("spider.headings")
local sources = api.nvim_create_namespace("spider.sources")
local module_path = debug.getinfo(1, "S").source:sub(2)
local backend = vim.fn.fnamemodify((vim.uv and vim.uv.fs_realpath(module_path)) or module_path, ":p:h:h:h")
  .. "/dist/spider-tui.cjs"
local providers = { "codex", "claude", "omp" }
local provider_labels = { codex = "Codex", claude = "Claude", omp = "omp" }
local role_labels = { system = "システム", user = "ユーザー", assistant = "アシスタント" }
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

local function status(session)
  if not owns_window(session.transcript_win, session.transcript) then return end
  local state = session.state
  local provider = state and provider_labels[state.provider]
  local activity = not session.job and "停止中"
    or not state and "起動中"
    or (session.pending or state.busy) and "応答待ち"
    or session.waiting and "処理中"
    or "待機中"
  vim.wo[session.transcript_win].winbar = " Spider · " .. (provider and provider .. " · " or "") .. activity
    .. " %=%<i 入力  Tab 分岐  S-Tab/h/← 親へ  → 子へ "
end

local function render_tree(session)
  local state = session.state
  local lines = {
    state and label(state.map.title) or "Spider",
    "Enter 分岐を開く",
    "C-w w 画面を切替",
    "m 一覧 / n 新規",
    "I 取り込み",
    "e 書き出し",
    "p 接続先",
    "x 中止 / q 終了",
    "",
  }
  local ids, selected = {}, nil
  if state then
    for _, entry in ipairs(state.tree) do
      local current = entry.id == state.node.id
      lines[#lines + 1] = string.rep("  ", math.min(entry.depth, 12))
        .. (current and "› " or "  ") .. label(entry.title)
      ids[#lines] = entry.id
      if current then selected = #lines end
    end
  end
  replace_lines(session.tree, lines)
  heading(session.tree, 1)
  session.tree_ids = ids
  session.tree_selected = selected
  if selected then
    heading(session.tree, selected)
    if owns_window(session.tree_win, session.tree) then
      api.nvim_win_set_cursor(session.tree_win, { selected, 0 })
    end
  end
end

local function render_transcript(session, scroll_end)
  local buf = session.transcript
  local node = session.state and session.state.node
  local lines = { node and label(node.title) or "Spider を起動中…", "" }
  local titles, blocks = { 1 }, {}
  local last_message_line = 1
  if node then
    if node.anchorText then
      titles[#titles + 1] = #lines + 1
      lines[#lines + 1] = "引用"
      vim.list_extend(lines, vim.split(node.anchorText, "\n", { plain = true }))
      lines[#lines + 1] = ""
    end
    for _, message in ipairs(node.messages) do
      titles[#titles + 1] = #lines + 1
      lines[#lines + 1] = role_labels[message.role] or label(message.role)
      local body = vim.split(message.content, "\n", { plain = true })
      blocks[message.id] = { first = #lines + 1, lines = body, message = message }
      vim.list_extend(lines, body)
      last_message_line = #lines
      lines[#lines + 1] = ""
    end
    if #node.messages == 0 then lines[#lines + 1] = "まだ会話がありません。i で入力できます。" end
  end
  replace_lines(buf, lines)
  api.nvim_buf_clear_namespace(buf, sources, 0, -1)
  for _, row in ipairs(titles) do heading(buf, row) end
  session.blocks = blocks
  if owns_window(session.transcript_win, buf) then
    api.nvim_win_set_cursor(session.transcript_win, { scroll_end and last_message_line or 1, 0 })
  end
end

local function byte_position(block, byte)
  for index, line in ipairs(block.lines) do
    if byte <= #line then return block.first + index - 1, byte end
    byte = byte - #line - 1
  end
end

local function show_source(session, jump)
  local block = session.blocks[jump.messageId]
  if not block then return end
  local content = block.message.content
  local row, col = byte_position(block, vim.str_byteindex(content, "utf-16", jump.start, false))
  local end_row, end_col = byte_position(block, vim.str_byteindex(content, "utf-16", jump["end"], false))
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
  maps = "maps", open = "state", new = "state", import = "state", export = "notice",
}

local function ready(session)
  if not live(session) or not session.job then notify("バックエンドが起動していません。")
  elseif not session.state then notify("バックエンドを起動中です。")
  elseif session.pending or session.state.busy then notify("応答を待つか、x で中止してください。")
  elseif session.waiting then notify("処理が終わるまでお待ちください。")
  else return true end
  return false
end

local function send(session, request)
  if request.op == "cancel" then
    if not session.job or not (session.pending or (session.state and session.state.busy)) then return false end
  elseif not ready(session) then
    return false
  end
  local ok, bytes = pcall(fn.chansend, session.job, vim.json.encode(request) .. "\n")
  if not ok or bytes == 0 then
    notify("バックエンドに送信できませんでした。", vim.log.levels.ERROR)
    return false
  end
  if request.op ~= "cancel" then
    session.waiting = replies[request.op]
    status(session)
  end
  return true
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
  vim.wo[win].winbar = " Spider 入力 · Esc → Enter で送信 · q で下書き保存 "
  api.nvim_create_autocmd("BufWinLeave", {
    buffer = buf,
    callback = function()
      if session.composer ~= composer then return end
      local draft = api.nvim_buf_get_lines(buf, 0, -1, false)
      drafts[node] = (#draft > 1 or draft[1] ~= "") and draft or nil
      session.composer = nil
    end,
  })
  vim.keymap.set("n", "q", function() close_composer(session) end, { buffer = buf, desc = "Spider の下書きを残して閉じる" })
  vim.keymap.set("n", "<CR>", function()
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if not text:find("%S") then notify("送信する内容を入力してください。"); return end
    if not send(session, { op = "ask", text = text }) then return end
    session.pending = composer
    close_composer(session)
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

local function receive(session, event)
  if event.type == session.waiting or event.type == "error" then session.waiting = nil end
  if event.type == "state" then
    local old = session.state
    local same_node = old and old.map.id == event.map.id and old.node.id == event.node.id
    if not same_node then close_composer(session) end
    session.state = event
    if not event.busy then session.pending = nil end
    if not same_node or old.map.title ~= event.map.title or not vim.deep_equal(old.tree, event.tree) then render_tree(session) end
    if not same_node or not vim.deep_equal(old.node, event.node) then render_transcript(session, same_node) end
    if event.jump then show_source(session, event.jump) end
    local queued = session.startup_request
    if queued then
      session.startup_request = nil
      send(session, queued)
    end
  elseif event.type == "submitted" then
    local draft = session.pending
    if draft then draft.drafts[draft.node] = nil end
    session.pending = nil
  elseif event.type == "error" then
    session.pending = nil
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
  key("<Left>", parent, "Spider の親分岐に移動")
  key("h", parent, "Spider の親分岐に移動")
  key("<Right>", function()
    local child = session.state and session.state.node.children[1]
    if child then send(session, { op = "goto", id = child }) end
  end, "Spider の最初の子分岐に移動")
  key("i", function() compose(session) end, "Spider へのメッセージを入力")
  key("p", function()
    if not visible(session) or not ready(session) then return end
    vim.ui.select(providers, {
      prompt = "AI の接続先を選択：",
      format_item = function(provider) return provider_labels[provider] end,
    }, function(provider)
      if provider and visible(session) then send(session, { op = "provider", provider = provider }) end
    end)
  end, "Spider の AI 接続先を選択")
  key("m", function() send(session, { op = "maps" }) end, "Spider マップを選択")
  key("n", function()
    input("新しい Spider マップの名前：", nil, function(title) return { op = "new", title = title } end)
  end, "Spider マップを作成")
  key("I", function()
    input("取り込む会話ファイル：", "file", function(path)
      return { op = "import", path = fn.fnamemodify(path, ":p") }
    end)
  end, "会話を Spider に取り込み")
  key("e", function()
    local workspace = session.state and session.state.workspace
    input("マップの書き出し先：", "file", function(path)
      return { op = "export", path = path }
    end, workspace and workspace .. "/")
  end, "Spider マップを書き出し")
  key("x", function() send(session, { op = "cancel" }) end, "Spider へのリクエストを中止")
  key("q", function()
    if not live(session) then return end
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
      if id then send(session, { op = "goto", id = id }) end
    end, "Spider の分岐に移動")
  else
    vim.keymap.set("x", "<Tab>", function() visual_branch(session) end, { buffer = buf, desc = "Spider の応答を引用して分岐" })
  end
end

local function ensure_panes(session)
  if not owns_window(session.transcript_win, session.transcript) then
    local win = api.nvim_open_win(session.transcript, true, { split = "right" })
    session.transcript_win = win
    configure(win, false)
  end
  if not owns_window(session.tree_win, session.tree) then
    local width = math.min(34, math.max(14, math.floor(vim.o.columns / 3)))
    local win = api.nvim_open_win(session.tree, false, { split = "left", win = session.transcript_win, width = width })
    session.tree_win = win
    configure(win, true)
    vim.wo[win].winfixwidth = true
    if session.tree_selected then api.nvim_win_set_cursor(win, { session.tree_selected, 0 }) end
  end
  status(session)
end

local function stop(session)
  if not session.job then return end
  local job = session.job
  session.job = nil
  pcall(fn.jobstop, job)
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
  configure(session.transcript_win, false)
  render_tree(session)
  render_transcript(session)
  bind(session, session.tree)
  bind(session, session.transcript)
  local group = api.nvim_create_augroup("SpiderTab" .. session.tab, { clear = true })
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
