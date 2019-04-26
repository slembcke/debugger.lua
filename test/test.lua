local tests = require("test_util")
local dbg = require("debugger")

local function do_nothing() end

local function func1()
	dbg()
end

local function func2()
	func1()
	_ = _ -- nop padding
end

local function func3()
	func2()
	do_nothing()
end

tests.run_test(tests.step, function()
	func3()
end)

tests.run_test(tests.next, function()
	func3()
end)

tests.run_test(tests.finish, function()
	func3()
end)

tests.run_test(tests.continue, function()
	func3()
	func3()
	func3()
end)

tests.run_test(tests.trace, function()
	func3()
end)

tests.run_test(tests.updown, function()
	func3()
end)

local func_from_string = (loadstring or load)[[
	require("debugger")()
	_ = _
]]

tests.run_test(tests.where, function()
	func3()
	func_from_string()
end)

GLOBAL = false
local upvar = false

tests.run_test(tests.eval, function()
	local var = false
	dbg()
	if not var then tests.print_red "ERROR: local variable not set" end
	
	dbg()
	if not upvar then tests.print_red "ERROR: upvalue not set" end
	
	dbg()
	if not GLOBAL then tests.print_red "ERROR: global variable not set" end
end)

tests.run_test(tests.print, function()
	dbg()
end)

tests.run_test(tests.locals, function()
	local var = upvar and "foobar"
	dbg()
	
	-- Need a no-op here.
	-- Lua 5.1 variables go out of scope right before 'end'
	-- All other versions go out of scope right after.
	_ = _
end)

tests.print_green "TESTS COMPLETE"
