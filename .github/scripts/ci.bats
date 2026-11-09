#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: A new test needs a prior maintainer ACK on the PR.
# Why: AG-WF-029 order, issue comment 6145242213.
# From: Issue #1683 | PR #1912

# What: run one base command, log its full output, keep rc.
# Why: one owner for the four base-fact tests below.
# From: Issue #1683 | PR #1858
base_fact() {
    run "$@"
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: logs uptime and load of the test host.
# Why: DoMe ACK 23.10. 21:40 CEST: base facts every run.
# From: Issue #1683 | PR #1858
@test "base: uptime" {
    base_fact uptime
}

# What: logs every process with full command lines.
# Why: DoMe ACK 23.10. 21:40 CEST: base facts every run.
# From: Issue #1683 | PR #1858
@test "base: ps auxwww" {
    base_fact ps auxwww
}

# What: logs disk usage of every mounted file system.
# Why: DoMe ACK 23.10. 21:40 CEST: base facts every run.
# From: Issue #1683 | PR #1858
@test "base: df -h" {
    base_fact df -h
}

# What: logs memory and swap use in MiB.
# Why: DoMe ACK 23.10. 21:40 CEST: base facts every run.
# From: Issue #1683 | PR #1858
@test "base: free -m" {
    base_fact free -m
}

# What: source ci.sh and load the SOT for a moved test.
# Why: moved tests call ci.sh helpers and read the SOT.
# From: Issue #1683
ci_sh_load() {
    load ci.sh
    # What: the init steps ci_main runs before a command.
    # Why: moved tests ran as ci.sh commands with this init.
    # From: Issue #1683
    _ci_cmd_time_init
    _ci_tmp_init
    _ci_proxy_init
    _ci_git_trust_init
    ci_require_manifest
    _ci_sot_load
    _ci_debug_init
}

# What: $2 trimmed, each blank run one space, into var $1.
# Why: one blank fold owner; bash only.
# From: Issue #1683 | PR #1858
_ci_ws_fold() {
    local ws_in="$2" ws_out="" ws_run
    ws_in="${ws_in#"${ws_in%%[![:space:]]*}"}"
    ws_in="${ws_in%"${ws_in##*[![:space:]]}"}"
    while [[ "${ws_in}" =~ [[:space:]]+ ]]; do
        ws_run="${BASH_REMATCH[0]}"
        ws_out+="${ws_in%%"${ws_run}"*} "
        ws_in="${ws_in#*"${ws_run}"}"
    done
    printf -v "$1" '%s' "${ws_out}${ws_in}"
}

# What: health ACL order and ignored-header hiding.
# Why: a bare return skips the ACL; ignored headers leak.
# From: Issue #1683 | PR #1858
_ci_check_proxy_nginx_policy() {
    local repo_root="${1:-${CI_REPO_ROOT}}" f out line pp blocks=0 b h a d al r px hk hu hp="" hq pn lb fb hv sv sp bn
    local hz_raw hz_line hz_body hz_in hz_a hz_d hz_al hz_r
    local la_raw la_line la_loc la_t la_in la_dep la_a la_d la_s la_m
    local ih_raw ih_h
    local -a viol=() bnt hz_fld=() la_fld=() ih_fld=() ih_seq=()
    local -A ih_ign=() ih_hid=()
    px="$(_ci_service_path ui nginx "${repo_root}")" || return 2
    px="${px%/}"
    # What: the health and status paths of the SOT.
    # Why: the templates name the keys; values must be sane.
    # From: Issue #1683 | PR #1912
    hv="$(_ci_runtime_default PROXY_HEALTH_PATH)" || return 2
    sv="$(_ci_runtime_default PROXY_STATUS_PATH)" || return 2
    if ! [[ "${sv}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        ci_log "[CI-ERROR-CHECK-0196]" "key=\"PROXY_STATUS_PATH\" value=\"${sv}\" reason=\"SOT status path is no plain absolute path\""
        return 2
    fi
    for hk in PROXY_HEALTH_URL PROXY_HEALTH_HTTPS_URL; do
        hu="$(_ci_runtime_default "${hk}")" || return 2
        hq="${hu#*://}"
        hq="/${hq#*/}"
        if [[ "${hu}" != *://*/* ]] || ! [[ "${hq}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
            ci_log "[CI-ERROR-CHECK-0194]" "key=\"${hk}\" value=\"${hu}\" reason=\"SOT health URL names no plain absolute path\""
            return 2
        fi
        if [ "${hq}" != "${hv}" ]; then
            ci_log "[CI-ERROR-CHECK-0195]" "key=\"${hk}\" path=\"${hq}\" other=\"${hv}\" reason=\"the SOT health URL path differs from PROXY_HEALTH_PATH\""
            return 2
        fi
    done
    hp="\${PROXY_HEALTH_PATH}"
    sp="\${PROXY_STATUS_PATH}"
    # What: the allow targets a location may carry.
    # Why: the SOT owns the ranges; templates name the key.
    # From: Issue #1683 | PR #1912
    pn="$(_ci_runtime_default PRIVATE_NETS)" || return 2
    bn="$(_ci_runtime_default DOCKER_BRIDGE_NET)" || return 2
    read -ra bnt <<<"${bn}"
    for h in "${bnt[@]}"; do
        [[ " ${pn} " == *" ${h} "* ]] \
            || viol+=("DOCKER_BRIDGE_NET holds ${h}, which is no PRIVATE_NETS member")
    done
    lb="\${LOOPBACK_BIND_IP}/32 \${DOCKER_BRIDGE_NET}"
    pp="${px}/proxy-params.conf"
    # What: one /healthz block, in proxy-params.conf only.
    # Why: both servers include it; a copy is a 2nd owner.
    # From: Issue #1683 | PR #1858
    for f in "${px}"/conf.d/*.conf "${pp}"; do
        out="" hz_in=0
        # What: per block "body|allows|deny|alias|return".
        # Why: deny is 1 for deny all; with no allow after.
        while IFS= read -r hz_raw || [ -n "${hz_raw}" ]; do
            read -r -a hz_fld <<< "${hz_raw}"
            if [ "${hz_fld[0]-}" = location ] && [ "${hz_fld[1]-}" = "=" ] && [ "${hz_fld[2]-}" = "${hp}" ] && [ "${hz_fld[3]-}" = "{" ]; then
                hz_in=1 hz_body="" hz_a=0 hz_d=0 hz_al=0 hz_r=0
                continue
            fi
            [ "${hz_in}" -eq 1 ] || continue
            if [[ "${hz_raw}" =~ ^[[:space:]]*\} ]]; then
                out+="${hz_body}|${hz_a}|${hz_d}|${hz_al}|${hz_r}"$'\n'
                hz_in=0
                continue
            fi
            _ci_ws_fold hz_line "${hz_raw}"
            hz_body+="${hz_line};"
            if [[ "${hz_line}" == "allow "* ]]; then
                hz_a=$((hz_a + 1))
                [ "${hz_d}" -eq 0 ] || hz_d=-1
            fi
            [ "${hz_line}" != "deny all;" ] || [ "${hz_d}" -ne 0 ] || hz_d=1
            [[ "${hz_line}" != "alias "* ]] || hz_al=1
            [[ "${hz_line}" != "return "* ]] || hz_r=1
        done < "${f}" || return 2
        out="${out%$'\n'}"
        fb=0
        while IFS='|' read -r b line; do
            [ -n "${b}" ] || continue
            blocks=$((blocks + 1))
            fb=$((fb + 1))
            IFS='|' read -r a d al r <<<"${line}"
            [ "${a}" -ge 1 ] && [ "${d}" -eq 1 ] || viol+=("${f#"${repo_root}/"}: ${hp} needs allow lines followed by deny all")
            [ "${al}" -eq 1 ] && [ "${r}" -eq 0 ] || viol+=("${f#"${repo_root}/"}: ${hp} must serve via alias, never return (return skips the ACL)")
        done <<<"${out}"
        if [ "${f}" = "${pp}" ]; then
            [ "${fb}" -eq 1 ] || viol+=("${f#"${repo_root}/"}: needs exactly one ${hp} block, found ${fb}")
        else
            [ "${fb}" -eq 0 ] || viol+=("${f#"${repo_root}/"}: ${hp} block belongs in proxy-params.conf only")
        fi
        # What: the allow lines of every location.
        # Why: a location with allow lines is an ACL.
        # From: Issue #1683 | PR #1912
        out="" la_in=0
        # What: rows "loc|T|target", "loc|D|" and "loc|S|".
        # Why: each location line opens a new block.
        while IFS= read -r la_raw || [ -n "${la_raw}" ]; do
            read -r -a la_fld <<< "${la_raw}"
            if [ "${la_fld[0]-}" = location ]; then
                la_loc="${la_raw#"${la_raw%%[![:space:]]*}"}"
                la_m=""
                [[ ! "${la_loc}" =~ [[:space:]]*\{[[:space:]]*$ ]] || la_m="${BASH_REMATCH[0]}"
                la_loc="${la_loc%"${la_m}"}"
                la_m=""
                [[ ! "${la_loc}" =~ [[:space:]]+$ ]] || la_m=" "
                _ci_ws_fold la_loc "${la_loc}"
                la_loc+="${la_m}"
                la_in=1 la_dep=0 la_a=0 la_d=0 la_s=0
            fi
            [ "${la_in}" -eq 1 ] || continue
            _ci_ws_fold la_line "${la_raw}"
            if [[ "${la_line}" == "allow "* ]]; then
                la_t="${la_line#allow }"
                out+="${la_loc}|T|${la_t%;}"$'\n'
                la_a=$((la_a + 1))
                [ "${la_d}" -eq 0 ] || la_d=-1
            fi
            [ "${la_line}" != "deny all;" ] || [ "${la_d}" -ne 0 ] || la_d=1
            [ "${la_line}" != "stub_status;" ] || la_s=1
            la_m="${la_raw//\{/}"
            la_dep=$((la_dep + ${#la_raw} - ${#la_m}))
            la_m="${la_raw//\}/}"
            la_dep=$((la_dep - ${#la_raw} + ${#la_m}))
            [ "${la_dep}" -le 0 ] || continue
            [ "${la_a}" -eq 0 ] || [ "${la_d}" -eq 1 ] || out+="${la_loc}|D|"$'\n'
            [ "${la_s}" -eq 0 ] || out+="${la_loc}|S|"$'\n'
            la_in=0
        done < "${f}" || return 2
        out="${out%$'\n'}"
        while IFS='|' read -r line b h; do
            [ -n "${line}" ] || continue
            if [ "${b}" = "T" ]; then
                [[ " ${lb} " == *" ${h} "* ]] \
                    || viol+=("${f#"${repo_root}/"}: ${line} allows ${h}, neither the loopback bind nor \${DOCKER_BRIDGE_NET} (a literal is a second owner)")
            elif [ "${b}" = "S" ]; then
                [ "${line}" = "location = ${sp}" ] \
                    || viol+=("${f#"${repo_root}/"}: ${line} serves stub_status but is not location = ${sp}")
            elif [ "${line}" != "location = ${hp}" ]; then
                viol+=("${f#"${repo_root}/"}: ${line} needs allow lines followed by deny all")
            fi
        done <<<"${out}"
    done
    # What: ignored and hidden headers of proxy-params.conf.
    # Why: keys get a k so an empty name is a key too.
    # From: Issue #1683 | PR #1858
    while IFS= read -r ih_raw || [ -n "${ih_raw}" ]; do
        read -r -a ih_fld <<< "${ih_raw}"
        if [ "${ih_fld[0]-}" = proxy_ignore_headers ]; then
            for ih_h in "${ih_fld[@]:1}"; do
                ih_h="k${ih_h%;}"
                [ -n "${ih_ign[${ih_h}]-}" ] || ih_seq+=("${ih_h}")
                ih_ign[${ih_h}]=1
            done
        elif [ "${ih_fld[0]-}" = proxy_hide_header ]; then
            ih_h="${ih_fld[1]-}"
            ih_hid[k${ih_h%;}]=1
        fi
    done < "${pp}" || return 2
    for ih_h in Cache-Control Expires Vary Set-Cookie; do
        [ -n "${ih_ign[k${ih_h}]-}" ] \
            || viol+=("${pp#"${repo_root}/"}: proxy_ignore_headers must include ${ih_h}")
    done
    for ih_h in "${ih_seq[@]}"; do
        [ -n "${ih_hid[${ih_h}]-}" ] \
            || viol+=("${pp#"${repo_root}/"}: ignored header ${ih_h#k} must also be hidden from clients")
    done
    # What: the https.conf template includes the listen file
    # Why: a literal listen would be a second port owner.
    # From: Issue #1683 | PR #1912
    _ci_file_match "[CI-ERROR-CHECK-0182]" "reason=\"https include not searched\"" "${px}/conf.d/https.conf" "    include     \${NGINX_DIR}/\${NGINX_HTTPS_LISTEN_FILE};" -Fx \
        || { [ "$?" -eq 1 ] || return 2; viol+=("${px#"${repo_root}/"}/conf.d/https.conf: no include of the SOT keys NGINX_DIR and NGINX_HTTPS_LISTEN_FILE"); }
    if _ci_file_match "[CI-ERROR-CHECK-0183]" "reason=\"https listen not searched\"" "${px}/conf.d/https.conf" '^[[:space:]]*listen[[:space:]]'; then
        viol+=("${px#"${repo_root}/"}/conf.d/https.conf: literal listen; the watchdog renders it")
    elif [ "$?" -ne 1 ]; then
        return 2
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0151]" "reason=\"proxy nginx policy violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'proxy-nginx-policy=clean healthz_blocks=%s\n' "${blocks}"
}

# What: proxy cert, CA and cache dirs sit on the SOT mounts.
# Why: the SOT owns them; Compose and nginx.conf use them.
# From: Issue #1683 | PR #1858
_ci_check_proxy_cert_volume() {
    local repo_root="${1:-${CI_REPO_ROOT}}" dir ca cache cf cfg out px
    local -a viol=() files=()
    local -A seen=()
    dir="$(_ci_nginx_subdir NGINX_SUBDIR_CERTS)" || return 2
    ca="$(_ci_nginx_subdir NGINX_SUBDIR_CA)" || return 2
    cache="$(_ci_runtime_default NGINX_CACHE_DIR)" || return 2
    px="$(_ci_service_path ui nginx "${repo_root}")" || return 2
    _ci_file_match "[CI-ERROR-CHECK-0184]" "reason=\"proxy_cache_path not searched\"" "${px%/}/nginx.conf" '^[[:space:]]*proxy_cache_path[[:space:]]+\$\{NGINX_CACHE_DIR\}[[:space:]]*$' \
        || { [ "$?" -eq 1 ] || return 2; viol+=("${px#"${repo_root}/"}nginx.conf: proxy_cache_path is not the SOT key NGINX_CACHE_DIR"); }
    _ci_stack_compose_files files || return $?
    for cf in "${files[@]}"; do
        [ -z "${seen[${cf}]:-}" ] || continue
        seen["${cf}"]=1
        cfg="$(_ci_compose_json "${repo_root}/${cf}")" || return 2
        out="$(_ci_capture 0 jq -r --arg d "${dir}" --arg c "${ca}" --arg k "${cache}" "$(cat <<'PROG'
.services.proxy // empty
            | def mount($t; $kind): [.volumes // [] | .[] | select(.target == $t)] as $m
                | if ($m | length) != 1 then "proxy needs exactly one mount at \($t) (got \($m | length))"
                  elif $m[0].type != $kind or ($m[0].source // "") == ""
                  then "proxy \($t) must be a \($kind) mount (got \($m[0].type) \($m[0].source // "anonymous"))"
                  else empty end;
              mount($d; "volume"), mount($c; "bind"), mount($k; "volume")
PROG
              )" <<<"${cfg}")" || return 2
        _ci_viol_lines viol "${cf}" "${out}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0149]" "reason=\"proxy dirs differ from the SOT mounts\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'proxy-cert-volume=clean cert_dir=%s ca_dir=%s cache_dir=%s files=%s\n' "${dir}" "${ca}" "${cache}" "${#seen[@]}"
}

# What: print *.domain stream targets not sent to the SNI
# Why: a root literal sends every subdomain to one origin
# From: Issue #1297 | PR #1858
_ci_stream_map_violations() {
    local port="$1" line second
    while IFS= read -r line || [ -n "${line}" ]; do
        [[ "${line}" =~ ^[[:space:]]*\*\. ]] || continue
        read -r _ second _ <<< "${line}"
        [ "${second}" = "\$ssl_preread_server_name:${port};" ] || printf '%s\n' "${line}"
    done
}

# What: print depth>=2 dispatch entries off the relay port
# Why: deeper SNI has no wildcard cert; it must passthrough
# From: Issue #1322 | PR #1858
_ci_https_dispatch_violations() {
    local port="$1" line
    local -a w
    while IFS= read -r line || [ -n "${line}" ]; do
        [[ "${line}" == *'~^.+\.'* ]] || continue
        read -r -a w <<< "${line}"
        [[ "${w[-1]}" == *":${port};" ]] || printf '%s\n' "${line}"
    done
}

# What: prove proxy routes wildcards by SNI.
# Why: root literal misroutes subdomains.
# From: Issue #1683
_ci_validate_proxy_stream_map() {
    local file port
    file="$(_ci_runtime_default NGINX_STREAM_TARGETS_FILE)" || return 2
    file="$(_ci_nginx_path "${file}")" || return 2
    port="$(_ci_runtime_default NGINX_ORIGIN_HTTPS_PORT)" || return 2
    _ci_validate_proxy_map "$1" "${file}" _ci_stream_map_violations "${port}" \
        "[CI-ERROR-VALIDATE-0022]" "no proxy container for stream-map check" \
        "[CI-ERROR-VALIDATE-0019]" "could not read proxy stream-target map" \
        "[CI-ERROR-VALIDATE-0020]" "stream-target wildcard forwards to a hardcoded root, not the requested SNI"
}

# What: read a proxy map; a filter prints its bad rows.
# Why: both SNI map checks share one read and verdict.
# From: Issue #1683 | PR #1912
_ci_validate_proxy_map() {
    local project="$1" file="$2" filter="$3" arg="$4" cid map bad svc
    svc="$(_ci_validation_service proxy)" || return 2
    cid="$(_ci_validate_cid "${project}" "${svc}")" || return 2
    if [ -z "${cid}" ]; then
        ci_log "$5" "reason=\"$6\""
        return 2
    fi
    if ! map="$(_ci_capture 0 _ci_bounded_exec "${cid}" cat "${file}")"; then
        ci_log "$7" "reason=\"$8\""
        return 2
    fi
    bad="$(printf '%s\n' "${map}" | "${filter}" "${arg}")"
    if [ -n "${bad}" ]; then
        ci_error "$9" "reason=\"${10}\"" "${bad}"
        return 1
    fi
}

# What: Prove https mode intercepts (MITM) with our LAN CA.
# Why: the proxy https port must show a cert we signed
# From: Issue #1683
_ci_validate_https_mitm() {
    local project="$1" ip cid domain ca_subj issuer tmp out cert tls_err ca ca_file port svc max
    max="$(_ci_variable CI_VALIDATE_HTTP_MAX_TIME)" || return 2
    ca="$(_ci_nginx_subdir NGINX_SUBDIR_CA)" || return 2
    ca_file="$(_ci_runtime_default CA_CERT_FILE)" || return 2
    port="$(_ci_runtime_default PROXY_HTTPS_PORT)" || return 2
    svc="$(_ci_validation_service proxy)" || return 2
    ip="$(_ci_validate_container_ip "${project}" "${svc}")"
    cid="$(_ci_validate_cid "${project}" "${svc}")" || return 2
    domain="$(_ci_validation_dns_domain)"
    if [ -z "${ip}" ] || [ -z "${cid}" ] || [ -z "${domain}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0023]" "reason=\"no proxy container/IP or test domain for https-mitm check\""
        return 2
    fi
    tmp="$(_ci_mktemp "${CI_TMPDIR}/ci-proxy-ca.XXXXXX")" || return 2
    if ! out="$(docker cp "${cid}:${ca}/${ca_file}" "${tmp}" 2>&1)"; then
        out+=$'\n'"$(_ci_validate_service_evidence "${project}" "$(_ci_validation_service ui)")"
        ci_error "[CI-ERROR-VALIDATE-0024]" "reason=\"could not read proxy LAN CA for https-mitm check\"" "${out}"
        rm -f "${tmp}"
        return 2
    fi
    ca_subj="$(_ci_capture 0 openssl x509 -noout -subject -in "${tmp}")" || { rm -f "${tmp}"; return 2; }
    ca_subj="${ca_subj#subject=}"
    rm -f "${tmp}"
    # What: s_client writes handshake notes to stderr.
    # Why: raw evidence when the issuer read fails.
    # From: Issue #1683 | PR #1858
    tls_err="$(_ci_mktemp "${CI_TMPDIR}/ci-tls-err.XXXXXX")" || { rm -f "${tmp}"; return 2; }
    cert="$(printf '' | timeout "${max}" openssl s_client -connect "${ip}:${port}" -servername "${domain}" 2>"${tls_err}")"
    issuer=""
    if [ -n "${cert}" ]; then
        issuer="$(openssl x509 -noout -issuer 2>>"${tls_err}" <<<"${cert}")"
        issuer="${issuer#issuer=}"
    fi
    if [ -z "${ca_subj}" ] || [ -z "${issuer}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0025]" "domain=\"${domain}\" reason=\"no TLS issuer or CA subject for https-mitm check\"" "$(cat "${tls_err}"; _ci_validate_service_evidence "${project}" "$(_ci_validation_service ui)")"
        rm -f "${tls_err}"
        return 1
    fi
    rm -f "${tls_err}"
    # What: the https cert issuer MUST equal our own LAN CA.
    # Why: proves interception, not passthrough.
    # From: Issue #668
    if [ "${issuer}" != "${ca_subj}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0026]" "issuer=\"${issuer}\" ca=\"${ca_subj}\" reason=\"https mode :${port} cert not issued by our LAN CA (not intercepting)\""
        return 1
    fi
}

# What: https-mode depth-dispatch routes deeper SNI right.
# Why: depth>=2 SNI takes the passthrough relay, not MITM
# From: Issue #1683
_ci_validate_https_dispatch_map() {
    local file relay
    file="$(_ci_runtime_default NGINX_HTTPS_DISPATCH_FILE)" || return 2
    file="$(_ci_nginx_path "${file}")" || return 2
    relay="$(_ci_runtime_default NGINX_PASSTHROUGH_RELAY_PORT)" || return 2
    _ci_validate_proxy_map "$1" "${file}" _ci_https_dispatch_violations "${relay}" \
        "[CI-ERROR-VALIDATE-0027]" "no proxy container for https-dispatch-map check" \
        "[CI-ERROR-VALIDATE-0028]" "could not read proxy https-dispatch map (HTTPS_ENABLED=0?)" \
        "[CI-ERROR-VALIDATE-0029]" "depth>=2 SNI dispatch entry routes to MITM, not passthrough relay :${relay}"
}

# What: retry a probe; print its last raw error on fail.
# Why: a timeout must show why the probe never answered.
# From: Issue #1683 | PR #1858
_ci_validate_poll() {
    local attempts="$1" pause="$2" i out
    shift 2
    for (( i = 1; i <= attempts; i++ )); do
        if out="$("$@" 2>&1)"; then
            return 0
        fi
        if [ "${i}" -lt "${attempts}" ]; then
            sleep "${pause}"
        fi
    done
    printf '%s\n' "${out}"
    return 1
}

# What: http://<ip>:<port> of one ui container in the /27
# Why: the image exposes one port; resolved once per probe
# From: Issue #1683 | PR #1858
_ci_validate_ui_base() {
    local project="$1" cid="$2" ip ports p
    local -a tcp=()
    if [ -z "${cid}" ] || ! ip="$(_ci_validate_cid_ip "${project}" "${cid}")"; then
        ci_log "[CI-ERROR-VALIDATE-0103]" "container=\"${cid}\" reason=\"no /27 IP for the ui container\""
        return 2
    fi
    ports="$(_ci_capture 0 docker inspect -f "{{range \$p, \$v := .Config.ExposedPorts}}{{println \$p}}{{end}}" "${cid}")" || return 2
    while IFS= read -r p; do
        if [[ "${p}" =~ ^([0-9]+)/tcp$ ]]; then
            tcp+=("${BASH_REMATCH[1]}")
        fi
    done <<< "${ports}"
    if [ "${#tcp[@]}" -ne 1 ]; then
        ci_error "[CI-ERROR-VALIDATE-0104]" "container=\"${cid}\" reason=\"need exactly one exposed TCP port\"" "${ports}"
        return 2
    fi
    printf 'http://%s:%s' "${ip}" "${tcp[0]}"
}

# What: open a ui session in <jar>; print its CSRF token
# Why: posts send the token a browser reads from the form
# From: Issue #1683 | PR #1858
_ci_validate_ui_session() {
    local jar="$1" base="$2" page csrf last url
    if [ -z "${base}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0030]" "reason=\"no ui container IP for session check\""
        return 2
    fi
    url="${base}$(_ci_runtime_default UI_PAGE_DOMAINS)" || return 2
    # What: one try; wait_healthy already saw ui healthy.
    # Why: its healthcheck asks the same server; no poll.
    # From: Issue #1683 | PR #1912
    if ! last="$(_ci_validate_curl -fsS -c "${jar}" "${url}" 2>&1)"; then
        ci_error "[CI-ERROR-VALIDATE-0031]" "url=\"${url}\" reason=\"ui page did not answer\"" "${last}"
        return 1
    fi
    page="$(_ci_capture 0 _ci_validate_curl -fsS -b "${jar}" -c "${jar}" "${url}")" || return 2
    csrf="$(_ci_capture 0 sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' <<< "${page}")" || return 2
    csrf="${csrf%%$'\n'*}"
    if [ -z "${csrf}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0032]" "url=\"${url}\" reason=\"no csrf_token field on the ui page\"" "${page}"
        return 1
    fi
    printf '%s' "${csrf}"
}

# What: new cookie jar plus ui session: sets $1 and $2.
# Why: one owner; three probes opened a session this way.
# From: Issue #1683 | PR #1912
_ci_validate_ui_login() {
    local -n _ci_ul_jar="$1" _ci_ul_csrf="$2"
    local _ci_ul_rc=0
    _ci_ul_jar="$(_ci_mktemp "${CI_TMPDIR}/ci-ui-jar.XXXXXX")" || return 2
    _ci_ul_csrf="$(_ci_validate_ui_session "${_ci_ul_jar}" "$3")" || _ci_ul_rc=$?
    [ "${_ci_ul_rc}" -eq 0 ] || rm -f "${_ci_ul_jar}"
    return "${_ci_ul_rc}"
}

# What: setup.sh rollback around a one-run .env.local.
# Why: one owner for the dns and Kea rollback legs.
# From: Issue #1683 | PR #1912
_ci_validate_setup_rollback() {
    local -n _ci_sr_out="$1" _ci_sr_rc="$2"
    local _ci_sr_env="$3" _ci_sr_svc="$4"
    shift 4
    _ci_sr_rc=0
    # What: the run's state root leads the one-run env file
    # Why: setup.sh reads the state root only from that file
    # From: Issue #1683 | PR #1912
    if [ -z "${LANCACHE_STATE_DIR:-}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0132]" "svc=\"${_ci_sr_svc}\" reason=\"no per-run LANCACHE_STATE_DIR to hand setup.sh\""
        return 2
    fi
    _ci_sr_env="LANCACHE_STATE_DIR=${LANCACHE_STATE_DIR}${_ci_sr_env:+$'\n'${_ci_sr_env}}"
    _ci_setup_run _ci_sr_out _ci_sr_rc "" "${_ci_sr_env}" \
        reset-to-last-known-good-config "${_ci_sr_svc}" @INST@ "$@" --yes
}

# What: POST one LAN A record through the ui (303 on ok)
# Why: drives the real UI->PowerDNS API write path
# From: Issue #1683 | PR #1858
_ci_validate_ui_add_record() {
    local base="$1" jar="$2" csrf="$3" name="$4" content="$5" ttl route
    if [ -z "${base}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0033]" "reason=\"no ui container IP for add-record\""
        return 2
    fi
    ttl="$(_ci_variable CI_VALIDATE_PROBE_TTL)" || return 2
    # What: the LAN add route of the ui, from the SOT
    # Why: the zone name is not part of the route path
    # From: Issue #1683 | PR #1912
    route="$(_ci_runtime_default UI_ROUTE_LAN_ADD)" || return 2
    _ci_validate_ui_post "${base}" "${jar}" "${route}" "csrf_token=${csrf}" \
        "name=${name}" record_type=A "content=${content}" "ttl=${ttl}"
}

# What: POST a UI form; rc 0 on 303, 1 other, 2 on error.
# Why: one owner for the CSRF form post and its 303 check.
# From: Issue #1683 | PR #1858
_ci_validate_ui_post() {
    local base="$1" jar="$2" path="$3" field code body raw
    shift 3
    local -a data=()
    for field in "$@"; do
        data+=(--data-urlencode "${field}")
    done
    body="$(_ci_mktemp "${CI_TMPDIR}/ci-ui-body.XXXXXX")" || return 2
    code="$(_ci_capture 0 _ci_validate_curl -sS -b "${jar}" -o "${body}" -w '%{http_code}' \
        "${data[@]}" "${base}${path}")" || {
        rm -f "${body}"
        ci_log "[CI-ERROR-VALIDATE-0082]" "url=\"${base}${path}\" reason=\"ui form post failed (raw above)\""
        return 2
    }
    if [ "${code}" != "303" ]; then
        raw="$(_ci_capture 0 cat "${body}")" || { rm -f "${body}"; return 2; }
        ci_error "[CI-ERROR-VALIDATE-0034]" "url=\"${base}${path}\" code=\"${code}\" reason=\"ui form post did not return 303; response body in raw\"" "${raw}"
        rm -f "${body}"
        return 1
    fi
    rm -f "${body}"
}

# What: the LAN zone (dotted) the dns side serves.
# Why: DHCP_DOMAIN of the stack env, else its SOT default.
# From: Issue #1683 | PR #1912
_ci_validate_lan_zone() {
    local env zone
    env="$(_ci_validation_env)" || return 2
    zone="$(_ci_kv_line DHCP_DOMAIN "${env}")"
    zone="${zone#*=}"
    if [ -z "${zone}" ]; then
        zone="$(_ci_runtime_default DHCP_DOMAIN)" || return 2
    fi
    if [ -z "${zone}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0106]" "reason=\"no DHCP_DOMAIN in the stack env or the SOT runtime.defaults\""
        return 2
    fi
    printf '%s.\n' "${zone%.}"
}

# What: host <n> of the SOT probe net (RFC 5737 TEST-NET)
# Why: a probe answer must never be a real LAN address
# From: Issue #1683 | PR #1858
_ci_validate_probe_ip() {
    local n="$1" net base
    net="$(_ci_variable CI_VALIDATE_PROBE_NET)" || return 2
    if [[ ! "${net}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/([0-9]+)$ ]] \
        || [ "${n}" -lt 1 ] || [ "${n}" -ge $(( (1 << (32 - BASH_REMATCH[1])) - 1 )) ]; then
        ci_log "[CI-ERROR-VALIDATE-0105]" "net=\"${net}\" host=\"${n}\" reason=\"probe host outside the SOT probe net\""
        return 2
    fi
    base="$(_ci_ipv4_to_int "${net%/*}")" || return 2
    _ci_int_to_ipv4 $(( base + n ))
}

# What: probe MAC <n>: the SOT probe MAC, last octet n
# Why: a locally administered MAC never hits a real NIC
# From: Issue #763 | PR #1858
_ci_validate_probe_mac() {
    local n="$1" mac
    mac="$(_ci_variable CI_VALIDATE_PROBE_MAC)" || return 2
    if [[ ! "${mac}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || [ "${n}" -lt 1 ] || [ "${n}" -gt 255 ]; then
        ci_log "[CI-ERROR-VALIDATE-0111]" "mac=\"${mac}\" host=\"${n}\" reason=\"probe MAC outside the SOT probe MAC\""
        return 2
    fi
    printf '%s:%02x' "${mac%:*}" "${n}"
}

# What: Poll one dns side until <fqdn> is <expected>.
# Why: AXFR to the second side is async; prove it.
# From: Issue #1683 | PR #1912
_ci_validate_dns_resolves() {
    local project="$1" side="$2" fqdn="$3" expected="$4" attempts="$5" ip port svc
    svc="$(_ci_validation_service dns)" || return 2
    ip="$(_ci_validate_container_ip "${project}" "${svc}")"
    if [ -z "${ip}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0035]" "side=\"${side}\" reason=\"no dns IP for resolve check\""
        return 2
    fi
    port="$(_ci_validate_dns_port "${side}")" || return 2
    local out pause
    pause="$(_ci_variable CI_VALIDATE_POLL_PAUSE)" || return 2
    # What: the one poll owner repeats one dig compare.
    # Why: AG-CODE-011: no second poll loop in this file.
    # From: Issue #1683 | PR #1858
    out="$(_ci_validate_poll "${attempts}" "${pause}" _ci_validate_dns_match "${port}" "${ip}" "${fqdn}" "${expected}")" && return 0
    # What: full answer, zone SOA and the service's logs.
    # Why: +short hides NXDOMAIN vs empty vs SERVFAIL.
    # From: Issue #1683 | PR #1858
    ci_error "[CI-ERROR-VALIDATE-0036]" "side=\"${side}\" fqdn=\"${fqdn}\" expected=\"${expected}\" reason=\"record did not resolve as expected\"" \
        "last try:
${out}
full answer:
$(_ci_validate_dig -p "${port}" "@${ip}" A "${fqdn}" 2>&1)
zone SOA:
$(_ci_validate_dig +short -p "${port}" "@${ip}" SOA "${fqdn#*.}" 2>&1)
service:
$(_ci_validate_service_evidence "${project}" "${svc}")"
    return 1
}

# What: one dig +short A answer against the expected set.
# Why: dig stderr stays out of the compared answer.
# From: Issue #1683 | PR #1858
_ci_validate_dns_match() {
    local port="$1" ip="$2" fqdn="$3" expected="$4" out got=""
    if out="$(_ci_validate_dig +short -p "${port}" "@${ip}" A "${fqdn}")"; then
        got="$(sort -u <<<"${out}")"
    fi
    [ "${got}" != "${expected}" ] || return 0
    printf 'got=%s\n' "${got}"
    return 1
}

# What: UI->PowerDNS writes reach both dns sides.
# Why: real end-to-end write, not a mock.
# From: Issue #1683 | PR #1912
_ci_validate_ui_dns() {
    local project="$1" jar csrf cid base zone label ip dns_wait side rc=0 svc
    svc="$(_ci_validation_service ui)" || return 2
    cid="$(_ci_validate_cid "${project}" "${svc}")" || return 2
    base="$(_ci_validate_ui_base "${project}" "${cid}")" || return $?
    zone="$(_ci_validate_lan_zone)" || return 2
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    ip="$(_ci_validate_probe_ip 1)" || return 2
    dns_wait="$(_ci_variable CI_VALIDATE_DNS_WAIT)" || return 2
    _ci_validate_ui_login jar csrf "${base}" || return $?
    _ci_validate_ui_add_record "${base}" "${jar}" "${csrf}" "${label}" "${ip}" || rc=$?
    rm -f "${jar}"
    [ "${rc}" -eq 0 ] || return "${rc}"
    for side in IP_HTTP IP_HTTPS; do
        _ci_validate_dns_resolves "${project}" "${side}" "${label}.${zone}" "${ip}" "${dns_wait}" || return $?
    done
}

# What: curl with one header, user or data line from stdin
# Why: a secret on argv shows in every process list
# From: Issue #1683 | PR #1858
_ci_curl_secret() {
    local opt="$1" value="$2"
    shift 2
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s = "%s"\n' "${opt}" "${value}" | _ci_validate_curl -K - "$@"
}

# What: zone snapshots as JSON, via the ui CLI.
# Why: the ui owns them; setup.sh calls the same.
# From: Issue #628 | PR #1980
_ci_validate_zone_snapshots() {
    local cid="$1" bin out
    bin="$(_ci_required_field ui crates list)" || return 2
    out="$(_ci_capture 0 _ci_bounded_exec "${cid}" "${bin%%$'\n'*}" zone-snapshots)" || return 2
    printf '%s\n' "${out##*$'\n'}"
}

# What: DNS known-good snapshot/rollback round-trip.
# Why: ui CLI snapshots + PATCH + cache flush.
# From: Issue #1683 | PR #1980
_ci_validate_dns_rollback() {
    local project="$1" ip cid jar csrf snap resp rc=0 last
    local zone label old new dns_wait ucid base tries pause decoy dsvc usvc
    dsvc="$(_ci_validation_service dns)" || return 2
    usvc="$(_ci_validation_service ui)" || return 2
    ip="$(_ci_validate_container_ip "${project}" "${dsvc}")"
    cid="$(_ci_validate_cid "${project}" "${dsvc}")" || return 2
    if [ -z "${ip}" ] || [ -z "${cid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0037]" "reason=\"no dns container/IP for rollback check\""
        return 2
    fi
    ucid="$(_ci_validate_cid "${project}" "${usvc}")" || return 2
    zone="$(_ci_validate_lan_zone)" || return 2
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    old="$(_ci_validate_probe_ip 2)" && new="$(_ci_validate_probe_ip 3)" || return 2
    dns_wait="$(_ci_variable CI_VALIDATE_DNS_WAIT)" || return 2
    base="$(_ci_validate_ui_base "${project}" "${ucid}")" || return $?
    _ci_validate_ui_login jar csrf "${base}" || return $?
    _ci_validate_ui_add_record "${base}" "${jar}" "${csrf}" "${label}" "${old}" || { rm -f "${jar}"; return 1; }
    _ci_validate_dns_resolves "${project}" IP_HTTP "${label}.${zone}" "${old}" "${dns_wait}" || { rm -f "${jar}"; return 1; }
    # What: capture the zone's newest snapshot (pre-change).
    # Why: target this test rolls back to after 2nd write.
    # From: Issue #628
    resp="$(_ci_validate_zone_snapshots "${ucid}")" || { rm -f "${jar}"; return 2; }
    snap="$(_ci_capture 0 jq -r --arg z "${zone}" ".zones[\$z][0].id // empty" <<<"${resp}")" || { rm -f "${jar}"; return 2; }
    if [ -z "${snap}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0042]" "zone=\"${zone}\" reason=\"no known-good snapshot after first write\""
        rm -f "${jar}"
        return 1
    fi
    _ci_validate_ui_add_record "${base}" "${jar}" "${csrf}" "${label}" "${new}" || { rm -f "${jar}"; return 1; }
    _ci_validate_dns_resolves "${project}" IP_HTTP "${label}.${zone}" "${new}" "${dns_wait}" || { rm -f "${jar}"; return 1; }
    rm -f "${jar}"
    resp="$(_ci_validate_zone_snapshots "${ucid}")" || return 2
    last="$(_ci_capture 0 jq -r --arg z "${zone}" ".zones[\$z][0].id // empty" <<<"${resp}")" || return 2
    # What: setup.sh rollback, wrong host PDNS_API_KEY.
    # Why: the key must be resolved inside the container.
    # From: Issue #836
    decoy="$(_ci_variable CI_VALIDATE_DECOY_API_KEY)" || return 2
    COMPOSE_PROJECT_NAME="${project}" PDNS_API_KEY="${decoy}" \
        _ci_validate_setup_rollback resp rc "" "${dsvc}" "${zone}" "${snap}" || return 2
    case "${rc}:${resp}" in
        *"cache-flush publishes failed"*) rc=1 ;;
        0:*"rolled back to known-good snapshot ${snap}."*) ;;
        *) rc=1 ;;
    esac
    if [ "${rc}" -ne 0 ]; then
        ci_error "[CI-ERROR-VALIDATE-0043]" "reason=\"setup.sh rollback not applied, probe unchanged or flush failed\"" "${resp}"
        return 1
    fi
    # What: post-rollback dig must return the OLD content.
    # Why: proves recursor cache flush reached it.
    # From: Issue #628
    _ci_validate_dns_resolves "${project}" IP_HTTP "${label}.${zone}" "${old}" "${dns_wait}" || return $?
    tries="$(_ci_variable CI_VALIDATE_SNAPSHOT_POLL_ATTEMPTS)" || return 2
    pause="$(_ci_variable CI_VALIDATE_POLL_PAUSE)" || return 2
    if ! resp="$(_ci_validate_poll "${tries}" "${pause}" _ci_validate_new_snapshot "${ucid}" "${last}" "${zone}")"; then
        ci_error "[CI-ERROR-VALIDATE-0087]" "previous=\"${last}\" zone=\"${zone}\" reason=\"no new snapshot after the rollback\"" "${resp}"
        return 1
    fi
}

# What: true if zone $4's newest snapshot id is not $3
# Why: a restore must record the restored state too.
# From: Issue #836
_ci_validate_new_snapshot() {
    _ci_validate_zone_snapshots "$1" \
        | jq -e --arg p "$2" --arg z "$3" '(.zones[$z][0].id // "") as $i | $i != "" and $i != $p'
}

# What: http-port or user of the Kea control agent
# Why: the SOT runtime.defaults owns both; dhcp renders them
# From: Issue #763 | PR #1912
_ci_validate_kea_agent() {
    local field="$1"
    case "${field}" in
        http-port) _ci_runtime_default KEA_CTRL_PORT ;;
        user) _ci_runtime_default KEA_CTRL_USER ;;
        *) ci_log "[CI-ERROR-VALIDATE-0109]" "field=\"${field}\" reason=\"unknown Kea agent field\""; return 2 ;;
    esac
}

# What: One Kea Control Agent command; prints the reply.
# Why: the product API as the ui sends it; no setup.sh load
# From: Issue #763 | PR #1858
_ci_validate_kea_cmd() {
    _ci_run "[CI-ERROR-VALIDATE-0133]" "url=\"$1\" reason=\"Kea Control Agent command failed\"" \
        _ci_curl_secret user "$2:$3" --fail-with-body -sS -X POST -H 'Content-Type: application/json' -d "$4" "$1/"
}

# What: fail unless a Kea reply carries result 0
# Why: Kea answers per service; result 0 means success
# From: Issue #1683 | PR #1858
_ci_kea_reply_check() {
    local code
    if ! code="$(jq -r 'if type == "array" then .[0] else . end | .result' <<< "$3" 2>&1)" || [ "${code}" != 0 ]; then
        ci_error "$1" "$2 result=\"${code}\"" "$3"
        return 1
    fi
}

# What: Kea snapshot ids under <snapshot dir>, oldest first.
# Why: the rollback target is the id a ui write added.
# From: Issue #763 | PR #1858
_ci_validate_kea_snapshots() {
    local found p id file ids=""
    file="$(_ci_runtime_default KEA_CONFIG_SNAPSHOT_FILE)" || return 2
    if ! [[ "${file}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        ci_log "[CI-ERROR-CHECK-0197]" "key=\"KEA_CONFIG_SNAPSHOT_FILE\" value=\"${file}\" reason=\"SOT snapshot file name is no plain file name\""
        return 2
    fi
    # What: no snapshot dir yet means no snapshots.
    # Why: the ui makes it with its first Kea write.
    # From: Issue #763 | PR #1980
    [ -d "$1" ] || return 0
    found="$(_ci_capture 0 find "$1" -mindepth 2 -maxdepth 2 -name "${file}")" || return 2
    while IFS= read -r p; do
        id="${p%/"${file}"}"
        id="${id##*/}"
        if [[ "${id}" =~ ^[0-9]+$ ]]; then
            ids+="${id}"$'\n'
        fi
    done <<< "${found}"
    [ -z "${ids}" ] || _ci_capture 0 sort <<< "${ids%$'\n'}"
}

# What: Count live Kea reservations for one MAC.
# Why: the rollback must change Kea's state, not a file.
# From: Issue #763 | PR #1858
_ci_validate_kea_has() {
    local cfg
    cfg="$(_ci_capture 0 _ci_validate_kea_cmd "$1" "$2" "$3" '{"command":"config-get","service":["dhcp4"]}')" || return 2
    _ci_kea_reply_check "[CI-ERROR-VALIDATE-0131]" "mac=\"$4\" reason=\"Kea config-get did not return result 0\"" "${cfg}" || return 2
    _ci_capture 0 jq -r --arg m "$4" \
        "[.[0].arguments.Dhcp4.subnet4[].reservations[]? | select((.\"hw-address\" | ascii_downcase) == (\$m | ascii_downcase))] | length" \
        <<< "${cfg}"
}

# What: Add one reservation via the ui, print new snapshot.
# Why: every ui write must record exactly one new snapshot.
# From: Issue #763 | PR #1858
_ci_validate_kea_add() {
    local base="$1" jar="$2" csrf="$3" sid="$4" mac="$5" ip="$6" host="$7" dir="$8"
    local before after new route
    before="$(_ci_validate_kea_snapshots "${dir}")" || return 2
    # What: the reservation add route, from the SOT
    # Why: the ui path has one owner, build-manifest.yml
    # From: Issue #1683 | PR #1912
    route="$(_ci_runtime_default UI_ROUTE_STATIC_ADD)" || return 2
    _ci_validate_ui_post "${base}" "${jar}" "${route}" "csrf_token=${csrf}" \
        "subnet_id=${sid}" "mac=${mac}" "ip=${ip}" "hostname=${host}" || return $?
    after="$(_ci_validate_kea_snapshots "${dir}")" || return 2
    new="${after##*$'\n'}"
    if [ -z "${new}" ] || _ci_list_has "${new}" "${before}"; then
        ci_log "[CI-ERROR-VALIDATE-0088]" "mac=\"${mac}\" before=\"${before//$'\n'/ }\" after=\"${after//$'\n'/ }\" reason=\"ui reservation write recorded no new Kea snapshot\""
        return 1
    fi
    printf '%s' "${new}"
}

# What: Two ui writes, setup.sh rollback, live config-get.
# Why: the CLI fallback must revert Kea's running config.
# From: Issue #763 | PR #1858
_ci_validate_kea_round_trip() {
    local project="$1" kip="$2" kport="$3" uname="$4" cfg token dir subnet resp sid ubase
    local jar csrf base snap snap_b n_a n_b rc=0 kbase kuser label mac_a mac_b snapdir mount snaps tries pause
    kbase="http://${kip}:${kport}"
    kuser="$(_ci_validate_kea_agent user)" || return 2
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    mac_a="$(_ci_validate_probe_mac 1)" && mac_b="$(_ci_validate_probe_mac 2)" || return 2
    cfg="$(_ci_validate_config_json)" || return 2
    token="$(_ci_capture 0 jq -r '.services.dhcp.environment.KEA_CTRL_TOKEN // empty' <<< "${cfg}")" || return 2
    snapdir="$(_ci_runtime_default KEA_CONFIG_SNAPSHOT_DIR)" || return 2
    # What: the dhcp mount holding KEA_CONFIG_SNAPSHOT_DIR
    # Why: its source is the Kea data dir on the host
    # From: Issue #763 | PR #1858
    mount="$(_ci_capture 0 jq -r --arg s "${snapdir}" "$(cat <<'PROG'
.services.dhcp.volumes[]? | .target as $t
        | select($t != "" and ($s | startswith($t + "/"))) | "\(.source)\t\($s | ltrimstr($t))"
PROG
        )" <<< "${cfg}")" || return 2
    subnet="$(_ci_capture 0 jq -r '.services.dhcp.environment.DHCP_SUBNET // empty' <<< "${cfg}")" || return 2
    if [ -z "${token}" ] || [ -z "${snapdir}" ] || [ -z "${mount}" ] || [[ "${mount}" == *$'\n'* ]] || [ -z "${subnet}" ]; then
        ci_error "[CI-ERROR-VALIDATE-0089]" "reason=\"dhcp compose config lacks KEA_CTRL_TOKEN, one mount holding KEA_CONFIG_SNAPSHOT_DIR, or DHCP_SUBNET\"" "${mount}"
        return 2
    fi
    dir="${mount%%$'\t'*}"
    snaps="${dir}${mount#*$'\t'}"
    # What: wait until the agent answers config-get.
    # Why: dhcp health checks no agent; the ui restarts it.
    # From: Issue #1683 | PR #1980
    tries="$(_ci_variable CI_VALIDATE_SNAPSHOT_POLL_ATTEMPTS)" || return 2
    pause="$(_ci_variable CI_VALIDATE_POLL_PAUSE)" || return 2
    # What: the wait shows its raw output and its rc.
    # Why: nothing is hidden; the next call decides.
    # From: Issue #1683 | PR #1984
    local prc=0
    _ci_validate_poll "${tries}" "${pause}" _ci_validate_kea_cmd "${kbase}" "${kuser}" "${token}" '{"command":"config-get","service":["dhcp4"]}' >&2 || prc=$?
    [ "${prc}" -eq 0 ] || ci_log "[CI-INFO-VALIDATE-0144]" "rc=${prc} reason=\"Kea agent wait ended without answer; the next call decides\""
    resp="$(_ci_capture 0 _ci_validate_kea_cmd "${kbase}" "${kuser}" "${token}" '{"command":"config-get","service":["dhcp4"]}')" || return 2
    _ci_kea_reply_check "[CI-ERROR-VALIDATE-0090]" "ip=\"${kip}\" reason=\"Kea control agent config-get did not return result 0\"" "${resp}" || return 1
    sid="$(_ci_capture 0 jq -r --arg s "${subnet}" ".[0].arguments.Dhcp4.subnet4[]? | select(.subnet == \$s) | .id" <<< "${resp}")" || return 2
    if [ -z "${sid}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0091]" "subnet=\"${subnet}\" reason=\"no Kea subnet4 entry for DHCP_SUBNET\""
        return 1
    fi
    ubase="$(_ci_validate_ui_base "${project}" "${uname}")" || {
        rc=$?
        ci_log "[CI-ERROR-VALIDATE-0092]" "container=\"${uname}\" reason=\"no /27 IP for the Kea ui run container\""
        return "${rc}"
    }
    _ci_validate_ui_login jar csrf "${ubase}" || return $?
    # What: reservation IPs base+2/+3 of DHCP_SUBNET.
    # Why: Kea rejects a reservation outside its subnet.
    # From: Issue #763 | PR #1858
    base="$(_ci_ipv4_to_int "${subnet%/*}")" || { rm -f "${jar}"; return 2; }
    snap="$(_ci_validate_kea_add "${ubase}" "${jar}" "${csrf}" "${sid}" "${mac_a}" \
        "$(_ci_int_to_ipv4 $(( base + 2 )))" "${label}-1" "${snaps}")" || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    snap_b="$(_ci_validate_kea_add "${ubase}" "${jar}" "${csrf}" "${sid}" "${mac_b}" \
        "$(_ci_int_to_ipv4 $(( base + 3 )))" "${label}-2" "${snaps}")" || { rc=$?; rm -f "${jar}"; return "${rc}"; }
    rm -f "${jar}"
    # What: .env.local holds this run's KEA_* values
    # Why: setup.sh reads a deploy/prod install's .env.local
    # From: Issue #763 | PR #1912
    _ci_validate_setup_rollback resp rc "$(printf 'KEA_CTRL_TOKEN=%s\nKEA_CTRL_HOST=%s\nKEA_DATA_DIR=%s\n' \
        "${token}" "${kip}" "${dir}")" kea "${snap}" || return 2
    case "${rc}:${resp}" in
        0:*"Kea rolled back to known-good snapshot ${snap} ("*) ;;
        *)
            ci_error "[CI-ERROR-VALIDATE-0094]" "snapshot=\"${snap}\" rc=\"${rc}\" reason=\"setup.sh kea rollback did not report the requested snapshot\"" "${resp}"
            return 1
            ;;
    esac
    n_a="$(_ci_validate_kea_has "${kbase}" "${kuser}" "${token}" "${mac_a}")" || return 2
    n_b="$(_ci_validate_kea_has "${kbase}" "${kuser}" "${token}" "${mac_b}")" || return 2
    if [ "${n_a}" != 1 ] || [ "${n_b}" != 0 ]; then
        ci_log "[CI-ERROR-VALIDATE-0095]" "snapshot=\"${snap}\" second=\"${snap_b}\" a=\"${n_a}\" b=\"${n_b}\" reason=\"live Kea config is not the snapshot state (want a=1 b=0)\""
        return 1
    fi
}

# What: Remove one compose run container of a probe.
# Why: frees its /27 address before the next probe runs.
# From: Issue #763 | PR #1858
_ci_validate_rm_run() {
    _ci_run "[CI-ERROR-VALIDATE-0099]" "container=\"$1\" reason=\"run container not removed\"" \
        docker rm -f "$1"
}

# What: Kea mode file and OpenRC state, for evidence.
# Why: a silent mode-off start shows no service lines.
# From: Issue #1683 | PR #1980
_ci_validate_kea_state() {
    local file
    file="$(_ci_runtime_default DHCP_MODE_FILE)" || return 2
    printf 'mode file %s:\n' "${file}"
    docker exec "$1" cat "${file}" 2>&1
    docker exec "$1" rc-status -a 2>&1
}

# What: Kea rollback leg on its own run containers.
# Why: dhcp is host-mode, so up never starts a Kea.
# From: Issue #763 | PR #1858
_ci_validate_kea_rollback() {
    local project="$1" net="$2" pin="$3" kname uname kip kport tail_lines rc=0 dsvc usvc
    dsvc="$(_ci_validation_service dhcp)" || return 2
    usvc="$(_ci_validation_service ui)" || return 2
    kname="${project}-kea"
    uname="${project}-kea-ui"
    kport="$(_ci_validate_kea_agent http-port)" || return 2
    tail_lines="$(_ci_variable CI_VALIDATE_RUN_LOG_TAIL)" || return 2
    _ci_run "[CI-ERROR-VALIDATE-0096]" "project=\"${project}\" service=\"dhcp\" reason=\"Kea run container not started\"" \
        _ci_validate_compose "${project}" "${net}" "${pin}" run -d --no-deps --name "${kname}" \
            -e DHCP_MODE=kea "${dsvc}" || return $?
    # What: both run containers must be healthy first.
    # Why: healthy means the Kea agent and ui accept.
    # From: Issue #1683 | PR #1912
    if ! _ci_validate_wait_cid "${dsvc}" "${kname}"; then
        ci_error "[CI-ERROR-VALIDATE-0129]" "service=\"dhcp\" container=\"${kname}\" reason=\"Kea run container not healthy (cause above)\"" \
            "$(docker logs --tail "${tail_lines}" "${kname}" 2>&1)"
        rc=1
    elif ! kip="$(_ci_validate_cid_ip "${project}" "${kname}")"; then
        ci_log "[CI-ERROR-VALIDATE-0097]" "container=\"${kname}\" reason=\"no /27 IP for the Kea run container\""
        rc=2
    elif _ci_run "[CI-ERROR-VALIDATE-0098]" "project=\"${project}\" service=\"ui\" reason=\"Kea ui run container not started\"" \
        _ci_validate_compose "${project}" "${net}" "${pin}" run -d --no-deps --name "${uname}" \
        -e DHCP_MODE=kea -e "DHCP_API_HOST=${kip}" "${usvc}"; then
        _ci_validate_wait_cid "${usvc}" "${uname}" || rc=$?
        [ "${rc}" -ne 0 ] || _ci_validate_kea_round_trip "${project}" "${kip}" "${kport}" "${uname}" || rc=$?
        # What: a failed round trip ships both run logs.
        # Why: the ui answer alone does not name the cause.
        # From: Issue #1683 | PR #1912
        if [ "${rc}" -ne 0 ]; then
            ci_error "[CI-ERROR-VALIDATE-0126]" "ui=\"${uname}\" kea=\"${kname}\" rc=${rc} reason=\"Kea round trip failed; run logs in raw\"" \
                "$(docker logs --tail "${tail_lines}" "${uname}" 2>&1; docker logs --tail "${tail_lines}" "${kname}" 2>&1; _ci_validate_kea_state "${kname}")"
        fi
        _ci_validate_rm_run "${uname}" || { [ "${rc}" -ne 0 ] || rc=2; }
    else
        rc=2
    fi
    _ci_validate_rm_run "${kname}" || { [ "${rc}" -ne 0 ] || rc=2; }
    return "${rc}"
}

# What: POST /api/secondary/register; print JSON on 200.
# Why: token-gated, no session/CSRF; reused per name.
# From: Issue #583
_ci_register_secondary() {
    local base="$1" token="$2" name="$3" out code url body
    # What: the register route from the SOT defaults
    # Why: the ui path has one owner, build-manifest.yml
    # From: Issue #1683 | PR #1912
    url="${base}$(_ci_runtime_default UI_ROUTE_SECONDARY_REGISTER)" || return 2
    # What: jq encodes the body; the token comes via env.
    # Why: a quote breaks pasted JSON; argv shows secrets.
    # From: Issue #1683 | PR #1858
    body="$(CI_REGISTER_TOKEN="${token}" _ci_capture 0 jq -cn --arg name "${name}" "{token: env.CI_REGISTER_TOKEN, name: \$name}")" || return 2
    out="$(_ci_run -q -s "[CI-ERROR-VALIDATE-0147]" "reason=\"secondary register call failed or wrote stderr\"" _ci_curl_secret data "${body}" \
        -sS -w '\n%{http_code}' -H 'Content-Type: application/json' \
        "${url}")" || {
        ci_log "[CI-ERROR-VALIDATE-0083]" "url=\"${url}\" name=\"${name}\" reason=\"secondary register request failed (raw above)\""
        return 2
    }
    code="${out##*$'\n'}"
    if [ "${code}" != "200" ]; then
        printf 'register %s: http %s\n%s\n' "${name}" "${code}" "${out%$'\n'*}" >&2
        return 1
    fi
    printf '%s' "${out%$'\n'*}"
}

# What: the ui's token file path, a SOT runtime default
# Why: the ui reads it from the SOT list, not a process env
# From: Issue #583 | PR #1905
_ci_validate_ui_token_file() {
    _ci_runtime_default SECONDARY_REGISTRATION_TOKEN_FILE
}

# What: each secondary gets the transfer key.
# Why: AXFR needs TSIG name, secret and primary.
# From: Issue #1683
_ci_validate_secondary_identity() {
    local project="$1" base cid token a au ap bp trc=0 tf label svc
    label="$(_ci_variable CI_VALIDATE_PROBE_LABEL)" || return 2
    svc="$(_ci_validation_service ui)" || return 2
    cid="$(_ci_validate_cid "${project}" "${svc}")" || return 2
    if [ -z "${cid}" ] || ! base="$(_ci_validate_ui_base "${project}" "${cid}")"; then
        ci_log "[CI-ERROR-VALIDATE-0045]" "reason=\"no ui container/IP for secondary-identity check\""
        return 2
    fi
    tf="$(_ci_validate_ui_token_file)" || return 2
    # What: token as the ui resolves it: its file, else env.
    # Why: no file when the ui got a real token via env.
    # From: Issue #583 | PR #1858
    _ci_bounded_exec "${cid}" test -f "${tf}" || trc=$?
    case "${trc}" in
        0) token="$(_ci_capture 0 _ci_bounded_exec "${cid}" cat "${tf}")" || {
               ci_log "[CI-ERROR-VALIDATE-0084]" "container=\"${cid}\" file=\"${tf}\" reason=\"token file unreadable (raw above)\""; return 2; } ;;
        1) token="$(_ci_capture 0 _ci_bounded_exec "${cid}" printenv SECONDARY_REGISTRATION_TOKEN)" || {
               ci_log "[CI-ERROR-VALIDATE-0085]" "container=\"${cid}\" reason=\"no token file and no SECONDARY_REGISTRATION_TOKEN env (raw above)\""; return 2; } ;;
        *)
            ci_log "[CI-ERROR-VALIDATE-0066]" "container=\"${cid}\" file=\"${tf}\" rc=${trc} reason=\"token file check in the ui container failed (docker error above)\""
            return 2
            ;;
    esac
    token="${token//$'\n'/}"
    if [ -z "${token}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0046]" "reason=\"could not read SECONDARY_REGISTRATION_TOKEN from ui\""
        return 2
    fi
    # What: one register; its reply carries all three keys.
    # Why: a 2nd register checked nothing new; 16.6 s each.
    # From: Issue #1683 | PR #1858
    if ! a="$(_ci_register_secondary "${base}" "${token}" "${label}-1")"; then
        ci_log "[CI-ERROR-VALIDATE-0047]" "reason=\"a secondary register did not return 200\""
        return 1
    fi
    au="$(_ci_capture 0 jq -r '.tsig_name // empty' <<< "${a}")" || return 1
    ap="$(_ci_run -q -s "[CI-ERROR-VALIDATE-0148]" "reason=\"tsig_secret read failed or wrote stderr\"" jq -r '.tsig_secret // empty' <<< "${a}")" || return 1
    bp="$(_ci_capture 0 jq -r '.primary // empty' <<< "${a}")" || return 1
    if [ -z "${au}" ] || [ -z "${ap}" ] || [ -z "${bp}" ]; then
        ci_log "[CI-ERROR-VALIDATE-0048]" "reason=\"register response missing tsig_name/tsig_secret/primary\""
        return 1
    fi
}

# What: nginx /healthz ACL order and hidden headers.
# Why: a skipped ACL or a leaked header breaks proxy policy.
# From: Issue #1683
@test "proxy_nginx_policy" {
    if [ "${proxy_nginx_policy_is_enabled:-false}" != "true" ]; then
        skip "proxy_nginx_policy_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_proxy_nginx_policy
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: proxy cert, CA and cache dirs sit on the SOT mounts.
# Why: Compose and nginx.conf must use the SOT paths.
# From: Issue #1683
@test "proxy_cert_volume" {
    if [ "${proxy_cert_volume_is_enabled:-false}" != "true" ]; then
        skip "proxy_cert_volume_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_proxy_cert_volume
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: live proxy forwards a wildcard SNI to its own name.
# Why: a fixed root target misroutes subdomains.
# From: Issue #1683
@test "proxy_stream_map" {
    if [ "${proxy_stream_map_is_enabled:-false}" != "true" ]; then
        skip "proxy_stream_map_is_enabled=false"
    fi
    ci_sh_load
    run _ci_validate_proxy_stream_map "${CI_VALIDATE_PROJECT:-}"
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: live https mode shows a cert signed by the LAN CA.
# Why: https mode must intercept with the project CA.
# From: Issue #1683
@test "https_mitm" {
    if [ "${https_mitm_is_enabled:-false}" != "true" ]; then
        skip "https_mitm_is_enabled=false"
    fi
    ci_sh_load
    run _ci_validate_https_mitm "${CI_VALIDATE_PROJECT:-}"
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: live depth>=2 SNI takes the passthrough relay.
# Why: deeper names must not be intercepted.
# From: Issue #1683
@test "https_dispatch_map" {
    if [ "${https_dispatch_map_is_enabled:-false}" != "true" ]; then
        skip "https_dispatch_map_is_enabled=false"
    fi
    ci_sh_load
    run _ci_validate_https_dispatch_map "${CI_VALIDATE_PROJECT:-}"
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: a live Admin UI record resolves on both dns sides.
# Why: UI writes must reach PowerDNS end to end.
# From: Issue #1683
@test "ui_dns" {
    if [ "${ui_dns_is_enabled:-false}" != "true" ]; then
        skip "ui_dns_is_enabled=false"
    fi
    ci_sh_load
    run _ci_validate_ui_dns "${CI_VALIDATE_PROJECT:-}"
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: live DNS snapshot and rollback round trip.
# Why: a rollback must restore and snapshot the zone.
# From: Issue #1683
@test "dns_rollback" {
    if [ "${dns_rollback_is_enabled:-false}" != "true" ]; then
        skip "dns_rollback_is_enabled=false"
    fi
    ci_sh_load
    run _ci_validate_dns_rollback "${CI_VALIDATE_PROJECT:-}"
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: live Kea rollback drops a later reservation.
# Why: a rollback must leave the first config running.
# From: Issue #1683
@test "kea_rollback" {
    if [ "${kea_rollback_is_enabled:-false}" != "true" ]; then
        skip "kea_rollback_is_enabled=false"
    fi
    ci_sh_load
    run _ci_validate_kea_rollback "${CI_VALIDATE_PROJECT:-}" "${CI_VALIDATE_NET_OVERRIDE:-}" "${CI_VALIDATE_PIN_OVERRIDE:-}"
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: a live secondary register answer has the TSIG key.
# Why: AXFR needs the TSIG name, secret and primary.
# From: Issue #1683
@test "secondary_identity" {
    if [ "${secondary_identity_is_enabled:-false}" != "true" ]; then
        skip "secondary_identity_is_enabled=false"
    fi
    ci_sh_load
    run _ci_validate_secondary_identity "${CI_VALIDATE_PROJECT:-}"
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}
