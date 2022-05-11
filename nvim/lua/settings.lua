HOME = os.getenv("HOME")

-- basic
vim.opt.encoding = 'utf-8'
vim.opt.backspace = 'indent,eol,start'
vim.opt.completeopt = 'menu,menuone,noselect'

-- display
vim.opt.showmatch = true
vim.opt.scrolloff = 3
vim.opt.synmaxcol = 300
vim.opt.laststatus = 3

vim.opt.list = true
vim.opt.foldenable = false
vim.opt.foldlevel = 4
vim.opt.foldmethod = 'syntax'
vim.opt.wrap = false
vim.opt.eol = false
vim.opt.showbreak = '↪'

-- Sidebar
vim.opt.number = true
vim.opt.numberwidth = 5
vim.opt.signcolumn = 'yes'
vim.opt.modelines = 0
vim.opt.showmode = false
vim.opt.showcmd = true

-- Ruler
vim.opt.textwidth = 120
vim.opt.colorcolumn = '+1'

-- Search
vim.opt.incsearch = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.matchtime = 2

-- White characters
vim.opt.autoindent = true
vim.opt.smartindent = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.formatoptions = 'qnj1'
vim.opt.expandtab = true

-- Backup files
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.swapfile = false

-- Split panes
vim.opt.splitbelow = true
vim.opt.splitright = true

-- Theme
vim.cmd([[ colorscheme nord ]])
