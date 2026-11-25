if vim.g.loaded_spider_tui then return end
vim.g.loaded_spider_tui = true

vim.api.nvim_create_user_command("Spider", function()
  require("spider").open()
end, { desc = "Open Spider chat map" })

vim.api.nvim_create_user_command("SpiderBranch", function(opts)
  require("spider").branch(opts.line1, opts.line2)
end, { range = true, desc = "Quote selected editor lines in a new Spider branch" })
