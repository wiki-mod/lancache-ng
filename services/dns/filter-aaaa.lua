-- lancache-ng (https://github.com/wiki-mod/lancache-ng)
--
-- PowerDNS Recursor Lua script (preresolve hook): AAAA filter that suppresses
-- IPv6 DNS responses for all domains. Enabled by the presence of
-- /var/lib/powerdns-state/aaaa-filter-enabled. The UI toggles this file
-- through the shared PowerDNS state volume. dq.variable=true prevents
-- caching so toggling takes effect immediately.

local MARKER = "/var/lib/powerdns-state/aaaa-filter-enabled"

-- Bug-hunt finding #14 (docs/bug-hunt/dns.md, re-verified 2026-08-06): this
-- script had no observability at all -- an operator with the AAAA filter
-- toggled on had no way to tell whether it was actually suppressing
-- anything, short of packet-capturing real client traffic. A per-query
-- pdnslog() call was deliberately rejected here: every device on the LAN
-- issuing an AAAA query would produce a log line, which on any real
-- network is enough query volume to flood the recursor's own log and mask
-- genuinely actionable messages. Instead, this counts suppressions in
-- memory and reports the delta from the Recursor's own periodic
-- maintenance() callback (doc.powerdns.com/recursor/lua-scripting/hooks.html,
-- confirmed 2026-08-06: called with no arguments at
-- `recursor.lua_maintenance_interval`, which this project leaves at
-- PowerDNS's own built-in default rather than pinning a project-specific
-- value it would then need to keep documented and in sync) -- one bounded
-- log line per interval regardless of real query volume, only ever emitted
-- when the filter actually did something.
local suppressed_count = 0

local function filter_active()
    local f = io.open(MARKER, "r")
    if f then f:close(); return true end
    return false
end

function preresolve(dq)
    if dq.qtype == pdns.AAAA and filter_active() then
        dq.rcode = pdns.NOERROR
        dq.variable = true
        suppressed_count = suppressed_count + 1
        return true
    end
    return false
end

function maintenance()
    if suppressed_count > 0 then
        pdnslog(
            "[lancache-dns][filter-aaaa] suppressed " .. suppressed_count .. " AAAA response(s) since last report",
            pdns.loglevels.Info
        )
        suppressed_count = 0
    end
end
