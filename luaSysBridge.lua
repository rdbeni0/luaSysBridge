#!/usr/bin/env lua
-- -*- mode: lua -*-
-- LUA COMPATIBILITY: LuaJIT, 5.1, 5.2, 5.3, 5.4

-- https://luacheck.readthedocs.io/en/stable/warnings.html
-- 631 = warning "line is too long (XXX > 120)
-- luacheck: ignore 631

--- This module provides the core "luaSysBridge" functionality which can be used by other Lua scripts.
--- It is recommended that all system-level Lua scripts import this module.
--- Everything has been tested for compatibility with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--- Wrapper functions have been implemented to ensure backward/forward compatibility for essential operations.
--- When a new version of Lua is released, this module should be reviewed (e.g., with AI assistance) and updated to align with the latest standards if necessary.
--- Backward and forward compatibility must always be preserved, especially for Lua 5.1 and LuaJIT.
---
--- The module also uses below dependencies:
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

--- Execute a program, replacing the current process (python os.execvp equivalent).
--- Uses LUAPOSIX posix.unistd.execp which performs PATH search when `file` contains no slash.
--- On success this function never returns (the current Lua process is replaced).
--- On failure it returns nil plus an error message (and optionally errnum).
--- Compatible with Lua 5.1–5.4 and LuaJIT.
---
--- Two calling styles are supported:
---
--- 1. Friendly (recommended):
---      luaSysBridge.execvp("podman", { "run", "--rm", "-it", "image" })
---
--- 2. Classic / explicit argv[0] (still works):
---      luaSysBridge.execvp("podman", { [0] = "podman", "run", "--rm", "-it", "image" })
---      luaSysBridge.execvp("podman", { "podman", "run", "--rm", "-it", "image" })
---
--- @param file string Program name or path. If it contains no '/', PATH is searched.
--- @param args table Argument vector. May start from the first real argument or contain key 0.
--- @return nil, string, integer Never returns on success; on failure: nil, errmsg, errnum
function luaSysBridge.execvp(file, args)
    if type(file) ~= "string" or file == "" then
        return nil, "execvp(): file must be a non-empty string"
    end

    if type(args) ~= "table" then
        return nil, "execvp(): args must be a table (argument vector)"
    end

    for _, v in pairs(args) do
        if type(v) ~= "string" then
            return nil, "execvp(): all args must be strings"
        end
    end

    -- Normalize to a proper argv table that always has index 0
    local argv = {}

    if args[0] ~= nil then
        -- User already provided explicit argv[0]
        for k, v in pairs(args) do
            argv[k] = v
        end
    elseif args[1] == file then
        -- Classic style: first element is the program name
        argv[0] = file
        for i = 2, #args do
            argv[i - 1] = args[i]
        end
    else
        -- Friendly style (recommended): args are only the real arguments
        argv[0] = file
        for i, v in ipairs(args) do
            argv[i] = v
        end
    end

    -- Guarantee at least argv[0]
    if next(argv) == nil then
        argv[0] = file
    end

    local unistd = require("posix.unistd")

    -- Performs PATH search like C execvp().
    -- Never returns on success; on failure returns nil, errmsg, errnum.
    local _, errstr, errnum = unistd.execp(file, argv)

    local errmsg = errstr or "unknown error"
    return nil, string.format("execvp failed for %q: %s (errno %d)", file, errmsg, errnum), errnum
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

--- Remove a directory and its contents. Uses LUAPOSIX. Equivalent to "rm -rf".
--- @param dir_path string Path to the directory to remove.
--- @return boolean|nil true when directory was removed successfully.
--- @return string|nil Error message when removal failed or directory does not exist.
function luaSysBridge.remove_dir(dir_path)
    if not luaSysBridge.exists_directory(dir_path) then
        return nil, "directory does not exist"
    end

    local unistd = require("posix.unistd")
    local stat = require("posix.sys.stat")
    local dirent = require("posix.dirent")

    -- Non-recursive DFS implementation using an explicit stack
    local function rm_rf(root)
        -- Stack entries:
        -- { path = <string>, visited = <boolean> }
        -- visited=false means: descend into directory first
        -- visited=true  means: all children processed, remove directory now
        local stack = { { path = root, visited = false } }

        while #stack > 0 do
            local node = stack[#stack]
            local path = node.path

            -- Retrieve file/directory metadata
            local st, err = stat.lstat(path)
            if not st then
                return false, ("lstat failed: %s"):format(err or "unknown error")
            end

            -- Directory case
            if stat.S_ISDIR(st.st_mode) ~= 0 then
                if not node.visited then
                    -- First time seeing this directory: list contents and push children.
                    node.visited = true

                    local files, err2 = dirent.dir(path)
                    if not files then
                        return false, ("cannot read directory %s: %s"):format(path, err2 or "unknown error")
                    end

                    -- Push children onto the stack (unvisited)
                    for _, name in ipairs(files) do
                        if name ~= "." and name ~= ".." then
                            local full = path .. "/" .. name
                            stack[#stack + 1] = { path = full, visited = false }
                        end
                    end
                else
                    -- Children are processed -> remove directory now.
                    stack[#stack] = nil
                    if unistd.rmdir(path) ~= 0 then
                        return false, "rmdir failed: " .. path
                    end
                end
            else
                -- Regular file / symlink / other -> remove immediately.
                stack[#stack] = nil
                if unistd.unlink(path) ~= 0 then
                    return false, "unlink failed: " .. path
                end
            end
        end

        return true
    end

    local ok, err = rm_rf(dir_path)
    if ok then
        return true
    else
        return nil, err
    end
    -- >>>>>>>>>>>>
    -- Old implementation -> without LUAPOSIX:
    -- Remove a directory and its contents using command "rm -rf" if the directory exists.
    --
    -- if luaSysBridge.exists_directory(dir_path) then
    -- 	local success, code = luaSysBridge.execute("rm -rf " .. dir_path)
    -- 	if success then
    -- 		return true
    -- 	else
    -- 		return nil, "rm failed with exit code " .. tostring(code)
    -- 	end
    -- end
    -- return nil, "directory does not exist"
    -- <<<<<<<<<<<<
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

--- Wrapper around os.time.
--- Normalizes input table for compatibility across Lua 5.1–5.4.
--- @param t? table Table with date fields (year, month, day, hour, min, sec, isdst)
--- @return number|nil timestamp Unix-like timestamp or nil on error
function luaSysBridge.time(t)
    -- No argument -> current time
    if t == nil then
        return os.time()
    end

    if type(t) ~= "table" then
        return nil, "time(): argument must be a table or nil"
    end

    -- normalize fields (Lua allows missing ones but behaviour differs per libc)
    local normalized = {
        year = assert(t.year, "time(): missing field 'year'"),
        month = assert(t.month, "time(): missing field 'month'"),
        day = assert(t.day, "time(): missing field 'day'"),
        hour = t.hour or 0,
        min = t.min or 0,
        sec = t.sec or 0,
        isdst = t.isdst,
    }

    return os.time(normalized)
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
--- Uses the native POSIX link() function from luaposix with soft=true (no exec/ln command).
--- Does not overwrite existing dirs, files or symlinks at the destination.
--- @param src string The symlink target. May be absolute or relative to the destination directory.
--- @param dst string The destination path where the symlink will be created.
--- @return boolean|nil, string? true on success; nil plus error message on failure.
function luaSysBridge.link_symlink(src, dst)
    local unistd = require("posix.unistd")
    local stat = require("posix.sys.stat")

    if type(src) ~= "string" or src == "" then
        return nil, "Invalid source path"
    end

    if type(dst) ~= "string" or dst == "" then
        return nil, "Invalid destination path"
    end

    -- lstat() checks the destination itself, including dangling symlinks.
    if stat.lstat(dst) then
        return nil, "Destination already exists: " .. dst
    end

    local ret, errstr, errnum = unistd.link(src, dst, true)

    if ret ~= 0 then
        return nil, string.format("Failed to create symlink: %s -> %s (errstr: %s, errnum: %s)", dst, src, errstr or "unknown error", tostring(errnum or "unknown"))
    end

    return true
    -- >>>>>>>>>>>>
    -- Old implementation -> without LUAPOSIX:
    -- Uses the native `ln -s` command and LuaFileSystem for existence checks.
    --
    -- local result = luaSysBridge.execute(string.format('ln -s "%s" "%s"', src, dst))
    -- if result ~= true and result ~= 0 then
    -- 	return nil, "Failed to create symlink: " .. dst
    -- end
    -- return true
    -- <<<<<<<<<<<<
end

--- Extract the base name of a path (GNU coreutils / bash basename compatible).
--- Handles trailing slashes, empty path, root, and optional suffix stripping.
--- Compatible with Lua 5.1–5.4 and LuaJIT.
---
--- Examples:
---   basename("/usr/bin/ls")           -> "ls"
---   basename("/usr/bin/ls", ".so")    -> "ls"     (no change)
---   basename("/usr/bin/ls.so", ".so") -> "ls"
---   basename("/")                     -> "/"
---   basename("//")                    -> "/"
---   basename("")                      -> ""
---   basename("a///")                  -> "a"
---
--- @param path string|nil Path to process
--- @param suffix string|nil Optional suffix to strip if present at the end
--- @return string Base name
function luaSysBridge.basename(path, suffix)
    path = tostring(path or "")

    -- Remove trailing slashes (but keep a single "/" for root)
    local cleaned = path:gsub("/+$", "")
    if cleaned == "" then
        return "/"
    end

    -- Extract the last component
    local base = cleaned:match("[^/]*$") or cleaned

    -- Optional suffix stripping (GNU basename behaviour)
    if suffix and suffix ~= "" and #base >= #suffix and base:sub(-#suffix) == suffix then
        base = base:sub(1, #base - #suffix)
    end

    return base
end

--- Extract the directory name of a path (GNU coreutils / bash dirname compatible).
--- Handles trailing slashes, empty path, root, and relative paths correctly.
--- Compatible with Lua 5.1–5.4 and LuaJIT.
---
--- Examples:
---   dirname("/usr/bin/ls")  -> "/usr/bin"
---   dirname("/usr/bin/")    -> "/usr"
---   dirname("/")            -> "/"
---   dirname("//")           -> "/"
---   dirname("a")            -> "."
---   dirname("a/b/c/")       -> "a/b"
---   dirname("")             -> "."
---
--- @param path string|nil Path to process
--- @return string Directory name
function luaSysBridge.dirname(path)
    path = tostring(path or "")

    -- Remove trailing slashes (but keep a single "/" for root)
    local cleaned = path:gsub("/+$", "")
    if cleaned == "" then
        return "/"
    end

    -- Extract everything before the last component
    local dir = cleaned:match("^(.*)/[^/]*$")
    if not dir then
        -- No slash found -> current directory
        return "."
    end

    -- Empty dir means root
    if dir == "" then
        return "/"
    end

    return dir
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

--- Set an environment variable for the current process (and any subsequently executed children).
--- Uses LUAPOSIX posix.setenv.
--- Compatible with Lua 5.1–5.4 and LuaJIT.
---
--- After calling this function the new value is immediately visible via getenv()
--- and will be inherited by any program started with execvp / execute / iopopen etc.
---
--- @param name  string  Name of the environment variable (must be non-empty)
--- @param value string  Value to set (may be empty string)
--- @param overwrite boolean|nil  If false, do not overwrite an existing variable
---                                 (default: true – always overwrite)
--- @return boolean true on success
--- @return string|nil error message on failure
function luaSysBridge.setenv(name, value, overwrite)
    if type(name) ~= "string" or name == "" then
        return false, "setenv(): name must be a non-empty string"
    end
    if type(value) ~= "string" then
        return false, "setenv(): value must be a string"
    end

    -- default: overwrite existing variable
    if overwrite == nil then
        overwrite = true
    end

    local posix = require("posix")

    -- posix.setenv returns 0 on success, nil + errmsg on failure
    local ret, err = posix.setenv(name, value, overwrite)

    if ret ~= 0 then
        return false, err or "setenv failed"
    end

    return true
end

--- Change file or dir owner and group. Uses LUAPOSIX:
--- https://luaposix.github.io/luaposix/modules/posix.unistd.html#chown
--- Compatible with Lua 5.1–5.4 and LuaJIT.
--- Accepts both numeric IDs (uid/gid) and symbolic names (e.g. "root", "www-data").
--- @param path string  Target single file or directory
--- @param owner string|number|nil  User name or numeric uid. Nil means "do not change"
--- @param group string|number|nil  Group name or numeric gid. Nil means "do not change"
--- @return boolean true on success
--- @return string? error message on failure
function luaSysBridge.chown(path, owner, group)
    if type(path) ~= "string" or path == "" then
        error("Invalid path (must be a non-empty string): " .. tostring(path))
    end

    local unistd = require("posix.unistd")
    local pwd = require("posix.pwd")
    local grp = require("posix.grp")

    -- Resolve owner to uid
    local uid
    if owner == nil then
        uid = -1 -- POSIX: passing -1 means "do not change"
    elseif type(owner) == "number" then
        uid = owner
    elseif type(owner) == "string" then
        local pw = pwd.getpwnam(owner)
        if not pw then
            return false, string.format("Unknown user: %s", owner)
        end
        uid = pw.pw_uid
    else
        return false, "Invalid owner type (must be number, string or nil)"
    end

    -- Resolve group to gid
    local gid
    if group == nil then
        gid = -1 -- POSIX: passing -1 means "do not change"
    elseif type(group) == "number" then
        gid = group
    elseif type(group) == "string" then
        local gr = grp.getgrnam(group)
        if not gr then
            return false, string.format("Unknown group: %s", group)
        end
        gid = gr.gr_gid
    else
        return false, "Invalid group type (must be number, string or nil)"
    end

    -- execute chown
    local ret, err_msg = unistd.chown(path, uid, gid)

    if ret ~= 0 then
        return false, string.format("chown failed on: %s", err_msg or "unknown error")
    end

    return true
end

--- Read the contents of one or more files, equivalent to the Unix `cat` command.
--- Concatenates the contents of all given files in the order provided (no extra separators).
--- Compatible with Lua 5.1–5.4 and LuaJIT.
---
--- Typical usage (shell-like assignment):
---   local key = luaSysBridge.cat("/path/to/secret")
---   -- or with multiple files:
---   local combined = luaSysBridge.cat({ "part1.txt", "part2.txt" })
---   -- with trimming (useful for keys / tokens):
---   local key = luaSysBridge.cat("/path/to/secret", { trim = true })
---
--- @param path_or_paths string|table Single file path, or array of file paths to concatenate
--- @param opts table|nil Options:
---   binary  boolean  Open files in binary mode ("rb") instead of text mode ("r").
---                    Default: false (text mode). Use true when reading binary data
---                    or when exact byte-for-byte content must be preserved.
---   trim    boolean  Strip leading and trailing whitespace (including newlines)
---                    from the final concatenated result. Default: false.
---                    Useful for reading single-line secrets / keys / tokens.
--- @return string|nil content Concatenated (and optionally trimmed) file contents on success
--- @return string|nil err     Error message on failure (nil on success)
function luaSysBridge.cat(path_or_paths, opts)
    opts = opts or {}

    local binary = opts.binary == true
    local trim = opts.trim == true
    local mode = binary and "rb" or "r"

    local paths
    if type(path_or_paths) == "string" then
        paths = { path_or_paths }
    elseif type(path_or_paths) == "table" then
        paths = path_or_paths
    else
        return nil, "cat(): first argument must be a string or a table of strings"
    end

    if #paths == 0 then
        return ""
    end

    local contents = {}

    for _, path in ipairs(paths) do
        if type(path) ~= "string" or path == "" then
            return nil, "cat(): all paths must be non-empty strings"
        end

        -- Prefer explicit regular-file check for clearer errors (consistent with other helpers)
        if not luaSysBridge.exists_file(path) then
            return nil, "cat(): file does not exist or is not a regular file: " .. path
        end

        local f, err = io.open(path, mode)
        if not f then
            return nil, "cat(): cannot open " .. path .. ": " .. tostring(err)
        end

        local content = f:read("*a")
        f:close()

        if content == nil then
            return nil, "cat(): cannot read " .. path
        end

        table.insert(contents, content)
    end

    local result = table.concat(contents)

    if trim then
        result = result:match("^%s*(.-)%s*$") or ""
    end

    return result
end

--- Change file/dir permissions. Uses LUAPOSIX:
--- https://luaposix.github.io/luaposix/modules/posix.html#chmod
--- Accepts classic notation like 'rwxrwxrwx' (e.g. 'rw-rw-r--').
--- It should also work with traditional notation: 755,777, etc.
--- @param path string   single file/directory path
--- @param mode number|string   Permission mode, e.g. "rw-rw-r--", "755", "755"
--- @return boolean true on success, false otherwise.
--- @return string? error message on failure.
function luaSysBridge.chmod(path, mode)
    if type(path) ~= "string" or path == "" then
        error("Invalid path (must be a non-empty string): " .. path)
    end

    local posix = require("posix")

    if tonumber(mode) then
        -- add leading "0" if required
        if mode:sub(1, 1) ~= "0" then
            mode = "0" .. mode
        end
    end

    local ret, err_msg = posix.chmod(path, mode)
    if ret ~= 0 then
        return false, string.format("chmod failed on %s: %s", path, err_msg or "unknown error")
    end

    return true

    -- >>>>>>>>>>>>
    -- Old implementation -> without LUAPOSIX:
    -- Uses the native 'chmod' via "os.execute".
    --
    -- local success = luaSysBridge.execute(string.format("chmod %o %s", mode, "'" .. path:gsub("'", "'\\''") .. "'"))
    -- if not success then
    --     return false, string.format("ERROR: Could not set permissions: %s", path)
    -- end
    -- <<<<<<<<<<<<
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

    --
    -- Alternative implementation for "mode_str":
    --
    -- https://luaposix.github.io/luaposix/modules/posix.html#chmod
    -- Extract permission bits as octal string (e.g., "0644").
    -- WARNING! Changes in this implementation may break compatibility with different versions of Lua!
    -- But the following solution has been tested and works satisfactorily:
    --
    -- Compatible with Lua 5.1, 5.2, 5.3, 5.4 (no 0o literals needed).
    -- "mode_str" can have values ​​e.g. "0577", "0755", "0755" etc, and it works fine
    --
    -- local sys_stat = require("posix.sys.stat")
    -- local st = sys_stat.stat(src)
    -- if st then
    -- 	local mode_num = st.st_mode % 512
    -- 	local mode_str = string.format("%04o", mode_num)
    -- (...)
    --

    local src_attr = lfs.attributes(src)

    if not src_attr then
        -- file copy succeeded, but permissions are optional
        return true
    end

    local mode_str = src_attr.permissions

    if mode_str then
        local ret, err_msg = luaSysBridge.chmod(dst, mode_str)
        if not ret then
            error("ERROR: Could not set permissions on destination file: " .. (err_msg or "unknown error"))
        end
    else
        error("ERROR: Could not set permissions on destination file!")
    end

    return true

    -- >>>>>>>>>>>>
    -- Old implementation -> without LUAPOSIX:
    -- Uses the native 'chmod' via "os.execute" and copies permissions (chmod, Unix-only) via "lfs.attributes"
    --
    -- src_attr = lfs.attributes(src)
    -- if src_attr.permissions then
    -- 	-- Parse symbolic permissions string (e.g., "rw-r--r--") to octal number
    -- 	local function parse_permissions(perm)
    -- 		if #perm ~= 9 then
    -- 			return nil
    -- 		end
    -- 		local function bits(s)
    -- 			return (s:find("r") and 4 or 0) + (s:find("w") and 2 or 0) + (s:find("x") and 1 or 0) + (s:find("[sStT]") and 0 or 0)
    -- 		end -- Ignore setuid/sticky for basic chmod
    -- 		return bits(perm:sub(1, 3)) * 64 + bits(perm:sub(4, 6)) * 8 + bits(perm:sub(7, 9))
    -- 	end
    --
    -- 	local perm_str = src_attr.permissions
    -- 	local mode_num = parse_permissions(perm_str)
    -- 	if mode_num then
    -- 	end
    -- end
    -- <<<<<<<<<<<<
end

--- Recursively copies a directory from "src" to "dst", preserving structure and permissions.
--- Compatible with Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT.
--- Uses lfs and LUAPOSIX when required.
--- When copying, skips symlinks that are not supported and should be handled separately.
--- @param src string The source directory path (must be a non-empty string).
--- @param dst string The destination directory path (must be a non-empty string).
--- @param symlink_quiet boolean [optional] If true, suppresses warnings when symlinks are skipped (default: false).
--- @return boolean true on success.
function luaSysBridge.copy_dir(src, dst, symlink_quiet)
    -- Default symlink_quiet to false if not provided
    if symlink_quiet == nil then
        symlink_quiet = false
    end

    -- Validate input paths
    if type(src) ~= "string" or src == "" then
        error("Invalid source path (src)")
    end
    if type(dst) ~= "string" or dst == "" then
        error("Invalid destination path (dst)")
    end

    -- Verify that src exists and is directory
    local src_attr = lfs.attributes(src)
    if not src_attr or src_attr.mode ~= "directory" then
        error("Source is not a directory: " .. tostring(src))
    end

    -- Ensure destination directory exists
    local dst_attr = lfs.attributes(dst)
    if not dst_attr then
        local ok, err = luaSysBridge.mkdir(dst)
        if not ok then
            error("Cannot create destination directory: " .. tostring(err))
        end
    elseif dst_attr.mode ~= "directory" then
        error("Destination exists and is not a directory: " .. tostring(dst))
    end

    -- Optional: fetch permission string from source directory
    local dir_perm = src_attr.permissions
    if not dir_perm then
        error("Could not read permissions from source directory.")
    end

    -- Try to set permissions on destination directory
    local ok_perm, err_perm = luaSysBridge.chmod(dst, dir_perm)
    if not ok_perm then
        error("Failed to set permissions on directory: " .. tostring(err_perm))
    end

    -- Recursive traversal (symlinks are ignored)
    for entry in lfs.dir(src) do
        if entry ~= "." and entry ~= ".." then
            local src_path = src .. "/" .. entry
            local dst_path = dst .. "/" .. entry

            local is_link = false
            local ok_symlink, res_symlink = pcall(luaSysBridge.exists_symlink, src_path)
            if ok_symlink and res_symlink == true then
                is_link = true
            end

            if is_link then
                -- Skip symlink, optionally print warning
                if not symlink_quiet then
                    print("WARNING! copy_dir -> symlink skipped: " .. tostring(src_path))
                end
            else
                -- Normal file or directory handling
                local attr = lfs.attributes(src_path)
                if not attr then
                    error("Cannot read attributes of: " .. tostring(src_path))
                end

                if attr.mode == "file" then
                    local ok, err = pcall(luaSysBridge.copy_file, src_path, dst_path)
                    if not ok then
                        error("File copy failed for: " .. src_path .. " -> " .. dst_path .. " :: " .. tostring(err))
                    end
                elseif attr.mode == "directory" then
                    local ok, err = pcall(luaSysBridge.copy_dir, src_path, dst_path, symlink_quiet)
                    if not ok then
                        error("Directory copy failed for: " .. src_path .. " -> " .. dst_path .. " :: " .. tostring(err))
                    end
                end
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
--- Works like `shutil.which`; returns the absolute path to the executable or nil if not found.
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

    -- >>>>>>>>>>>>
    -- Old implementation -> without LUAPOSIX:
    -- Uses the system `hostname` command.
    --
    -- local success, _, stdout = luaSysBridge.iopopen_stdout_err("hostname")
    -- if not success then
    -- 	error("Failed to obtain host name: " .. stdout)
    -- end
    -- return (stdout:gsub("\n", ""))
    -- <<<<<<<<<<<<
end

--- Execute a main function protected with pcall.
--- Use `local function main()` and pass that function as the `main` argument.
--- Errors other than "interrupted" or "interrupted!" are silently dismissed.
--- Errors equal to "interrupted" or "interrupted!" are printed to stdout.
--- The function is intended for use with Lua 5.1 interrupt handling,
--- where Ctrl+C may result in an error with one of these values.
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

--- Parses an OpenSSH-style `~/.ssh/config` file into a Lua table.
--- Compatible with Lua 5.1–5.4 and LuaJIT.
--- @param path string [optional] Path to the SSH config file. If nil, defaults to `$HOME/.ssh/config` or `./.ssh/config`.
--- @return table|nil If success: { global = { ... }, hosts = { { patterns = {...}, config = {...} }, ... } }, nil otherwise
--- @return nil err Returns nil plus an error message string on failure.
function luaSysBridge.ssh_table_load_config(path)
    -- Helper: safe getenv and default to HOME/.ssh/config
    local getenv = os.getenv
    local home = getenv and getenv("HOME") or nil
    local default = (home and (home .. "/.ssh/config")) or ".ssh/config"

    local target = path or default

    -- Utilities
    local function trim(s)
        if not s then
            return s
        end
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    local function split_once(s)
        -- split on first whitespace sequence
        if not s then
            return nil, nil
        end
        local key, rest = s:match("^%s*([^%s]+)%s*(.*)$")
        if not key then
            return nil, nil
        end
        rest = rest or ""
        rest = trim(rest)
        return key, rest
    end

    local function unquote(v)
        if not v then
            return v
        end
        local q = v:match('^"(.*)"$') or v:match("^'(.*)'$")
        if q then
            return q
        end
        return v
    end

    -- Normalize path with ~
    local function expand_tilde(p)
        if not p then
            return p
        end
        if p:sub(1, 2) == "~/" and home then
            return home .. p:sub(2)
        end
        return p
    end

    -- Try to expand include globs. Use lfs if available, otherwise try io.popen + shell.
    local function expand_glob(pattern)
        if not pattern then
            return {}
        end
        pattern = expand_tilde(pattern)

        -- Quick path: no glob meta-characters -> return single if exists
        if not pattern:find("[%*%?%[]") then
            -- simple existence check
            local f = io.open(pattern, "r")
            if f then
                f:close()
                return { pattern }
            end
            return {}
        end

        -- split into dir + basemode
        local dir, base = pattern:match("^(.-)/([^/]+)$")
        if not dir then
            dir = "."
            base = pattern
        end
        dir = dir == "" and "." or dir

        -- convert shell glob to Lua pattern
        local function glob_to_lua(pat)
            -- very small conversion: * -> .*, ? -> ., [..] -> %[%] keep
            pat = pat:gsub("([%^%$%(%)%%%.%+%-%])", "%%%1") -- escape magic
            pat = pat:gsub("%%%*", ".*")
            pat = pat:gsub("%%%?", ".")
            -- bracket expressions: keep as-is (naive)
            pat = pat:gsub("%%(%[.-%])", "%1")
            return "^" .. pat .. "$"
        end
        local lua_pat = glob_to_lua(base)
        local res = {}
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                if entry:match(lua_pat) then
                    table.insert(res, dir .. "/" .. entry)
                end
            end
        end
        table.sort(res)
        return res
    end

    -- Internal: parse a single file
    local function parse_file(fname, accumulator)
        local f, err = io.open(fname, "r")
        if not f then
            return nil, ("cannot open file: " .. tostring(err or fname))
        end

        -- table { patterns = {...}, config = {...} }
        local current_host = nil
        for rawline in f:lines() do
            -- Remove any leading or trailing whitespace
            local line = rawline
            -- Remove comments: '#' that is not inside quotes - simple heuristic: strip from first unquoted #
            local i = 1
            local in_single, in_double = false, false
            local outchars = {}
            while i <= #line do
                local ch = line:sub(i, i)
                if ch == "'" and not in_double then
                    in_single = not in_single
                end
                if ch == '"' and not in_single then
                    in_double = not in_double
                end
                if ch == "#" and not in_single and not in_double then
                    break -- stop at comment
                end
                table.insert(outchars, ch)
                i = i + 1
            end
            line = table.concat(outchars)
            line = trim(line)
            if line ~= "" then
                -- Handle continuation lines ending with '\'
                while line:match("\\%s*$") do
                    -- remove trailing backslash
                    line = line:gsub("\\%s*$", "")
                    local cont = f:read("*l")
                    if not cont then
                        break
                    end
                    -- remove comments from continuation similarly
                    local j = 1
                    local ins, ind = false, false
                    local outc = {}
                    while j <= #cont do
                        local ch2 = cont:sub(j, j)
                        if ch2 == "'" and not ind then
                            ins = not ins
                        end
                        if ch2 == '"' and not ins then
                            ind = not ind
                        end
                        if ch2 == "#" and not ins and not ind then
                            break
                        end
                        table.insert(outc, ch2)
                        j = j + 1
                    end
                    cont = trim(table.concat(outc))
                    line = line .. " " .. cont
                end

                local key, rest = split_once(line)
                -- skip malformed
                if key then
                    local lower = key:lower()
                    if lower == "host" then
                        -- Start new host block. 'rest' contains one or more patterns
                        local patterns = {}
                        if rest then
                            for p in rest:gmatch("%S+") do
                                p = unquote(p)
                                table.insert(patterns, p)
                            end
                        end
                        -- finalize previous host if exists
                        if current_host then
                            table.insert(accumulator.hosts, current_host)
                        end
                        current_host = { patterns = patterns, config = {} }
                    elseif lower == "include" then
                        -- Expand include(s) and parse each file immediately
                        -- rest may contain multiple space-separated patterns
                        if rest ~= nil then
                            for pattern in rest:gmatch("%S+") do
                                pattern = unquote(pattern)
                                local files = expand_glob(pattern) or {} -- fallback na pustą tabelę
                                for _, inc in ipairs(files) do
                                    parse_file(inc, accumulator) -- ignore returned error for includes
                                end
                            end
                        end
                    else
                        -- Regular option. If inside a Host block, attach to it; otherwise to global.
                        local optname = key
                        local optval = unquote(rest)
                        -- Some directives like 'hostname' may be case-insensitive; preserve original casing but store keys as given.
                        if current_host then
                            -- If option already exists, convert to list to preserve multiple occurrences
                            local cfg = current_host.config
                            if cfg[optname] == nil then
                                cfg[optname] = optval
                            else
                                if type(cfg[optname]) == "table" then
                                    table.insert(cfg[optname], optval)
                                else
                                    cfg[optname] = { cfg[optname], optval }
                                end
                            end
                        else
                            local g = accumulator.global
                            if g[optname] == nil then
                                g[optname] = optval
                            else
                                if type(g[optname]) == "table" then
                                    table.insert(g[optname], optval)
                                else
                                    g[optname] = { g[optname], optval }
                                end
                            end
                        end
                    end
                end
            end
        end

        f:close()
        -- finalize last host
        if current_host then
            table.insert(accumulator.hosts, current_host)
        end

        return true
    end

    -- accumulator structure
    local accumulator = { global = {}, hosts = {} }

    -- Expand initial path in case it includes globs or ~
    local initial_paths = {}
    if target:find("[%*%?%[]") then
        initial_paths = expand_glob(target)
        if #initial_paths == 0 then
            -- if nothing matched, try literal
            table.insert(initial_paths, target)
        end
    else
        table.insert(initial_paths, expand_tilde(target))
    end

    -- Parse each file in order
    for _, fname in ipairs(initial_paths) do
        local ok, err = parse_file(fname, accumulator)
        if not ok then
            return nil, err
        end
    end

    -- Provide a convenience helper to lookup host-specific effective config (no pattern matching implementation here)
    -- The table returned does not attempt to resolve pattern matching; it provides the raw structure.
    -- If the user wants matching by hostname, they can implement fn that tests patterns (globs) against the target host.
    return accumulator
end

--- Get current working directory:
--- read in the place where the lua script was run (but not the location of the script).
--- Doesn't work with lfs.chdir() (which is wrapper around luaSysBridge.chdir()).
--- Only the path where the script was run will always be returned.
--- Uses LUAPOSIX. Falls back to the value of the PWD environment variable when available.
--- @return string current working directory path or "." when unknown
function luaSysBridge.pwd_os_pwd()
    local path
    local unistd = require("posix.unistd")
    path = unistd.getcwd()
    if not path then
        path = os.getenv("PWD")
    end
    return path or "."

    -- >>>>>>>>>>>>
    -- Old implementation -> without LUAPOSIX:
    -- Uses the system `pwd` command if required.
    -- if not path then
    -- 	local p = io.popen("pwd")
    -- 	if p then
    -- 		path = p:read("*l")
    -- 		p:close()
    -- 	end
    -- end
    -- <<<<<<<<<<<<
end

--- Wrapper around lfs.currentdir().
--- Wraps LuaFileSystem's currentdir for future compatibility and consistent API.
--- Works well with luaSysBridge.chdir() (which is wrapper around lfs.chdir()).
--- @return string|nil A string with the current working directory or nil plus an error string.
function luaSysBridge.pwd_currentdir()
    return lfs.currentdir()
end

--- Compatibility wrapper for table.unpack / unpack.
--- Works on Lua 5.1 + LuaJIT (global `unpack`) and Lua 5.2+ (`table.unpack`).
--- @param ... any  table [, i [, j ]]
--- @return ... Unpacked values
luaSysBridge.table_unpack = table.unpack or unpack

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
--- Uses LUAPOSIX to check.
--- This function validates its argument and raises an error for invalid input.
--- @param path string Non-empty file system path to check.
--- @return boolean True if the path is a symbolic link, false otherwise.
function luaSysBridge.exists_symlink(path)
    -- Validate argument
    if type(path) ~= "string" or path == "" then
        error("Invalid path: expected a non-empty string")
    end

    local sys_stat = require("posix.sys.stat")
    -- lstat returns nil on error, table on success
    local st = sys_stat.lstat(path)
    if not st then
        -- If the file does not exist or is inaccessible, it cannot be a symlink
        return false
    end

    -- S_ISLNK returns non-zero if true, so compare to 0:
    -- "int non-zero if mode represents a symbolic link"
    return sys_stat.S_ISLNK(st.st_mode) ~= 0

    -- >>>>>>>>>>>>
    -- Old implementation -> without LUAPOSIX:
    -- Uses the external shell "test -L" command.
    --
    -- -- Escape path to handle spaces and special characters.
    -- -- Use single quotes and escape single quotes inside the path.
    -- local escaped_path = "'" .. path:gsub("'", "'\\''") .. "'"
    -- local cmd = "test -L " .. escaped_path

    -- -- Execute the test command; success == true means path is a symlink.
    -- local success, _ = luaSysBridge.execute(cmd)
    -- return success
    -- <<<<<<<<<<<<
end

--- Create (if needed) or update a file's timestamps, equivalent to shell "touch".
--- Uses only Lua standard I/O and LuaFileSystem.
--- @param path string Path to the file to touch.
--- @param atime number|nil Optional access time (Unix timestamp). Defaults to current time.
--- @param mtime number|nil Optional modification time (Unix timestamp). Defaults to atime.
--- @return boolean success True on success, false otherwise.
--- @return string|nil err Error message on failure, nil on success.
function luaSysBridge.touch(path, atime, mtime)
    if type(path) ~= "string" or path == "" then
        error("Invalid path (must be a non-empty string): " .. tostring(path))
    end

    -- If file does not exist, create an empty one using built-in Lua I/O.
    local attr = lfs.attributes(path, "mode")
    if not attr then
        local f, err = io.open(path, "a")
        if not f then
            return false, "Cannot create file: " .. tostring(err)
        end
        f:close()
    end

    -- Default times: current time if not provided.
    local now = luaSysBridge.time()
    atime = atime or now
    mtime = mtime or atime

    -- Use LuaFileSystem to set timestamps.
    local ok, err = lfs.touch(path, atime, mtime)
    if not ok then
        return false, "Failed to touch file: " .. tostring(err)
    end

    return true
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
--- @param path string|nil Optional path to a git repository; if provided, changes working directory before running.
--- @return string|nil Selected commit hash or nil if nothing selected.
function luaSysBridge.git_fzf_select_commit(path)
    -- If path is provided, change directory
    if path and #path > 0 then
        luaSysBridge.chdir(path)
    end

    -- Run git log piped to fzf:
    local success, _, selection = luaSysBridge.iopopen_stdout_err("git log --date=iso --pretty=format:'%H %ad %s' | fzf --ansi --no-sort --tac")
    if not success then
        return nil
    end

    if selection and #selection > 0 then
        -- Extract commit hash (first non-space sequence)
        local commit_ref = selection:match("^(%S+)")
        return commit_ref
    else
        return nil
    end
end

--- Reset repository to a given commit and perform cleanup.
--- Runs: git reset --hard <commit_ref>, git reflog expire, git gc.
--- @param commit_ref string Commit hash to reset to.
--- @param path string|nil Optional path to a git repository; if provided, changes working directory before running.
--- @return boolean success True if all commands executed successfully, false otherwise.
function luaSysBridge.git_reset_and_cleanup(commit_ref, path)
    -- Validate commit_ref
    if not commit_ref or #commit_ref == 0 then
        return false
    end

    -- Change directory if path is provided
    if path and #path > 0 then
        luaSysBridge.chdir(path)
    end

    local success1 = luaSysBridge.execute("git reset --hard " .. commit_ref)
    if not success1 then
        return false
    end

    local success2 = luaSysBridge.execute("git reflog expire --expire=now --all")
    if not success2 then
        return false
    end

    local success3 = luaSysBridge.execute("git gc --prune=now --aggressive")
    if not success3 then
        return false
    end

    return true
end

--- Stage all changes and commit with msg1 (timestamp) and optional msg2.
--- Runs: git add -A ., git commit -m <msg1> -m <msg2>.
--- @param path string|nil Optional path to a git repository; if provided, changes working directory before running.
--- @param msg1 string|nil Optional msg1 string; if not provided, defaults to luaSysBridge.date("%Y-%m-%d_%H:%M:%S").
--- @param msg2 string|nil Optional commit message msg2; if provided, used as the second -m argument.
--- @return boolean success True if all commands executed successfully, false otherwise.
function luaSysBridge.git_add_and_commit(path, msg1, msg2)
    -- Change directory if path is provided
    if path and #path > 0 then
        luaSysBridge.chdir(path)
    end

    -- Stage all changes
    local success1 = luaSysBridge.execute("git add -A .")
    if not success1 then
        return false
    end

    -- Use provided timestamp or default
    local msg_or_ts = (msg1 and #msg1 > 0) and msg1 or luaSysBridge.date("%Y-%m-%d_%H:%M:%S")

    local commit_cmd
    if msg2 and #msg2 > 0 then
        commit_cmd = 'git commit -m "' .. msg_or_ts .. '" -m "' .. msg2 .. '"'
    else
        commit_cmd = 'git commit -m "' .. msg_or_ts .. '"'
    end

    local success2 = luaSysBridge.execute(commit_cmd)
    if not success2 then
        return false
    end

    return true
end

--- @param file1 string Path to the first file
--- @param file2 string Path to the second file
--- @param opts table|nil Options:
---   context                number  Number of context lines (default: 3)
---   brief                  boolean Only report whether files differ
---   ignore_all_space       boolean Ignore all whitespace
---   ignore_space_change    boolean Ignore changes in whitespace amount
---   ignore_blank_lines     boolean Ignore blank lines
---   ignore_case            boolean Ignore case
---   strip_trailing_cr      boolean Remove trailing CR from every line
---   ignore_trailing_cr     boolean Alias for strip_trailing_cr
---   ignore_matching_lines  string  Ignore changes consisting only of
---                                  lines matching this Lua pattern
---   minimal                boolean Reserved for compatibility
---   color                  boolean Enable ANSI colors via the ansicolors
---                                  module (default: false / off).
---                                  When enabled:
---                                    - meta (--- / +++ / @@ headers) -> blue
---                                    - content A (deletions, "-" lines) -> red
---                                    - content B (insertions, "+" lines) -> green
---                                  Context lines (" " prefix) stay uncolored.
---                                  Requires: local ansicolors = require("ansicolors")
---
--- @return boolean, integer, string
function luaSysBridge.diff(file1, file2, opts)
    opts = opts or {}

    local context = tonumber(opts.context) or 3
    if context < 0 then
        context = 0
    end

    local strip_trailing_cr = opts.strip_trailing_cr or opts.ignore_trailing_cr

    local ignore_matching_lines = opts.ignore_matching_lines

    -- Optional ANSI color support (default: off)
    local use_color = opts.color == true
    local ansicolors
    if use_color then
        ansicolors = require("ansicolors")
    end

    -- Color helpers (no-op when color is disabled)
    local function color_meta(s)
        if use_color then
            return ansicolors("%{blue}" .. s)
        end
        return s
    end

    -- Content A is displayed as "+" and green.
    local function color_a(s)
        if use_color then
            return ansicolors("%{green}" .. s)
        end
        return s
    end

    -- Content B is displayed as "-" and red.
    local function color_b(s)
        if use_color then
            return ansicolors("%{red}" .. s)
        end
        return s
    end

    ----------------------------------------------------------------------
    -- Helpers
    ----------------------------------------------------------------------

    local function read_lines(path)
        local f, err = io.open(path, "r")
        if not f then
            return nil, err
        end

        local lines = {}

        for line in f:lines() do
            if strip_trailing_cr then
                line = line:gsub("\r$", "")
            end

            table.insert(lines, line)
        end

        f:close()
        return lines
    end

    local function normalize(line)
        if opts.ignore_all_space then
            line = line:gsub("%s+", "")
        elseif opts.ignore_space_change then
            line = line:gsub("%s+", " ")
            line = line:gsub("^%s+", "")
            line = line:gsub("%s+$", "")
        end

        if opts.ignore_case then
            line = line:lower()
        end

        return line
    end

    local function is_blank(line)
        return line:match("^%s*$") ~= nil
    end

    ----------------------------------------------------------------------
    -- GNU diff -I-like matching.
    --
    -- ignore_matching_lines is a Lua pattern, not a POSIX/PCRE regex.
    -- The pattern must match the entire line.
    ----------------------------------------------------------------------

    local ignore_pattern

    if ignore_matching_lines then
        ignore_pattern = "^" .. ignore_matching_lines .. "$"
    end

    local function matches_ignore_pattern(line)
        if not ignore_pattern then
            return false
        end

        return line:match(ignore_pattern) ~= nil
    end

    ----------------------------------------------------------------------
    -- Read files
    ----------------------------------------------------------------------

    local a, err1 = read_lines(file1)
    if not a then
        return false, 2, "diff(): cannot read " .. tostring(file1) .. ": " .. tostring(err1)
    end

    local b, err2 = read_lines(file2)
    if not b then
        return false, 2, "diff(): cannot read " .. tostring(file2) .. ": " .. tostring(err2)
    end

    ----------------------------------------------------------------------
    -- Optional blank-line filtering
    ----------------------------------------------------------------------

    if opts.ignore_blank_lines then
        local function filter_blank(t)
            local r = {}

            for _, line in ipairs(t) do
                if not is_blank(line) then
                    table.insert(r, line)
                end
            end

            return r
        end

        a = filter_blank(a)
        b = filter_blank(b)
    end

    local na = #a
    local nb = #b

    ----------------------------------------------------------------------
    -- Build normalized versions for comparison.
    ----------------------------------------------------------------------

    local na_norm = {}
    local nb_norm = {}

    for i = 1, na do
        na_norm[i] = normalize(a[i])
    end

    for i = 1, nb do
        nb_norm[i] = normalize(b[i])
    end

    ----------------------------------------------------------------------
    -- Myers diff
    --
    -- Finds a shortest edit script using O(ND) time.
    --
    -- The trace is retained for backtracking, so this implementation
    -- does not use the linear-space "middle snake" variant.
    ----------------------------------------------------------------------

    local function myers_diff()
        local n = na
        local m = nb

        if n == 0 then
            local result = {}

            for j = 1, m do
                table.insert(result, {
                    "insert",
                    0,
                    j,
                })
            end

            return result
        end

        if m == 0 then
            local result = {}

            for i = 1, n do
                table.insert(result, {
                    "delete",
                    i,
                    0,
                })
            end

            return result
        end

        local max = n + m
        local offset = max + 1

        local v = {}
        v[offset] = 0

        local trace = {}
        local final_d

        for d = 0, max do
            local v_next = {}

            for k = -d, d, 2 do
                local k_index = k + offset
                local x

                if k == -d then
                    x = v[k_index + 1] or 0
                elseif k == d then
                    x = (v[k_index - 1] or 0) + 1
                else
                    local down = v[k_index + 1] or 0
                    local right = (v[k_index - 1] or 0) + 1

                    if right > down then
                        x = right
                    else
                        x = down
                    end
                end

                local y = x - k

                while x < n and y < m and na_norm[x + 1] == nb_norm[y + 1] do
                    x = x + 1
                    y = y + 1
                end

                v_next[k_index] = x

                if x >= n and y >= m then
                    trace[d] = v_next
                    final_d = d
                    break
                end
            end

            if final_d then
                break
            end

            trace[d] = v_next
            v = v_next
        end

        ------------------------------------------------------------------
        -- Backtrack
        ------------------------------------------------------------------

        local script = {}

        local x = n
        local y = m

        for d = final_d, 1, -1 do
            local previous = trace[d - 1]

            local k = x - y
            local k_index = k + offset

            local prev_k

            if k == -d or (k ~= d and (previous[k_index - 1] or 0) < (previous[k_index + 1] or 0)) then
                -- Insertion.
                prev_k = k + 1
            else
                -- Deletion.
                prev_k = k - 1
            end

            local prev_x = previous[prev_k + offset] or 0

            local prev_y = prev_x - prev_k

            ----------------------------------------------------------------
            -- Consume equal lines along the diagonal.
            ----------------------------------------------------------------

            while x > prev_x and y > prev_y do
                table.insert(script, 1, {
                    "equal",
                    x,
                    y,
                })

                x = x - 1
                y = y - 1
            end

            ----------------------------------------------------------------
            -- Consume the actual edit.
            ----------------------------------------------------------------

            if x == prev_x then
                table.insert(script, 1, {
                    "insert",
                    x,
                    y,
                })

                y = y - 1
            else
                table.insert(script, 1, {
                    "delete",
                    x,
                    y,
                })

                x = x - 1
            end
        end

        ------------------------------------------------------------------
        -- Remaining prefix.
        ------------------------------------------------------------------

        while x > 0 and y > 0 do
            table.insert(script, 1, {
                "equal",
                x,
                y,
            })

            x = x - 1
            y = y - 1
        end

        while x > 0 do
            table.insert(script, 1, {
                "delete",
                x,
                0,
            })

            x = x - 1
        end

        while y > 0 do
            table.insert(script, 1, {
                "insert",
                0,
                y,
            })

            y = y - 1
        end

        return script
    end

    ----------------------------------------------------------------------
    -- Generate edit script.
    ----------------------------------------------------------------------

    local script = myers_diff()

    ----------------------------------------------------------------------
    -- ignore_matching_lines
    --
    -- Ignore a change when every inserted/deleted line in that contiguous
    -- change matches the supplied Lua pattern.
    ----------------------------------------------------------------------

    if ignore_pattern then
        local filtered = {}
        local p = 1

        while p <= #script do
            if script[p][1] == "equal" then
                table.insert(filtered, script[p])
                p = p + 1
            else
                local q = p
                local all_match = true

                while q <= #script and script[q][1] ~= "equal" do
                    local op = script[q][1]

                    if op == "delete" then
                        local index = script[q][2]

                        if not matches_ignore_pattern(a[index]) then
                            all_match = false
                        end
                    elseif op == "insert" then
                        local index = script[q][3]

                        if not matches_ignore_pattern(b[index]) then
                            all_match = false
                        end
                    end

                    q = q + 1
                end

                if not all_match then
                    for k = p, q - 1 do
                        table.insert(filtered, script[k])
                    end
                end

                p = q
            end
        end

        script = filtered
    end

    ----------------------------------------------------------------------
    -- Determine whether files differ.
    ----------------------------------------------------------------------

    local has_diff = false

    for _, op in ipairs(script) do
        if op[1] ~= "equal" then
            has_diff = true
            break
        end
    end

    ----------------------------------------------------------------------
    -- Brief mode.
    ----------------------------------------------------------------------

    if opts.brief then
        if has_diff then
            return false, 1, string.format("Files %s and %s differ\n", file1, file2)
        end

        return true, 0, ""
    end

    if not has_diff then
        return true, 0, ""
    end

    ----------------------------------------------------------------------
    -- Unified diff.
    ----------------------------------------------------------------------

    local out = {}

    table.insert(out, color_meta(string.format("--- %s\n", file1)))
    table.insert(out, color_meta(string.format("+++ %s\n", file2)))

    ----------------------------------------------------------------------
    -- Hunk generation.
    --
    -- Hunks separated by <= context equal lines are merged.
    ----------------------------------------------------------------------

    local h = 1

    while h <= #script do
        ------------------------------------------------------------------
        -- Find next change.
        ------------------------------------------------------------------

        while h <= #script and script[h][1] == "equal" do
            h = h + 1
        end

        if h > #script then
            break
        end

        local hunk_start = h

        ------------------------------------------------------------------
        -- Context before.
        ------------------------------------------------------------------

        local ctx_before = 0

        while hunk_start > 1 and ctx_before < context and script[hunk_start - 1][1] == "equal" do
            hunk_start = hunk_start - 1
            ctx_before = ctx_before + 1
        end

        ------------------------------------------------------------------
        -- Find end of changes.
        ------------------------------------------------------------------

        local hunk_end = h

        while hunk_end <= #script and script[hunk_end][1] ~= "equal" do
            hunk_end = hunk_end + 1
        end

        ------------------------------------------------------------------
        -- Context after.
        --
        -- If another change is encountered before context is exhausted,
        -- it becomes part of the same hunk.
        ------------------------------------------------------------------

        local ctx_after = 0

        while hunk_end <= #script and ctx_after < context and script[hunk_end][1] == "equal" do
            hunk_end = hunk_end + 1
            ctx_after = ctx_after + 1
        end

        hunk_end = hunk_end - 1

        ------------------------------------------------------------------
        -- Calculate old/new ranges.
        ------------------------------------------------------------------

        local old_start
        local old_count = 0

        local new_start
        local new_count = 0

        for k = hunk_start, hunk_end do
            local op, oi, nj = script[k][1], script[k][2], script[k][3]

            if op == "equal" or op == "delete" then
                if not old_start then
                    old_start = oi
                end

                old_count = old_count + 1
            end

            if op == "equal" or op == "insert" then
                if not new_start then
                    new_start = nj
                end

                new_count = new_count + 1
            end
        end

        if not old_start then
            old_start = 0
        end

        if not new_start then
            new_start = 0
        end

        ------------------------------------------------------------------
        -- GNU-style unified range.
        --
        -- count == 1:
        --     -10
        --
        -- count ~= 1:
        --     -10,3
        --
        -- This also handles zero-length ranges:
        --     -0,0
        ------------------------------------------------------------------

        local function format_range(start, count)
            if count == 1 then
                return tostring(start)
            end

            return string.format("%d,%d", start, count)
        end

        table.insert(out, color_meta(string.format("@@ -%s +%s @@\n", format_range(old_start, old_count), format_range(new_start, new_count))))

        ------------------------------------------------------------------
        -- Emit hunk.
        ------------------------------------------------------------------

        for k = hunk_start, hunk_end do
            local op, oi, nj = script[k][1], script[k][2], script[k][3]

            if op == "equal" then
                table.insert(out, " " .. a[oi] .. "\n")
            elseif op == "delete" then
                -- Reversed presentation:
                -- original deletion is displayed as "+" and green.
                table.insert(out, color_a("+" .. a[oi] .. "\n"))
            elseif op == "insert" then
                -- Reversed presentation:
                -- original insertion is displayed as "-" and red.
                table.insert(out, color_b("-" .. b[nj] .. "\n"))
            end
        end

        h = hunk_end + 1
    end

    return false, 1, table.concat(out)
end

--- Tries to copy file A (src) to B (dst), preserving file permissions (via copy_file).
--- - If dst does not exist -> perform the copy.
--- - If dst exists -> run a diff with full option support, show it, and ask the user
---   whether to overwrite (y/Y/yes -> copy; anything else / <ENTER> -> skip).
---
--- @param src  string Source file path
--- @param dst  string Destination file path
--- @param opts table|nil Options passed directly to luaSysBridge.diff():
---   context                number
---   brief                  boolean
---   ignore_all_space       boolean
---   ignore_space_change    boolean
---   ignore_blank_lines     boolean
---   ignore_case            boolean
---   strip_trailing_cr      boolean
---   ignore_trailing_cr     boolean
---   ignore_matching_lines  string
---   minimal                boolean
---   color                  boolean Enable ANSI colors
---
--- @return boolean true when a copy was performed (or files were identical),
---                 false when the user declined the overwrite
function luaSysBridge.diff_ask_and_copy(src, dst, opts)
    if type(src) ~= "string" or src == "" then
        error("diff_ask_and_copy(): src must be a non-empty string")
    end
    if type(dst) ~= "string" or dst == "" then
        error("diff_ask_and_copy(): dst must be a non-empty string")
    end

    print("=================================================")
    print(string.format("diff %s %s", src, dst))

    -- Destination does not exist -> just copy (permissions preserved by copy_file)
    if not luaSysBridge.exists_file(dst) then
        print("Destination does not exist. Copying...")
        local ok, err = pcall(luaSysBridge.copy_file, src, dst)
        if not ok then
            error("diff_ask_and_copy(): copy failed: " .. tostring(err))
        end
        print("Done.")
        return true
    end

    -- Destination exists -> compare using full diff options
    local same, _, output = luaSysBridge.diff(src, dst, opts)

    if same then
        print("No differences. Nothing to do.")
        return true
    end

    -- Show the unified diff (or error message)
    if output and output ~= "" then
        io.write(output)
        if not output:match("\n$") then
            io.write("\n")
        end
    end

    print()

    -- Ask user (default = no / <ENTER>)
    if luaSysBridge.prompt_y_yes("Files differ. Do you want to overwrite the destination file?") then
        print("Overwriting file...")
        local ok, err = pcall(luaSysBridge.copy_file, src, dst)
        if not ok then
            error("diff_ask_and_copy(): overwrite failed: " .. tostring(err))
        end
        print("Done.")
        return true
    else
        print("Skipping copy.")
        return false
    end
end

--- Interactive fuzzy finder using the external `fzf` binary.
--- Compatible with Lua 5.1–5.4 and LuaJIT.
---
--- @param options table  Array of values to choose from (converted to strings)
--- @param opts table|nil Options (all optional):
---   prompt     string   Prompt text shown by fzf (default: "Select: ")
---   multi      boolean  Allow multiple selection (default: false)
---                       When true -> returns table of selected strings
---                       When false -> returns a single string
---   height     string|number  Height of fzf window, e.g. "40%", 15, "50%"
---   reverse    boolean  Reverse the layout (list on top)
---   preview    string   Preview command (passed to --preview)
---   header     string   Header text (--header)
---   no_sort    boolean  Disable sorting (--no-sort)
---   ansi       boolean  Enable ANSI color codes (--ansi)
---   bash       boolean  If true, run preview via a temp bash script so the
---                       preview body can use bash/sh syntax even when
---                       $SHELL is fish. Default: false (no change).
---   shell      string   Explicit shell binary for the temp preview script
---                       (e.g. "bash", "sh"). Overrides bash=true when set.
---
--- @return string|table|nil
---   - single mode : selected string or nil (cancelled / error)
---   - multi mode  : table of selected strings (may be empty) or nil on error
function luaSysBridge.fzf(options, opts)
    opts = opts or {}

    if type(options) ~= "table" or #options == 0 then
        return nil
    end

    ----------------------------------------------------------------
    -- Helper: safe single-quote for the shell
    ----------------------------------------------------------------
    local function shell_quote(s)
        return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
    end

    ----------------------------------------------------------------
    -- Build input list
    ----------------------------------------------------------------
    local lines = {}
    for i = 1, #options do
        lines[i] = tostring(options[i])
    end
    local input_data = table.concat(lines, "\n") .. "\n"

    ----------------------------------------------------------------
    -- Optional: materialise preview as a temp script under bash/sh
    -- so nested quotes and fish-as-$SHELL are not a problem.
    --
    -- Inside the preview string, keep using `{}` as usual — it is
    -- rewritten to `"$1"` (the argument fzf passes to the script).
    ----------------------------------------------------------------
    local preview_script_path = nil

    local function build_preview_arg(preview_body)
        local wrap_shell = nil
        if type(opts.shell) == "string" and opts.shell ~= "" then
            wrap_shell = opts.shell
        elseif opts.bash == true then
            wrap_shell = "bash"
        end

        if not wrap_shell then
            -- Default: pass preview through unchanged (fzf uses $SHELL)
            return "--preview=" .. shell_quote(preview_body)
        end

        -- Rewrite {} -> "$1" for the script argument
        local script_body = preview_body:gsub("{}", "$1")

        preview_script_path = os.tmpname()
        local sf, serr = io.open(preview_script_path, "w")
        if not sf then
            return "--preview=" .. shell_quote(preview_body)
        end
        sf:write("#!/usr/bin/env " .. wrap_shell .. "\n")
        sf:write(script_body)
        if script_body:sub(-1) ~= "\n" then
            sf:write("\n")
        end
        sf:close()

        -- fzf replaces {} with the selected line and passes it as $1
        local preview_cmd = string.format("%s %s {}", wrap_shell, shell_quote(preview_script_path))
        return "--preview=" .. shell_quote(preview_cmd)
    end

    ----------------------------------------------------------------
    -- Build fzf command line from opts
    ----------------------------------------------------------------
    local fzf_args = { "fzf" }

    local prompt = opts.prompt or "Select: "
    table.insert(fzf_args, "--prompt=" .. shell_quote(prompt))

    if opts.multi then
        table.insert(fzf_args, "--multi")
    end

    if opts.height then
        table.insert(fzf_args, "--height=" .. tostring(opts.height))
    end

    if opts.reverse then
        table.insert(fzf_args, "--reverse")
    end

    if opts.preview and opts.preview ~= "" then
        table.insert(fzf_args, build_preview_arg(opts.preview))
    end

    if opts.header and opts.header ~= "" then
        table.insert(fzf_args, "--header=" .. shell_quote(opts.header))
    end

    if opts.no_sort then
        table.insert(fzf_args, "--no-sort")
    end

    if opts.ansi then
        table.insert(fzf_args, "--ansi")
    end

    local cmd = table.concat(fzf_args, " ")

    ----------------------------------------------------------------
    -- Run fzf (feed list via stdin, capture selection)
    ----------------------------------------------------------------
    local tmp = os.tmpname()
    local f = io.open(tmp, "w")
    if not f then
        if preview_script_path then
            os.remove(preview_script_path)
        end
        return nil
    end
    f:write(input_data)
    f:close()

    -- fzf draws UI on stderr — do not redirect it
    local full_cmd = string.format("%s < %s", cmd, shell_quote(tmp))
    local pipe = io.popen(full_cmd, "r")
    if not pipe then
        os.remove(tmp)
        if preview_script_path then
            os.remove(preview_script_path)
        end
        return nil
    end

    local output = pipe:read("*a") or ""
    pipe:close()
    os.remove(tmp)
    if preview_script_path then
        os.remove(preview_script_path)
    end

    output = output:gsub("\n+$", "")

    if output == "" then
        if opts.multi then
            return {}
        else
            return nil
        end
    end

    if opts.multi then
        local result = {}
        for line in output:gmatch("[^\n]+") do
            result[#result + 1] = line
        end
        return result
    else
        return (output:match("^[^\n]+")) or nil
    end
end

--- Interactive selection of a script matching a given prefix and then
--- execute / execvp it.
--- Compatible with Lua 5.1–5.4 and LuaJIT.
---
--- Typical use-case: scripts named "ab0_fzf", "ai_fzf", "ab1_fzf" that
--- should list and launch sibling scripts with the same prefix.
---
--- @param prefix  string   Prefix used for matching (e.g. "ab0", "ai")
--- @param dir     string   Directory that contains the scripts
--- @param prompt  string   Prompt shown by fzf
--- @param mode    string|nil  "execvp" (default) or "exec"
---                            - "execvp" -> replaces current process (never returns on success)
---                            - "exec"   -> runs via os.execute / luaSysBridge.execute and returns
--- @param opts    table|nil  Extra options passed directly to luaSysBridge.fzf()
---                           (height, reverse, multi, preview, header, ...)
---
--- @return boolean|nil, string|nil
---   - mode "execvp": never returns on success; on failure returns nil + error
---   - mode "exec"  : returns success (boolean), error message (or nil)
function luaSysBridge.fzf_select_and_run(prefix, dir, prompt, mode, opts)
    opts = opts or {}
    mode = mode or "execvp"

    if type(prefix) ~= "string" or prefix == "" then
        return nil, "fzf_select_and_run(): prefix must be a non-empty string"
    end
    if type(dir) ~= "string" or dir == "" then
        return nil, "fzf_select_and_run(): dir must be a non-empty string"
    end
    if type(prompt) ~= "string" then
        prompt = "Select script > "
    end
    if mode ~= "execvp" and mode ~= "exec" then
        return nil, 'fzf_select_and_run(): mode must be "execvp" or "exec"'
    end

    if not luaSysBridge.exists_directory(dir) then
        return nil, "fzf_select_and_run(): directory does not exist: " .. dir
    end

    ----------------------------------------------------------------
    -- Build candidate list (exclude the calling script itself)
    ----------------------------------------------------------------
    local current_basename = luaSysBridge.basename(arg and arg[0] or "")
    local candidates = luaSysBridge.find(dir, prefix .. "*") or {}

    local scripts = {}
    for _, name in ipairs(candidates) do
        if name ~= current_basename then
            scripts[#scripts + 1] = name
        end
    end

    if #scripts == 0 then
        return nil, 'fzf_select_and_run(): no scripts matching "' .. prefix .. '*" found'
    end

    ----------------------------------------------------------------
    -- Interactive selection
    ----------------------------------------------------------------
    local selected = luaSysBridge.fzf(scripts, {
        prompt = prompt,
        height = opts.height,
        reverse = opts.reverse,
        multi = opts.multi, -- normally false for this use-case
        preview = opts.preview,
        header = opts.header,
        no_sort = opts.no_sort,
        ansi = opts.ansi,
        -- any future fzf options can be forwarded here
    })

    if not selected or selected == "" then
        -- User cancelled
        return nil, "cancelled"
    end

    -- In multi mode selected is a table – take the first entry for running
    if type(selected) == "table" then
        selected = selected[1]
        if not selected then
            return nil, "cancelled"
        end
    end

    local full_path = dir .. "/" .. selected

    if not luaSysBridge.exists_file(full_path) then
        return nil, "fzf_select_and_run(): selected file does not exist: " .. full_path
    end

    ----------------------------------------------------------------
    -- Run the selected script
    ----------------------------------------------------------------
    if mode == "execvp" then
        -- Replaces current process – does not return on success
        local _, errstr, errnum = luaSysBridge.execvp(full_path, {})
        return nil, string.format("execvp failed: %s (errno %s)", tostring(errstr), tostring(errnum))
    else
        -- Ordinary execute – returns control to the caller
        local success, code = luaSysBridge.execute(full_path)
        if success then
            return true
        else
            return false, "execute failed with code " .. tostring(code)
        end
    end
end

return luaSysBridge
