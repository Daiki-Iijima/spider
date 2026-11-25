if vim.g.loaded_spider_tui then return end
vim.g.loaded_spider_tui = true

vim.api.nvim_create_user_command("Spider", function()
  require("spider").open()
end, { desc = "Spider の会話マップを開く" })

vim.api.nvim_create_user_command("SpiderBranch", function(opts)
  require("spider").branch(opts.line1, opts.line2)
end, { range = true, desc = "選択行を引用して Spider に分岐を作成" })

vim.api.nvim_create_user_command("SpiderImport", function(opts)
  require("spider").import(opts.fargs[1])
end, { nargs = 1, complete = "file", desc = "Spider の会話 JSON を新しいマップに取り込み" })
