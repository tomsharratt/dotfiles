local wezterm = require("wezterm")

local config = wezterm.config_builder()

config.font = wezterm.font("Hack Nerd Font")
config.font_size = 14.0

config.window_padding = {
  left = 4,
  right = 4,
  top = 4,
  bottom = 4,
}
config.window_background_opacity = 0.8
config.macos_window_background_blur = 20

config.hide_tab_bar_if_only_one_tab = true

-- Nightfox / duskfox palette
config.colors = {
  foreground = "#e0def4",
  background = "#232136",

  cursor_bg = "#ff69b4",
  cursor_border = "#ff69b4",
  cursor_fg = "#232136",

  ansi = {
    "#393552", -- black
    "#eb6f92", -- red
    "#a3be8c", -- green
    "#f6c177", -- yellow
    "#569fba", -- blue
    "#c4a7e7", -- magenta
    "#9ccfd8", -- cyan
    "#e0def4", -- white
  },
  brights = {
    "#47407d",
    "#f083a2",
    "#b1d196",
    "#f9cb8c",
    "#65b1cd",
    "#ccb1ed",
    "#a6dae3",
    "#e2e0f7",
  },
}

return config
