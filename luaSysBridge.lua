#!/usr/bin/env lua
-- -*- mode: lua -*-
-- LUA COMPATIBILITY: LuaJIT, 5.1, 5.2, 5.3, 5.4

-- 631 = "line is too ling (XXX > 120)
-- luacheck: ignore 631

--- This module provides the core "luaSysBridge" functionality which can be used by other Lua scripts.
--- It is recommended that all system-level Lua scripts import this module.
--- Everything has been tested for compatibility with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--- Wrapper functions have been implemented to ensure backward/forward compatibility for essential operations.
--- When a new version of Lua is released, this module should be reviewed (e.g., with AI assistance) and updated to align with the latest standards if necessary.
--- Backward and forward compatibility must always be preserved, especially for Lua 5.1 and LuaJIT.
---
--- The module also uses below dependancies:
--- LUAPOSIX : https://luaposix.github.io/luaposix/index.html
--- LuaFileSystem : https://lunarmodules.github.io/luafilesystem/manual.html

local lfs = require("lfs")

local luaSysBridge = {}

--- Executes a system command and normalizes the return values across diffrent Lua versions.
--- @param cmd string The system command to execute.
--- @return boolean success True if the command executed successfully (exit code == 0), false otherwise.
--- @return integer|nil code The exit code (or nil if the command couldn't run).
function luaSysBridge.execute(cmd)
	-- Execute the system command
	local result, _, code = os.execute(cmd)

	-- Check the type of the returned value to adjust for the Lua version:
	if type(result) == "number" then
		-- Lua 5.1: returns a number (exit code)
		-- Lua 5.1: Convert the exit code to Lua 5.4 format
		-- Lua 5.1: Get the proper exit code, POSIX-compliant for Linux:
		local exit_code = math.floor(result / 256)
		return exit_code == 0, exit_code
	else
		-- Lua 5.2/5.3/5.4: returns 3 values: success (boolean or nil), exit_type (string), code (number)
		-- Lua 5.2/5.3/5.4: Transform these 3 values to Lua 5.4 format (success, code)
		-- Lua 5.2/5.3/5.4: Ignore exit_type
		-- To make consistent with 5.1: success only if code == 0 (and command ran); false if couldn't run or code != 0
		if result == nil then
			return false, code -- Couldn't execute; treat as failure
		else
			return code == 0, code -- Command ran; success based on code == 0
		end
	end
end

--- Create directories recursively, equivalent to the shell command "mkdir -p"
--- @param path string Directory path to create
--- @return boolean success true when directory exists or was created successfully, false otherwise
--- @return string|nil err Error message when creation failed, nil on success
function luaSysBridge.mkdir(path)
	-- Normalize path (remove trailing '/')
	if path:sub(-1) == "/" then
		path = path:sub(1, -2)
	end

	-- If the directory already exists, return success
	local attr = lfs.attributes(path)
	if attr and attr.mode == "directory" then
		return true
	end

	-- Find parent directory
	local parent = path:match("^(.*)/[^/]*$")
	if parent and parent ~= "" then
		local ok, err = luaSysBridge.mkdir(parent)
		if not ok then
			return false, err
		end
	end

	-- Attempt to create the current directory
	local ok, err = lfs.mkdir(path)
	if not ok then
		-- If another process created it in the meantime, that’s fine
		attr = lfs.attributes(path)
		if attr and attr.mode == "directory" then
			return true
		end
		return false, err
	end

	return true
end

--- Remove a directory and its contents using command "rm -rf" if the directory exists.
--- @param dir_path string Path to the directory to remove.
--- @return boolean|nil true when directory was removed successfully.
--- @return string|nil Error message when removal failed or directory does not exist.
function luaSysBridge.remove_dir(dir_path)
	if luaSysBridge.exists_directory(dir_path) then
		local success, code = luaSysBridge.execute("rm -rf " .. dir_path)
		if success then
			return true
		else
			return nil, "rm failed with exit code " .. tostring(code)
		end
	end
	return nil, "directory does not exist"
end

--- Wrapper around os.remove.
--- @param file_path string Path to the file to remove.
--- @return boolean|nil true on success; nil plus error message on failure.
function luaSysBridge.remove(file_path)
	-- Currently all versions work the same, but this may change in the future (5.4++)
	return os.remove(file_path)
end

--- Wrapper around os.date.
--- @param format string Format string for the date (e.g. "%Y-%m-%d").
--- @return string|osdate Current date/time formatted according to the given format.
function luaSysBridge.date(format)
	return os.date(format)
end

--- Removes a symbolic link if it exists.
--- @param link_path string Path to the symbolic link to remove.
--- @return boolean|nil, string? true on success; nil plus error message on failure.
function luaSysBridge.link_unlink(link_path)
	if luaSysBridge.exists_symlink(link_path) then
		return luaSysBridge.remove(link_path)
	end
	return nil, "symlink does not exist"
end

--- Create a symbolic link for a single file or directory on Linux.
--- Uses the native `ln -s` command and LuaFileSystem for existence checks.
--- Does not overwrite existing files or symlinks at the destination.
--- @param src string The source file or directory to symlink.
--- @param dst string The destination path where the symlink will be created.
--- @return boolean|nil, string? true on success; nil plus error message on failure.
function luaSysBridge.link_symlink(src, dst)
	-- Check that the source exists
	local ok_src = lfs.attributes(src)
	if not ok_src then
		return nil, "Source path does not exist: " .. src
	end

	-- Check that destination does not exist
	if lfs.attributes(dst) then
		return nil, "Destination already exists: " .. dst
	end

	-- Create symlink using Linux command
	local result = luaSysBridge.execute(string.format('ln -s "%s" "%s"', src, dst))
	if result ~= true and result ~= 0 then
		return nil, "Failed to create symlink: " .. dst
	end

	return true
end

--- Wrapper around os.rename.
--- @param file_path string Current path of the file.
--- @param new_file_path string New path for the file.
--- @return boolean|nil true on success; nil plus error message on failure.
function luaSysBridge.rename(file_path, new_file_path)
	-- Currently all versions work the same, but this may change in the future (5.4++)
	return os.rename(file_path, new_file_path)
end

--- Wrapper around os.getenv.
--- @param var_name string Name of the environment variable.
--- @return string|nil The value of the environment variable, or nil if not found.
function luaSysBridge.getenv(var_name)
	-- Currently all versions work the same, but this may change in the future (5.4++)
	return os.getenv(var_name)
end

--- Copies the file from "src" to "dst", preserving content and permissions where possible.
--- @param src string The source file path (must be a non-empty string).
--- @param dst string The destination file path (must be a non-empty string).
--- @return boolean true on success.
function luaSysBridge.copy_file(src, dst)
	-- Check parameters
	if type(src) ~= "string" or src == "" then
		error("Invalid source path (src)")
	end
	if type(dst) ~= "string" or dst == "" then
		error("Invalid destination path (dst)")
	end

	-- Check if src exists and is a file
	if not luaSysBridge.exists_file(src) then
		error("Source does not exist or is not a file: " .. tostring(src))
	end

	-- Open source file for binary read
	local src_file, src_err = io.open(src, "rb")
	if not src_file then
		error("Cannot open source file: " .. src_err)
	end

	-- Open destination file for binary write
	local dst_file, dst_err = io.open(dst, "wb")
	if not dst_file then
		src_file:close()
		error("Cannot create destination file: " .. dst_err)
	end

	-- Copy content (in chunks)
	while true do
		local chunk = src_file:read(4096)
		if not chunk then
			break
		end
		dst_file:write(chunk)
	end

	-- Close files
	src_file:close()
	dst_file:close()

	-- Copy permissions (chmod, Unix-only)
	local src_attr = lfs.attributes(src)
	if src_attr.permissions then
		-- Parse symbolic permissions string (e.g., "rw-r--r--") to octal number
		local function parse_permissions(perm)
			if #perm ~= 9 then
				return nil
			end
			local function bits(s)
				return (s:find("r") and 4 or 0) + (s:find("w") and 2 or 0) + (s:find("x") and 1 or 0) + (s:find("[sStT]") and 0 or 0)
			end -- Ignore setuid/sticky for basic chmod
			return bits(perm:sub(1, 3)) * 64 + bits(perm:sub(4, 6)) * 8 + bits(perm:sub(7, 9))
		end

		-- chmod via os.execute (Unix only)
		local perm_str = src_attr.permissions
		local mode_num = parse_permissions(perm_str)
		if mode_num then
			local success = luaSysBridge.execute(string.format("chmod %o %s", mode_num, "'" .. dst:gsub("'", "'\\''") .. "'"))
			if not success then
				error("ERROR: Could not set permissions!!")
			end
		end
	end

	return true
end

--- Wrapper around lfs.chdir().
--- Wraps LuaFileSystem's chdir for future compatibility and consistent API.
--- Works well with luaSysBridge.pwd_currentdir() (which is wrapper around lfs.currentdir()).
--- @param path string The path to change the current working directory to.
--- @return boolean|nil true on success; nil plus error message on failure.
function luaSysBridge.chdir(path)
	return lfs.chdir(path)
end

--- Lua equivalent of Python "os.path.dirname(__file__)".
--- Returns the real location of the executing script.
--- @return string The directory path of the script, or "." if not found.
function luaSysBridge.get_script_dir()
	for i = 2, math.huge do
		local info = debug.getinfo(i, "S")
		if not info then
			break
		end
		if info.source:sub(1, 1) == "@" then
			return info.source:match("@?(.*/)") or "."
		end
	end
	return "."
end

--- Wrapper for os.exit for Lua 5.1-5.4, ensuring consistent behavior across versions.
--- In Lua 5.1/LuaJIT, the close parameter is always treated as true (Lua state is closed).
--- @param code boolean|number|nil The exit code (boolean true/false maps to 0/1, number used directly, defaults to 0).
--- @param close boolean|nil Whether to close the Lua environment (defaults to true; ignored in Lua 5.1/LuaJIT).
function luaSysBridge.exit(code, close)
	-- Handle boolean code properly (true -> 0, false -> 1)
	if type(code) == "boolean" then
		code = code and 0 or 1
	else
		code = tonumber(code) or 0 -- Ensure code is a number
	end

	-- Normalize close to true/false
	close = (close ~= false)

	if _VERSION == "Lua 5.1" or _VERSION:match("LuaJIT") then
		os.exit(code) -- Ignore close, as Lua 5.1 and LuaJIT do not support the second argument (always closes Lua state)
	else
		os.exit(code, close) -- Lua 5.2+ supports both arguments
	end
end

--- Wrapper for io.popen, returning stdout/err.
--- Executes the command with stderr redirected to stdout.
--- Normalizes return to: success (true if code == 0), code (exit code or approx), output (stdout/err combined).
--- If the process cannot be opened, returns false, 1, "Cannot open process".
--- @param cmd string The command to execute.
--- @return boolean success True if the command succeeded (exit code == 0), false otherwise.
--- @return number code The exit code (or error code if applicable).
--- @return string output The combined stdout/stderr output.
function luaSysBridge.iopopen_stdout_err(cmd)
	local is_lua51 = (_VERSION == "Lua 5.1" or _VERSION:match("LuaJIT"))
	local full_cmd = cmd .. " 2>&1"

	if is_lua51 then
		-- Add unique marker to distinguish exit code line safely
		full_cmd = full_cmd .. "; echo __EXITCODE:$?"
	end

	-- Try to open the process
	local pipe = io.popen(full_cmd, "r")
	if not pipe then
		return false, 1, "Cannot open process"
	end

	-- Read entire output
	local output = pipe:read("*a") or ""

	-- Collect result and exit code
	local result, code
	if not is_lua51 then
		local ok, _, c = pipe:close()
		result = ok or false
		code = c or 1
	else
		pipe:close()
		-- Extract exit code marker
		local code_marker = output:match("__EXITCODE:(%d+)%s*$")
		code = tonumber(code_marker or "1") or 1
		-- Remove the marker line from output
		output = output:gsub("\n?__EXITCODE:%d+%s*$", "")
		result = (code == 0)
	end

	-- Normalize result
	if result == nil then
		result = false
		code = code or 1
	end

	if result then
		result = (code == 0)
	else
		code = code or 1
	end

	return result, code, output
end

--- Calculate file MD5 using the system md5sum command.
--- @param file_path string Path to the file to hash.
--- @return string|nil Lowercase 32-character hexadecimal MD5 digest on success; nil on error.
function luaSysBridge.calculate_md5(file_path)
	-- Validate argument
	if type(file_path) ~= "string" or file_path == "" then
		return nil
	end

	-- Safely escape the argument for the shell: replace each single quote ' -> '\''
	local escaped_path = "'" .. file_path:gsub("'", "'\\''") .. "'"
	local command = "md5sum " .. escaped_path

	-- Execute command (assumes luaSysBridge.iopopen_stdout_err is available and tested)
	local success, code, output = luaSysBridge.iopopen_stdout_err(command)

	-- Check execution result
	if not success or code ~= 0 then
		return nil
	end

	-- Parse output: md5sum returns "<hash>  <path>"
	local md5 = output:match("^([0-9a-fA-F]+)")

	-- Trim trailing whitespace
	if md5 then
		md5 = md5:match("^(.-)%s*$")
	end

	-- Validate hash (32 hex characters) and normalize to lowercase
	if md5 and #md5 == 32 and md5:match("^[0-9a-fA-F]+$") then
		return md5:lower()
	end

	return nil
end

--- Find an executable in PATH (Unix/Linux only).
--- Works like "shutil.which"; returns the absolute path to the executable or nil if not found.
--- @param cmd string Command name to search for.
--- @return string|nil Absolute path to executable on success; nil if not found or on error.
function luaSysBridge.which(cmd)
	-- Validate argument
	if type(cmd) ~= "string" or cmd == "" then
		return nil
	end

	-- Safely escape the argument for the shell: replace each single quote ' -> '\''
	local escaped_cmd = "'" .. cmd:gsub("'", "'\\''") .. "'"
	local command = "which " .. escaped_cmd

	-- Execute command (assumes luaSysBridge.iopopen_stdout_err is available and tested)
	local success, code, stdout = luaSysBridge.iopopen_stdout_err(command)

	-- Check execution result
	if not success or code ~= 0 then
		return nil
	end

	-- Trim trailing whitespace
	local path = stdout:match("^(.-)%s*$")

	-- Return path only if non-empty and file exists (assumes luaSysBridge.exists_file is available)
	if path and path ~= "" then
		if luaSysBridge.exists_file(path) then
			return path
		else
			return nil
		end
	end

	return nil
end

--- Returns the host name. Uses LUAPOSIX.
--- @return string hostname Host name without trailing newline.
function luaSysBridge.get_hostname()
	-- https://luaposix.github.io/luaposix/modules/posix.sys.utsname.html#uname
	-- Fields:
	-- machine string hardware platform name
	-- nodename string network node name
	-- release string operating system release level
	-- sysname string operating system name
	-- version string operating system version
	--
	local utsname = require("posix.sys.utsname")
	local data, err, errnum = utsname.uname()
	if data and data.nodename and data.nodename ~= "" then
		-- strip trailing whitespace/newlines
		local clean = data.nodename:gsub("[\r\n]+$", "")
		-- take only first word before any space:
		-- e.g. "mymachine 5" -> "mymachine"
		clean = clean:match("^(%S+)")
		return clean
	end

	-- Fallback #1: read /proc/sys/kernel/hostname (Linux-specific)
	local f = io.open("/proc/sys/kernel/hostname", "r")
	if f then
		local hostname = f:read("*l")
		f:close()
		if hostname and hostname ~= "" then
			return hostname:gsub("[\r\n]+$", ""):match("^(%S+)")
		end
	end

	-- Fallback #2: read /etc/hostname (common on many Unix systems)
	f = io.open("/etc/hostname", "r")
	if f then
		local hostname = f:read("*l")
		f:close()
		if hostname and hostname ~= "" then
			return hostname:gsub("[\r\n]+$", ""):match("^(%S+)")
		end
	end

	-- If all methods fail
	error('Failed to obtain host name using "posix.sys.utsname" or fallback files: ' .. err .. "  errnum: " .. errnum)
end

--- Execute a main function protected with pcall and ignore Ctrl+C interrupts.
--- Use `local function main()` and pass that function as the `main` argument.
--- The function dismiss errors equal to "interrupted" or "interrupted!" (typical from Ctrl+C handlers)
--- and prints other errors to stdout.
--- @param main function Function to call under pcall.
function luaSysBridge.pcall_interrupted(main)
	-- Use `pcall` to handle the error caused by Ctrl+C:
	local status, err = pcall(main)
	if not status then
		if err and err ~= "interrupted" and err ~= "interrupted!" then
			-- in case of Ctrl+C (err as interrupted) do nothing: ignore errors silently
			return
		else
			print("An error occurred: " .. tostring(err))
		end
	end
end

--- Check SSH reachability by pinging a host and exit on failure.
--- This function only checks the boolean success value returned by that call.
--- @param ip string IP address or hostname to ping
--- @return nil Terminates the process with `luaSysBridge.exit(1)` when ping fails
function luaSysBridge.ssh_check_connection(ip)
	local success, code = luaSysBridge.execute("ping -i 0.3 -c 2 " .. ip .. " > /dev/null 2>&1")

	-- We only check `success`, which is a boolean in the `luaSysBridge.execute`
	if not success then
		print("WARNING - SSH CONNECTION NOT WORKING! CHECK SSH! Exit code: " .. tostring(code))
		luaSysBridge.exit(1)
	end
end

--- Get current working directory:
--- read in the place where the lua script was run (but not the location of the script).
--- Doesn't work with lfs.chdir() (which is wrapper around luaSysBridge.chdir()).
--- Only the path where the script was run will always be returned.
--- Uses LUAPOSIX. Falls back to the value of the PWD environment variable when available.
--- And then falls back to calling the system `pwd` command if PWD env is not set.
--- @return string current working directory path or "." when unknown
function luaSysBridge.pwd_os_pwd()
	local path
	local unistd = require("posix.unistd")
	path = unistd.getcwd()
	if not path then
		path = os.getenv("PWD")
	end
	if not path then
		local p = io.popen("pwd")
		if p then
			path = p:read("*l")
			p:close()
		end
	end
	return path or "."
end

--- Wrapper around lfs.currentdir().
--- Wraps LuaFileSystem's currentdir for future compatibility and consistent API.
--- Works well with luaSysBridge.chdir() (which is wrapper around lfs.chdir()).
--- @return string|nil A string with the current working directory or nil plus an error string.
function luaSysBridge.pwd_currentdir()
	return lfs.currentdir()
end

--- Pretty-print a given lua table recursively to stdout.
--- Prints keys and values; when a value is a table, recurses with increased indentation.
--- @param tbl table Table to print
--- @param indent string|nil Current indentation prefix (optional)
function luaSysBridge.table_print(tbl, indent)
	indent = indent or "" -- default indentation
	for key, value in pairs(tbl) do
		if type(value) == "table" then
			print(indent .. key .. ":")
			luaSysBridge.table_print(value, indent .. "  ") -- recursion with increased indentation
		else
			print(indent .. key .. ": " .. tostring(value))
		end
	end
end

--- Save a Lua table to a file as valid Lua code.
--- The function serializes a given table (including nested tables) into
--- a Lua-readable format using "return { ... }" syntax. Unsupported types
--- such as functions or userdata are written as "nil".
--- @param tbl table The table to serialize and save
--- @param file_path string The file path where the Lua code will be written
--- @return boolean True if the file was written successfully, false otherwise
function luaSysBridge.table_save_to_file(tbl, file_path)
	-- Local helper function that converts a Lua table into a Lua code string
	local function table_to_lua_code(t, indent)
		indent = indent or 0
		local pad = string.rep(" ", indent)
		local lines = { "{" }
		for k, v in pairs(t) do
			local key
			if type(k) == "string" then
				key = string.format("[%q]", k)
			else
				key = string.format("[%s]", tostring(k))
			end

			local value
			if type(v) == "table" then
				-- Recursively convert nested tables
				value = table_to_lua_code(v, indent + 4)
			elseif type(v) == "string" then
				value = string.format("%q", v)
			elseif type(v) == "number" or type(v) == "boolean" then
				value = tostring(v)
			else
				-- Unsupported types (e.g., functions, userdata, threads) are stored as nil
				value = "nil"
			end

			table.insert(lines, string.rep(" ", indent + 4) .. key .. " = " .. value .. ",")
		end
		table.insert(lines, pad .. "}")
		return table.concat(lines, "\n")
	end

	-- Main logic: generate Lua code and write it to the specified file
	local lua_code = "return " .. table_to_lua_code(tbl) .. "\n"

	local file, err = io.open(file_path, "w")
	if not file then
		print("ERROR: could not open file for writing: " .. err)
		return false
	end

	file:write(lua_code)
	file:close()
	-- print("INFO: table saved successfully to: " .. file_path)
	return true
end

--- Prompt the user to select a value of element (string or number) from a given table.
--- The table must contain only strings or numbers (unnested).
--- If the user fails to select a valid option within the allowed attempts,
--- or provides no input, the function returns an empty string.
--- @param options table A table of elements to choose from.
--- @param prompt string Optional message displayed before listing options (default: "Choose element:")
--- @param max_attempts number Maximum number of attempts before returning an empty string (default: 0 = unlimited)
--- @return string The selected value, or an empty string if no valid choice was made.
function luaSysBridge.table_select_element(options, prompt, max_attempts)
	prompt = prompt or "Choose element:"
	max_attempts = max_attempts or 0

	if type(options) ~= "table" or #options == 0 then
		return ""
	end

	local attempt = 0
	local count = #options

	while true do
		print(prompt)
		for i, value in ipairs(options) do
			print(string.format("[%d] %s", i, tostring(value)))
		end
		io.write(string.format("Enter a number [1-%d] and press <ENTER>: ", count))
		local input = io.read()

		if not input or input == "" then
			return ""
		end

		local num = tonumber(input)
		if num and num >= 1 and num <= count then
			return options[num]
		end

		attempt = attempt + 1
		print("ERROR: Invalid selection. Please try again.")

		if max_attempts > 0 and attempt >= max_attempts then
			return ""
		end
	end
end

--- Load a Lua table from a file containing valid Lua code.
--- The file must return a table (e.g., created by luaSysBridge.table_save_to_file).
--- Uses dofile() to safely execute and return the table.
--- @param file_path string The path to the Lua file to load
--- @return table|nil The loaded table if successful, or nil if loading failed
function luaSysBridge.table_get_from_file(file_path)
	-- Attempt to load and execute the Lua file
	local ok, result = pcall(dofile, file_path)
	if not ok then
		print("ERROR: could not load table from file: " .. tostring(result))
		return nil
	end

	-- Ensure the file returned a table
	if type(result) ~= "table" then
		print("ERROR: file did not return a table: " .. tostring(file_path))
		return nil
	end

	-- Return the loaded table
	return result
end

--- Ask the user for confirmation input <Y/y/Yes/yes>.
--- Prints a message and waits for user input from stdin (prompt).
--- Returns true only if the user types "y" or "yes" (case-insensitive).
--- @param promptMsg string The message to display before the prompt.
--- @return boolean True if the user confirmed, false otherwise.
function luaSysBridge.prompt_y_yes(promptMsg)
	io.write(promptMsg .. " - <Y/y/Yes/yes>? ")
	io.flush()

	local input = io.read("*l")
	if not input then
		io.stderr:write("ERROR: Could not read from stdin!\n")
		luaSysBridge.exit(1)
	end

	-- trim and lowercase
	input = string.lower((string.gsub(input, "^%s*(.-)%s*$", "%1")))
	if input == "y" or input == "yes" then
		return true
	end

	return false
end

--- Wait for the user to press <ENTER> to continue.
--- Prints a message and pauses until the user presses <ENTER>.
--- @param promptMsg string The message to display before waiting.
--- @return boolean True if the user confirmed
function luaSysBridge.prompt_enter(promptMsg)
	io.write(promptMsg .. " - <ENTER>")
	io.flush()

	local input = io.read("*l")
	if input == nil then
		io.stderr:write("ERROR: Could not read from stdin!\n")
		luaSysBridge.exit(1)
	end

	return true
end

--- Replace a line in a file that starts with a given string.
--- Reads the file, replaces any line that starts with the specified prefix,
--- and writes the modified content back to the same file.
--- Returns true on success, false on any error.
--- All params are required: if nil or invalid, an error message is printed.
--- @param filePath string The path to the file.
--- @param startsWith string The prefix to search for at the beginning of each line.
--- @param newLine string The new line to replace matching lines with.
--- @return boolean True if operation succeeded, false otherwise.
function luaSysBridge.replace_in_file_line(filePath, startsWith, newLine)
	if filePath == nil or startsWith == nil or newLine == nil then
		io.stderr:write("ERROR: Invalid parameters! Please provide correct params!\n")
		return false
	end

	local file = io.open(filePath, "r")
	if not file then
		io.stderr:write("ERROR: File does not exist or cannot be opened: " .. filePath .. "\n")
		return false
	end

	-- Read all lines
	local lines = {}
	for line in file:lines() do
		if string.sub(line, 1, string.len(startsWith)) == startsWith then
			table.insert(lines, newLine)
		else
			table.insert(lines, line)
		end
	end
	file:close()

	-- Write modified lines back to file
	local fileOut = io.open(filePath, "w")
	if not fileOut then
		io.stderr:write("ERROR: Unable to write to the file: " .. filePath .. "\n")
		return false
	end
	for i, line in ipairs(lines) do
		fileOut:write(line)
		if i < #lines then
			fileOut:write("\n")
		end
	end
	fileOut:close()

	return true
end

--- Check whether a path points to an existing regular file.
--- Implementation without lfs is possible but will be slower.
--- @param path string Path to the file.
--- @return boolean True if the path exists and is a regular file, false otherwise.
function luaSysBridge.exists_file(path)
	local attr = lfs.attributes(path, "mode")
	return attr ~= nil and attr == "file"
end

--- Check whether a path points to an existing directory.
--- Implementation without lfs is possible but will be slower.
--- @param path string Path to the directory.
--- @return boolean True if the path exists and is a directory, false otherwise.
function luaSysBridge.exists_directory(path)
	local attr = lfs.attributes(path, "mode")
	return attr ~= nil and attr == "directory"
end

--- Check whether a path is a symbolic link (Linux/Unix only).
--- Uses the external shell "test -L" command.
--- This function validates its argument and raises an error for invalid input.
--- @param path string Non-empty file system path to check.
--- @return boolean True if the path is a symbolic link, false otherwise.
function luaSysBridge.exists_symlink(path)
	-- Validate argument
	if type(path) ~= "string" or path == "" then
		error("Invalid path: expected a non-empty string")
	end

	-- Escape path to handle spaces and special characters.
	-- Use single quotes and escape single quotes inside the path.
	local escaped_path = "'" .. path:gsub("'", "'\\''") .. "'"
	local cmd = "test -L " .. escaped_path

	-- Execute the test command; success == true means path is a symlink.
	local success, _ = luaSysBridge.execute(cmd)
	return success
end

--- Performs a file or directory name search inside `dir` using a glob-like `pattern_base`.
--- Converts `pattern_base` into a Lua pattern by escaping magic characters (except * and ?),
--- preserving their semantics, and wrapping the pattern with `.*` for partial matches.
---
--- Example:
---     local files = luaSysBridge.find("/var/log", "*.log")       -- only files
---     local both  = luaSysBridge.find("/var", "*", true)         -- files + dirs
---     local dirs  = luaSysBridge.find("/var", "*log*", "dirs")   -- only dirs
---
--- @param dir string Directory path where the search will be performed.
--- @param pattern_base string Glob-like pattern to match against file or directory names.
--- @param mode any Optional. If nil: only files. If truthy: files + dirs. If string "dirs" (or non-nil non-true): only dirs.
--- @return table Array (integer-keyed) of file or directory names that match the converted pattern.
function luaSysBridge.find(dir, pattern_base, mode)
	local results = {}
	pattern_base = pattern_base or "*"

	-- Escape Lua magic characters except * and ?
	local lua_pattern = pattern_base:gsub("([%.%+%-%%%[%]%^%$%(%)])", "%%%1"):gsub("%*", ".*"):gsub("%?", ".")

	lua_pattern = ".*" .. lua_pattern .. ".*"

	local include_files = (mode == nil) or (mode == true)
	local include_dirs = (mode and mode ~= true)

	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." then
			local full_path = dir .. "/" .. entry
			local attr = lfs.attributes(full_path)
			if attr then
				local is_file = (attr.mode == "file")
				local is_dir = (attr.mode == "directory")

				if entry:match(lua_pattern) then
					if (is_file and include_files) or (is_dir and include_dirs) then
						table.insert(results, entry)
					end
				end
			end
		end
	end
	return results
end

--- Lists regular files (non-recursive) in a given directory.
--- Returns only entries that are regular files (not directories, symlinks, etc.).
--- On error (e.g. invalid directory), returns `nil`.
--- @param dir string Path to the directory to list.
--- @return string[]|nil files A numerically indexed array of file names, or `nil` on error.
function luaSysBridge.ls_dir(dir)
	local files = {}
	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." then
			local full_path = dir .. "/" .. entry
			local attr = lfs.attributes(full_path)
			if attr and attr.mode == "file" then
				table.insert(files, entry)
			end
		end
	end
	return files
end

--- Prints a formatted log message.
--- If the message type is shorter than 5 characters, spaces are added to align it.
--- @param msgType string The type or category of the log message (INFO, WARN, ERROR, CMD).
--- @param msg string The message to print.
--- @return nil
function luaSysBridge.log_print(msgType, msg)
	-- Get the length of msgType
	local msgTypeLen = string.len(msgType)

	-- Pad msgType with spaces if it is shorter than 5 characters
	if msgTypeLen < 5 then
		msgType = msgType .. string.rep(" ", 5 - msgTypeLen)
	end

	-- Print formatted message
	print("> " .. msgType .. " : " .. msg)
end

--- Wrapper around 'fzf' to select a git commit.
--- Shows commit refs and titles, lets user pick one.
--- @return string|nil Selected commit hash or nil if nothing selected.
function luaSysBridge.git_fzf_select_commit()
	-- Run git log piped to fzf:
	local success, _, selection = luaSysBridge.iopopen_stdout_err("git log --date=iso --pretty=format:'%H %ad %s' | fzf --ansi --no-sort --tac")
	if not success then
		return nil
	end

	if selection and #selection > 0 then
		-- Split string by space in Lua
		local commit_ref = selection:match("^(%S+)")
		return commit_ref
	else
		return nil
	end
end

return luaSysBridge
