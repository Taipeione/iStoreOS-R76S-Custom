#!/usr/bin/lua
-- Additive application-rule migration for OpenWrt 25.12 APK images.
-- Existing named sections, user rules, nodes and ordering are never replaced.
-- AppleEcosystem intentionally carries no node/outbound/strategy option and
-- therefore follows the active system default outbound policy.
local fs = require 'nixio.fs'
local json = require 'luci.jsonc'
local uci = require 'uci'.cursor()
local path = '/usr/share/r76s/r76s-app-rules.json'
local text = fs.readfile(path)
if not text or text == '' then os.exit(0) end
local doc = json.parse(text)
if type(doc) ~= 'table' or doc.schema_version ~= 1 or type(doc.rules) ~= 'table' then
    io.stderr:write('r76s-rules-merge: invalid manifest\n')
    os.exit(1)
end

local function section_exists(pkg, name)
    local found = false
    uci:foreach(pkg, 'shunt_rules', function(s)
        if s['.name'] == name then found = true end
    end)
    return found
end

local function merge_package(pkg)
    if not uci:get_first(pkg, 'global') and not uci:get_first(pkg, 'globals') then
        return
    end
    local changed = false
    for _, rule in ipairs(doc.rules) do
        if type(rule) == 'table' and type(rule.name) == 'string' and
           type(rule.options) == 'table' and not section_exists(pkg, rule.name) then
            uci:section(pkg, 'shunt_rules', rule.name, rule.options)
            changed = true
        end
    end
    if changed then uci:commit(pkg) end
end

merge_package('passwall')
merge_package('passwall2')
