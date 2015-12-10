local lua_src = string.format("%q", io.open("debugger.lua"):read("a"))

-- Fix the weird escape characters
lua_src = string.gsub(lua_src, "\\\n", "\\n")
lua_src = string.gsub(lua_src, "\\9", "\\t")

local c_src = [[/*
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
*/

#include <stdbool.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#include "debugger.h"


static const char *DEBUGGER_SRC = ]]..lua_src..[[;


int luaopen_debugger(lua_State *lua){
	if(luaL_dostring(lua, DEBUGGER_SRC)) lua_error(lua);
	
	// Or you could load it from disk:
//	if(luaL_dostring(lua, "return require('debugger')")) lua_error(lua);
	
	return 1;
}

static const char *MODULE_NAME = "DEBUGGER_LUA_MODULE";
static const char *MSGH = "DEBUGGER_LUA_MSGH";

void dbg_setup(lua_State *lua, const char *name, const char *globalName, lua_CFunction readFunc, lua_CFunction writeFunc){
	// Check that the module name was not already defined.
	lua_getfield(lua, LUA_REGISTRYINDEX, MODULE_NAME);
	assert(lua_isnil(lua, -1) || strcmp(name, luaL_checkstring(lua, -1)));
	lua_pop(lua, 1);
	
	// Push the module name into the registry.
	lua_pushstring(lua, name);
	lua_setfield(lua, LUA_REGISTRYINDEX, MODULE_NAME);
	
	// Preload the module
	luaL_requiref(lua, name, luaopen_debugger, false);
	
	// Insert the msgh function into the registry.
	lua_getfield(lua, -1, "msgh");
	lua_setfield(lua, LUA_REGISTRYINDEX, MSGH);
	
	if(readFunc){
		lua_pushcfunction(lua, readFunc);
		lua_setfield(lua, -1, "read");
	}
	
	if(writeFunc){
		lua_pushcfunction(lua, writeFunc);
		lua_setfield(lua, -1, "write");
	}
	
	if(globalName){
		lua_setglobal(lua, globalName);
	} else {
		lua_pop(lua, 1);
	}
}

void dbg_setup_default(lua_State *lua){
	dbg_setup(lua, "debugger", "dbg", NULL, NULL);
}

int dbg_pcall(lua_State *lua, int nargs, int nresults, int _msgh){
	// Call regular lua_pcall() if a message handler is provided.
	if(_msgh) return lua_pcall(lua, nargs, nresults, _msgh);
	
	// Grab the msgh function out of the registry.
	lua_getfield(lua, LUA_REGISTRYINDEX, MSGH);
	if(lua_isnil(lua, -1)){
		luaL_error(lua, "Tried to call dbg_call() before calling dbg_setup().");
	}
	
	// Move the error handler just below the function.
	const int msgh = -(nargs + 2);
	lua_insert(lua, msgh);
	
	// Call the function.
	bool err = lua_pcall(lua, nargs, nresults, msgh);
	
	// Remove the debug handler.
	lua_remove(lua, -(nresults + 1));
	
	return err;
}
]]

io.open("debugger.c", "w"):write(c_src)
