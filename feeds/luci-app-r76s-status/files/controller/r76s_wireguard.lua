module("luci.controller.r76s_wireguard", package.seeall)

function index()
    local page = entry({"admin", "network", "r76s_wireguard"},
        call("action_status"), _("WireGuard 管理"), 65)
    page.dependent = false
    entry({"admin", "network", "r76s_wireguard", "data"}, call("action_data")).leaf=true
end

local function snapshot()
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require("luci.model.uci").cursor()
    local model = require "luci.model.r76s.services"
    local configured = {}
    uci:foreach("network", "interface", function(section)
        if section.proto == "wireguard" then
            local peers, clients = 0, {}
            uci:foreach("network", "wireguard_" .. section[".name"], function(peer)
                peers=peers+1
                if peer.public_key then clients[#clients+1]={key=peer.public_key,
                    label=peer.description or peer[".name"] or ("Peer " .. peers),
                    disabled=peer.disabled == "1"} end
            end)
            configured[#configured + 1] = {name=section[".name"], peers=peers, clients=clients}
        end
    end)
    local dump = json.parse(sys.exec("ubus call network.interface dump 2>/dev/null"))
    local live = type(dump) == "table" and dump.interface or {}
    if type(live) ~= "table" then live = {} end
    -- These commands never print private keys or preshared keys.
    local handshakes = sys.exec("wg show all latest-handshakes 2>/dev/null")
    local transfers = sys.exec("wg show all transfer 2>/dev/null")
    local installed=fs.access("/usr/bin/wg", "x")
    local healthy=installed and type(dump) == "table" and type(dump.interface) == "table" and sys.call("wg show all >/dev/null 2>&1") == 0
    return { healthy=healthy, timestamp=os.time(),
        installed=fs.access("/usr/bin/wg", "x"),
        rows=model.wireguard(configured, live, handshakes, transfers, os.time(), healthy)
    }
end

function action_status()
    require("luci.template").render("r76s_wireguard/status", {data=snapshot()})
end

function action_data()
    local http=require "luci.http"
    http.header("Cache-Control", "no-store")
    http.prepare_content("application/json")
    http.write_json(snapshot())
end
