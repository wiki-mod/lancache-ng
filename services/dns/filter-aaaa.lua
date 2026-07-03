-- lancache-ng (https://github.com/wiki-mod/lancache-ng)
--
-- PowerDNS Recursor Lua script (preresolve hook): AAAA filter that suppresses
-- IPv6 DNS responses for all domains. Enabled by the presence of
-- /var/lib/powerdns/aaaa-filter-enabled. The UI toggles this file via docker
-- exec — no recursor restart needed. dq.variable=true prevents caching so
-- toggling takes effect immediately.

local MARKER = "/var/lib/powerdns/aaaa-filter-enabled"

local function filter_active()
    local f = io.open(MARKER, "r")
    if f then f:close(); return true end
    return false
end

function preresolve(dq)
    if dq.qtype == pdns.AAAA and filter_active() then
        dq.rcode = pdns.NOERROR
        dq.variable = true
        return true
    end
    return false
end
