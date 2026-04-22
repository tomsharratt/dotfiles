return {
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    lazy = false,
    build = ':TSUpdate',
    config = function()
        local parsers = {
            'javascript', 'typescript', 'tsx',
            'ruby', 'embedded_template',
            'go', 'lua', 'vim', 'vimdoc', 'query',
            'markdown', 'markdown_inline',
            'json', 'yaml', 'toml',
            'html', 'css', 'bash',
        }

        require('nvim-treesitter').install(parsers)

        vim.api.nvim_create_autocmd('FileType', {
            pattern = {
                'javascript', 'javascriptreact',
                'typescript', 'typescriptreact',
                'ruby', 'eruby',
                'go', 'lua', 'vim', 'help', 'query',
                'markdown',
                'json', 'yaml', 'toml',
                'html', 'css', 'bash', 'sh',
            },
            callback = function()
                vim.treesitter.start()
                vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
            end,
        })
    end,
}
