--[[
	TODO:
	print short function arguments as part of stack location
	bug: sometimes doesn't advance to next line (same line event reported multiple times)
	do coroutines work as expected?
]]

local function pretty(obj, non_recursive)
	if type(obj) == "string" then
		return string.format("%q", obj)
	elseif type(obj) == "table" and not non_recursive then
		local str = "{"
		
		for k, v in pairs(obj) do
			local pair = pretty(k, true).." = "..pretty(v, true)
			str = str..(str == "{" and pair or ", "..pair)
		end
		
		return str.."}"
	else
		return tostring(obj)
	end
end

local help_message = [[
[return] - re-run last command
c(ontinue) - contiue execution
s(tep) - step forward by one line (into functions)
n(ext) - step forward by one line (skipping over functions)
p(rint) [expression] - execute the expression and print the result
f(inish) - step forward until exiting the current function
u(p) - move up the stack by one frame
d(own) - move down the stack by one frame
t(race) - print the stack trace
l(ocals) - print the function arguments, locals and upvalues.
h(elp) - print this message
]]

-- The stack level that cmd_* functions use to access locals or info
local LOCAL_STACK_LEVEL = 6

-- Extra stack frames to chop off.
-- Used for things like dbgcall() or the overridden assert/error functions
local stack_top = 0

-- The current stack frame index.
-- Changed using the up/down commands
local stack_offset = 0

-- Override if you don't want to use stdin
-- Override if you don't want to use stdout.
local function dbg_write(str, ...)
	io.write(string.format(str, ...))
end

local function dbg_writeln(str, ...)
	dbg_write((str or "").."\n", ...)
end

local function dbg_read(prompt)
	dbg_write(prompt)
	return io.read()
end

local function formatStackLocation(info)
	local fname = (info.name or string.format("<%s:%d>", info.short_src, info.linedefined))
	return string.format("%s:%d in function '%s'", info.short_src, info.currentline, fname)
end

local repl

local function hook_factory(repl_threshold)
	return function(offset)
		return function(event, line)
			local info = debug.getinfo(2)
			
			if event == "call" and info.linedefined >= 0 then
				offset = offset + 1
			elseif event == "return" and info.linedefined >= 0 then
				if offset <= repl_threshold then
					-- TODO this is what causes the duplicated lines
					-- Don't remember why this is even here...
					--repl()
				else
					offset = offset - 1
				end
			elseif event == "line" and offset <= repl_threshold then
				repl()
			end
		end
	end
end

local hook_step = hook_factory(1)
local hook_next = hook_factory(0)
local hook_finish = hook_factory(-1)

local function table_merge(t1, t2)
	local tbl = {}
	for k, v in pairs(t1) do tbl[k] = v end
	for k, v in pairs(t2) do tbl[k] = v end
	
	return tbl
end

local VARARG_SENTINEL = "(*varargs)"

local function local_bindings(offset, include_globals)
	--[[ TODO
		Need to figure out how to get varargs with LuaJIT
	]]
	
	local level = stack_offset + offset + LOCAL_STACK_LEVEL
	local func = debug.getinfo(level).func
	local bindings = {}
	
	-- Retrieve the upvalues
	do local i = 1; repeat
		local name, value = debug.getupvalue(func, i)
		if name then bindings[name] = value end
		i = i + 1
	until name == nil end
	
	-- Retrieve the locals (overwriting any upvalues)
	do local i = 1; repeat
		local name, value = debug.getlocal(level, i)
		if name then bindings[name] = value end
		i = i + 1
	until name == nil end
	
	-- Retrieve the varargs. (only works in Lua 5.2)
	local varargs = {}
	do local i = -1; repeat
		local name, value = debug.getlocal(level, i)
		table.insert(varargs, value)
		i = i - 1
	until name == nil end
	bindings[VARARG_SENTINEL] = varargs
	
	if include_globals then
		-- Merge the local bindings over the top of the environment table.
		-- In Lua 5.2, you have to get the environment table from the function's locals.
		local env = (_VERSION <= "Lua 5.1" and getfenv(func) or bindings._ENV)
		
		-- Finally, merge the tables and add a lookup for globals.
		return setmetatable(table_merge(env, bindings), {__index = _G})
	else
		return bindings
	end
end

local function compile_chunk(expr, env)
	if _VERSION <= "Lua 5.1" then
		local chunk = loadstring("return "..expr, "<debugger repl>")
		if chunk then setfenv(chunk, env) end
		return chunk
	else
		-- The Lua 5.2 way is a bit cleaner
		return load("return "..expr, "<debugger repl>", "t", env)
	end
end

local function super_pack(...)
	return select("#", ...), {...}
end

local function cmd_print(expr)
	local env = local_bindings(1, true)
	local chunk = compile_chunk(expr, env)
	if chunk == nil then
		dbg_writeln("Error: Could not evaluate expression.")
		return false
	end
	
	local count, results = super_pack(pcall(chunk, unpack(env[VARARG_SENTINEL])))
	if not results[1] then
		dbg_writeln("Error: %s", results[2])
	elseif count == 1 then
		dbg_writeln("Error: No expression to execute")
	else
		local result = ""
		for i=2, count do
			result = result..(i ~= 2 and ", " or "")..pretty(results[i])
		end
		
		dbg_writeln(expr.." => "..result)
	end
	
	return false
end

local function cmd_up()
	local info = debug.getinfo(stack_offset + LOCAL_STACK_LEVEL + 1)
	
	if info then
		stack_offset = stack_offset + 1
		dbg_writeln("Inspecting frame: "..formatStackLocation(info))
	else
		dbg_writeln("Error: Already at the top of the stack.")
	end
	
	return false
end

local function cmd_down()
	if stack_offset > stack_top then
		stack_offset = stack_offset - 1
		
		local info = debug.getinfo(stack_offset + LOCAL_STACK_LEVEL)
		dbg_writeln("Inspecting frame: "..formatStackLocation(info))
	else
		dbg_writeln("Error: Already at the bottom of the stack.")
	end
	
	return false
end

local function cmd_trace()
	local location = formatStackLocation(debug.getinfo(stack_offset + LOCAL_STACK_LEVEL))
	local offset = stack_offset - stack_top
	local message = string.format("Inspecting frame: %d - (%s)", offset, location)
	dbg_writeln(debug.traceback(message, stack_offset + LOCAL_STACK_LEVEL))
	
	return false
end

local function cmd_locals()
	for k, v in pairs(local_bindings(1, false)) do
		-- Don't print the Lua 5.2 __ENV local. It's pretty huge and useless to see.
		if k ~= "_ENV" then
			dbg_writeln("\t%s => %s", k, pretty(v))
		end
	end
	
	return false
end

local function cmd_help()
	dbg_writeln(help_message)
	return false
end

local last_cmd = false

-- Run a command line
-- Returns true if the REPL should exit and the hook function factory
local function run_command(line)
	-- Continue without caching the command if you hit control-d.
	if line == nil then
		dbg_writeln()
		return true
	end
	
	-- Execute the previous command or cache it
	if line == "" then
		if last_cmd then return unpack({run_command(last_cmd)}) else return false end
	else
		last_cmd = line
	end
	
	local commands = {
		["c"] = function() return true end,
		["s"] = function() return true, hook_step end,
		["n"] = function() return true, hook_next end,
		["f"] = function() return true, hook_finish end,
		["p%s?(.*)"] = cmd_print,
		["u"] = cmd_up,
		["d"] = cmd_down,
		["t"] = cmd_trace,
		["l"] = cmd_locals,
		["h"] = cmd_help,
	}
	
	for cmd, cmd_func in pairs(commands) do
		local matches = {string.match(line, "^("..cmd..")$")}
		if matches[1] then
			return unpack({cmd_func(select(2, unpack(matches)))})
		end
	end
	
	dbg_writeln("Error: command '%s' not recognized", line)
	return false
end

repl = function()
	dbg_writeln(formatStackLocation(debug.getinfo(LOCAL_STACK_LEVEL - 3 + stack_top)))
	
	repeat
		local success, done, hook = pcall(run_command, dbg_read("debugger.lua> "))
		if success then
			debug.sethook(hook and hook(0), "crl")
		else
			local message = string.format("INTERNAL DEBUGGER.LUA ERROR. ABORTING\n: %s", done)
			dbg_writeln(message)
			error(message)
		end
	until done
end

local dbg = setmetatable({}, {
	__call = function(self, condition, offset)
		if condition then return end
		
		offset = (offset or 0)
		stack_offset = offset
		stack_top = offset
		
		debug.sethook(hook_next(1), "crl")
		return
	end,
})

dbg.write = dbg_write
dbg.writeln = dbg_writeln
dbg.pretty = pretty

function dbg.error(err, level)
	level = level or 1
	dbg_writeln("Debugger stopped on error(%s)", pretty(err))
	dbg(false, level)
	error(err, level)
end

function dbg.assert(condition, message)
	if not condition then
		dbg_writeln("Debugger stopped on assert(..., %s)", message)
		dbg(false, 1)
	end
	assert(condition, message)
end

function dbg.call(f, l)
	return (xpcall(f, function(err)
		dbg_writeln("Debugger stopped on error: "..pretty(err))
		dbg(false, (l or 0) + 1)
		return
	end))
end

local function luajit_load_readline_support()
	local ffi = require("ffi")
	
	ffi.cdef[[
		void free(void *ptr);
		
		char *readline(const char *);
		int add_history(const char *);
	]]
	
	local readline = ffi.load("readline")
	
	dbg_read = function(prompt)
		local cstr = readline.readline(prompt)
		
		if cstr ~= nil then
			local str = ffi.string(cstr)
			
			if string.match(str, "[^%s]+") then
				readline.add_history(cstr)
			end
			
			ffi.C.free(cstr)
			return str
		else
			return nil
		end
	end
	
	dbg_writeln("Readline support loaded.")
end

if jit and
	jit.version == "LuaJIT 2.0.0-beta10"
then
	dbg_writeln("debugger.lua loaded for "..jit.version)
	pcall(luajit_load_readline_support)
elseif
	 _VERSION == "Lua 5.2" or
	 _VERSION == "Lua 5.1"	 
then
	dbg_writeln("debugger.lua loaded for ".._VERSION)
else
	dbg_writeln("debugger.lua not tested against ".._VERSION)
	dbg_writeln("Please send me feedback!")
end

return dbg
