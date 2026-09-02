#!/usr/bin/env lua
-- -*- mode: lua -*-
-- LUA COMPATIBILITY: LuaJIT, 5.1, 5.2, 5.3, 5.4

-- https://luacheck.readthedocs.io/en/stable/warnings.html
-- 631 = warning "line is too long (XXX > 120)
-- luacheck: ignore 631

--- luaPodBridge – helper library for Podman (and partially Docker) workflows.
---
--- This module provides higher-level utilities focused on container runtimes,
--- especially Podman. While many operations are compatible with Docker,
--- the primary development target is Podman (rootless, systemd integration,
--- etc.).
---
--- The library deliberately does **not** re-implement low-level system
--- primitives already present in luaSysBridge.
--- Instead it builds on top of them when needed.
---
--- Dependencies:
---   - the same as luaSysBridge
---   - lyaml: https://github.com/gvvaughan/lyaml , https://gvvaughan.github.io/lyaml

local luaSysBridge = require("luaSysBridge")
local lyaml = require("lyaml")

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
--- @param data table   Array of "KEY=value" strings or map {key = value}
--- @param opts table|nil Optional { chmod = "...", chown = "...", group = "..." }
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

    if type(opts) ~= "table" then
        return false, "env_write(): opts must be a table or nil"
    end

    local lines = {}

    -- Detect array vs map.
    local is_array = (#data > 0)

    if is_array then
        for _, line in ipairs(data) do
            if type(line) == "string" and line ~= "" then
                lines[#lines + 1] = line
            end
        end
    else
        -- Map: preserve a stable order (sorted keys).
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

    -- Optional post-write chmod / chown.
    if opts.chmod then
        local ok_chmod, err_chmod = luaSysBridge.chmod(path, opts.chmod)

        if not ok_chmod then
            return false, "env_write(): chmod failed: " .. tostring(err_chmod)
        end
    end

    if opts.chown or opts.group then
        local ok_chown, err_chown = luaSysBridge.chown(path, opts.chown, opts.group)

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
--- @param opts    table|nil Optional { chmod = "...", chown = "...", group = "..." }
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

    if type(opts) ~= "table" then
        return false, "env_update(): opts must be a table or nil"
    end

    -- Read current content (empty table when file does not exist).
    local current_lines = {}

    local f = io.open(path, "r")

    if f then
        for line in f:lines() do
            current_lines[#current_lines + 1] = line
        end

        f:close()
    end

    -- Track which keys we have already replaced.
    local replaced = {}
    local new_lines = {}

    for _, line in ipairs(current_lines) do
        -- Match KEY=... (allow spaces around =, ignore comments).
        local key = line:match("^%s*([%w_]+)%s*=")

        if key and updates[key] ~= nil then
            new_lines[#new_lines + 1] = key .. "=" .. tostring(updates[key])

            replaced[key] = true
        else
            -- Keep original line (comment, blank, or unrelated key).
            new_lines[#new_lines + 1] = line
        end
    end

    -- Append keys that were not present in the original file.
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

    -- Optional post-write chmod / chown.
    if opts.chmod then
        local ok_chmod, err_chmod = luaSysBridge.chmod(path, opts.chmod)

        if not ok_chmod then
            return false, "env_update(): chmod failed: " .. tostring(err_chmod)
        end
    end

    if opts.chown or opts.group then
        local ok_chown, err_chown = luaSysBridge.chown(path, opts.chown, opts.group)

        if not ok_chown then
            return false, "env_update(): chown failed: " .. tostring(err_chown)
        end
    end

    return true
end

-------------------------------------------------------------------------------
-- Container helpers (podman / docker ps --format json)
-------------------------------------------------------------------------------

--- Run `<runtime> ps --format json` and decode the result.
---
--- By default only currently running containers are returned, matching the
--- normal behaviour of `podman ps`.
---
--- When `opts.all == true`, `podman ps --all --format json` is used and
--- stopped containers are included.
---
--- Supported runtimes:
---   podman  default
---   docker
---
--- @param opts table|string|nil Options or runtime name.
---   runtime string   "podman" (default) or "docker"
---   all     boolean  Include stopped containers (default false)
--- @return table|nil data Array of raw container records returned by runtime
--- @return string|nil err
function luaPodBridge.ps_fetch_json(opts)
    opts = opts or {}

    if type(opts) == "string" then
        opts = { runtime = opts }
    elseif type(opts) ~= "table" then
        return nil, "ps_fetch_json(): options must be a table, string or nil"
    end

    local runtime = opts.runtime or "podman"

    if runtime ~= "podman" and runtime ~= "docker" then
        return nil, 'ps_fetch_json(): runtime must be "podman" or "docker"'
    end

    if opts.all ~= nil and type(opts.all) ~= "boolean" then
        return nil, "ps_fetch_json(): opts.all must be a boolean"
    end

    local command = runtime .. " ps"

    if opts.all == true then
        command = command .. " --all"
    end

    command = command .. " --format json"

    local success, code, output = luaSysBridge.iopopen_stdout_err(command)

    if not success or code ~= 0 then
        local message = tostring(output or "")
        message = message:match("^[^\n]*") or ""

        return nil, string.format("%s ps failed (code %s): %s", runtime, tostring(code), message)
    end

    if not output or output:match("^%s*$") then
        return {}
    end

    local json = require("json")

    local ok, data = pcall(json.decode, output)

    if not ok then
        return nil, "ps_fetch_json(): failed to parse JSON: " .. tostring(data)
    end

    if type(data) ~= "table" then
        return nil, "ps_fetch_json(): decoded JSON is not an array"
    end

    return data
end

--- Return containers matching the requested filters.
---
--- By default only currently running containers are returned, matching
--- `podman ps`.
---
--- The returned container records are the original records produced by
--- `podman ps --format json`; their field names are therefore preserved
--- exactly as returned by the runtime (`Id`, `Names`, `Image`, `State`,
--- `Status`, `Ports`, etc.).
---
--- Returned object:
---   {
---       count = 2,
---       running = 2,
---       total = 2,
---       containers = {
---           { ... },
---           ...
---       }
---   }
---
--- `count` and `running` contain the number of running containers among
--- the containers selected by the filters.
---
--- With `all = true`, stopped containers are included. In that case
--- `total` may be greater than `count`.
---
--- Optional filters:
---   name    string  Lua pattern matched against every container name
---   image   string  Lua pattern matched against Image
---   id      string  Lua pattern matched against Id
---   status  string  Exact match against State
---
--- @param opts table|string|nil
--- @return table|nil result
--- @return string|nil err
function luaPodBridge.ps(opts)
    opts = opts or {}

    if type(opts) == "string" then
        opts = { runtime = opts }
    elseif type(opts) ~= "table" then
        return nil, "ps(): options must be a table, string or nil"
    end

    if opts.name ~= nil and type(opts.name) ~= "string" then
        return nil, "ps(): opts.name must be a string"
    end

    if opts.image ~= nil and type(opts.image) ~= "string" then
        return nil, "ps(): opts.image must be a string"
    end

    if opts.id ~= nil and type(opts.id) ~= "string" then
        return nil, "ps(): opts.id must be a string"
    end

    if opts.status ~= nil and type(opts.status) ~= "string" then
        return nil, "ps(): opts.status must be a string"
    end

    -- Validate Lua patterns before processing the container list.
    local function validate_pattern(name, pattern)
        if pattern == nil then
            return true
        end

        local ok = pcall(function()
            return (""):match(pattern)
        end)

        if not ok then
            return false, "ps(): invalid " .. name .. " pattern: " .. pattern
        end

        return true
    end

    local ok, pattern_err = validate_pattern("name", opts.name)

    if not ok then
        return nil, pattern_err
    end

    ok, pattern_err = validate_pattern("image", opts.image)

    if not ok then
        return nil, pattern_err
    end

    ok, pattern_err = validate_pattern("id", opts.id)

    if not ok then
        return nil, pattern_err
    end

    local data, err = luaPodBridge.ps_fetch_json(opts)

    if not data then
        return nil, "ps(): " .. tostring(err)
    end

    local containers = {}

    local function container_name_matches(container, pattern)
        if not pattern then
            return true
        end

        if type(container.Names) ~= "table" then
            return false
        end

        for _, name in ipairs(container.Names) do
            if type(name) == "string" and name:match(pattern) then
                return true
            end
        end

        return false
    end

    local function container_matches(container)
        if not container_name_matches(container, opts.name) then
            return false
        end

        if opts.image then
            local image = container.Image

            if type(image) ~= "string" or not image:match(opts.image) then
                return false
            end
        end

        if opts.id then
            local id = container.Id

            if type(id) ~= "string" or not id:match(opts.id) then
                return false
            end
        end

        if opts.status and container.State ~= opts.status then
            return false
        end

        return true
    end

    for _, container in ipairs(data) do
        if type(container) == "table" and container_matches(container) then
            containers[#containers + 1] = container
        end
    end

    local running = 0

    for _, container in ipairs(containers) do
        if container.State == "running" then
            running = running + 1
        end
    end

    return {
        count = running,
        running = running,
        total = #containers,
        containers = containers,
    }
end

--- Return the number of currently running containers.
---
--- This is equivalent to the `count` field returned by `ps()`.
---
--- With `all = true`, stopped containers are included in the query,
--- but they are not included in the returned count.
---
--- @param opts table|string|nil
--- @return integer|nil count Number of running containers
--- @return string|nil err
function luaPodBridge.ps_count(opts)
    local result, err = luaPodBridge.ps(opts)

    if not result then
        return nil, err
    end

    return result.count
end

--- Return a single container by exact name or ID.
---
--- The lookup is performed against the complete container list and does
--- not use `ps()` filters.
---
--- An exact name match takes precedence over an ID match.
---
--- Container IDs may be abbreviated. If an abbreviated ID matches more
--- than one container, the function returns an error instead of choosing
--- an arbitrary container.
---
--- @param name_or_id string Container name or full/abbreviated ID
--- @param opts table|string|nil Optional options passed to ps_fetch_json().
---   The `all` and `runtime` options are supported.
--- @return table|nil container Container record
--- @return string|nil err
function luaPodBridge.ps_get(name_or_id, opts)
    if type(name_or_id) ~= "string" or name_or_id == "" then
        return nil, "ps_get(): name_or_id must be a non-empty string"
    end

    opts = opts or {}

    if type(opts) == "string" then
        opts = { runtime = opts }
    elseif type(opts) ~= "table" then
        return nil, "ps_get(): options must be a table, string or nil"
    end

    local data, err = luaPodBridge.ps_fetch_json(opts)

    if not data then
        return nil, "ps_get(): " .. tostring(err)
    end

    local id_matches = {}

    for _, container in ipairs(data) do
        if type(container) == "table" then
            -- Exact name match always wins.
            if type(container.Names) == "table" then
                for _, name in ipairs(container.Names) do
                    if name == name_or_id then
                        return container
                    end
                end
            end

            -- Exact ID match.
            if container.Id == name_or_id then
                return container
            end

            -- Abbreviated ID match.
            if type(container.Id) == "string" and #name_or_id < #container.Id and container.Id:sub(1, #name_or_id) == name_or_id then
                id_matches[#id_matches + 1] = container
            end
        end
    end

    if #id_matches == 1 then
        return id_matches[1]
    end

    if #id_matches > 1 then
        return nil, "ps_get(): abbreviated ID is ambiguous: " .. name_or_id
    end

    return nil, "container not found: " .. name_or_id
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
--- @param registries table|nil Array of prefixes; defaults to DEFAULT_REGISTRIES
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

--- Collect name candidates from one image record
--- (Names -> History -> RepoTags).
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

--- Run `<runtime> images --format json` and decode the result.
---
--- Supported runtimes:
---   podman
---   docker
---
--- @param runtime string "podman" or "docker"
--- @return table|nil data Array of image records
--- @return string|nil err
function luaPodBridge.images_fetch_json(runtime)
    if type(runtime) ~= "string" or runtime == "" then
        return nil, "images_fetch_json(): runtime must be a non-empty string"
    end

    if runtime ~= "podman" and runtime ~= "docker" then
        return nil, 'images_fetch_json(): runtime must be "podman" or "docker"'
    end

    local success, code, output = luaSysBridge.iopopen_stdout_err(runtime .. " images --format json")

    if not success or code ~= 0 then
        local message = tostring(output or "")
        message = message:match("^[^\n]*") or ""

        return nil, string.format("%s images failed (code %s): %s", runtime, tostring(code), message)
    end

    if not output or output:match("^%s*$") then
        return {}
    end

    local json = require("json")

    local ok, data = pcall(json.decode, output)

    if not ok then
        return nil, "images_fetch_json(): failed to parse JSON: " .. tostring(data)
    end

    if type(data) ~= "table" then
        return nil, "images_fetch_json(): decoded JSON is not an array"
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
    elseif type(opts) ~= "table" then
        return nil, "images_get_names(): options must be a table, string or nil"
    end

    local runtime = opts.runtime or "podman"

    if type(runtime) ~= "string" or runtime == "" then
        return nil, "images_get_names(): runtime must be a non-empty string"
    end

    if runtime ~= "podman" and runtime ~= "docker" then
        return nil, 'images_get_names(): runtime must be "podman" or "docker"'
    end

    local mode = opts.mode or "names"

    if mode ~= "names" and mode ~= "digests" then
        return nil, 'images_get_names(): mode must be "names" or "digests"'
    end

    if opts.filter ~= nil and type(opts.filter) ~= "string" then
        return nil, "images_get_names(): opts.filter must be a string"
    end

    if opts.registry_pattern ~= nil and type(opts.registry_pattern) ~= "string" then
        return nil, "images_get_names(): opts.registry_pattern must be a string"
    end

    if opts.registries ~= nil and type(opts.registries) ~= "table" then
        return nil, "images_get_names(): opts.registries must be a table"
    end

    if opts.registry_only ~= nil and type(opts.registry_only) ~= "boolean" then
        return nil, "images_get_names(): opts.registry_only must be a boolean"
    end

    if opts.include_history ~= nil and type(opts.include_history) ~= "boolean" then
        return nil, "images_get_names(): opts.include_history must be a boolean"
    end

    if opts.include_repotags ~= nil and type(opts.include_repotags) ~= "boolean" then
        return nil, "images_get_names(): opts.include_repotags must be a boolean"
    end

    if opts.exclude_none ~= nil and type(opts.exclude_none) ~= "boolean" then
        return nil, "images_get_names(): opts.exclude_none must be a boolean"
    end

    if opts.with_meta ~= nil and type(opts.with_meta) ~= "boolean" then
        return nil, "images_get_names(): opts.with_meta must be a boolean"
    end

    if opts.sort ~= nil and type(opts.sort) ~= "boolean" then
        return nil, "images_get_names(): opts.sort must be a boolean"
    end

    -- Validate Lua patterns before processing images.
    local function validate_pattern(name, pattern)
        if pattern == nil then
            return true
        end

        local ok = pcall(function()
            return (""):match(pattern)
        end)

        if not ok then
            return false, "images_get_names(): invalid " .. name .. " pattern: " .. pattern
        end

        return true
    end

    local ok, pattern_err = validate_pattern("filter", opts.filter)

    if not ok then
        return nil, pattern_err
    end

    ok, pattern_err = validate_pattern("registry_pattern", opts.registry_pattern)

    if not ok then
        return nil, pattern_err
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

-------------------------------------------------------------------------------
-- YAML, docker-compose.yml helpers
-------------------------------------------------------------------------------

--- Apply YAML tags to generated YAML text using YAML paths.
---
--- Each tag definition is a table containing:
---   path string YAML path to the key. Dot-separated components are used.
---         The '*' component matches any single path component.
---   tag  string YAML tag to append after the matched key.
---   count number|nil Maximum number of matches. Defaults to 1.
---         Use 0 to replace all matches.
---
--- Examples:
---     {
---         {
---             path = "services.api.ports",
---             tag = "!override",
---         },
---     }
---
--- turns:
---     services:
---       api:
---         ports:
---
--- into:
---     services:
---       api:
---         ports: !override
---
--- A wildcard can be used to match any single path component:
---
---     {
---         {
---             path = "services.*.ports",
---             tag = "!override",
---             count = 0,
---         },
---     }
---
--- @param yaml_content string Generated YAML content
--- @param yaml_tags table|nil Array of YAML tag definitions
--- @return string|nil content Modified YAML content
--- @return string|nil err Error message
local function yaml_apply_tags(yaml_content, yaml_tags)
    if yaml_tags == nil then
        return yaml_content
    end

    if type(yaml_tags) ~= "table" then
        return nil, "yaml_apply_tags(): yaml_tags must be a table or nil"
    end

    local function split_path(path)
        local result = {}

        for component in path:gmatch("[^%.]+") do
            result[#result + 1] = component
        end

        return result
    end

    local function path_matches(path, pattern)
        if #path ~= #pattern then
            return false
        end

        for index, component in ipairs(pattern) do
            if component ~= "*" and component ~= path[index] then
                return false
            end
        end

        return true
    end

    local lines = {}

    for line in yaml_content:gmatch("([^\n]*)\n?") do
        if line ~= "" or #lines > 0 then
            lines[#lines + 1] = line
        end
    end

    for index, definition in ipairs(yaml_tags) do
        if type(definition) ~= "table" then
            return nil, string.format(
                "yaml_apply_tags(): tag definition #%d must be a table",
                index
            )
        end

        local path = definition.path
        local tag = definition.tag
        local count = definition.count

        if type(path) ~= "string" or path == "" then
            return nil, string.format(
                "yaml_apply_tags(): tag definition #%d has invalid path",
                index
            )
        end

        if type(tag) ~= "string" or tag == "" then
            return nil, string.format(
                "yaml_apply_tags(): tag definition #%d has invalid tag",
                index
            )
        end

        if count ~= nil and type(count) ~= "number" then
            return nil, string.format(
                "yaml_apply_tags(): tag definition #%d count must be a number or nil",
                index
            )
        end

        local path_pattern = split_path(path)
        local replacement_limit = count or 1
        local replacement_count = 0

        local stack = {}

        for line_index, line in ipairs(lines) do
            -- Ignore empty lines and YAML document markers.
            if line ~= ""
                and line ~= "---"
                and line ~= "..."
            then
                local indentation = line:match("^(%s*)")
                local indent_length = #indentation

                local key = line:match("^%s*([^%s:#][^:]*):")

                if key then
                    key = key:gsub("%s+$", "")

                    -- Remove stack entries at the current or deeper level.
                    while #stack > 0
                        and stack[#stack].indent >= indent_length
                    do
                        stack[#stack] = nil
                    end

                    stack[#stack + 1] = {
                        indent = indent_length,
                        key = key,
                    }

                    local current_path = {}

                    for stack_index, entry in ipairs(stack) do
                        current_path[stack_index] = entry.key
                    end

                    if path_matches(current_path, path_pattern) then
                        if replacement_limit == 0
                            or replacement_count < replacement_limit
                        then
                            if not line:find(":%s*!" .. tag:sub(2), 1) then
                                lines[line_index] = line .. " " .. tag
                                replacement_count = replacement_count + 1
                            end
                        end
                    end
                end
            end
        end

        if replacement_count == 0 then
            return nil, string.format(
                "yaml_apply_tags(): path did not match YAML: %s",
                path
            )
        end
    end

    return table.concat(lines, "\n")
end

--- Write a Docker Compose configuration to a YAML file.
---
--- The configuration is serialized using lyaml. Optional YAML tags can be
--- applied to selected YAML keys after serialization, which is useful for
--- Docker Compose-specific tags such as `!override` and `!reset` that lyaml
--- does not emit directly.
---
--- Example:
---     luaPodBridge.write_docker_compose(
---         "./docker-compose.override.yaml",
---         {
---             services = {
---                 api = {
---                     ports = {
---                         "57241:3080",
---                     },
---                 },
---             },
---         },
---         {
---             yaml_tags = {
---                 {
---                     pattern = "([ \t]*ports:)",
---                     tag = "!override",
---                 },
---             },
---         }
---     )
---
--- @param docker_compose_file string Path to the Docker Compose YAML file.
--- @param docker_compose_tbl table Docker Compose configuration to serialize.
--- @param opts table|nil Optional serialization and YAML tag options.
--- @param opts.yaml_tags table|nil List of YAML tag definitions to apply.
--- @param opts.yaml_tags[].pattern string Lua pattern matching the YAML key.
--- @param opts.yaml_tags[].tag string YAML tag to append to the matched key.
--- @param opts.yaml_tags[].count number|nil Maximum number of replacements;
---        defaults to 1. Use 0 to replace all matches.
--- @return boolean success True if the file was written successfully.
--- @return string|nil err Error message if the operation failed.
function luaPodBridge.write_docker_compose(docker_compose_file, docker_compose_tbl, opts)
    if type(docker_compose_file) ~= "string" or docker_compose_file == "" then
        return false, "write_docker_compose(): docker_compose_file must be a non-empty string"
    end

    if type(docker_compose_tbl) ~= "table" then
        return false, "write_docker_compose(): docker_compose_tbl must be a table"
    end

    if opts ~= nil and type(opts) ~= "table" then
        return false, "write_docker_compose(): opts must be a table or nil"
    end

    opts = opts or {}

    local yaml_content, err = lyaml.dump({
        docker_compose_tbl,
    })

    if not yaml_content then
        return false, "write_docker_compose(): Lyaml could not generate YAML: " .. tostring(err)
    end

    if opts.yaml_tags then
        yaml_content, err = yaml_apply_tags(yaml_content, opts.yaml_tags)

        if not yaml_content then
            return false, "write_docker_compose(): " .. tostring(err)
        end
    end

    local fh, open_err = io.open(docker_compose_file, "w")

    if not fh then
        return false, string.format("write_docker_compose(): failed to open %s for writing: %s", docker_compose_file, tostring(open_err))
    end

    local ok, write_err = fh:write(yaml_content)
    fh:close()

    if not ok then
        return false, "write_docker_compose(): write failed: " .. tostring(write_err)
    end

    return true
end

return luaPodBridge
