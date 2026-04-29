return {
    'nvim-telescope/telescope.nvim',
    tag = 'v0.2.2',
    dependencies = { 'nvim-lua/plenary.nvim' },
    config = function()
        local builtin = require('telescope.builtin')

        vim.keymap.set('n', '<leader>pf', builtin.find_files, {})
        vim.keymap.set('n', '<C-p>', builtin.git_files, {})
        vim.keymap.set('n', '<leader>ps', function()
            builtin.grep_string({ search = vim.fn.expand("<cword>") })
        end)
        vim.keymap.set('v', '<leader>ps', function()
            vim.cmd('noau normal! "vy"')
            builtin.grep_string({ search = vim.fn.getreg('v') })
        end)
        vim.keymap.set('n', '<leader>pg', builtin.live_grep, {})
    end,
}
