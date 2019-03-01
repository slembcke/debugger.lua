--[[
	Copyright (c) 2016 Scott Lembcke and Howling Moon Software
	
	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:
	
	The above copyright notice and this permission notice shall be included in
	all copies or substantial portions of the Software.
	
	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
	
	TODO:
	* Print short function arguments as part of stack location.
	* Bug: sometimes doesn't advance to next line (same line event reported multiple times).
	* Do coroutines work as expected?
]]

local dbg

-- Use ANSI color codes in the prompt by default.
local COLOR_RED = ""
local COLOR_BLUE = ""
local COLOR_RESET = ""

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

local help_message = [[
[return] - re-run last command
c(ontinue) - continue execution
s(tep) - step forward by one line (into functions)
n(ext) - step forward by one line (skipping over functions)
f(inish) - step forward until exiting the current function
u(p) - move up the stack by one frame
d(own) - move down the stack by one frame
w(here) [line count] - print source code around the current line
e(val) [statement] - execute the statement
p(rint) [expression] - execute the expression and print the result
t(race) - print the stack trace
l(ocals) - print the function arguments, locals and upvalues.
h(elp) - print this message
q(uit) - halt execution]]

-- The stack level that cmd_* functions use to access locals or info
-- The structure of the code very carefully ensures this.
local CMD_STACK_LEVEL = 6

-- Location of the top of the stack outside of the debugger.
-- Adjusted by some debugger entrypoints.
local stack_top = 0

-- The current stack frame index.
-- Changed using the up/down commands
local stack_inspect_offset = 0

-- Default dbg.read function
local function dbg_read(prompt)
	dbg.write(prompt)
	return io.read()
end

-- Default dbg.write function
local function dbg_write(str)
	io.write(str)
end

local function dbg_writeln(str, ...)
	if select("#", ...) == 0 then
		dbg.write((str or "<NULL>").."\n")
	else
		dbg.write(string.format(str.."\n", ...))
	end
end

local function format_stack_frame_info(info)
	local path = dbg.shorten_path(info.source:sub(2))
	local fname = (info.name or string.format("<%s:%d>", path, info.linedefined))
	return string.format(COLOR_BLUE.."%s:%d"..COLOR_RESET.." in '%s'", path, info.currentline, fname)
end

local repl

-- Return false for stack frames without source,
-- which includes C frames, Lua bytecode, and `loadstring` functions
local function frame_has_line(info) return info.currentline >= 0 end

local function hook_factory(repl_threshold)
	return function(offset)
		return function(event, _)
			-- Skip events that don't have line information.
			if not frame_has_line(debug.getinfo(2)) then return end
			
			-- Tail calls are specifically ignored since they also will have tail returns to balance out.
			if event == "call" then
				offset = offset + 1
			elseif event == "return" and offset > repl_threshold then
				offset = offset - 1
			elseif event == "line" and offset <= repl_threshold then
				repl()
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
			dbg_writeln(COLOR_RED.."<debugger.lua: set local '"..COLOR_BLUE..name..COLOR_RED.."'>"..COLOR_RESET)
			return debug.setlocal(level, i, value)
		end
		i = i + 1
	until var == nil end
	
	-- Set an upvalue.
	local func = debug.getinfo(level).func
	do local i = 1; repeat
		local var = debug.getupvalue(func, i)
		if name == var then
			dbg_writeln(COLOR_RED.."<debugger.lua: set upvalue '"..COLOR_BLUE..name..COLOR_RED.."'>"..COLOR_RESET)
			return debug.setupvalue(func, i, value)
		end
		i = i + 1
	until var == nil end
	
	-- Set a global.
	dbg_writeln(COLOR_RED.."<debugger.lua: set global '"..COLOR_BLUE..name..COLOR_RED.."'>"..COLOR_RESET)
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
	
	if chunk then
		return chunk
	else
		dbg_writeln(COLOR_RED.."Error: Could not compile block:\n"..COLOR_RESET..block)
		return nil
	end
end

local SOURCE_CACHE = {["<unknown filename>"] = {}}

function where(info, context_lines)
	local key = info.source or "<unknown filename>"
	local source = SOURCE_CACHE[key]
	
	if not source then
		source = {}
		local filename = info.source:match("@(.*)")
		if filename then
			pcall(function() for line in io.lines(filename) do table.insert(source, line) end end)
		else
			for line in info.source:gmatch("(.-)\n") do table.insert(source, line) end
		end
		
		SOURCE_CACHE[key] = source
	end
	
	if source[info.currentline] then
		for i = info.currentline - context_lines, info.currentline + context_lines do
			local caret = (i == info.currentline and " => " or "    ")
			local line = source[i]
			if line then dbg_writeln(COLOR_BLUE.."%d"..COLOR_RED.."%s"..COLOR_RESET.."%s", i, caret, line) end
		end
	else
		dbg_writeln(COLOR_RED.."Error: Source file '%s' not found.", info.source);
	end
	
	return false
end

-- Wee version differences
local unpack = unpack or table.unpack
local pack = function(...) return {n = select("#", ...), ...} end

function cmd_step()
	stack_inspect_offset = stack_top
	return true, hook_step
end

function cmd_next()
	stack_inspect_offset = stack_top
	return true, hook_next
end

function cmd_finish()
	local offset = stack_top - stack_inspect_offset
	stack_inspect_offset = stack_top
	return true, offset < 0 and hook_factory(offset - 1) or hook_finish
end

local function cmd_print(expr)
	local env = local_bindings(1, true)
	local chunk = compile_chunk("return "..expr, env)
	if chunk == nil then return false end
	
	-- Call the chunk and collect the results.
	local results = pack(pcall(chunk, unpack(rawget(env, "...") or {})))
	
	-- The first result is the pcall error.
	if not results[1] then
		dbg_writeln(COLOR_RED.."Error:"..COLOR_RESET.." %s", results[2])
	else
		local output = ""
		for i = 2, results.n do
			output = output..(i ~= 2 and ", " or "")..pretty(results[i])
		end
		
		if output == "" then output = "<no result>" end
		dbg_writeln(COLOR_BLUE..expr..COLOR_RED.." => "..COLOR_RESET..output)
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
		dbg_writeln(COLOR_RED.."Error:"..COLOR_RESET.." %s", err)
	end
	
	return false
end

local function cmd_up()
	local offset = stack_inspect_offset
	local info
	
	repeat -- Find the next frame with a file.
		offset = offset + 1
		info = debug.getinfo(offset + CMD_STACK_LEVEL)
	until not info or frame_has_line(info)
	
	if info then
		stack_inspect_offset = offset
	else
		info = debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL)
		dbg_writeln(COLOR_BLUE.."Already at the top of the stack."..COLOR_RESET)
	end
	
	dbg_writeln("Inspecting frame: "..format_stack_frame_info(info))
	if tonumber(dbg.auto_where) then where(info, dbg.auto_where) end
	
	return false
end

local function cmd_down()
	local offset = stack_inspect_offset
	local info
	
	repeat -- Find the next frame with a file.
		offset = offset - 1
		if offset < stack_top then info = nil; break end
		info = debug.getinfo(offset + CMD_STACK_LEVEL)
	until frame_has_line(info)
	
	if info then
		stack_inspect_offset = offset
	else
		info = debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL)
		dbg_writeln(COLOR_BLUE.."Already at the bottom of the stack."..COLOR_RESET)
	end
	
	dbg_writeln("Inspecting frame: "..format_stack_frame_info(info))
	if tonumber(dbg.auto_where) then where(info, dbg.auto_where) end
	
	return false
end

local function cmd_where(context_lines)
	local info = debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL)
	return (info and where(info, tonumber(context_lines) or 5))
end

local function cmd_trace()
	local location = format_stack_frame_info(debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL))
	local message = string.format("Inspecting frame: %d - (%s)", stack_inspect_offset - stack_top, location)
	local str = debug.traceback(message, stack_top + CMD_STACK_LEVEL)
	
	-- Iterate the lines of the stack trace so we can number/highlight them.
	local i = -2
	for line in str:gmatch("([^\n]+)\n?") do
		if i >= 0 then line = tostring(i)..line end
		dbg_writeln((i + stack_top == stack_inspect_offset) and COLOR_BLUE..line..COLOR_RESET or line)
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
			dbg_writeln("\t"..COLOR_BLUE.."%s "..COLOR_RED.."=>"..COLOR_RESET.." %s", k, pretty(v))
		end
	end
	
	return false
end

local last_cmd = false

local function match_command(line)
	local commands = {
		["c"] = function() return true end,
		["s"] = cmd_step,
		["n"] = cmd_next,
		["f"] = cmd_finish,
		["p (.*)"] = cmd_print,
		["e (.*)"] = cmd_eval,
		["u"] = cmd_up,
		["d"] = cmd_down,
		["w ?(%d*)"] = cmd_where,
		["t"] = cmd_trace,
		["l"] = cmd_locals,
		["h"] = function() dbg_writeln(help_message); return false end,
		["q"] = function() dbg.exit(0); return true end,
	}
	
	for cmd, cmd_func in pairs(commands) do
		local matches = {line:match("^("..cmd..")$")}
		if matches[1] then return cmd_func, select(2, unpack(matches)) end
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
	end
	
	if #line == 1 then
		dbg_writeln(COLOR_RED.."Error:"..COLOR_RESET.." command '%s' not recognized.\nType 'h' and press return for a command list.", line)
		return false
	end
end

repl = function()
	-- Skip frames without source info.
	while not frame_has_line(debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL - 3)) do
		stack_inspect_offset = stack_inspect_offset + 1
	end
	
	local info = debug.getinfo(stack_inspect_offset + CMD_STACK_LEVEL - 3)
	dbg_writeln(format_stack_frame_info(info))
	
	if tonumber(dbg.auto_where) then where(info, dbg.auto_where) end
	
	repeat
		local success, done, hook = pcall(run_command, dbg.read(COLOR_RED.."debugger.lua> "..COLOR_RESET))
		if success then
			debug.sethook(hook and hook(0), "crl")
		else
			local message = string.format(COLOR_RED.."INTERNAL DEBUGGER.LUA ERROR. ABORTING\n:"..COLOR_RESET.." %s", done)
			dbg_writeln(message)
			error(message)
		end
	until done
end

-- Make the debugger object callable like a function.
dbg = setmetatable({}, {
	__call = function(self, condition, top_offset)
		if condition then return end
		
		top_offset = (top_offset or 0)
		stack_inspect_offset = top_offset
		stack_top = top_offset
		
		debug.sethook(hook_next(1), "crl")
		return
	end,
})

-- Expose the debugger's IO functions.
dbg.read = dbg_read
dbg.write = dbg_write
dbg.shorten_path = function (path) return path end
dbg.exit = function(err) os.exit(err) end

dbg.writeln = dbg_writeln

dbg.pretty_depth = 3
dbg.pretty = pretty
dbg.pp = function(value, depth) dbg_writeln(pretty(value, depth)) end

dbg.auto_where = false

-- Works like error(), but invokes the debugger.
function dbg.error(err, level)
	level = level or 1
	dbg_writeln(COLOR_RED.."Debugger stopped on error:"..COLOR_RESET.."(%s)", pretty(err))
	dbg(false, level)
	
	error(err, level)
end

-- Works like assert(), but invokes the debugger on a failure.
function dbg.assert(condition, message)
	if not condition then
		dbg_writeln(COLOR_RED.."Debugger stopped on "..COLOR_RESET.."assert(..., %s)", message)
		dbg(false, 1)
	end
	
	assert(condition, message)
end

-- Works like pcall(), but invokes the debugger on an error.
function dbg.call(f, ...)
	return xpcall(f, function(err)
		dbg_writeln(COLOR_RED.."Debugger stopped on error: "..COLOR_RESET..pretty(err))
		dbg(false, 1)
		
		return err
	end, ...)
end

-- Error message handler that can be used with lua_pcall().
function dbg.msgh(...)
	dbg.write(...)
	dbg(false, 1)
	
	return ...
end

-- Detect Lua version.
if jit then -- LuaJIT
	dbg_writeln(COLOR_RED.."debugger.lua: Loaded for "..jit.version..COLOR_RESET)
elseif "Lua 5.1" <= _VERSION and _VERSION <= "Lua 5.3" then
	dbg_writeln(COLOR_RED.."debugger.lua: Loaded for ".._VERSION..COLOR_RESET)
else
	dbg_writeln(COLOR_RED.."debugger.lua: Not tested against ".._VERSION..COLOR_RESET)
	dbg_writeln(COLOR_RED.."Please send me feedback!"..COLOR_RESET)
end

-- Assume stdin/out are TTYs unless we can use LuaJIT's FFI to properly check them.
local stdin_isatty = true
local stdout_isatty = true

-- Conditionally enable the LuaJIT FFI.
local ffi = (jit and require("ffi"))
if ffi then
	ffi.cdef[[
		int isatty(int); // Unix
		int _isatty(int); // Windows
		void free(void *ptr);
		
		char *readline(const char *);
		int add_history(const char *);
	]]
	
	local function get_func_or_nil(sym)
		local success, func = pcall(function() return ffi.C[sym] end)
		return success and func or nil
	end
	
	local isatty = get_func_or_nil("isatty") or get_func_or_nil("_isatty")
	stdin_isatty = isatty(0)
	stdout_isatty = isatty(1)
end

-- Conditionally enable color support.
local color_maybe_supported = (stdout_isatty and os.getenv("TERM") and os.getenv("TERM") ~= "dumb")
if color_maybe_supported and not os.getenv("DBG_NOCOLOR") then
	COLOR_RED = string.char(27) .. "[31m"
	COLOR_BLUE = string.char(27) .. "[34m"
	COLOR_RESET = string.char(27) .. "[0m"
end

if stdin_isatty and not os.getenv("DBG_NOREADLINE") then
	pcall(function()
		local linenoise = require 'linenoise'
		
		-- Load command history from ~/.lua_history
		local hist_path = os.getenv('HOME') .. '/.lua_history'
		linenoise.historyload(hist_path)
		linenoise.historysetmaxlen(50)
		
		local function autocomplete(env, input, matches)
			for name, _ in pairs(env) do
				if name:match('^' .. input .. '.*') then
					linenoise.addcompletion(matches, name)
				end
			end
		end
		
		-- Auto-completion for locals and globals
		linenoise.setcompletion(function(matches, input)
			-- First, check the locals and upvalues.
			local env = local_bindings(1, true)
			autocomplete(env, input, matches)
			
			-- Then, check the implicit environment.
			env = getmetatable(env).__index
			autocomplete(env, input, matches)
		end)
		
		dbg.read = function(prompt)
			local str = linenoise.linenoise(prompt)
			if str and not str:match "^%s*$" then
				linenoise.historyadd(str)
				linenoise.historysave(hist_path)
			end
			return str
		end
		dbg_writeln(COLOR_RED.."debugger.lua: Linenoise support enabled."..COLOR_RESET)
	end)
	
	-- Conditionally enable LuaJIT readline support.
	pcall(function()
		if dbg.read == nil and ffi then
			local readline = ffi.load("readline")
			dbg.read = function(prompt)
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
			dbg_writeln(COLOR_RED.."debugger.lua: Readline support enabled."..COLOR_RESET)
		end
	end)
end

return dbg
