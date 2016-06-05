debugger.lua
=

A simple, highly embedabble CLI debugger for Lua 5.x, and LuaJIT 2.0.

Have you ever been working on an embedded Lua project and found yourself in need of a debugger? The lua-users wiki lists a [number of them](http://lua-users.org/wiki/DebuggingLuaCode). While clidebugger was closest to what I wanted, I ran into several compatibility issues. The rest of them are very large libraries that require you to integrate socket libraries or other native libraries and such into your program. I just wanted something simple to integrate that would work through stdin/stdout. I also decided that it sounded fun to try and make my own.

Features
-

- Trivial to "install". Can be integrated as a single .lua _or_ .c file.
- The regular assortment of commands you'd expect from a debugger: continue, step, next, finish, print/eval expression, move up/down the stack, backtrace, print locals, inline help.
- Evaluate expressions and call functions interactively in the debugger with pretty printed output. Inspect locals, upvalues and globals. Even works with varargs <code>...</code> (Lua 5.2+ and LuaJIT only).
- Pretty printed output so you get <code>{1 = 3, "a" = 5}</code> instead of <code>table: 0x10010cfa0</code>
- Speed. The debugger hooks are only set when running the step/next/finish commands and shouldn't otherwise affect your program's performance.
- Conditional, assert-style breakpoints.
- Colored output and GNU readline support when possible.
- Easy to set it up to break on Lua's <code>assert()</code> or <code>error()</code> functions.
- <code>dbg.call()</code> works similar to <code>xpcall()</code> but starts the debugger when an error occurs.
- From the C API, <code>dbg_call()</code> works as a drop-in replacement for <code>lua_pcall()</code>.
- IO can easily be remapped to a socket or window by overwriting the <code>dbg.write()</code> and <code>dbg.read()</code> functions.
- Permissive MIT license.

How to Use it:
-

First of all, there is nothing to install. Just drop debugger.lua into your project and load it using <code>require()</code>. It couldn't be simpler. 

	local dbg = require("debugger")
	
	function foo()
		-- Calling dbg() will enter the debugger on the next executable line, right before it calls print().
		-- Once in the debugger, you will be able to step around and inspect things.
		dbg()
		print("Woo!")
		
		-- Maybe you only want to start the debugger on a certain condition.
		-- If you pass a value to dbg(), it works like an assert statement.
		-- The debugger only triggers if it's nil or false.
		dbg(5 == 5) -- Will be ignored
		
		print("Fooooo!")
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
	-- These variations will enter the debugger instead of aborting the program.
	-- dbg.call() is generally more useful though.
	local assert = dbg.assert
	local error = dbg.error

Super Simple C API:
-

debugger.lua can be easily integrated into an embedded project by including a single .c (and .h) file. First, you'll need to run `lua debugger.c.lua`. This generates debugger.c by inserting the lua code into a template .c file.

	int main(int argc, char **argv){
		lua_State *lua = luaL_newstate();
		luaL_openlibs(lua);
		
		// The 2nd parameter is the module name. (Ex: require("debugger") )
		// The 3rd parameter is the name of a global variable to bind it to, or NULL if you don't want one.
		// The last two are lua_CFunctions for overriding the I/O functions.
		// A NULL I/O function  means to use standard input or output respectively.
		dbg_setup(lua, "debugger", "dbg", NULL, NULL);
		
		// Load some lua code and prepare to call the MyBuggyFunction() defined below...
		
		// dbg_pcall() is called exactly like lua_pcall().
		// Although note that using a custom message handler disables the debugger.
		if(dbg_pcall(lua, nargs, nresults, 0)){
			fprintf(stderr, "Lua Error: %s\n", lua_tostring(lua, -1));
		}
	}

Now you can go nuts adding all sorts of bugs in your Lua code! When an error occurs inside `dbg_call()` it will automatically load, and connect the debugger on the line of the crash.

	function MyBuggyFunction()
		-- You can either load the debugger module the usual way using the module name passed to dbg_setup()...
		local enterTheDebuggerREPL = require("debugger");
		enterTheDebuggerREPL()
		
		-- or if you defined a global name, you can use that instead. (highly recommended)
		dbg()
		
		-- When lua is invoked from dbg_pcall() using the default message handler (0),
		-- errors will cause the debugger to attach automatically! Nice!
		error()
		assert(false)
		(nil)[0]
	end

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

Environment Variables:
-

Want to disable ANSI color support or disable GNU readline? Set the <code>DBG_NOCOLOR</code> and/or <code>DBG_NOREADLINE</code> environment variables.

Known Issues:
-

- Lua 5.1 lacks the API to access varargs. The workaround is to do something like <code>local args = {...}</code> and then use <code>unpack(args)</code> when you want to access them. In Lua 5.2+ and LuaJIT, you can simply use <code>...</code> in your expressions with the print command.
- You can't add breakpoints to a running program or remove them. Currently the only way to set them is by explicitly calling the <code>dbg()</code> function explicitly in your code. (This is sort of by design and sort of because it's difficult.)
- Different interpreters (and versions) print out different stack trace information.
- Tail calls are handled silghtly differently in different interpreters. You may find that 1.) stepping into a function that does nothing but a tail call steps you into the tail called function. 2.) The interpreter gives you the wrong name of a tail called function (watch the line numbers). 3.) Stepping out of a tail called function also steps out of the function that performed the tail call. Mostly this is never a problem, but it is a little confusing if you don't know what is going on.
- Coroutine support has not been tested extensively yet, and Lua vs. LuaJIT handle them differently anyway. -_-

License:
-

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
