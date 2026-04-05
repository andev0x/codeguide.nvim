local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  return {
    exports = {},
  }
end

local extension = telescope.register_extension({
  setup = function()
  end,
  exports = {
    important = function()
      require("codeguide.telescope").pick("important")
    end,
    entry = function()
      require("codeguide.telescope").pick("entry")
    end,
  },
})

return extension
