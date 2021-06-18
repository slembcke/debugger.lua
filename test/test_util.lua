package.path = package.path .. ";../?.lua"

-- Hack to disable color support
local getenv = os.getenv
os.getenv = function(sym) return (sym == "TERM") and "dumb" or getenv(sym) end

-- Do color test output
COLOR_RED = string.char(27) .. "[31m"
COLOR_GREEN = string.char(27) .. "[32m"
COLOR_RESET = string.char(27) .. "[0m"
local function print_red(str) print(COLOR_RED..str..COLOR_RESET) end
local function print_green(str) print(COLOR_GREEN..str..COLOR_RESET) end

local dbg = require("debugger");
local dbg_read = dbg.read
local dbg_write = dbg.write

-- The global Lua versions will be overwritten in some tests.
local lua_assert = assert
local lua_error = error

local LOG_IO = false

function string.strip(str) return str:match("^%s*(.-)%s*$") end

local module = {}

-- Debugger command line string to run next.
local commands = {}
local function cmd(str) table.insert(commands, str) end

dbg.read = function(prompt)
	local str = table.remove(commands, 1)
	lua_assert(str, COLOR_RED.."Command not set!"..COLOR_RESET)
	
	if LOG_IO then print(prompt..str) end
	return str
end

local function sanity_write(str)
	print_red "ERROR: dbg.write called unexpectedly?!"
	if LOG_IO then print(str) end
end

local function expect(str, cmd)
	local str2 = coroutine.yield():strip()
	if LOG_IO then print(str2) end
	if str ~= str2 then
		print_red("FAILURE (expect)")
		print("expected: "..str)
		print("got     : "..str2)
	end
end

local function expect_match(pattern, cmd)
	pattern = "^"..pattern.."$"
	
	local str = coroutine.yield():strip()
	if LOG_IO then print(str2) end
	if not str:match(pattern) then
		print_red("FAILURE (expect_match)")
		print("expected: "..pattern)
		print("got     : "..str)
	end
end

-- Used for setting up new tests.
local function show()
	print("expect \""..coroutine.yield():strip().."\"")
end

local function ignore()
	local str = coroutine.yield():strip()
	if LOG_IO then print(str) end
end

function module.repl(_, test_body)
	dbg.read = dbg_read
	dbg.write = dbg_write
	test_body()
end

function module.run_test(test, test_body)
	local coro = coroutine.create(test)
	coroutine.resume(coro)
	
	dbg.write = function(str) coroutine.resume(coro, str) end
	test_body()
	dbg.write = sanity_write
	
	if coroutine.status(coro) ~= "dead" then
		print_red("FAILURE: test coroutine not finished")
	end
end

function module.step()
	expect "break via dbg() => test.lua:8 in upvalue 'func1'"; cmd "s"
	expect "test.lua:12 in upvalue 'func2'"; cmd "s"
	expect "test.lua:13 in upvalue 'func2'"; cmd "s"
	expect "test.lua:17 in upvalue 'func3'"; cmd "s"
	expect "test.lua:4 in upvalue 'do_nothing'"; cmd "s"
	expect "test.lua:18 in upvalue 'func3'"; cmd "s"
	expect "test.lua:22 in local 'test_body'"; cmd "c"
	print_green "STEP TESTS COMPLETE"
end

function module.next()
	expect "break via dbg() => test.lua:8 in upvalue 'func1'"; cmd "n"
	expect "test.lua:12 in upvalue 'func2'"; cmd "n"
	expect "test.lua:13 in upvalue 'func2'"; cmd "n"
	expect "test.lua:17 in upvalue 'func3'"; cmd "n"
	expect "test.lua:18 in upvalue 'func3'"; cmd "n"
	expect "test.lua:26 in local 'test_body'"; cmd "c"
	print_green "NEXT TESTS COMPLETE"
end

function module.finish()
	expect "break via dbg() => test.lua:8 in upvalue 'func1'"; cmd "f"
	expect "test.lua:12 in upvalue 'func2'"; cmd "f"
	expect "test.lua:17 in upvalue 'func3'"; cmd "f"
	expect "test.lua:30 in local 'test_body'"; cmd "c"
	print_green "FINISH TESTS COMPLETE"
end

function module.continue()
	expect "break via dbg() => test.lua:8 in upvalue 'func1'"; cmd "c"
	expect "break via dbg() => test.lua:8 in upvalue 'func1'"; cmd "c"
	expect "break via dbg() => test.lua:8 in upvalue 'func1'"; cmd "c"
	print_green "CONTINUE TESTS COMPLETE"
end

function module.trace()
	ignore(); -- Stack frame info that will be in the trace anyway.
	
	cmd "t"
	expect "Inspecting frame 0"
	expect "0 => test.lua:8 in upvalue 'func1'"
	expect "1    test.lua:11 in upvalue 'func2'"
	expect "2    test.lua:16 in upvalue 'func3'"
	expect "3    test.lua:39 in local 'test_body'"
	expect_match "4    ./test_util%.lua:%d+ in field 'run_test'"
	expect "5    test.lua:38 in chunk at test.lua:0"
	expect "6    [C]:-1 in chunk at [C]:-1"
	
	cmd "c"
	print_green "TRACE TESTS COMPLETE"
end

function module.updown()
	ignore();
	
	cmd "u"
	expect "Already at the top of the stack."
	
	cmd "d"
	expect "Inspecting frame: test.lua:11 in upvalue 'func2'"
	
	cmd "d"
	expect "Inspecting frame: test.lua:16 in upvalue 'func3'"
	
	cmd "d"
	expect "Inspecting frame: test.lua:43 in local 'test_body'"
	
	cmd "d"
	expect_match "Inspecting frame: %./test_util%.lua:%d+ in field 'run_test'"
	
	cmd "d"
	expect "Inspecting frame: test.lua:42 in chunk at test.lua:0"
	
	cmd "d"
	expect "Already at the bottom of the stack."
	
	cmd "c"
	print_green "UP/DOWN TESTES COMPLETE"
end

function module.where()
	ignore()
	
	cmd "w 1"
	expect_match "7%s+dbg%(%)"
	expect_match "8%s+=> end"
	expect "9"
	
	cmd "c"
	ignore()
	
	cmd "w"
	expect_match "1%s+require%(\"debugger\"%)%(%)"
	expect_match "2%s+=>%s+_ = _"
	
	cmd "c"
	print_green "WHERE TESTS COMPLETE"
end

function module.eval()
	ignore(); cmd "e var = true"
	expect "debugger.lua => Set local variable var"; cmd "c"
	
	ignore(); cmd "e upvar = true"
	expect "debugger.lua => Set upvalue upvar"; cmd "c"
	
	ignore(); cmd "e GLOBAL = true"
	expect "debugger.lua => Set global variable GLOBAL"; cmd "c"
	
	print_green "EVAL TESTS COMPLETE"
end

function module.print()
	ignore()
	
	-- Basic types
	cmd "p 1+1"; expect "1+1 => 2"
	cmd "p 1, 2, 3, 4"; expect "1, 2, 3, 4 => 1, 2, 3, 4"
	cmd 'p "str"'; expect '"str" => "str"'
	cmd 'p "\\0"'; expect_match '"\\0" => "\\0+"'
	cmd "p {}"; expect "{} => {}"
	
	-- Kinda light on table examples because I want to avoid iteration order issues.
	cmd "p {1, 2, 3}"; expect "{1, 2, 3} => {1 = 1, 2 = 2, 3 = 3}"
	cmd "p {{}}"; expect "{{}} => {1 = {}}"
	
	cmd "p nil, false"; expect "nil, false => nil, false"
	cmd "p nil, nil, false"; expect "nil, nil, false => nil, nil, false"
	cmd "p nil, nil, nil, false"; expect "nil, nil, nil, false => nil, nil, nil, false"
	
	cmd "p nil"; expect "nil => nil"
	cmd "p false, nil"; expect "false, nil => false, nil"
	cmd "p false, nil, nil"; expect "false, nil, nil => false, nil, nil"
	cmd "p false, nil, nil, nil"; expect "false, nil, nil, nil => false, nil, nil, nil"
	
	CIRCULAR_REF = {}
	CIRCULAR_REF.ref = CIRCULAR_REF
	
	-- Don't particularly care about the result as long as it doesn't get stuck in a loop.
	cmd "p CIRCULAR_REF"; ignore()
	
	cmd "c"
	print_green "PRINT TESTS COMPLETE"
end

function module.locals()
	ignore()
	
	cmd "l"
	expect 'upvar => true'
	expect 'var => "foobar"'
	
	cmd "c"
	print_green "LOCALS TESTS COMPLETE"
end

module.print_red = print_red
module.print_green = print_green
return module
