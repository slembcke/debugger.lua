debugger.lua
=

A simple, embedabble CLI debugger for Lua 5.1, Lua 5.2 and LuaJIT 2.0.

Have you ever been working on an embedded Lua project and found yourself in need of a debugger? (I actually have never done a project in Lua, but I'm warming up to the idea now that I have a debugger I like...) The lua-users wiki lists a [number of them](http://lua-users.org/wiki/DebuggingLuaCode). While clidebugger was closest to what I wanted, I ran into several compatibility issues. The rest of them are very large libraries that require you to integrate socket libraries or other native libraries and such into your program. I just wanted something simple that would work through stdin/out. I also decided that it sounded fun to try and make my own.

Features
-

- Simple to "install". Simply copy debugger.lua into your project then load it using <code>local dbg = require()</code>.
- Conditional assert-style breakpoints.
- Easy to set it up to break on <code>assert()</code> or <code>error()</code>
- <code>dbg.call()</code> works similar to <code>xpcall()</code> but starts the debugger when an error occurs.
- Works with Lua 5.2, Lua 5.1, LuaJIT 2.0 and probably other versions that I didn't bother to test.
- The regular assortment of commands you'd expect from a debugger: continue, step, next, finish, print/eval expression, move up/down the stack, backtrace, print locals, inline help.
- Evaluate expressions and call functions interactively in the debugger. Inspect locals, upvalues and globals. Even works with varargs <code>...</code> (Lua 5.2 only).
- Pretty printed output so you get <code>{1 = 3, "a" = 5}</code> instead of <code>table: 0x10010cfa0</code>
- Speed. The debugger hooks are only set when running the step/next/finish commands and shouldn't otherwise affect your program's performance.
- IO could easily be remapped to a socket or window by rewriting the <code>dbg_write()</code> and <code>dbg_read()</code> functions.

How to Use it:
-

First of all, there is nothing to install. Just drop debugger.lua into your project and load it using <code>require()</code>. It couldn't be simpler. 

  
	-- MyBuggyProgram.lua
	
	local dbg = require("debugger")
	
	function foo()
		-- Calling dbg() will enter the debugger on the next executable line, right before it calls print().
		-- Once in the debugger, you will be able to step around and inspect things.
		dbg()
		
		-- Maybe you only want to start the debugger on a certain condition.
		-- If you pass a value to dbg(), it works like an assert statement.
		-- The debugger only triggers if it's nil or false.
		dbg(5 == 5) -- Will be ignored
		
		print("Fooooo!!!!")
	end
	
	foo()
	
	-- You can also wrap a chunk of code in a dbg.call() block.
	-- Any error that occurs will cause the debugger to attach.
	-- Then you can inspect the cause.
	-- (NOTE: dbg.call() expects a function that takes no parameters)
	dbg.call(function()
		-- Put some buggy code in here:
		local err1 = "foo" + 5
		local err2 = (nil).bar
	end)
	
	-- Lastly, you can override the standard Lua error() and assert() functions if you want:
	-- These variations will enter the debugger instead of throwing an error.
	-- dbg.call() is generally more useful though.
	local assert = dbg.assert
	local error = dbg.error

Debugger Commands:
-

If you have used other CLI debuggers, debugger.lua should present no surprises. All the commands are a single letter as writting a "real" command parser seemed like a waste of time. debugger.lua is simple, and there are only a small handful of commands anwyay.

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

If you've never used a CLI debugger before. Start a nice warm cozy fire, run tutorial.lua and open it up in your favorite editor so you can follow along.

Known Issues:
-

- Lua 5.1 and LuaJIT lack the API to access varargs. The workaround is to do something like <code>local args = {...}</code> and then use <code>unpack(args)</code> when you want to access them. In Lua 5.2, you can simply use <code>...</code> in your expressions with the print command.
- You can't add breakpoints to a running program or remove them. Currently the only way to set them is by explicitly calling the <code>dbg()</code> function.
- The print command will only print out the first 256 return values of an expression. Darn!
- Untested with Lua versions other than Lua 5.1, Lua 5.2 and LuaJIT 2.0b10.
- Different interpreters (and versions) print out different stack trace information. They all seem to output slightly different variations of mostly the same thing.
- Tail calls are handled silghtly differently in different interpreters. You may find that 1.) stepping into a function that does nothing but a tail call steps you into the tail called function. 2.) The interpreter gives you the wrong name of a tail called function (watch the line numbers). 3.) Stepping out of a tail called function also steps out of the function that performed the tail call. Mostly this is never a problem, but it is a little confusing if you don't know what is going on.
- Coroutines may or may not work as expected... I haven't tested them extensively yet. (Though I certainly will on my current project)

Future Plans:
-

debugger.lua basically does everything I want now, although I have some ideas for enhancements.

- Custom formatters: The built in pretty-printing works fine for most things. It would be nice to be able to register custom formatting functions though.
- Readline support for LuaJIT: Line editing and history would be pretty nice to have. With LuaJIT it might be easy using the FFI.