local PATH_PREFIX_REGEX = vim.regex([[\~\?[./]\+]])
local defaults = {
  allowed_cmd_context = {
    [string.byte('e')] = true,
    [string.byte('w')] = true,
    [string.byte('r')] = true,
  },
  fd_timeout_msec = 500,
}

-- return new_pattern, cwd, prefix
local function find_cwd(pattern)
  local s, e = PATH_PREFIX_REGEX:match_str(pattern)
  if s == nil then
    return pattern, vim.fn.getcwd(), ''
  else
    local prefix = pattern:sub(s, e)
    if prefix:byte(#prefix) ~= string.byte('/') then
      prefix = prefix .. '/'
    end
    return pattern:sub(e + 1), vim.fn.resolve(vim.fn.expand(prefix)), prefix
  end
end

local source
source = {
  new = function()
    return setmetatable({}, { __index = source })
  end,
  get_trigger_characters = function()
    return { '.', '/', '~' }
  end,
  get_keyword_pattern = function(_, params)
    if vim.api.nvim_get_mode().mode == 'c' then
      return [[\S\+]]
    else
      return [[[.~/]\+\S\+]]
    end
  end,
  stat = function(_, path)
    local stat = vim.loop.fs_stat(path)
    if stat then
      return stat
    end
    return nil
  end,
  complete = function(self, params, callback)
    params.option = vim.tbl_deep_extend('keep', params.option, defaults)
    local is_cmd = (vim.api.nvim_get_mode().mode == 'c')
    if is_cmd then
      if params.option.allowed_cmd_context[params.context.cursor_line:byte(1)] == nil then
        callback()
        return
      elseif params.context.cursor_line:find('%s') == nil then
        -- we should have a space between, e.g., `edit` and a path
        callback({ items = {}, isIncomplete = true })
        return
      end
    end
    local pattern = params.context.cursor_before_line:sub(params.offset)

    local new_pattern, cwd, prefix = find_cwd(pattern)
    if not self:stat(cwd) then
      return callback()
    end

    local items = {}
    local cmd = ""
    if new_pattern == "" then
      cmd = "fd --type file -i -p -d 20"
    else
      cmd = "fd --type file -i -p -d 20 | sk -f " .. new_pattern
    end

    local job
    job = vim.fn.jobstart(cmd, {
      stdout_buffered = false,
      cwd = cwd,
      on_stdout = function(_, lines, _)
        if #lines == 0 or (#lines == 1 and lines[1] == '') then
          vim.fn.jobstop(job)
          callback({ items = items, isIncomplete = true })
          return
        end
        for _, item in ipairs(lines) do
          if #item > 0 then
            local stat, kind = self:kind(cwd .. '/' .. item)
            table.insert(items, {
              label = prefix .. vim.fn.fnameescape(item),
              kind = kind,
              data = { path = cwd .. '/' .. vim.fn.fnameescape(item), stat = stat },
              -- hack cmp to not filter our fuzzy matches. If we do not use
              -- this, the user has to input the first character of the match
              filterText = string.sub(params.context.cursor_before_line, params.offset),
            })
          end
        end
      end,
    })

    vim.fn.timer_start(params.option.fd_timeout_msec, function()
      vim.fn.jobstop(job)
    end)
  end,
  kind = function(self, path)
    local stat = self:stat(path)
    local type = (stat and stat.type) or 'unknown'
    if type == 'directory' then
      return stat, 19 -- cmp.lsp.CompletionItemKind.Folder
    elseif type == 'file' then
      return stat, 17 -- cmp.lsp.CompletionItemKind.File
    else
      return nil, nil
    end
  end,
}

return source