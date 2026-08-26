.PHONY: build test mcp-build mcp-test

build:
	lua -e 'local f,err=loadfile("./luaSysBridge.lua"); if not f then error(err,0) end'

test:
	LUA_PATH="./?.lua;$$LUA_PATH" lua -e 'local ok,err=pcall(require,"luaSysBridge"); if not ok then error(err,0) end'

############################################
# MCP (AI agents)
############################################

mcp-build: build

mcp-test: test
