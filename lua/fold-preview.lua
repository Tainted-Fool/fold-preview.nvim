local ffi = require("ffi")
local api = vim.api
local fn = vim.fn
local augroup_id = api.nvim_create_augroup('fold_preview', { clear = true })
local M = {}

ffi.cdef('int curwin_col_off(void);')

---Raise a warning message
---@param msg string
local function warn(msg)
   vim.schedule(function()
      vim.notify_once('[pretty-fold.nvim] '..msg, vim.log.levels.WARN)
   end)
end

---@class fold-preview.Config
---@field border string | string[]
---@field default_keybindings boolean
---@field border_shift integer[]

---@type fold-preview.Config
M.config = {
   default_keybindings = true,
   border = { ' ', '', ' ', ' ', ' ', ' ', ' ', ' ' },
}

---@param config? table
function M.setup(config)
   if fn.has('nvim-0.7') ~= 1 then
      warn('Neovim v0.7 or higher is required')
      return
   end

   M.config = vim.tbl_deep_extend('force', M.config, config or {}) --[[@as fold-preview.Config]]
   config = M.config

   ---Shifts due to each of the 4 parts of the border: {up, right, down, left}.
   config.border_shift = {}
   if type(config.border) == 'string' then
      if config.border == 'none' then
         config.border_shift = { 0, 0, 0, 0 }
      elseif vim.tbl_contains({ 'single', 'double', 'rounded', 'solid' }, config.border)
      then
         config.border_shift = { -1, -1, -1, -1 }
      elseif config.border == 'shadow' then
         config.border_shift = { 0, -1, -1, 0 }
      end
   elseif type(config.border) == 'table' then
      for i = 1, 4 do
         M.config.border_shift[i] = config.border[i*2] == '' and 0 or -1
      end
   else
      assert(false, 'Invalid border type or value')
   end

   M.fold_preview_cocked = true
   if M.config.default_keybindings then
      local ok, keymap_amend = pcall(require, 'keymap-amend')
      if not ok then
        warn('The "anuvyklack/keymap-amend.nvim" plugin is required for preview key mappings to work')
        return
      end
      keymap_amend('n', 'h',  M.mapping.show_close_preview_open_fold)
      keymap_amend('n', 'l',  M.mapping.close_preview_open_fold)
      keymap_amend('n', 'zo', M.mapping.close_preview)
      keymap_amend('n', 'zO', M.mapping.close_preview)
      keymap_amend('n', 'zc', M.mapping.close_preview_without_defer)
      keymap_amend('n', 'zR', M.mapping.close_preview)
      keymap_amend('n', 'zM', M.mapping.close_preview_without_defer)
   end
end

---Open popup window with folded text preview. Also set autocommands to close
---popup window and change its size on scrolling and vim resizing.
function M.show_preview()
   local config = M.config

   ---Current buffer ID
   ---@type number
   local curbufnr = api.nvim_get_current_buf()

   ---Current window ID, i.e window from which preview was opened.
   ---@type number
   local curwin = api.nvim_get_current_win()

   -- Some plugins (for example 'beauwilliams/focus.nvim') change this option,
   -- but we need it to make scrolling work correctly.
   local winminheight = vim.o.winminheight
   vim.o.winminheight = 1

   local fold_start = fn.foldclosed('.') -- '.' is the current line
   if fold_start == -1 then return end
   local fold_end = fn.foldclosedend('.')

   ---@cast fold_start integer
   ---@cast fold_end integer

   ---The number of folded lines.
   local fold_size = fold_end - fold_start + 1

   ---The number of window rows from the current cursor line to the end of the
   ---window. I.e. room below for float window.
   local room_below = api.nvim_win_get_height(0) - fn.winline() + 1 --[[@as integer]]

   ---The maximum line length of the folded region.
   local max_line_len = 0

   --- @type string[]
   local folded_lines = api.nvim_buf_get_lines(0, fold_start - 1, fold_end, true)
   local indent = #(folded_lines[1]:match('^%s+') or '')
   for i, line in ipairs(folded_lines) do
      if indent > 0 then
         line = line:sub(indent + 1)
      end
      folded_lines[i] = line
      local line_len = fn.strdisplaywidth(line)  --[[@as integer]]
      if line_len > max_line_len then max_line_len = line_len end
   end

   local bufnr = api.nvim_create_buf(false, true)
   api.nvim_buf_set_lines(bufnr, 0, 1, false, folded_lines)
   vim.bo[bufnr].filetype = vim.bo.filetype
   vim.bo[bufnr].modifiable = false

   ---The width of offset of a window, occupied by line number column,
   ---fold column and sign column.
   ---@type integer
   local gutter_width = ffi.C.curwin_col_off()

   ---The number of columns from the left boundary of the preview window to the
   ---right boundary of the current window.
   local room_right = api.nvim_win_get_width(0) - gutter_width - indent

   ---@type integer
   local winid = api.nvim_open_win(bufnr, false, {
      border = config.border,
      relative = 'win',
      bufpos = {
         fold_start - 1, -- zero-indexed, that's why minus one
         indent,
      },
      -- The position of the window relative to 'bufpos' field.
      row = config.border_shift[1],
      col = config.border_shift[4],

      width = max_line_len + 2 < room_right and max_line_len + 1 or room_right - 1,
      height = fold_size < room_below and fold_size or room_below,
      style = 'minimal',
      focusable = false,
      noautocmd = true
   })
   vim.wo[winid].foldenable = false
   vim.wo[winid].signcolumn = 'no'
   vim.wo[winid].conceallevel = vim.wo[curwin].conceallevel

   function M.close_preview()
      if api.nvim_win_is_valid(winid) then
         api.nvim_win_close(winid, false)
      end
      api.nvim_buf_delete(bufnr, { force = true, unload = false })
      vim.o.winminheight = winminheight
      vim.api.nvim_clear_autocmds({ group = augroup_id })
      M.close_preview = nil
      M.fold_preview_cocked = true
   end

   -- close
   api.nvim_create_autocmd({ 'CursorMoved', 'ModeChanged', 'BufLeave' }, {
      group = augroup_id,
      once = true,
      buffer = curbufnr,
      callback = M.close_preview
   })

   -- window scrolled
   api.nvim_create_autocmd('WinScrolled', {
      group = augroup_id,
      buffer = curbufnr,
      callback = function()
         room_below = api.nvim_win_get_height(0) - fn.winline() + 1 --[[@as integer]]
         api.nvim_win_set_height(winid,
            fold_size < room_below and fold_size or room_below)
      end
   })

   -- vim resize
   api.nvim_create_autocmd('VimResized', {
      group = augroup_id,
      buffer = curbufnr,
      callback = function()
         room_right = api.nvim_win_get_width(0) - gutter_width - indent --[[@as integer]]
         api.nvim_win_set_width(winid,
            max_line_len < room_right and max_line_len or room_right)
      end
   })

end

---Functions in this table are meant to be used with the next plugin:
--- https://github.com/anuvyklack/keymap-amend.nvim
---@type table<string, function>
M.mapping = {}

---Show preview, if preview opened — close it and open fold.
---If no closed fold under the cursor, execute original mapping.
---@param original? function
function M.mapping.show_close_preview_open_fold(original)
   if fn.foldclosed('.') ~= -1 and M.fold_preview_cocked then
      M.fold_preview_cocked = false
      M.show_preview()
   elseif fn.foldclosed('.') ~= -1 and not M.fold_preview_cocked then
      api.nvim_command('normal! zv') -- open fold
      if M.close_preview then
         -- For smoothness to avoid annoying screen flickering.
         vim.defer_fn(M.close_preview, 1)
      end
   else
      if original then original() end
   end
end

---Close preview and open fold or execute original mapping.
---@param original function
function M.mapping.close_preview_open_fold(original)
   if fn.foldclosed('.') ~= -1 and not M.fold_preview_cocked then
      api.nvim_command('normal! zv')
      if M.close_preview then
         vim.defer_fn(M.close_preview, 1)
      end
   elseif fn.foldclosed('.') ~= -1 then
      api.nvim_command('normal! zv') -- open fold
   else
      original()
   end
end

---Close preview and execute original mapping.
---@param original? function
function M.mapping.close_preview(original)
   if M.close_preview then
      vim.defer_fn(M.close_preview, 1)
   end
   if original then original() end
end

---Close preview immediately (without very small defer which was added to avoid
---flickering during opening fold) and execute original mapping. This function
---should be used, when you want to close fold-preview without opening fold.
---@param original? function
function M.mapping.close_preview_without_defer(original)
   if M.close_preview then M.close_preview() end
   if original then original() end
end

return M
