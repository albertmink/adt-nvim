local M = {}

M._dest = nil
local PASSWORD = os.getenv('ADT_PASSWORD')
local PORT = 3011
local CACHE_DIR = vim.fn.expand('~/.adtls')

local PLATFORM_PATHS = {
  Darwin  = 'macosx/cocoa/aarch64/Adt-ls.app/Contents/MacOS/adt-ls',
  Linux   = 'linux/gtk/x86_64/adt-ls',
  Windows = 'win32/win32/x86_64/adt-lsc.exe',
}

local function find_binary()
  if M._binary then return M._binary end

  local env = os.getenv('ADT_LS_PATH')
  if env and vim.fn.filereadable(env) == 1 then
    M._binary = env
    return env
  end

  local sysname = vim.loop.os_uname().sysname
  if sysname:match('Windows') then sysname = 'Windows' end
  local rel = PLATFORM_PATHS[sysname]
  if not rel then return nil end

  local exts = vim.fn.glob(vim.fn.expand('~/.vscode/extensions') .. '/sapse.adt-vscode-*', false, true)
  if #exts == 0 then return nil end
  table.sort(exts)
  local bin = exts[#exts] .. '/adt-ls/' .. rel
  if vim.fn.filereadable(bin) == 1 then
    M._binary = bin
    return bin
  end
  return nil
end

-- Uses vim.fn.system (synchronous) because vim.wait+libuv doesn't work reliably
-- inside the coroutine-wrapped vim.schedule context of Neovim's LSP request dispatch.
local function write_sensitive_sync(port, fields)
  local json = vim.json.encode(fields)
  local py = string.format(
    "import socket;s=socket.socket();s.connect(('127.0.0.1',%d));s.sendall(b'%s');s.close()",
    port, json:gsub("'", "\\'"))
  vim.fn.system({ 'python3', '-c', py })
end

local function setup_buf(buf, content, client)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content:gsub('\r\n', '\n'), '\n'))
  vim.bo[buf].filetype = 'abap'
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.lsp.buf_attach_client(buf, client.id)
end

-- Ensure a remote URI buffer exists and is loaded. Calls cb(buf) when ready.
-- If the buffer is already loaded, calls cb synchronously.
local function ensure_buf(client, uri, cb)
  local existing = vim.fn.bufnr(uri)
  if existing ~= -1 and vim.fn.bufloaded(existing) == 1 then
    cb(existing)
    return
  end

  client:request('adtLs/fileSystem/readFile', { uri = uri }, function(_, r)
    if not r or not r.content then return end
    vim.schedule(function()
      local buf = vim.fn.bufnr(uri)
      if buf == -1 then
        buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_buf_set_name(buf, uri)
      end
      setup_buf(buf, r.content, client)
      cb(buf)
    end)
  end)
end

local function open_object(client, adt_uri)
  client:request('adtLs/repository/getLsUri', {
    destination = M._dest, adtUri = adt_uri,
  }, function(_, r1)
    if not r1 or not r1.uri then return end
    ensure_buf(client, r1.uri, function(buf)
      vim.api.nvim_set_current_buf(buf)
    end)
  end)
end

local function poll_for_server(on_ready)
  local attempts = 0
  local lsp_starting = false
  local timer = vim.loop.new_timer()
  timer:start(500, 500, vim.schedule_wrap(function()
    attempts = attempts + 1
    if attempts > 30 then
      timer:stop(); timer:close()
      vim.notify('[adt] Server did not become ready in time', vim.log.levels.ERROR)
      return
    end

    local clients = vim.lsp.get_clients({ name = 'adt-ls' })
    if #clients > 0 then
      timer:stop(); timer:close()
      on_ready(clients[1])
      return
    end

    if lsp_starting then return end

    local tcp = vim.loop.new_tcp()
    tcp:connect('127.0.0.1', PORT, function(err)
      tcp:close()
      if err then return end
      vim.schedule(function()
        if lsp_starting then return end
        lsp_starting = true
        vim.lsp.start({
          name = 'adt-ls',
          cmd = vim.lsp.rpc.connect('127.0.0.1', PORT),
          root_dir = vim.fn.getcwd(),
          init_options = { userAgentInfos = { { name = 'ADTNvim', version = '0.1.0' } } },
          on_init = function(client)
            client:request('adtLs/destinations/initializeService', {
              destinationsStorePath = CACHE_DIR,
            }, function() end)
          end,
        })
      end)
    end)
  end))
end

-- Resolve SNC_LIB for SSO authentication.  Terminal sessions on macOS don't
-- inherit the launchd environment where SAP Secure Login Client sets SNC_LIB.
-- Result is cached so the synchronous shell call only runs once per session.
local function resolve_snc_lib()
  if M._snc_lib ~= nil then return M._snc_lib or nil end
  local val = os.getenv('SNC_LIB')
  if val then M._snc_lib = val; return val end
  if vim.loop.os_uname().sysname == 'Darwin' then
    val = vim.fn.system('launchctl getenv SNC_LIB'):gsub('%s+$', '')
    if vim.v.shell_error == 0 and val ~= '' then M._snc_lib = val; return val end
  end
  M._snc_lib = false
  return nil
end

local function spawn_and_poll(on_ready)
  local bin = find_binary()
  if not bin then
    vim.notify('[adt] Cannot find adt-ls binary', vim.log.levels.ERROR)
    return
  end
  local snc_lib = resolve_snc_lib()
  local env = snc_lib and { SNC_LIB = snc_lib }
  M._job = vim.fn.jobstart({
    bin, '-consoleLog', '-data', CACHE_DIR,
    '-configuration', CACHE_DIR .. '/configuration',
    '-Djco.trace_path=' .. CACHE_DIR,
    '-Declipse.platform.mergeTrust=true',
    '-Djava.security.manager=disallow',
  }, {
    detach = true,
    env = env,
    on_exit = function() M._job = nil end,
  })
  poll_for_server(on_ready)
end

local function connect(on_ready)
  if M._job then
    poll_for_server(on_ready)
    return
  end

  -- Skip spawn if a detached server from a previous session is still running
  local probe = vim.loop.new_tcp()
  probe:connect('127.0.0.1', PORT, function(err)
    probe:close()
    if not err then
      vim.schedule(function() poll_for_server(on_ready) end)
    else
      vim.schedule(function() spawn_and_poll(on_ready) end)
    end
  end)
end

local function try_logon(client, cb, attempt)
  local delays = { 1000, 2000, 3000 }
  attempt = attempt or 1
  vim.defer_fn(function()
    client:request('adtLs/destinations/ensureLoggedOn', M._dest, function(err, result)
      vim.schedule(function()
        if M._logged_on or (result and result.logonState == 'connected') then
          M._logged_on = true
          M._logon_in_flight = false
          vim.notify('[adt] Connected to ' .. (M._dest or '?'), vim.log.levels.INFO)
          cb(client)
        elseif attempt < #delays then
          try_logon(client, cb, attempt + 1)
        else
          M._logon_in_flight = false
          vim.notify('[adt] Logon failed: ' .. vim.inspect(err or result), vim.log.levels.ERROR)
        end
      end)
    end)
  end, delays[attempt])
end

local function pick_destination(client, cb, on_cancel)
  client:request('adtLs/destinations/list', vim.NIL, function(err, result)
    if err or not result then
      vim.schedule(function()
        vim.notify('[adt] Failed to list destinations', vim.log.levels.ERROR)
        if on_cancel then on_cancel() end
      end)
      return
    end
    vim.schedule(function()
      vim.ui.select(result, {
        prompt = 'SAP Destination:',
        format_item = function(d)
          local props = d.properties or {}
          local user = props.user or ''
          local sys = props.systemId or ''
          return string.format('%-30s [%s]  %s@%s', d.id, d.protocol or '?', user, sys)
        end,
      }, function(choice)
        if not choice then
          if on_cancel then on_cancel() end
          return
        end
        M._dest = choice.id
        M._logged_on = false
        if cb then cb() end
      end)
    end)
  end)
end

local function ensure_ready(cb)
  local clients = vim.lsp.get_clients({ name = 'adt-ls' })
  if #clients > 0 and M._logged_on then
    cb(clients[1])
    return
  end
  if M._logon_in_flight then return end

  connect(function(client)
    if M._logged_on then cb(client); return end

    if not M._dest then
      M._logon_in_flight = true
      pick_destination(client, function()
        try_logon(client, cb)
      end, function()
        M._logon_in_flight = false
      end)
      return
    end

    M._logon_in_flight = true
    try_logon(client, cb)
  end)
end

-- Synchronous API for agentic workflows — all return {ok=bool, data=..., error=string?}
M.api = {}

local SYNC_TIMEOUT = 10000

local function lsp_err(r)
  if r and r.err then return r.err.message or vim.inspect(r.err) end
  return 'request failed'
end

local function get_client()
  local clients = vim.lsp.get_clients({ name = 'adt-ls' })
  if #clients == 0 then return nil end
  return clients[1]
end

local function ensure_buf_sync(client, uri)
  local existing = vim.fn.bufnr(uri)
  if existing ~= -1 and vim.fn.bufloaded(existing) == 1 then
    return existing
  end
  local r = client:request_sync('adtLs/fileSystem/readFile', { uri = uri }, SYNC_TIMEOUT)
  if not r or r.err or not r.result or not r.result.content then return nil end
  local buf = vim.fn.bufnr(uri)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, uri)
  end
  setup_buf(buf, r.result.content, client)
  return buf
end

local function resolve_uri_sync(client, uri)
  if not uri:match('^adt://') then return uri end
  local r = client:request_sync('adtLs/repository/getLsUri', {
    destination = M._dest, adtUri = uri,
  }, SYNC_TIMEOUT)
  if r and r.result and r.result.uri then return r.result.uri end
  return nil
end

local function with_buf(uri, fn)
  local client = get_client()
  if not client then return { ok = false, error = 'server not connected' } end
  if not M._logged_on then return { ok = false, error = 'not logged on' } end
  local resolved = resolve_uri_sync(client, uri)
  if not resolved then return { ok = false, error = 'failed to resolve URI' } end
  local buf = ensure_buf_sync(client, resolved)
  if not buf then return { ok = false, error = 'failed to load buffer' } end
  return fn(client, buf, resolved)
end

local function position_request(method, uri, line, col, timeout)
  line = math.max(line or 1, 1)
  col = math.max(col or 1, 1)
  return with_buf(uri, function(client, buf)
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = line - 1, character = col - 1 },
    }
    if method == 'textDocument/references' then
      params.context = { includeDeclaration = true }
    end
    local r, err = client:request_sync(method, params, timeout or SYNC_TIMEOUT, buf)
    if not r or r.err then
      return { ok = false, error = err or lsp_err(r) }
    end
    return { ok = true, data = r.result }
  end)
end

function M.api.search(pattern, opts)
  local client = get_client()
  if not client then return { ok = false, error = 'server not connected' } end
  if not M._logged_on then return { ok = false, error = 'not logged on' } end
  opts = opts or {}
  local dest = opts.destination or M._dest
  local r = client:request_sync('adtLs/repository/quickSearch', {
    destination = dest,
    pattern = pattern,
    maxResults = opts.maxResults or 50,
  }, SYNC_TIMEOUT)
  if not r or r.err then
    return { ok = false, error = lsp_err(r) }
  end
  local refs = (r.result and r.result.references) or {}
  local resolved = {}
  for _, ref in ipairs(refs) do
    if ref.uri and not ref.uri:match('^abap:') then
      local lr = client:request_sync('adtLs/repository/getLsUri', {
        destination = dest, adtUri = ref.uri,
      }, 5000)
      if lr and lr.result and lr.result.uri then
        ref.uri = lr.result.uri
        resolved[#resolved + 1] = ref
      end
    else
      resolved[#resolved + 1] = ref
    end
  end
  return { ok = true, data = resolved }
end

function M.api.read(uri, opts)
  opts = opts or {}
  return with_buf(uri, function(_, buf, resolved)
    local total = vim.api.nvim_buf_line_count(buf)
    local s = math.max(1, math.min(opts.startLine or 1, total))
    local e = math.max(s, math.min(opts.endLine or total, total))
    local lines = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
    return { ok = true, data = {
      uri = resolved, content = table.concat(lines, '\n'),
      startLine = s, endLine = e, totalLines = total,
    }}
  end)
end

function M.api.symbols(uri)
  return with_buf(uri, function(client, buf)
    local params = { textDocument = { uri = vim.uri_from_bufnr(buf) } }
    local r = client:request_sync('textDocument/documentSymbol', params, SYNC_TIMEOUT, buf)
    if not r or r.err then
      return { ok = false, error = lsp_err(r) }
    end
    return { ok = true, data = r.result or {} }
  end)
end

function M.api.definition(uri, line, col)
  return position_request('textDocument/definition', uri, line, col)
end

function M.api.references(uri, line, col)
  return position_request('textDocument/references', uri, line, col, 30000)
end

function M.api.hover(uri, line, col)
  local result = position_request('textDocument/hover', uri, line, col)
  if result.ok and result.data and result.data.contents then
    local c = result.data.contents
    if type(c) == 'table' and c.value then
      result.data = { content = c.value }
    elseif type(c) == 'string' then
      result.data = { content = c }
    elseif type(c) == 'table' and vim.islist(c) then
      local parts = {}
      for _, item in ipairs(c) do
        if type(item) == 'string' then
          parts[#parts + 1] = item
        elseif type(item) == 'table' and item.value then
          parts[#parts + 1] = item.value
        end
      end
      result.data = { content = table.concat(parts, '\n') }
    end
  end
  return result
end

function M.api.typeHierarchy(uri, line, col)
  line = math.max(line or 1, 1)
  col = math.max(col or 1, 1)
  return with_buf(uri, function(client, buf)
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = line - 1, character = col - 1 },
    }
    local r = client:request_sync('textDocument/prepareTypeHierarchy', params, SYNC_TIMEOUT, buf)
    if not r or r.err then
      return { ok = false, error = lsp_err(r) }
    end
    local items = r.result
    if not items or #items == 0 then return { ok = true, data = nil } end
    local item = items[1]
    local supers = {}
    local subs = {}
    local r1 = client:request_sync('typeHierarchy/supertypes', { item = item }, SYNC_TIMEOUT)
    if r1 and not r1.err then supers = r1.result or {} end
    local r2 = client:request_sync('typeHierarchy/subtypes', { item = item }, SYNC_TIMEOUT)
    if r2 and not r2.err then subs = r2.result or {} end
    return { ok = true, data = { item = item, supertypes = supers, subtypes = subs } }
  end)
end

function M.api.status()
  local client = get_client()
  return {
    ok = true,
    data = {
      destination = M._dest,
      logged_on = M._logged_on or false,
      server_connected = client ~= nil,
    },
  }
end

function M.api.connect(destination, password)
  if not destination then
    return { ok = false, error = 'connect: destination required' }
  end
  M._dest = destination
  M._logged_on = false
  if password then PASSWORD = password end
  connect(function(client)
    try_logon(client, function() end)
  end)
  return { ok = true, data = {
    destination = destination,
    message = 'connecting — poll status() until logged_on=true',
  }}
end

local function jump_to_buf(buf, line, col)
  vim.cmd("normal! m'")
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { line + 1, col })
  vim.cmd('normal! zv')
end

-- Override vim.lsp.buf methods that jump to locations so we can handle
-- remote URIs (abap://) by fetching file content before jumping.
local function override_lsp_location_method(name, method)
  local original = vim.lsp.buf[name]
  vim.lsp.buf[name] = function(opts)
    local bufnr = vim.api.nvim_get_current_buf()
    local clients = vim.lsp.get_clients({ method = method, bufnr = bufnr })
    if #clients == 0 then return original(opts) end

    local win = vim.api.nvim_get_current_win()
    vim.lsp.buf_request_all(bufnr, method, function(client)
      return vim.lsp.util.make_position_params(win, client.offset_encoding)
    end, function(results)
      for _, res in pairs(results) do
        if res and res.result then
          local locs = vim.islist(res.result) and res.result or { res.result }
          if #locs == 1 then
            local loc = locs[1]
            local uri = loc.uri or loc.targetUri
            local range = loc.range or loc.targetSelectionRange
            if uri and not uri:match('^file://') and range then
              local adt_client = vim.lsp.get_clients({ name = 'adt-ls' })[1]
              if not adt_client then return end
              ensure_buf(adt_client, uri, function(buf)
                jump_to_buf(buf, range.start.line, range.start.character)
              end)
              return
            end
          end
        end
      end
      original(opts)
    end)
  end
end

function M.setup(opts)
  opts = opts or {}
  if opts.destination then M._dest = opts.destination end
  if opts.password then PASSWORD = opts.password end

  override_lsp_location_method('definition', 'textDocument/definition')
  override_lsp_location_method('declaration', 'textDocument/declaration')
  override_lsp_location_method('type_definition', 'textDocument/typeDefinition')
  override_lsp_location_method('implementation', 'textDocument/implementation')

  vim.api.nvim_create_autocmd('VimLeavePre', {
    callback = function()
      if M._job then
        vim.fn.jobstop(M._job)
        M._job = nil
      end
    end,
  })

  local function attach_keymaps(buf)
    local kopts = { buffer = buf }
    vim.keymap.set('n', 'gd',  '<Cmd>AdtDefinition<CR>',     kopts)
    vim.keymap.set('n', 'gD',  '<Cmd>AdtDeclaration<CR>',    kopts)
    vim.keymap.set('n', 'gr',  '<Cmd>AdtReferences<CR>',     kopts)
    vim.keymap.set('n', 'gi',  '<Cmd>AdtImplementation<CR>', kopts)
    vim.keymap.set('n', 'go',  '<Cmd>AdtSymbols<CR>',        kopts)
    vim.keymap.set('n', 'K',   '<Cmd>AdtHover<CR>',          kopts)
    vim.keymap.set('n', 'gth', '<Cmd>AdtTypeHierarchy<CR>',  kopts)
  end

  vim.api.nvim_create_autocmd('LspAttach', {
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not client or client.name ~= 'adt-ls' then return end
      attach_keymaps(ev.buf)

      local ok, navic = pcall(require, 'nvim-navic')
      if ok and navic then navic.attach(client, ev.buf) end

      vim.api.nvim_create_autocmd('CursorHold', {
        buffer = ev.buf,
        callback = vim.lsp.buf.document_highlight,
      })
      vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = ev.buf,
        callback = vim.lsp.buf.clear_references,
      })
    end,
  })

  -- Keymaps for buffers already attached before setup() ran
  for _, client in ipairs(vim.lsp.get_clients({ name = 'adt-ls' })) do
    for buf in pairs(client.attached_buffers) do
      attach_keymaps(buf)
    end
  end

  vim.lsp.handlers['adtLs/destinations/requestLogonInput'] = function(_, params)
    if not params then return nil end
    local sensitive = {}
    local non_sensitive = {}
    for _, p in ipairs(params.params or {}) do
      if p.sensitive then
        if not PASSWORD then
          vim.notify('[adt] No password set — pass it to setup{ password = ... }, '
            .. 'M.api.connect(dest, pw), or the ADT_PASSWORD env var', vim.log.levels.ERROR)
          return nil
        end
        sensitive[p.name] = PASSWORD
      else
        non_sensitive[p.name] = p.value or ''
      end
    end
    if params.sensitiveFieldsSocketPort and next(sensitive) then
      write_sensitive_sync(params.sensitiveFieldsSocketPort, sensitive)
    end
    return { nonSensitiveFields = non_sensitive }
  end

  vim.lsp.handlers['adtLs/destinations/requestBrowserBasedLogon'] = function() return true end
  vim.lsp.handlers['adtLs/destinations/logonStateChanged'] = function(_, params)
    if params and params.destinationId == M._dest then
      M._logged_on = params.logonState == 'connected'
    end
  end

  vim.api.nvim_create_user_command('AdtOpen', function()
    ensure_ready(function(client)
      local ok = pcall(require, 'telescope')
      if not ok then
        vim.ui.input({ prompt = 'ABAP object: ' }, function(pattern)
          if not pattern or pattern == '' then return end
          client:request('adtLs/repository/quickSearch', {
            destination = M._dest, pattern = pattern, maxResults = 20,
          }, function(err, result)
            if err or not result or not result.references then return end
            vim.schedule(function()
              vim.ui.select(result.references, {
                prompt = 'Select:',
                format_item = function(r) return r.name .. '  [' .. r.type .. ']' end,
              }, function(choice)
                if choice then open_object(client, choice.uri) end
              end)
            end)
          end)
        end)
        return
      end

      local pickers = require('telescope.pickers')
      local finders = require('telescope.finders')
      local conf = require('telescope.config').values
      local actions = require('telescope.actions')
      local action_state = require('telescope.actions.state')

      pickers.new({}, {
        prompt_title = 'ABAP Object (' .. (M._dest or '?') .. ')',
        finder = finders.new_dynamic({
          fn = function(prompt)
            if not prompt or prompt == '' then return {} end
            local r = client:request_sync('adtLs/repository/quickSearch', {
              destination = M._dest, pattern = prompt, maxResults = 50,
            }, 10000)
            if r and r.result and r.result.references then return r.result.references end
            return {}
          end,
          entry_maker = function(ref)
            return {
              value = ref,
              display = string.format('%-40s %-8s %s', ref.name, ref.type, ref.description or ''),
              ordinal = ref.name,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local sel = action_state.get_selected_entry()
            if sel then open_object(client, sel.value.uri) end
          end)
          return true
        end,
      }):find()
    end)
  end, { desc = 'Search and open ABAP object' })

  vim.api.nvim_create_user_command('AdtSwitch', function()
    connect(function(client)
      pick_destination(client, function()
        M._logon_in_flight = true
        try_logon(client, function()
          vim.notify('[adt] Switched to ' .. (M._dest or '?'), vim.log.levels.INFO)
        end)
      end)
    end)
  end, { desc = 'Switch SAP destination' })

  vim.api.nvim_create_user_command('AdtDefinition',
    function() ensure_ready(function() vim.lsp.buf.definition() end) end,
    { desc = 'Go to definition' })
  vim.api.nvim_create_user_command('AdtDeclaration',
    function() ensure_ready(function() vim.lsp.buf.declaration() end) end,
    { desc = 'Go to declaration' })
  vim.api.nvim_create_user_command('AdtReferences',
    function() ensure_ready(function() vim.lsp.buf.references() end) end,
    { desc = 'Find references' })
  vim.api.nvim_create_user_command('AdtImplementation',
    function() ensure_ready(function() vim.lsp.buf.implementation() end) end,
    { desc = 'Go to implementation' })
  vim.api.nvim_create_user_command('AdtHover',
    function() ensure_ready(function() vim.lsp.buf.hover() end) end,
    { desc = 'Show hover info' })
  vim.api.nvim_create_user_command('AdtSymbols',
    function() ensure_ready(function() vim.lsp.buf.document_symbol() end) end,
    { desc = 'List document symbols' })

  vim.api.nvim_create_user_command('AdtTypeHierarchy', function()
    ensure_ready(function(client)
      local bufnr = vim.api.nvim_get_current_buf()
      local win = vim.api.nvim_get_current_win()
      local cursor = vim.api.nvim_win_get_cursor(win)
      local params = {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = { line = cursor[1] - 1, character = cursor[2] },
      }
      client:request('textDocument/prepareTypeHierarchy', params, function(err, items)
        if err then
          vim.notify('[adt] prepareTypeHierarchy error: ' .. vim.inspect(err), vim.log.levels.ERROR)
          return
        end
        if not items or #items == 0 then
          vim.notify('[adt] No type hierarchy at cursor', vim.log.levels.WARN)
          return
        end
        local item = items[1]
        local pending = 2
        local supers, subs = {}, {}
        local function on_done()
          pending = pending - 1
          if pending > 0 then return end
          local entries = {}
          for _, s in ipairs(supers) do
            entries[#entries + 1] = { kind = 'super', item = s }
          end
          for _, s in ipairs(subs) do
            entries[#entries + 1] = { kind = 'sub', item = s }
          end
          if #entries == 0 then
            vim.notify('[adt] ' .. (item.name or '?') .. ' has no supertypes or subtypes', vim.log.levels.INFO)
            return
          end
          local function label(e)
            return string.format('[%-5s] %s', e.kind, e.item.name or e.item.uri or '?')
          end
          local function open_entry(e)
            local uri = e.item.uri
            if not uri then return end
            ensure_buf(client, uri, function(buf)
              local r = e.item.range or e.item.selectionRange
              if r then
                jump_to_buf(buf, r.start.line, r.start.character)
              else
                vim.api.nvim_set_current_buf(buf)
              end
            end)
          end
          local ok = pcall(require, 'telescope')
          if not ok then
            vim.ui.select(entries, {
              prompt = 'Type hierarchy of ' .. (item.name or '?') .. ':',
              format_item = label,
            }, function(choice)
              if choice then open_entry(choice) end
            end)
            return
          end
          local pickers = require('telescope.pickers')
          local finders = require('telescope.finders')
          local conf = require('telescope.config').values
          local actions = require('telescope.actions')
          local action_state = require('telescope.actions.state')
          pickers.new({}, {
            prompt_title = 'Type hierarchy: ' .. (item.name or '?'),
            finder = finders.new_table({
              results = entries,
              entry_maker = function(e)
                return { value = e, display = label(e), ordinal = e.kind .. e.item.name }
              end,
            }),
            sorter = conf.generic_sorter({}),
            attach_mappings = function(prompt_bufnr)
              actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local sel = action_state.get_selected_entry()
                if sel then open_entry(sel.value) end
              end)
              return true
            end,
          }):find()
        end
        client:request('typeHierarchy/supertypes', { item = item }, function(_, r)
          supers = r or {}; on_done()
        end)
        client:request('typeHierarchy/subtypes', { item = item }, function(_, r)
          subs = r or {}; on_done()
        end)
      end, bufnr)
    end)
  end, { desc = 'Show type hierarchy at cursor' })

  vim.api.nvim_create_user_command('AdtApi', function(args)
    local sub = args.fargs[1]
    if not sub then
      print(vim.json.encode({ ok = false, error = 'usage: AdtApi <cmd> [args...]' }))
      return
    end
    local a = args.fargs
    local pos = function() return a[2] or '', tonumber(a[3]) or 1, tonumber(a[4]) or 1 end
    local dispatch = {
      search = function() return M.api.search(a[2] or '', { maxResults = tonumber(a[3]) }) end,
      read = function()
        return M.api.read(a[2] or '', {
          startLine = tonumber(a[3]), endLine = tonumber(a[4]),
        })
      end,
      symbols = function() return M.api.symbols(a[2] or '') end,
      definition = function() return M.api.definition(pos()) end,
      references = function() return M.api.references(pos()) end,
      hover = function() return M.api.hover(pos()) end,
      typeHierarchy = function() return M.api.typeHierarchy(pos()) end,
      status = function() return M.api.status() end,
      connect = function() return M.api.connect(a[2], a[3]) end,
    }
    local handler = dispatch[sub]
    local result = handler and handler() or { ok = false, error = 'unknown command: ' .. sub }
    print(vim.json.encode(result))
  end, { nargs = '+', desc = 'Programmatic API for agentic workflows' })
end

return M
