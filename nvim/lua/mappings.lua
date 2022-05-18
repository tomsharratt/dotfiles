function map(mode, shortcut, command)
  vim.api.nvim_set_keymap(mode, shortcut, command, { noremap = true, silent = true})
end

function nmap(shortcut, command)
  map('n', shortcut, command)
end

function imap(shortcut, command)
  map('i', shortcut, command)
end

-- Switch between the last two files
nmap('<leader><leader>', '<c-^>')

-- Ctrl+P Fuzzy Finder
nmap('<c-p>', ':GFiles<cr>')
nmap('ff', ':Ag<cr>')

-- Quicker window movement
nmap('<c-j>', '<c-w>j')
nmap('<c-k>', '<c-w>k')
nmap('<c-h>', '<c-w>h')
nmap('<c-l>', '<c-w>l')

-- Test runners
nmap('<leader>t', ':TestNearest<cr>')
nmap('<leader>T', ':TestFile<cr>')
nmap('<leader>a', ':TestSuite<cr>')
nmap('<leader>l', ':TestLast<cr>')
nmap('<leader>g', ':TestVisit<cr>')
