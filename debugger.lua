-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Scott Lembcke and Howling Moon Software

local dbg

local function pretty(obj, max_depth)
	if max_depth == nil then max_depth = dbg.pretty_depth end
	
	-- Returns true if a table has a __tostring metamethod.
	local function coerceable(tbl)
		local meta = getmetatable(tbl)
		return (meta and meta.__tostring)
	end
	
	local function recurse(obj, depth)
		if type(obj) == "string" then
			-- Dump the string so that escape sequences are printed.
			return string.format("%q", obj)
		elseif type(obj) == "table" and depth < max_depth and not coerceable(obj) then
			local str = "{"
			
			for k, v in pairs(obj) do
				local pair = pretty(k, 0).." = "..recurse(v, depth + 1)
				str = str..(str == "{" and pair or ", "..pair)
			end
			
			return str.."}"
		else
			-- tostring() can fail if there is an error in a __tostring metamethod.
			local success, value = pcall(function() return tostring(obj) end)
			return (success and value or "<!!error in __tostring metamethod!!>")
		end
	end
	
	return recurse(obj, 0)
end

-- The stack level that cmd_* functions use to access locals or info
-- The structure of the debugger's code *very* carefully ensures this.
local CMD_STACK_LEVEL = 6

-- Location of the top of the stack outside of the debugger.
-- Adjusted by some debugger entrypoints.
local stack_top = 0

-- The current stack frame index.
-- Changed using the up/down commands
local stack_inspect_offset = 0

-- LuaJIT has an off by one bug when setting local variables.
local LUA_JIT_SETLOCAL_WORKAROUND = 0

-- Default dbg.read function
local function dbg_read(prompt)
	dbg.write(prompt)
	io.flush()
	return io.read()
end

-- Default dbg.write function
local function dbg_write(str)
	io.stderr:write(str)
end

local function dbg_writeln(str, ...)
	if select("#", ...) == 0 then
		dbg.write((str or "<NULL>").."\n")
	else
		dbg.write(string.format(str.."\n", ...))
	end
end

local function format_loc(info, line)
	local filename = info.source:match("^@(.*)")
	local source = filename and dbg.shorten_path(filename) or info.short_src
	return (dbg.COLOR_BLUE)..source..(dbg.COLOR_RESET)..":"..(dbg.COLOR_YELLOW)..line..(dbg.COLOR_RESET)
end

local function format_stack_frame_info(info)
	local namewhat = (info.namewhat == "" and "chunk at" or info.namewhat)
	local name = (info.name and "'"..(dbg.COLOR_BLUE)..(info.name)..(dbg.COLOR_RESET).."'" or dbg.format_loc(info, info.linedefined))
	return dbg.format_loc(info, info.currentline).." in "..namewhat.." "..name
end

local repl

-- Return false for stack frames without source,
-- which includes C frames, Lua bytecode, and `loadstring` functions
local function frame_has_line(info) return info.currentline >= 0 end

local function hook_factory(repl_threshold)
	return function(offset, reason)
		return function(event, _)
			-- Skip events that don't have line information.
			if not frame_has_line(debug.getinfo(2)) then return end
			
			-- Tail calls are specifically ignored since they also will have tail returns to balance out.
			if event == "call" then
				offset = offset + 1
			elseif event == "return" and offset > repl_threshold then
				offset = offset - 1
			elseif event == "line" and offset <= repl_threshold then
				repl(reason)
			end
		end
	end
end

local hook_step = hook_factory(1)
local hook_next = hook_factory(0)
local hook_finish = hook_factory(-1)

-- Create a table of all the locally accessible variables.
-- Globals are not included when running the locals command, but are when running the print command.
local function local_bindings(offset, include_globals)
	local level = offset + stack_inspect_offset + CMD_STACK_LEVEL
	local func = debug.getinfo(level).func
	local bindings = {}
	
	-- Retrieve the upvalues
	do local i = 1; while true do
		local name, value = debug.getupvalue(func, i)
		if not name then break end
		bindings[name] = value
		i = i + 1
	end end
	
	-- Retrieve the locals (overwriting any upvalues)
	do local i = 1; while true do
		local name, value = debug.getlocal(level, i)
		if not name then break end
		bindings[name] = value
		i = i + 1
	end end
	
	-- Retrieve the varargs (works in Lua 5.2 and LuaJIT)
	local varargs = {}
	do local i = 1; while true do
		local name, value = debug.getlocal(level, -i)
		if not name then break end
		varargs[i] = value
		i = i + 1
	end end
	if #varargs > 0 then bindings["..."] = varargs end
	
	if include_globals then
		-- In Lua 5.2, you have to get the environment table from the function's locals.
		local env = (_VERSION <= "Lua 5.1" and getfenv(func) or bindings._ENV)
		return setmetatable(bindings, {__index = env or _G})
	else
		return bindings
	end
end

-- Used as a __newindex metamethod to modify variables in cmd_eval().
local function mutate_bindings(_, name, value)
	local FUNC_STACK_OFFSET = 3 -- Stack depth of this function.
	local level = stack_inspect_offset + FUNC_STACK_OFFSET + CMD_STACK_LEVEL
	
	-- Set a local.
	do local i = 1; repeat
		local var = debug.getlocal(level, i)
		if name == var then
			dbg_writeln((dbg.COLOR_YELLOW).."debugger.lua"..(dbg.GREEN_CARET).."Set local variable "..(dbg.COLOR_BLUE)..name..(dbg.COLOR_RESET))
			return debug.setlocal(level + LUA_JIT_SETLOCAL_WORKAROUND, i, value)
		end
		i = i + 1
	until var == nil end
	
	-- Set an upvalue.
	local func = debug.getinfo(level).func
	do local i = 1; repeat
		local var = debug.getupvalue(func, i)
		if name == var then
			dbg_writeln((dbg.COLOR_YELLOW).."debugger.lua"..(dbg.GREEN_CARET).."Set upvalue "..(dbg.COLOR_BLUE)..name..(dbg.COLOR_RESET))
			return debug.setupvalue(func, i, value)
		end
		i = i + 1
	until var == nil end
	
	-- Set a global.
	dbg_writeln((dbg.COLOR_YELLOW).."debugger.lua"..(dbg.GREEN_CARET).."Set global variable "..(dbg.COLOR_BLUE)..name..(dbg.COLOR_RESET))
	_G[name] = value
end

-- Compile an expression with the given variable bindings.
local function compile_chunk(block, env)
	local source = "debugger.lua REPL"
	local chunk = nil
	
	if _VERSION <= "Lua 5.1" then
		chunk = loadstring(block, source)
		if chunk then setfenv(chunk, env) end
	else
		-- The Lua 5.2 way is a bit cleaner
		chunk = load(block, source, "t", env)
	end
	
	if not chunk then dbg_writeln((dbg.COLOR_RED).."Error: Could not compile block:\n"..(dbg.COLOR_RESET)..block) end
	return chunk
end

local SOURCE_CACHE = {}

local function where(info, context_lines)
	local source = SOURCE_CACHE[info.source]
	if not source then
		source = {}
		local filename = info.source:match("^@(.*)")
		if filename then
			pcall(function() for line in io.lines(filename) do table.insert(source, line) end end)
		elseif info.source then
			for line in info.source:gmatch("([^\n]*)\n?") do table.insert(source, line) end
		end
		SOURCE_CACHE[info.source] = source
	end
	
	if source and source[info.currentline] then
		for i = info.currentline - context_lines, info.currentline + context_lines do
			local tab_or_caret = (i == info.currentline and  (dbg.GREEN_CARET) or "    ")
			local line = source[i]
			if line then dbg_writeln((dbg.COLOR_GRAY).."% 4d"..tab_or_caret.."%s", i, line) end
		end
	else
		dbg_writeln((dbg.COLOR_RED).."Error: Source not available for "..(dbg.COLOR_BLUE)..(info.short_src));
	end
	
	return false
end

local function cmd_step()
	stack_inspect_offset = stack_top
	return true, hook_step
end

local function cmd_next()
	stack_inspect_offset = stack_top
	return true, hook_next
end

local function cmd_finish()
	local offset = stack_top - stack_inspect_offset
	stack_inspect_offset = stack_top
	return true, offset < 0 and hook_factory(offset - 1) or hook_finish
end

-- Wee Lua version differences
local pack = function(...) return select("#", ...), {...} end
local unpack = unpack or table.unpack

local function cmd_print(expr)
	local env = local_bindings(1, true)
	local chunk = compile_chunk("return "..expr, env)
	if chunk == nil then return false end
	
	-- Call the chunk and collect the results.
	local nresults, results = pack(pcall(chunk, unpack(rawget(env, "...") or {})))
	
	-- The first result is the pcall error.
	if not results[1] then
		dbg_writeln((dbg.COLOR_RED).."Error:"..(dbg.COLOR_RESET).." "..results[2])
	else
		local output = ""
		for i = 2, nresults do
			output = output..(i ~= 2 and ", " or "")..dbg.pretty(results[i])
		end
		
		if output == "" then output = "<no result>" end
		dbg_writeln((dbg.COLOR_BLUE)..expr.. (dbg.GREEN_CARET)..output)
	end
	
	return false
end

local function cmd_eval(code)
	local env = local_bindings(1, true)
	local mutable_env = setmetatable({}, {
		__index = env,
		__newindex = mutate_bindings,
	})
	
	local chunk = compile_chunk(code, mutable_env)
	if chunk == nil then return false end
	
	-- Call the chunk and collect the results.
	local success, err = pcall(chunk, unpack(rawget(env, "...") or {}))
	if not success then
		dbg_writeln((dbg.COLOR_RED).."Error:"..(dbg.COLOR_RESET).." "..tostring(err))
	end
	
	return false
end

local function cmd_down()
	local offset = stack_inspect_offset
	local info
	
	repeat -- Find the next frame with a file.
		offset = offset + 1
		info = debug.getinfo(offset + CMD_STACK_LEVEL)
	until not info or frame_has_line(info)
	
	if info then
		stack_inspect_offset = offset
		dbg_writeln("Inspecting frame: "..dbg.format_stack_frame_info(info))
		if tonumber(dbg.auto_where) then where(info, dbg.auto_where) end
	else
		info = debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL)
		dbg_writeln("Already at the bottom of the stack.")
	end
	
	return false
end

local function cmd_up()
	local offset = stack_inspect_offset
	local info
	
	repeat -- Find the next frame with a file.
		offset = offset - 1
		if offset < stack_top then info = nil; break end
		info = debug.getinfo(offset + CMD_STACK_LEVEL)
	until frame_has_line(info)
	
	if info then
		stack_inspect_offset = offset
		dbg_writeln("Inspecting frame: "..dbg.format_stack_frame_info(info))
		if tonumber(dbg.auto_where) then where(info, dbg.auto_where) end
	else
		info = debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL)
		dbg_writeln("Already at the top of the stack.")
	end
	
	return false
end

local function cmd_inspect(offset)
	offset = stack_top + tonumber(offset)
	local info = debug.getinfo(offset + CMD_STACK_LEVEL)
	if info then
		stack_inspect_offset = offset
		dbg.writeln("Inspecting frame: "..dbg.format_stack_frame_info(info))
	else
		dbg.writeln((dbg.COLOR_RED).."ERROR: "..(dbg.COLOR_BLUE).."Invalid stack frame index."..(dbg.COLOR_RESET))
	end
end

local function cmd_where(context_lines)
	local info = debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL)
	return (info and where(info, tonumber(context_lines) or 5))
end

local function cmd_trace()
	dbg_writeln("Inspecting frame %d", stack_inspect_offset - stack_top)
	local i = 0; while true do
		local info = debug.getinfo(stack_top + CMD_STACK_LEVEL + i)
		if not info then break end
		
		local is_current_frame = (i + stack_top == stack_inspect_offset)
		local tab_or_caret = (is_current_frame and  (dbg.GREEN_CARET) or "    ")
		dbg_writeln((dbg.COLOR_GRAY).."% 4d"..(dbg.COLOR_RESET)..tab_or_caret.."%s", i, dbg.format_stack_frame_info(info))
		i = i + 1
	end
	
	return false
end

local function cmd_locals()
	local bindings = local_bindings(1, false)
	
	-- Get all the variable binding names and sort them
	local keys = {}
	for k, _ in pairs(bindings) do table.insert(keys, k) end
	table.sort(keys)
	
	for _, k in ipairs(keys) do
		local v = bindings[k]
		
		-- Skip the debugger object itself, "(*internal)" values, and Lua 5.2's _ENV object.
		if not rawequal(v, dbg) and k ~= "_ENV" and not k:match("%(.*%)") then
			dbg_writeln("  "..(dbg.COLOR_BLUE)..k.. (dbg.GREEN_CARET)..dbg.pretty(v))
		end
	end
	
	return false
end

local function cmd_help()
	dbg.write(""
		..(dbg.COLOR_BLUE).."  <return>"..(dbg.GREEN_CARET).."re-run last command\n"
		..(dbg.COLOR_BLUE).."  c"..(dbg.COLOR_YELLOW).."(ontinue)"..(dbg.GREEN_CARET).."continue execution\n"
		..(dbg.COLOR_BLUE).."  s"..(dbg.COLOR_YELLOW).."(tep)"..(dbg.GREEN_CARET).."step forward by one line (into functions)\n"
		..(dbg.COLOR_BLUE).."  n"..(dbg.COLOR_YELLOW).."(ext)"..(dbg.GREEN_CARET).."step forward by one line (skipping over functions)\n"
		..(dbg.COLOR_BLUE).."  f"..(dbg.COLOR_YELLOW).."(inish)"..(dbg.GREEN_CARET).."step forward until exiting the current function\n"
		..(dbg.COLOR_BLUE).."  u"..(dbg.COLOR_YELLOW).."(p)"..(dbg.GREEN_CARET).."move up the stack by one frame\n"
		..(dbg.COLOR_BLUE).."  d"..(dbg.COLOR_YELLOW).."(own)"..(dbg.GREEN_CARET).."move down the stack by one frame\n"
		..(dbg.COLOR_BLUE).."  i"..(dbg.COLOR_YELLOW).."(nspect) "..(dbg.COLOR_BLUE).."[index]"..(dbg.GREEN_CARET).."move to a specific stack frame\n"
		..(dbg.COLOR_BLUE).."  w"..(dbg.COLOR_YELLOW).."(here) "..(dbg.COLOR_BLUE).."[line count]"..(dbg.GREEN_CARET).."print source code around the current line\n"
		..(dbg.COLOR_BLUE).."  e"..(dbg.COLOR_YELLOW).."(val) "..(dbg.COLOR_BLUE).."[statement]"..(dbg.GREEN_CARET).."execute the statement\n"
		..(dbg.COLOR_BLUE).."  p"..(dbg.COLOR_YELLOW).."(rint) "..(dbg.COLOR_BLUE).."[expression]"..(dbg.GREEN_CARET).."execute the expression and print the result\n"
		..(dbg.COLOR_BLUE).."  t"..(dbg.COLOR_YELLOW).."(race)"..(dbg.GREEN_CARET).."print the stack trace\n"
		..(dbg.COLOR_BLUE).."  l"..(dbg.COLOR_YELLOW).."(ocals)"..(dbg.GREEN_CARET).."print the function arguments, locals and upvalues.\n"
		..(dbg.COLOR_BLUE).."  h"..(dbg.COLOR_YELLOW).."(elp)"..(dbg.GREEN_CARET).."print this message\n"
		..(dbg.COLOR_BLUE).."  q"..(dbg.COLOR_YELLOW).."(uit)"..(dbg.GREEN_CARET).."halt execution\n"
	)
	return false
end

local last_cmd = false

local commands = {
	["^c$"] = function() return true end,
	["^s$"] = cmd_step,
	["^n$"] = cmd_next,
	["^f$"] = cmd_finish,
	["^p%s+(.*)$"] = cmd_print,
	["^e%s+(.*)$"] = cmd_eval,
	["^u$"] = cmd_up,
	["^d$"] = cmd_down,
	["i%s*(%d+)"] = cmd_inspect,
	["^w%s*(%d*)$"] = cmd_where,
	["^t$"] = cmd_trace,
	["^l$"] = cmd_locals,
	["^h$"] = cmd_help,
	["^q$"] = function() dbg.exit(0); return true end,
}

local function match_command(line)
	for pat, func in pairs(commands) do
		-- Return the matching command and capture argument.
		if line:find(pat) then return func, line:match(pat) end
	end
end

-- Run a command line
-- Returns true if the REPL should exit and the hook function factory
local function run_command(line)
	-- GDB/LLDB exit on ctrl-d
	if line == nil then dbg.exit(1); return true end
	
	-- Re-execute the last command if you press return.
	if line == "" then line = last_cmd or "h" end
	
	local command, command_arg = match_command(line)
	if command then
		last_cmd = line
		-- unpack({...}) prevents tail call elimination so the stack frame indices are predictable.
		return unpack({command(command_arg)})
	elseif dbg.auto_eval then
		return unpack({cmd_eval(line)})
	else
		dbg_writeln((dbg.COLOR_RED).."Error:"..(dbg.COLOR_RESET).." command '%s' not recognized.\nType 'h' and press return for a command list.", line)
		return false
	end
end

repl = function(reason)
	-- Skip frames without source info.
	while not frame_has_line(debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL - 3)) do
		stack_inspect_offset = stack_inspect_offset + 1
	end
	
	local info = debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL - 3)
	reason = reason and ((dbg.COLOR_YELLOW).."break via "..(dbg.COLOR_RED)..reason..(dbg.GREEN_CARET)) or ""
	dbg_writeln(reason..dbg.format_stack_frame_info(info))
	
	if tonumber(dbg.auto_where) then where(info, dbg.auto_where) end
	
	repeat
		local success, done, hook = pcall(run_command, dbg.read((dbg.COLOR_RED).."debugger.lua> "..(dbg.COLOR_RESET)))
		if success then
			debug.sethook(hook and hook(0), "crl")
		else
			local message = (dbg.COLOR_RED).."INTERNAL DEBUGGER.LUA ERROR. ABORTING\n:"..(dbg.COLOR_RESET).." "..done
			dbg_writeln(message)
			error(message)
		end
	until done
end

-- Make the debugger object callable like a function.
dbg = setmetatable({}, {
	__call = function(_, condition, top_offset, source)
		if condition then return end
		
		top_offset = (top_offset or 0)
		stack_inspect_offset = top_offset
		stack_top = top_offset
		
		debug.sethook(hook_next(1, source or "dbg()"), "crl")
		return
	end,
})

-- Expose the debugger's IO functions.
dbg.read = dbg_read
dbg.write = dbg_write
dbg.shorten_path = function (path) return path end
dbg.format_loc = format_loc
dbg.format_stack_frame_info = format_stack_frame_info
dbg.exit = function(err) os.exit(err) end

dbg.writeln = dbg_writeln

dbg.pretty_depth = 3
dbg.pretty = pretty
dbg.pp = function(value, depth) dbg_writeln(dbg.pretty(value, depth)) end

dbg.auto_where = false
dbg.auto_eval = false

local lua_error, lua_assert = error, assert

-- Works like error(), but invokes the debugger.
function dbg.error(err, level)
	level = level or 1
	dbg_writeln((dbg.COLOR_RED).."ERROR: "..(dbg.COLOR_RESET)..dbg.pretty(err))
	dbg(false, level, "dbg.error()")
	
	lua_error(err, level)
end

-- Works like assert(), but invokes the debugger on a failure.
function dbg.assert(condition, message, ...)
	if not condition then
		message = message or "assertion failed!"
		dbg_writeln((dbg.COLOR_RED).."ERROR: "..(dbg.COLOR_RESET)..message)
		dbg(false, 1, "dbg.assert()")
	end
	
	return lua_assert(condition, message, ...)
end

-- Works like pcall(), but invokes the debugger on an error.
function dbg.call(f, ...)
	return xpcall(f, function(err)
		dbg_writeln((dbg.COLOR_RED).."ERROR: "..(dbg.COLOR_RESET)..dbg.pretty(err))
		dbg(false, 1, "dbg.call()")
		
		return err
	end, ...)
end

-- Error message handler that can be used with lua_pcall().
function dbg.msgh(...)
	if debug.getinfo(2) then
		dbg_writeln((dbg.COLOR_RED).."ERROR: "..(dbg.COLOR_RESET)..dbg.pretty(...))
		dbg(false, 1, "dbg.msgh()")
	else
		dbg_writeln((dbg.COLOR_RED).."debugger.lua: "..(dbg.COLOR_RESET).."Error did not occur in Lua code. Execution will continue after dbg_pcall().")
	end
	
	return ...
end

function dbg.use_color(value)
	local esc = string.char(27)
	dbg.COLOR_GRAY = value and (esc.."[90m") or ""
	dbg.COLOR_RED = value and (esc.."[91m") or ""
	dbg.COLOR_BLUE = value and (esc.."[94m") or ""
	dbg.COLOR_YELLOW = value and (esc.."[33m") or ""
	dbg.COLOR_RESET = value and (esc.."[0m") or ""
	dbg.GREEN_CARET = value and (esc.."[92m => "..(dbg.COLOR_RESET)) or " => "
end

-- Conditionally enable color support.
local color_maybe_supported = (os.getenv("TERM") and os.getenv("TERM") ~= "dumb")
dbg.use_color(color_maybe_supported and not os.getenv("DBG_NOCOLOR"))

-- Detect Lua version.
if jit then -- LuaJIT
	LUA_JIT_SETLOCAL_WORKAROUND = -1
elseif _VERSION < "Lua 5.1" or _VERSION > "Lua 5.5" then
	dbg_writeln((dbg.COLOR_YELLOW).."debugger.lua: "..(dbg.COLOR_RESET).."Not tested against ".._VERSION)
	dbg_writeln("Please send me feedback!")
end

return dbg
