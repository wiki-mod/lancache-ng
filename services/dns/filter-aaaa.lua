
-- LanCache-NG (https://github.com/wiki-mod/lancache-ng)
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- What: AAAA: NOERROR, no records, if marker exists
-- Why: marker file is the on/off switch the UI toggles

local MARKER = assert(os.getenv("AAAA_FILTER_MARKER_PATH"), "AAAA_FILTER_MARKER_PATH is not set")

-- What: counts suppressed AAAA answers in memory
-- Why: per-query log lines would flood the recursor log
local suppressed_count = 0

-- What: true when the marker file opens for reading
-- Why: checked per query, so toggles apply without restart
local function filter_active()
    local f = io.open(MARKER, "r")
    if f then f:close(); return true end
    return false
end

function preresolve(dq)
    if dq.qtype == pdns.AAAA and filter_active() then
        dq.rcode = pdns.NOERROR
        -- What: marks the answer as not cacheable
        -- Why: a cached AAAA answer would outlive a toggle
        dq.variable = true
        suppressed_count = suppressed_count + 1
        return true
    end
    return false
end

function maintenance()
    -- What: logs and resets the count when it is non-zero
    -- Why: one bounded line per interval, not per query
    if suppressed_count > 0 then
        -- What: logs count at loglevels.Warning
        -- Why: unverified loglevels may raise Lua error
        pdnslog(
            "[lancache-dns][filter-aaaa] suppressed " .. suppressed_count .. " AAAA response(s) since last report",
            pdns.loglevels.Warning
        )
        suppressed_count = 0
    end
end
