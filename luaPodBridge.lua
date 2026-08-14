#!/usr/bin/env lua
-- -*- mode: lua -*-
-- LUA COMPATIBILITY: LuaJIT, 5.1, 5.2, 5.3, 5.4

-- https://luacheck.readthedocs.io/en/stable/warnings.html
-- 631 = warning "line is too long (XXX > 120)
-- luacheck: ignore 631

--- luaPodBridge – helper library for Podman (and partially Docker) workflows.
---
--- This module provides higher-level utilities focused on container runtimes,
--- especially Podman.  While many operations are compatible with Docker,
--- the primary development target is Podman (rootless, systemd integration,
--- etc.).
---
--- The library deliberately does **not** re-implement low-level system
--- primitives already present in luaSysBridge.
--- Instead it builds on top of them when needed.
---
--- Dependencies:
---   - the same as luaSysBridge

local luaSysBridge = require("luaSysBridge")

local luaPodBridge = {}

-------------------------------------------------------------------------------
-- .env file helpers
-------------------------------------------------------------------------------

--- Write (overwrite) a complete .env file.
---
--- Accepts either:
---   1. an array of already-formatted lines  {"KEY=value", "PORT=3001", ...}
---   2. a key→value map                     {KEY = "value", PORT = "3001", ...}
---
--- Optional third argument `opts`:
---   opts.chmod  string|number   permission mode (e.g. "644", 644, "0644")
---   opts.chown  string|number   owner (user name or uid)
---   opts.group  string|number   group (optional, used together with chown)
---
--- The file is always terminated with a final newline.
--- Existing content is completely replaced.
---
--- @param path string  Absolute or relative path to the .env file
--- @param data table   Array of "KEY=value" strings **or** map {key = value}
--- @param opts table|nil  Optional { chmod = "...", chown = "...", group = "..." }
--- @return boolean true on success
--- @return string|nil error message on failure
function luaPodBridge.env_write(path, data, opts)
    if type(path) ~= "string" or path == "" then
        return false, "env_write(): path must be a non-empty string"
    end
    if type(data) ~= "table" then
        return false, "env_write(): data must be a table (array or map)"
    end

    opts = opts or {}

    local lines = {}

    -- Detect array vs map
    local is_array = (#data > 0)

    if is_array then
        for _, line in ipairs(data) do
            if type(line) == "string" and line ~= "" then
                lines[#lines + 1] = line
            end
        end
    else
        -- map: preserve a stable order (sorted keys)
        local keys = {}
        for k in pairs(data) do
            keys[#keys + 1] = k
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = data[k]
            if v ~= nil then
                lines[#lines + 1] = tostring(k) .. "=" .. tostring(v)
            end
        end
    end

    local content = table.concat(lines, "\n")
    if content ~= "" then
        content = content .. "\n"
    end

    local f, err = io.open(path, "w")
    if not f then
        return false, "env_write(): cannot open " .. path .. " for writing: " .. tostring(err)
    end

    local ok, write_err = f:write(content)
    f:close()

    if not ok then
        return false, "env_write(): write failed: " .. tostring(write_err)
    end

    -- optional post-write chmod / chown
    local bridge = require("luaSysBridge")

    if opts.chmod then
        local ok_chmod, err_chmod = bridge.chmod(path, opts.chmod)
        if not ok_chmod then
            return false, "env_write(): chmod failed: " .. tostring(err_chmod)
        end
    end

    if opts.chown or opts.group then
        local ok_chown, err_chown = bridge.chown(path, opts.chown, opts.group)
        if not ok_chown then
            return false, "env_write(): chown failed: " .. tostring(err_chown)
        end
    end

    return true
end

--- Update or add variables inside an existing .env file.
---
--- - Existing keys that appear in `updates` are replaced (value changed).
--- - Keys that do not yet exist are appended at the end.
--- - Comments, blank lines and unknown keys are preserved in their
---   original order.
--- - The final newline is guaranteed.
---
--- Optional third argument `opts`:
---   opts.chmod  string|number   permission mode (e.g. "644", 644, "0644")
---   opts.chown  string|number   owner (user name or uid)
---   opts.group  string|number   group (optional, used together with chown)
---
--- @param path    string  Path to the .env file (created if missing)
--- @param updates table   Map of { KEY = "new_value", ... }
--- @param opts    table|nil  Optional { chmod = "...", chown = "...", group = "..." }
--- @return boolean true on success
--- @return string|nil error message on failure
function luaPodBridge.env_update(path, updates, opts)
    if type(path) ~= "string" or path == "" then
        return false, "env_update(): path must be a non-empty string"
    end
    if type(updates) ~= "table" then
        return false, "env_update(): updates must be a table (key → value map)"
    end

    opts = opts or {}

    -- Read current content (empty table when file does not exist)
    local current_lines = {}
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            current_lines[#current_lines + 1] = line
        end
        f:close()
    end

    -- Track which keys we have already replaced
    local replaced = {}

    local new_lines = {}

    for _, line in ipairs(current_lines) do
        -- Match KEY=... (allow spaces around =, ignore comments)
        local key = line:match("^%s*([%w_]+)%s*=")
        if key and updates[key] ~= nil then
            -- replace the whole line
            new_lines[#new_lines + 1] = key .. "=" .. tostring(updates[key])
            replaced[key] = true
        else
            -- keep original line (comment, blank, or unrelated key)
            new_lines[#new_lines + 1] = line
        end
    end

    -- Append keys that were not present in the original file
    local missing_keys = {}
    for k in pairs(updates) do
        if not replaced[k] then
            missing_keys[#missing_keys + 1] = k
        end
    end
    table.sort(missing_keys)

    for _, k in ipairs(missing_keys) do
        new_lines[#new_lines + 1] = k .. "=" .. tostring(updates[k])
    end

    local content = table.concat(new_lines, "\n")
    if content ~= "" then
        content = content .. "\n"
    end

    local out, err = io.open(path, "w")
    if not out then
        return false, "env_update(): cannot open " .. path .. " for writing: " .. tostring(err)
    end

    local ok, write_err = out:write(content)
    out:close()

    if not ok then
        return false, "env_update(): write failed: " .. tostring(write_err)
    end

    -- optional post-write chmod / chown
    local bridge = require("luaSysBridge")

    if opts.chmod then
        local ok_chmod, err_chmod = bridge.chmod(path, opts.chmod)
        if not ok_chmod then
            return false, "env_update(): chmod failed: " .. tostring(err_chmod)
        end
    end

    if opts.chown or opts.group then
        local ok_chown, err_chown = bridge.chown(path, opts.chown, opts.group)
        if not ok_chown then
            return false, "env_update(): chown failed: " .. tostring(err_chown)
        end
    end

    return true
end

return luaPodBridge
