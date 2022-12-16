local function map(mode, shortcut, command)
  vim.api.nvim_set_keymap(mode, shortcut, command, { noremap = true, silent = true})
end

local function nmap(shortcut, command)
  map('n', shortcut, command)
end

local function imap(shortcut, command)
  map('i', shortcut, command)
end

local function vmap(shortcut, command)
  map('v', shortcut, command)
end

-- Switch between the last two files
nmap('<leader><leader>', '<c-^>')

-- Ctrl+P Fuzzy Finder
nmap('<c-p>', ':Telescope find_files<cr>')
nmap('ff', ':Telescope live_grep<cr>')

-- Exploror
nmap('<leader>e', ':NvimTreeToggle<cr>')

-- Quicker window movement
nmap('<c-j>', '<c-w>j')
nmap('<c-k>', '<c-w>k')
nmap('<c-h>', '<c-w>h')
nmap('<c-l>', '<c-w>l')

-- Resize windows with arrows
nmap('<c-up>', ':resize +2<cr>')
nmap('<c-down>', ':resize -2<cr>')
nmap('<c-left>', ':vertical resize -2<cr>')
nmap('<c-right>', ':vertical resize +2<cr>')

-- Buffers
nmap('<s-l>', ':bnext<cr>')
nmap('<s-h>', ':bprevious<cr>')
nmap('<c-q>', ':bd<cr>')

-- Test runners
nmap('<leader>t', ':TestNearest<cr>')
nmap('<leader>T', ':TestFile<cr>')
nmap('<leader>a', ':TestSuite<cr>')
nmap('<leader>l', ':TestLast<cr>')
nmap('<leader>g', ':TestVisit<cr>')
