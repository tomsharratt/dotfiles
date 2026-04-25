return {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    opts = {
        terminal_cmd = "claude --allow-dangerously-skip-permissions",
        terminal = {
            split_width_percentage = 0.33,
        },
        diff_opts = {
            layout = "vertical",
            open_in_new_tab = true,
        },
    },
    keys = {
        { "<leader>c",  nil,                              desc = "AI/Claude Code" },
        { "<leader>cc", "<cmd>ClaudeCode<cr>",            desc = "Toggle Claude" },
        { "<leader>cf", "<cmd>ClaudeCodeFocus<cr>",       desc = "Focus Claude" },
        { "<leader>cr", "<cmd>ClaudeCode --resume<cr>",   desc = "Resume Claude" },
        { "<leader>cC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
        { "<leader>cb", "<cmd>ClaudeCodeAdd %<cr>",       desc = "Add current buffer" },
        { "<leader>cs", "<cmd>ClaudeCodeSend<cr>",        mode = "v", desc = "Send selection" },
        { "<leader>ca", "<cmd>ClaudeCodeDiffAccept<cr>",  desc = "Accept diff" },
        { "<leader>cd", "<cmd>ClaudeCodeDiffDeny<cr>",    desc = "Deny diff" },
    },
    init = function()
        vim.api.nvim_create_autocmd("TermOpen", {
            callback = function(ev)
                local name = vim.api.nvim_buf_get_name(ev.buf)
                if name:match("claude") then
                    vim.keymap.set("t", "<esc>", "<esc>", { buffer = ev.buf })
                end
            end,
        })
    end,
}
