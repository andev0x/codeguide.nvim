if vim.g.loaded_codeguide == 1 then
  return
end

vim.g.loaded_codeguide = 1

require("codeguide").setup()
