#!/bin/sh
# R76S V1.1.1 DNS Configuration Guard
# Read-only classifier for: uci show dhcp.@dnsmasq[0]
# Never writes UCI, files, or service state.

awk '
{
    pos = index($0, "=")
    if (!pos) next

    key = substr($0, 1, pos - 1)
    val = substr($0, pos + 1)

    sub(/^.*[.]/, "", key)

    quote = sprintf("%c", 39)
    if (length(val) >= 2 &&
        substr(val, 1, 1) == quote &&
        substr(val, length(val), 1) == quote) {
        val = substr(val, 2, length(val) - 2)
    }

    if (key == "server") {
        server_count++
        server = val
    }
    if (key == "noresolv") {
        noresolv_count++
        noresolv = val
    }
    if (key == "resolvfile") {
        resolvfile_count++
        resolvfile = val
    }
}
END {
    profile = "CUSTOM_OR_UNKNOWN"
    action = "BLOCK_AUTO_REWRITE"

    if (server_count == 0 &&
        noresolv_count <= 1 &&
        (noresolv_count == 0 || noresolv == "0") &&
        resolvfile_count == 1 &&
        resolvfile == "/tmp/resolv.conf.d/resolv.conf.auto") {

        profile = "WAN_BASELINE"
        action = "KEEP_EXISTING_CONFIG"
    }

    if (server_count == 1 &&
        server == "127.0.0.1#3053" &&
        noresolv_count == 1 &&
        noresolv == "1" &&
        resolvfile_count == 1 &&
        resolvfile == "/tmp/resolv.conf.d/r76s-unused") {

        profile = "LEGACY_3053"
        action = "REQUIRE_BACKUP_BEFORE_MIGRATION"
    }

    print "DNS_PROFILE=" profile
    print "RECOMMENDED_ACTION=" action
    print "SERVER_ENTRIES=" (server_count + 0)
    print "AUTOMATIC_CHANGES=NONE"
}
'
