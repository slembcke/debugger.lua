local dbg = require("debugger")
print()

print[[
	Welcome to the interactive debugger.lua tutorial.
	You'll want to open tutorial.lua in an editor to follow along.
]]

print[[
	debugger.lua doesn't support traditional breakpoints.
	Instead you call the dbg() object to set a breakpoint.
	
	You are now in the debugger! (Woo! \o/).
	Notice how it prints out your current file and
	line as well as which function you are in.
	Sometimes functions don't have global names.
	It might print the method name, local variable
	that held the function, or file:line where it starts.
	
	Type 's' to step to the next line.
	(s = step to the next executable line)
]]

-- Multi-line strings are executable statements apparently
-- need to put this in an local to make the tutorial flow nicely.
local str1 = [[
	The 's' command steps to the next executable line.
	This may step you into a function call.
	
	If you hit <return>, the debugger will rerun your last command.
	Hit <return> 5 times to step through the next function.
]]

local str2 = [[
	Stop!
	You've now stepped through func1()
	Notice how entering and exiting a function takes a step.
	
	Now try the 'n' command.
	(n = step to the next line in the source code)
]]

local function func1()
	print("	Stepping through func1()...")
	print("	Almost there...")
end

local function func2()
	print("	You used the 'n' command.")
	print("	So it's skipping over the lines in func2().")
	
	local function f()
		print("	... and anything it might call.")
	end
	
	f()
	
	print()
	print[[
	The 'n' command also steps to the next line in the source file.
	Unlike the 's' command, it steps over function
	calls, not into them.
	
	Now try the 'c' command to continue on to the next breakpoint.
	(c =  continue execution)
]]
end

dbg()
print(str1)

func1()
print(str2)

func2()

local function func3()
	print[[
	You are now sitting at a breakpoint inside of a function.
	Let's say you got here by stepping into the function.
	After poking around for a bit, you just want to step until the
	function returns, but don't want to
	run the next command over and over.
	
	For this you would use the 'f' command. Try it now.
	(f = finish current function)
]]
	
	dbg()
	
	print[[
	Now you are sitting inside func4().
	It has some arguments, local variables and upvalues.
	Let's assume you want to see them.
	
	Try the 'l' command to list all the locally available variables.
	(l = local variables)
	
	Type 'c' to continue on to the next section.
]]
end

local my_upvalue1 = "Wee an upvalue"
local my_upvalue2 = "Awww, can't see this one"
globalvar = "Weeee a global"

function func4(a, b, ...)
	local c = "sea"
	local varargs_copy = {...}
	
	-- Functions only get upvalues if you reference them.
	local d = my_upvalue1.." ... with stuff appended to it"
	
	func3()
	
	print[[
	Some things to notice about the local variables list.
	'(*vargargs)'
		This is the list of varargs passed to the function.
		(only works with Lua 5.2)
	'(*temporary)'
		Other values like this may (or may not) appear as well.
		They are temporary values used by the lua interpreter.
		They may be stripped out in the future.
	'my_upvalue1'
		This is a local variable defined outside of but
		referenced by the function. Upvalues show up
		*only* when you reference them within your
		function. 'my_upvalue2' isn't in the list
		because func4() doesn't reference it.
	
	Listing the locals is nice, but sometimes it's just noise.
	Often times it's useful to print just a single variable,
	evaluate an expression, or call a function to see what it returns.
	
	For that you use the 'p' command.
	Try these commands:
	p my_upvalue1
	p 1 + 1
	p print("foo")
	p math.cos(0)
	
	You can also interact with varargs,
	but it depends on your Lua version.
	In Lua 5.2 you can do this:
	p select(2, ...)
	
	In Lua 5.1 or LuaJIT you need to copy
	the varargs into a table and unpack them:
	p select(2, unpack(varargs_copy))
]]
	dbg()
end

func4(1, "two", "vararg1", "vararg2", "vararg3")

-- TODO trace
-- TODO up/down
-- TODO help

-- TODO printing varargs and closures

local function func2(a, b, c)
	local sum = b + c
	print(b, c)
	
	return function()
		print[[
	This is a closue with some upvalues.
	Try printing them with the 'p' command.
	Note that you can print the value of 'a' and 'sum', but not 'b'.
	'b' is not referenced by the closure, so it's read as an undefined global variable.
]]
		
		print(a, sum)
		dbg()
	end
end

local function func3(d, e, ...)
	-- Lua 5.1 doesn't expose varargs to the debug interface.
	-- You'll need to make a local variable copyf of them if you want to inspect them.
	local varargs = {...}
	
	-- Return the closure that func1() returns
	return func2(d, ...)
end

-- call func2 and save the closure it returns
local f = func2(1, 2, 3, 4)

print[[
	Now type 'c' to step into the closure function
]]

dbg()
f()

print[[
	The following loop uses an assert-style breakpoint.
	It will only engage when the conditional fails. (when i == 5)
	Type 'c' to continue afterwards.
]]

for i=0, 10 do
	print("i = "..tostring(i))
	
	dbg(i ~= 5)
end

-- Optionally you can redefine assert() and error() to invoke the debugger as well
assert = dbg.assert
error = dbg.error
