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
	
	local isatty = get_func_or_nil("isatty") or get_func_or_nil("_isatty") or (ffi.load("ucrtbase"))["_isatty"]
	stdin_isatty = isatty(0)
	stdout_isatty = isatty(1)
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
		dbg_writeln((dbg.COLOR_YELLOW).."debugger.lua: "..(dbg.COLOR_RESET).."Linenoise support enabled.")
	end)
	
	-- Conditionally enable LuaJIT readline support.
	pcall(function()
		if dbg.read == dbg_read and ffi then
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
			dbg_writeln((dbg.COLOR_YELLOW).."debugger.lua: "..(dbg.COLOR_RESET).."Readline support enabled.")
		end
	end)
end
