require('lualine').setup {
  options = {
    theme = 'nord',
    component_separators = '|',
    section_separators = '',
  },
  tabline = {
    lualine_a = { 'buffers' },
    lualine_z = { 'tabs' },
  },
}
