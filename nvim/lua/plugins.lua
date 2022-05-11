return require('packer').startup(function()
  use 'wbthomason/packer.nvim'

  -- FZF
  use '/opt/homebrew/opt/fzf'
  use 'junegunn/fzf.vim'

  -- Themes
  use 'arcticicestudio/nord-vim'

  -- Status line
  use {
    'nvim-lualine/lualine.nvim',
    requires = { 'kyazdani42/nvim-web-devicons', opt = true }
  }

  -- LSP
  use 'neovim/nvim-lspconfig'
  use 'hrsh7th/cmp-nvim-lsp'
  use 'hrsh7th/cmp-buffer'
  use 'hrsh7th/cmp-path'
  use 'hrsh7th/cmp-cmdline'
  use 'hrsh7th/nvim-cmp'

  -- Tests
  use 'vim-test/vim-test'

  -- Ruby
  use 'tpope/vim-endwise'
end)
