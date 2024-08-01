#include <stdio.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

// You need to define this in one of your C files. (and only one!)
#define DEBUGGER_LUA_IMPLEMENTATION
#include "debugger_lua.h"

int main(int argc, char **argv){
	// Do normal Lua init stuff.
	lua_State *lua = luaL_newstate();
	luaL_openlibs(lua);
	
	// Load up the debugger module as "debugger".
	// Also stores it in a global variable "dbg".
	// Use dbg_setup() to change these or use custom I/O.
	dbg_setup_default(lua);
	
	// Load some buggy Lua code.
	luaL_loadstring(lua,
		"local num = 1 \n"
		"local str = 'one' \n"
		"local res = num + str \n"
	);
	
	// Run it in the debugger. This function works just like lua_pcall() otherwise.
	// Note that setting your own custom message handler disables the debugger.
	if(dbg_pcall(lua, 0, 0, 0)){
		fprintf(stderr, "Lua Error: %s\n", lua_tostring(lua, -1));
	}
}
