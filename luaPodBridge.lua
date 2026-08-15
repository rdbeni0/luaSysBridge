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
---   2. a key->value map                     {KEY = "value", PORT = "3001", ...}
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
        return false, "env_update(): updates must be a table (key -> value map)"
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

-------------------------------------------------------------------------------
-- Image helpers (podman / docker images --format json)
-------------------------------------------------------------------------------

-- Known public registry prefixes (via string prefix match).
local DEFAULT_REGISTRIES = {
    "docker.io/",
    "ghcr.io/",
    "quay.io/",
    "registry.fedoraproject.org/",
    "registry.opensuse.org/",
    "registry.librechat.ai/",
}

--- Return true when `name` starts with any of the given registry prefixes.
--- @param name string
--- @param registries table|nil  Array of prefixes; defaults to DEFAULT_REGISTRIES
--- @return boolean
local function matches_registry(name, registries)
    registries = registries or DEFAULT_REGISTRIES
    if type(name) ~= "string" or name == "" then
        return false
    end
    for _, prefix in ipairs(registries) do
        if type(prefix) == "string" and prefix ~= "" and name:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

--- Collect name candidates from one image record (Names -> History -> RepoTags).
local function image_collect_names(img, include_history, include_repotags)
    local list = {}
    local seen = {}

    local function add(n)
        if type(n) == "string" and n ~= "" and not seen[n] then
            seen[n] = true
            list[#list + 1] = n
        end
    end

    if type(img.Names) == "table" then
        for _, n in ipairs(img.Names) do
            add(n)
        end
    end
    if include_history ~= false and type(img.History) == "table" then
        for _, n in ipairs(img.History) do
            add(n)
        end
    end
    if include_repotags and type(img.RepoTags) == "table" then
        for _, n in ipairs(img.RepoTags) do
            add(n)
        end
    end

    return list
end

--- Primary display name for an image (first Names entry, else History).
local function image_primary_name(img)
    if type(img.Names) == "table" and img.Names[1] then
        return img.Names[1]
    end
    if type(img.History) == "table" and img.History[1] then
        return img.History[1]
    end
    return nil
end

--- Human-readable size (e.g. "528.34 MB").
local function format_size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1073741824 then
        return string.format("%.2f GB", bytes / 1073741824)
    elseif bytes >= 1048576 then
        return string.format("%.2f MB", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.2f KB", bytes / 1024)
    end
    return string.format("%d B", bytes)
end

--- Run `<runtime> images --format json` and decode with json.lua.
--- @param runtime string  "podman" or "docker"
--- @return table|nil data  Array of image records
--- @return string|nil err
function luaPodBridge.images_fetch_json(runtime)
    if type(runtime) ~= "string" or runtime == "" then
        return nil, "images_fetch_json(): runtime must be a non-empty string"
    end

    local json = require("json")
    local success, code, output = luaSysBridge.iopopen_stdout_err(runtime .. " images --format json")

    if not success or code ~= 0 then
        return nil, string.format(
            "%s images failed (code %s): %s",
            runtime,
            tostring(code),
            tostring(output):match("^[^\n]*") or ""
        )
    end

    if not output or output:match("^%s*$") then
        return {}
    end

    local ok, data = pcall(json.decode, output)
    if not ok or type(data) ~= "table" then
        return nil, "failed to parse JSON: " .. tostring(data)
    end

    return data
end

--- Return local image references (names or digests), optionally with metadata.
---
--- Runs `<runtime> images --format json`, parses with json.lua.
---
--- opts:
---   runtime           string   "podman" (default) or "docker"
---   mode              string   "names" (default) | "digests"
---                                names   -> Repository:Tag (Names/History/RepoTags)
---                                digests -> Repository@sha256:... (RepoDigests)
---   filter            string   Lua pattern applied to each value (optional)
---   registry_only     boolean  keep only DEFAULT_REGISTRIES (default false)
---   registries        table    custom array of prefixes, e.g. { "ghcr.io/", "docker.io/" }
---                              (takes precedence over registry_only)
---   registry_pattern  string   optional extra Lua pattern (no | alternation) applied after
---                              prefix filters
---   include_history   boolean  also read History when Names empty (default true; names mode)
---   include_repotags  boolean  also read RepoTags (default false; names mode)
---   exclude_none      boolean  drop values containing "<none>" (default true)
---   with_meta         boolean  return rich records instead of plain strings (default false)
---   sort              boolean  sort results (default false)
---
--- mode "names", with_meta == false:
---   { "ghcr.io/foo/bar:latest", ... }
---
--- mode "names", with_meta == true:
---   {
---     {
---       name       = "ghcr.io/foo/bar:latest",
---       id         = "0d9945c1a163...",
---       size       = 554003588,
---       size_human = "528.34 MB",
---       created    = 1786086271,
---       created_at = "2026-08-07T07:04:31Z",
---       digest     = "sha256:a0659f81...",
---       digests    = { "ghcr.io/foo/bar@sha256:...", ... },
---       containers = 0,
---       labels     = { ... } or nil,
---     },
---     ...
---   }
---
--- mode "digests", with_meta == false:
---   { "ghcr.io/foo/bar@sha256:...", ... }
---
--- mode "digests", with_meta == true:
---   {
---     {
---       digest_ref = "ghcr.io/foo/bar@sha256:...",
---       name       = "ghcr.io/foo/bar:latest",
---       id         = "...",
---       size       = 123,
---       size_human = "...",
---       created    = ...,
---       created_at = "...",
---       digest     = "sha256:...",
---     },
---     ...
---   }
---
--- Backward compatible: images_get_names("podman") still works.
---
--- @param opts table|string|nil
--- @return table|nil result
--- @return string|nil err
function luaPodBridge.images_get_names(opts)
    opts = opts or {}
    if type(opts) == "string" then
        opts = { runtime = opts }
    end

    local runtime = opts.runtime or "podman"
    if type(runtime) ~= "string" or runtime == "" then
        return nil, "images_get_names(): runtime must be a non-empty string"
    end

    local mode = opts.mode or "names"
    if mode ~= "names" and mode ~= "digests" then
        return nil, 'images_get_names(): mode must be "names" or "digests"'
    end

    local data, err = luaPodBridge.images_fetch_json(runtime)
    if not data then
        return nil, "images_get_names(): " .. tostring(err)
    end

    local filter = opts.filter
    local reg_pat = opts.registry_pattern
    local registries = opts.registries
    if not registries and opts.registry_only then
        registries = DEFAULT_REGISTRIES
    end

    local exclude_none = (opts.exclude_none ~= false)
    local with_meta = (opts.with_meta == true)
    local include_history = (opts.include_history ~= false)
    local include_repotags = (opts.include_repotags == true)

    local results = {}
    local seen = {}

    local function value_ok(v)
        if exclude_none and v:find("<none>", 1, true) then
            return false
        end
        if filter and not v:match(filter) then
            return false
        end
        if registries and not matches_registry(v, registries) then
            return false
        end
        if reg_pat and not v:match(reg_pat) then
            return false
        end
        return true
    end

    if mode == "names" then
        for _, img in ipairs(data) do
            if type(img) == "table" then
                local candidates = image_collect_names(img, include_history, include_repotags)
                for _, n in ipairs(candidates) do
                    if value_ok(n) and not seen[n] then
                        seen[n] = true
                        if with_meta then
                            results[#results + 1] = {
                                name = n,
                                id = img.Id,
                                size = img.Size,
                                size_human = format_size(img.Size),
                                created = img.Created,
                                created_at = img.CreatedAt,
                                digest = img.Digest,
                                digests = img.RepoDigests,
                                containers = img.Containers,
                                labels = img.Labels,
                            }
                        else
                            results[#results + 1] = n
                        end
                    end
                end
            end
        end
    else
        -- mode == "digests"
        for _, img in ipairs(data) do
            if type(img) == "table" and type(img.RepoDigests) == "table" then
                local primary = image_primary_name(img)
                for _, d in ipairs(img.RepoDigests) do
                    if type(d) == "string" and d ~= "" and not seen[d] and value_ok(d) then
                        seen[d] = true
                        if with_meta then
                            results[#results + 1] = {
                                digest_ref = d,
                                name = primary,
                                id = img.Id,
                                size = img.Size,
                                size_human = format_size(img.Size),
                                created = img.Created,
                                created_at = img.CreatedAt,
                                digest = img.Digest,
                            }
                        else
                            results[#results + 1] = d
                        end
                    end
                end
            end
        end
    end

    if opts.sort then
        if with_meta then
            local key = (mode == "digests") and "digest_ref" or "name"
            table.sort(results, function(a, b)
                return tostring(a[key]) < tostring(b[key])
            end)
        else
            table.sort(results)
        end
    end

    return results
end

return luaPodBridge
