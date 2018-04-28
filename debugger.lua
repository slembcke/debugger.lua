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


-- Use ANSI color codes in the prompt by default.
local COLOR_RED = ""
local COLOR_BLUE = ""
local COLOR_GRAY = ""
local COLOR_RESET = ""

local function pretty(obj, max_depth)
	if max_depth == nil then max_depth = 1 end

	-- Returns true if a table has a __tostring metamethod.
	local function coerceable(tbl)
		local meta = getmetatable(tbl)
		return (meta and meta.__tostring)
	end

	local depth = 1
	local function recurse(obj)
		if type(obj) == "string" then
			-- Dump the string so that escape sequences are printed.
			return string.format("%q", obj)
		elseif type(obj) == "table" and not coerceable(obj) then
			if pairs(obj)(obj) == nil then
				return '{}' -- Always print empty tables.
			end
			if depth > max_depth then
				return tostring(obj)
			end

			local str = "{"
			depth = depth + 1

			for k, v in pairs(obj) do
				local pair = pretty(k, 0).." = "..recurse(v)
				str = str..(str == "{" and pair or ", "..pair)
			end

			depth = depth - 1
			return str.."}"
		else
			-- tostring() can fail if there is an error in a __tostring metamethod.
			local success, value = pcall(function() return tostring(obj) end)
			return (success and value or "<!!error in __tostring metamethod!!>")
		end
	end

	return recurse(obj)
end

local help_message = [[
[return] - re-run last command
c(ontinue) - continue execution
s(tep) - step forward by one line (into functions)
n(ext) - step forward by one line (skipping over functions)
f(inish) - step forward until exiting the inspected frame
u(p) - inspect the next frame up the stack
d(own) - inspect the next frame down the stack
p(rint) [expression] - execute the expression and print the result
e(val) [statement] - execute the statement
t(race) - print the stack trace
l(ocals) - print the function arguments, locals and upvalues.
h(elp) - print this message
q(uit) - halt execution]]

-- The stack level that cmd_* functions use to access locals or info
-- The structure of the code very carefully ensures this.
local LOCAL_STACK_LEVEL = 6

-- Extra stack frames to chop off.
-- Used for things like dbgcall() or the overridden assert/error functions
local stack_top = 0

-- The current stack frame index.
-- Changed using the up/down commands
local stack_offset = 0

local dbg

-- Default dbg.read function
local function dbg_read(prompt)
	dbg.write(prompt)
	return io.read()
end

-- Default dbg.write function
local function dbg_write(str, ...)
	if select("#", ...) == 0 then
		io.write(str or "<NULL>")
	else
		io.write(string.format(str, ...))
	end
end

-- Default dbg.writeln function.
local function dbg_writeln(str, ...)
	dbg.write((str or "").."\n", ...)
end

local cwd = '^' .. os.getenv('PWD') .. '/'
local home = '^' .. os.getenv('HOME') .. '/'
local function format_stack_frame_info(info)
	local path = info.source:sub(2)
	path = path:gsub(cwd, './'):gsub(home, '~/')
	if #path > 50 then
		path = '...' .. path:sub(-47)
	end
	local fname = (info.name or string.format("<%s:%d>", path, info.linedefined))
	return string.format(COLOR_BLUE.."%s:%d"..COLOR_RESET.." in '%s'", path, info.currentline, fname)
end

local repl

-- Return false for stack frames without a source file,
-- which includes C frames and pre-compiled Lua bytecode.
local function frame_has_file(info)
	return info.what == "main" or info.source:match("^@[%.%/]") ~= nil
end

local function hook_factory(repl_threshold)
	return function(offset)
		return function(event, _)
			local info = debug.getinfo(2)
			local has_file = frame_has_file(info)
			
			if event == "call" and has_file then
				offset = offset + 1
			elseif event == "return" and has_file then
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

local function local_bind(offset, name, value)
	local level = stack_offset + offset + LOCAL_STACK_LEVEL

	-- Mutating a local?
	do local i = 1; repeat
		local var = debug.getlocal(level, i)
		if name == var then
			return debug.setlocal(level, i, value)
		end
		i = i + 1
	until var == nil end

	-- Mutating an upvalue?
	local func = debug.getinfo(level).func
	do local i = 1; repeat
		local var = debug.getupvalue(func, i)
		if name == var then
			return debug.setupvalue(func, i, value)
		end
		i = i + 1
	until var == nil end

	dbg.writeln(COLOR_RED.."Error: "..COLOR_RESET.."Unknown local variable: "..name)
end

-- Create a table of all the locally accessible variables.
-- Globals are not included when running the locals command, but are when running the print command.
local function local_bindings(offset, include_globals)
	local level = stack_offset + offset + LOCAL_STACK_LEVEL
	local func = debug.getinfo(level).func
	local bindings = {}
	local i

	-- Retrieve the upvalues
	i = 1; while true do
		local name, value = debug.getupvalue(func, i)
		if not name then break end
		bindings[name] = value
		i = i + 1
	end

	-- Retrieve the locals (overwriting any upvalues)
	i = 1; while true do
		local name, value = debug.getlocal(level, i)
		if not name then break end
		bindings[name] = value
		i = i + 1
	end

	-- Retrieve the varargs (works in Lua 5.2 and LuaJIT)
	local varargs = {}
	i = 1; while true do
		local name, value = debug.getlocal(level, -i)
		if not name then break end
		varargs[i] = value
		i = i + 1
	end
	if i > 1 then bindings["..."] = varargs end

	if include_globals then
		-- In Lua 5.2, you have to get the environment table from the function's locals.
		local env = (_VERSION <= "Lua 5.1" and getfenv(func) or bindings._ENV)
		return setmetatable(bindings, {__index = env or _G})
	else
		return bindings
	end
end --189

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
		dbg.writeln(COLOR_RED.."Error: Could not compile block:\n"..COLOR_RESET..block)
		return nil
	end
end

-- Wee version differences
local unpack = unpack or table.unpack
local pack = table.pack or function(...)
	return {n = select("#", ...), ...}
end

function cmd_step()
	stack_offset = stack_top
	return true, hook_step
end

function cmd_next()
	stack_offset = stack_top
	return true, hook_next
end

function cmd_finish()
	local offset = stack_top - stack_offset
	stack_offset = stack_top
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
		dbg.writeln(COLOR_RED.."Error:"..COLOR_RESET.." %s", results[2])
	else
		local output = ""
		for i = 2, results.n do
			output = output..(i ~= 2 and ", " or "")..pretty(results[i], 3)
		end
		if output == "" then
			output = COLOR_GRAY.."<no result>"
		end
		dbg.writeln(COLOR_BLUE..expr..COLOR_RED.." => "..COLOR_RESET..output)
	end
	
	return false
end

local function cmd_eval(code)
	local index = local_bindings(1, true)
	local env = setmetatable({}, {
		__index = index,
		__newindex = function(env, name, value)
			local_bind(4, name, value)
		end
	})

	local chunk = compile_chunk(code, env)
	if chunk == nil then return false end

	-- Call the chunk and collect the results.
	local success, err = pcall(chunk, unpack(rawget(index, "...") or {}))
	if success then
		-- Look for assigned variable names.
		local names = code:match("^([^{=]+)%s?=[^=]")
		if names then
			stack_offset = stack_offset + 1
			cmd_print(names)
			stack_offset = stack_offset - 1
		end
	else
		dbg.writeln(COLOR_RED.."Error:"..COLOR_RESET.." %s", err)
	end
end

local function cmd_up()
	local offset = stack_offset
	local info
	repeat -- Find the next frame with a file.
		offset = offset + 1
		info = debug.getinfo(offset + LOCAL_STACK_LEVEL)
	until not info or frame_has_file(info)

	if info then
		stack_offset = offset
	else
		info = debug.getinfo(stack_offset + LOCAL_STACK_LEVEL)
		dbg.writeln(COLOR_BLUE.."Already at the top of the stack."..COLOR_RESET)
	end

	dbg.writeln("Inspecting frame: "..format_stack_frame_info(info))
	return false
end

local function cmd_down()
	local offset = stack_offset
	local info
	repeat -- Find the next frame with a file.
		offset = offset - 1
		if offset < stack_top then info = nil; break end
		info = debug.getinfo(offset + LOCAL_STACK_LEVEL)
	until frame_has_file(info)

	if info then
		stack_offset = offset
	else
		info = debug.getinfo(stack_offset + LOCAL_STACK_LEVEL)
		dbg.writeln(COLOR_BLUE.."Already at the bottom of the stack."..COLOR_RESET)
	end

	dbg.writeln("Inspecting frame: "..format_stack_frame_info(info))
	return false
end

local function cmd_trace()
	local location = format_stack_frame_info(debug.getinfo(stack_offset + LOCAL_STACK_LEVEL))
	local offset = stack_offset - stack_top
	local message = string.format("Inspecting frame: %d - (%s)", offset, location)
	local str = debug.traceback(message, stack_top + LOCAL_STACK_LEVEL)
	
	-- Iterate the lines of the stack trace so we can highlight the current one.
	local line_num = -2
	while str and #str ~= 0 do
		local line, rest = string.match(str, "([^\n]*)\n?(.*)")
		str = rest
		
		if line_num >= 0 then line = tostring(line_num)..line end
		dbg.writeln((line_num + stack_top == stack_offset) and COLOR_BLUE..line..COLOR_RESET or line)
		line_num = line_num + 1
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
		
		-- Skip the debugger object itself, temporaries and Lua 5.2's _ENV object.
		if not rawequal(v, dbg) and k ~= "_ENV" and k ~= "(*temporary)" then
			dbg.writeln("\t"..COLOR_BLUE.."%s "..COLOR_RED.."=>"..COLOR_RESET.." %s", k, pretty(v, 0))
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
		["t"] = cmd_trace,
		["l"] = cmd_locals,
		["h"] = function() dbg.writeln(help_message); return false end,
		["q"] = function() os.exit(0) end,
	}
	
	for cmd, cmd_func in pairs(commands) do
		local matches = {string.match(line, "^("..cmd..")$")}
		if matches[1] then
			return cmd_func, select(2, unpack(matches))
		end
	end
end

-- Try loading a chunk with a leading return.
local function is_expression(block)
	if _VERSION <= "Lua 5.1" then
		return loadstring("return "..block, "") ~= nil
	end
	return load("return "..block, "", "t") ~= nil
end

-- Run a command line
-- Returns true if the REPL should exit and the hook function factory
local function run_command(line)
	-- Continue without caching the command if you hit control-d.
	if line == nil then
		dbg.writeln()
		return true
	end

	-- Re-execute the last command if you press return.
	if line == "" then
		line = last_cmd or "h"
	end

	local command, command_arg = match_command(line)
	if command then
		-- Some commands are not worth repeating.
		if not line:match("^[hlt]$") then
			last_cmd = line
		end
		-- unpack({...}) prevents tail call elimination so the stack frame indices are predictable.
		return unpack({command(command_arg)})
	end

	if #line == 1 then
		dbg.writeln(COLOR_RED.."Error:"..COLOR_RESET.." command '%s' not recognized.\nType 'h' and press return for a command list.", line)
		return false
	end

	-- Evaluate the chunk appropriately.
	if is_expression(line) then cmd_print(line) else cmd_eval(line) end
end

repl = function()
	dbg.writeln(format_stack_frame_info(debug.getinfo(LOCAL_STACK_LEVEL - 3 + stack_top)))
	
	repeat
		local success, done, hook = pcall(run_command, dbg.read(COLOR_RED.."debugger.lua> "..COLOR_RESET))
		if success then
			debug.sethook(hook and hook(0), "crl")
		else
			local message = string.format(COLOR_RED.."INTERNAL DEBUGGER.LUA ERROR. ABORTING\n:"..COLOR_RESET.." %s", done)
			dbg.writeln(message)
			error(message)
		end
	until done
end

-- Make the debugger object callable like a function.
dbg = setmetatable({}, {
	__call = function(self, condition, offset)
		if condition then return end
		
		offset = (offset or 0)
		stack_offset = offset
		stack_top = offset
		
		debug.sethook(hook_next(1), "crl")
		return
	end,
})

-- Expose the debugger's IO functions.
dbg.read = dbg_read
dbg.write = dbg_write
dbg.writeln = dbg_writeln
dbg.pretty = pretty

-- Works like error(), but invokes the debugger.
function dbg.error(err, level)
	level = level or 1
	dbg.writeln(COLOR_RED.."Debugger stopped on error:"..COLOR_RESET.."(%s)", pretty(err))
	dbg(false, level)
	
	error(err, level)
end

-- Works like assert(), but invokes the debugger on a failure.
function dbg.assert(condition, message)
	if not condition then
		dbg.writeln(COLOR_RED.."Debugger stopped on "..COLOR_RESET.."assert(..., %s)", message)
		dbg(false, 1)
	end
	
	assert(condition, message)
end

-- Works like pcall(), but invokes the debugger on an error.
function dbg.call(f, ...)
	local catch = function(err)
		dbg.writeln(COLOR_RED.."Debugger stopped on error: "..COLOR_RESET..pretty(err))
		dbg(false, 2)

		return err
	end
	if select('#', ...) > 0 then
		local args = {...}
		return xpcall(function()
			return f(unpack(args))
		end, catch)
	end
	return xpcall(f, catch)
end

-- Error message handler that can be used with lua_pcall().
function dbg.msgh(...)
	dbg.write(...)
	dbg(false, 1)
	
	return ...
end

-- Detect Lua version.
if jit then -- LuaJIT
	dbg.writeln(COLOR_RED.."debugger.lua: Loaded for "..jit.version..COLOR_RESET)
elseif "Lua 5.1" <= _VERSION and _VERSION <= "Lua 5.3" then
	dbg.writeln(COLOR_RED.."debugger.lua: Loaded for ".._VERSION..COLOR_RESET)
else
	dbg.writeln(COLOR_RED.."debugger.lua: Not tested against ".._VERSION..COLOR_RESET)
	dbg.writeln(COLOR_RED.."Please send me feedback!"..COLOR_RESET)
end

-- Assume stdin/out are TTYs unless we can use LuaJIT's FFI to properly check them.
local stdin_isatty = true
local stdout_isatty = true

-- Conditionally enable the LuaJIT FFI.
local ffi = (jit and require("ffi"))
if ffi then
	ffi.cdef[[
		bool isatty(int);
		void free(void *ptr);
		
		char *readline(const char *);
		int add_history(const char *);
	]]
	
	stdin_isatty = ffi.C.isatty(0)
	stdout_isatty = ffi.C.isatty(1)
end

-- Conditionally enable color support.
local color_maybe_supported = (stdout_isatty and os.getenv("TERM") and os.getenv("TERM") ~= "dumb")
if color_maybe_supported and not os.getenv("DBG_NOCOLOR") then
	COLOR_RED = string.char(27) .. "[31m"
	COLOR_BLUE = string.char(27) .. "[34m"
	COLOR_GRAY = string.char(27) .. "[38;5;59m"
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
		dbg.writeln(COLOR_RED.."debugger.lua: Linenoise support enabled."..COLOR_RESET)
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
			dbg.writeln(COLOR_RED.."debugger.lua: Readline support enabled."..COLOR_RESET)
		end
	end)
end

return dbg
