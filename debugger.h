/*
	Copyright (c) 2015 Scott Lembcke and Howling Moon Software
	
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


	NOTE: MAKE SURE TO RUN 'lua debugger.c.lua' TO GENERATE THE .C FILE!
	
	
	EXAMPLE:
	
	int main(int argc, char **argv){
		lua_State *lua = luaL_newstate();
		luaL_openlibs(lua);
		
		// Register the debuggr module as "util.debugger" and store it in the global variable "dbg".
		dbg_setup(lua, "debugger", "dbg", NULL, NULL);
		
		// Load some lua code and prepare to call the MyBuggyFunction() defined below...
		
		// dbg_pcall() is called exactly like lua_pcall().
		// Although note that passing a custom message handler disables the debugger.
		if(dbg_pcall(lua, nargs, nresults, 0)){
			fprintf(stderr, "Lua Error: %s\n", lua_tostring(lua, -1));
		}
	}
	
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
*/

#ifdef __cplusplus
extern "C" {
#endif


typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);


// This function must be called before calling dbg_pcall() to set up the debugger module.
// 'name' must be the name of the module to register the debugger as. (ex: to use with 'reqiure(name)')
// 'globalName' can either be NULL or a global variable name to assign the debugger to. (I use "dbg")
// 'readFunc' is a lua_CFunction that returns a line of input when called. Pass NULL if you want to read from stdin.
// 'writeFunc' is a lua_CFunction that takes a single string as an argument. Pass NULL if you want to write to stdout.
void dbg_setup(lua_State *lua, const char *name, const char *globalName, lua_CFunction readFunc, lua_CFunction writeFunc);

// Same as 'dbg_setup(lua, "debugger", "dbg", NULL, NULL)'
void dbg_setup_default(lua_State *lua);

// Drop in replacement for lua_pcall() that attaches the debugger on an error if 'msgh' is 0.
int dbg_pcall(lua_State *lua, int nargs, int nresults, int msgh);

#ifdef __cplusplus
}
#endif
