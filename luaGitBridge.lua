#!/usr/bin/env lua
-- -*- mode: lua -*-
-- LUA COMPATIBILITY: LuaJIT, 5.1, 5.2, 5.3, 5.4

-- https://luacheck.readthedocs.io/en/stable/warnings.html
-- 631 = warning "line is too long (XXX > 120)
-- luacheck: ignore 631

--- git and gitHub release helpers for Lua scripts.
--- Same conventions as luaSysBridge
---
--- Dependencies:
---   luaSysBridge (with cURL support for HTTP)

local luaSysBridge = require("luaSysBridge")

local luaGitBridge = {}

luaGitBridge.DEFAULT_USER_AGENT = "luaGitBridge/1.0"

----------------------------------------------------------------------
-- Core git helpers
----------------------------------------------------------------------

--- Wrapper around 'fzf' to select a git commit.
--- Shows commit refs and titles, lets user pick one.
--- @param path string|nil Optional path to a git repository; if provided, changes working directory before running.
--- @return string|nil Selected commit hash or nil if nothing selected.
function luaGitBridge.git_fzf_select_commit(path)
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
function luaGitBridge.git_reset_and_cleanup(commit_ref, path)
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
function luaGitBridge.git_add_and_commit(path, msg1, msg2)
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

----------------------------------------------------------------------
-- Lightweight JSON field extractors (no external JSON library)
----------------------------------------------------------------------

--- Extract a simple JSON string field value.
--- @param json_body string
--- @param key string  field name without quotes
--- @return string|nil value
--- @return string|nil err
function luaGitBridge.json_get_string(json_body, key)
    if type(json_body) ~= "string" or json_body == "" then
        return nil, "json_get_string(): json_body must be a non-empty string"
    end
    if type(key) ~= "string" or key == "" then
        return nil, "json_get_string(): key must be a non-empty string"
    end
    local value = json_body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    if not value then
        return nil, "json_get_string(): key not found: " .. key
    end
    return value
end

--- Parse tag_name from a GitHub release JSON body.
--- @param json_body string
--- @return string|nil tag
--- @return string|nil err
function luaGitBridge.parse_latest_tag(json_body)
    return luaGitBridge.json_get_string(json_body, "tag_name")
end

--- Find browser_download_url for an asset by exact name.
--- @param json_body string
--- @param asset_name string
--- @return string|nil url
--- @return string|nil err
function luaGitBridge.find_asset_download_url(json_body, asset_name)
    if type(json_body) ~= "string" or json_body == "" then
        return nil, "find_asset_download_url(): json_body must be a non-empty string"
    end
    if type(asset_name) ~= "string" or asset_name == "" then
        return nil, "find_asset_download_url(): asset_name must be a non-empty string"
    end

    local escaped = asset_name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    local url = json_body:match('"name"%s*:%s*"' .. escaped .. '".-"browser_download_url"%s*:%s*"([^"]+)"')
    if not url then
        url = json_body:match('"browser_download_url"%s*:%s*"([^"]+)".-"name"%s*:%s*"' .. escaped .. '"')
    end
    if not url then
        return nil, "asset not found in release JSON: " .. asset_name
    end
    return url
end

----------------------------------------------------------------------
-- Version helpers
----------------------------------------------------------------------

--- Strip leading v/V from a version string.
--- @param ver string
--- @return string
function luaGitBridge.normalize_version(ver)
    if type(ver) ~= "string" then
        return ""
    end
    return (ver:gsub("^[vV]", ""))
end

--- True when versions are equal after normalization.
--- @param a string
--- @param b string
--- @return boolean
function luaGitBridge.versions_equal(a, b)
    return luaGitBridge.normalize_version(a) == luaGitBridge.normalize_version(b)
end

----------------------------------------------------------------------
-- URL builders
----------------------------------------------------------------------

--- @param owner string
--- @param repo string
--- @return string
function luaGitBridge.api_latest_release_url(owner, repo)
    return string.format("https://api.github.com/repos/%s/%s/releases/latest", owner, repo)
end

--- @param owner string
--- @param repo string
--- @param tag string
--- @return string
function luaGitBridge.api_release_by_tag_url(owner, repo, tag)
    return string.format("https://api.github.com/repos/%s/%s/releases/tags/%s", owner, repo, tag)
end

--- Direct asset download URL (no API call).
--- @param owner string
--- @param repo string
--- @param tag string
--- @param asset_name string
--- @return string
function luaGitBridge.asset_download_url(owner, repo, tag, asset_name)
    return string.format("https://github.com/%s/%s/releases/download/%s/%s", owner, repo, tag, asset_name)
end

----------------------------------------------------------------------
-- High-level GitHub helpers (HTTP via luaSysBridge)
----------------------------------------------------------------------

local function http_opts(opts)
    opts = opts or {}
    if not opts.useragent then
        opts.useragent = luaGitBridge.DEFAULT_USER_AGENT
    end
    return opts
end

--- Fetch the latest release tag for a public repository.
--- @param owner string
--- @param repo string
--- @param opts table|nil  passed to luaSysBridge.http_get
--- @return string|nil tag
--- @return string|nil err
function luaGitBridge.get_latest_tag(owner, repo, opts)
    if type(owner) ~= "string" or owner == "" then
        return nil, "get_latest_tag(): owner must be a non-empty string"
    end
    if type(repo) ~= "string" or repo == "" then
        return nil, "get_latest_tag(): repo must be a non-empty string"
    end

    local body, err = luaSysBridge.http_get(luaGitBridge.api_latest_release_url(owner, repo), http_opts(opts))
    if not body then
        return nil, "get_latest_tag(): " .. tostring(err)
    end

    local tag, err2 = luaGitBridge.parse_latest_tag(body)
    if not tag then
        return nil, "get_latest_tag(): " .. tostring(err2)
    end
    return tag
end

--- Fetch latest release: tag + raw JSON body.
--- @param owner string
--- @param repo string
--- @param opts table|nil
--- @return string|nil tag
--- @return string|nil json_body
--- @return string|nil err
function luaGitBridge.get_latest_release(owner, repo, opts)
    local body, err = luaSysBridge.http_get(luaGitBridge.api_latest_release_url(owner, repo), http_opts(opts))
    if not body then
        return nil, nil, "get_latest_release(): " .. tostring(err)
    end
    local tag, err2 = luaGitBridge.parse_latest_tag(body)
    if not tag then
        return nil, nil, "get_latest_release(): " .. tostring(err2)
    end
    return tag, body
end

--- Fetch release JSON by tag.
--- @param owner string
--- @param repo string
--- @param tag string
--- @param opts table|nil
--- @return string|nil json_body
--- @return string|nil err
function luaGitBridge.get_release_json(owner, repo, tag, opts)
    local body, err = luaSysBridge.http_get(luaGitBridge.api_release_by_tag_url(owner, repo, tag), http_opts(opts))
    if not body then
        return nil, "get_release_json(): " .. tostring(err)
    end
    return body
end

--- Latest release asset download URL + tag.
--- Falls back to constructed URL if asset is missing from JSON.
--- @param owner string
--- @param repo string
--- @param asset_name string
--- @param opts table|nil
--- @return string|nil download_url
--- @return string|nil tag
--- @return string|nil err
function luaGitBridge.get_latest_asset_url(owner, repo, asset_name, opts)
    local tag, body, err = luaGitBridge.get_latest_release(owner, repo, opts)
    if not tag then
        return nil, nil, err
    end
    local url = luaGitBridge.find_asset_download_url(body, asset_name)
    if not url then
        url = luaGitBridge.asset_download_url(owner, repo, tag, asset_name)
    end
    return url, tag
end

return luaGitBridge
