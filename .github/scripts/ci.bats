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

# What: one string key of a [workspace.package] table.
# Why: verify reads version and license the same way.
# From: Issue #1683 | PR #1858
_ci_cargo_ws_value() {
    _ci_capture 0 env K="$2" yq -p toml -oy '.workspace.package[strenv(K)]' "$1"
}

# What: Cargo has no version; license, edition from SOT.
# Why: AG-SEC-004: PROJECT_RELEASE_VERSION owns it.
# From: Issue #1683 | PR #1858
_ci_version_release() {
    local lic ed got cargo members m mf k rc=0
    _ci_version_inputs lic ed cargo || return 2
    got="$(_ci_cargo_ws_value "${cargo}" version)" || return 2
    if [ "${got}" != null ]; then
        ci_log "[CI-ERROR-VERSION-0021]" "path=\"${cargo}\" got=\"${got}\" reason=\"workspace.package.version must be absent; the repo variable PROJECT_RELEASE_VERSION owns it\""
        rc=1
    fi
    got="$(_ci_cargo_ws_value "${cargo}" license)" || return 2
    if [ "${got}" != "${lic}" ]; then
        ci_log "[CI-ERROR-VERSION-0028]" "path=\"${cargo}\" got=\"${got}\" want=\"${lic}\" reason=\"workspace.package.license is not SOT release.license\""
        rc=1
    fi
    got="$(_ci_cargo_ws_value "${cargo}" edition)" || return 2
    if [ "${got}" != "${ed}" ]; then
        ci_log "[CI-ERROR-VERSION-0031]" "path=\"${cargo}\" got=\"${got}\" want=\"${ed}\" reason=\"workspace.package.edition is not SOT release.rust_edition\""
        rc=1
    fi
    members="$(_ci_cargo_members "${cargo}")" || return 2
    while IFS= read -r m; do
        [ -n "${m}" ] || continue
        mf="$(_ci_repo_path CI_CARGO_MANIFEST "${CI_REPO_ROOT:-.}/${m}")" || return 2
        local vrc=0
        _ci_file_match "[CI-ERROR-VERSION-0033]" "member=\"${m}\" key=\"version\"" "${mf}" "^version([.]workspace)? *=" || vrc=$?
        case "${vrc}" in
            0)
                ci_log "[CI-ERROR-VERSION-0032]" "member=\"${m}\" key=\"version\" reason=\"member sets a version; PROJECT_RELEASE_VERSION owns it\""
                rc=1
                ;;
            1) ;;
            *) return 2 ;;
        esac
        for k in edition license; do
            local mrc=0
            _ci_file_match "[CI-ERROR-VERSION-0029]" "member=\"${m}\" key=\"${k}\"" "${mf}" "^${k}\.workspace *= *true$" || mrc=$?
            case "${mrc}" in
                0) ;;
                1)
                    ci_log "[CI-ERROR-VERSION-0022]" "member=\"${m}\" key=\"${k}\" reason=\"member owns its ${k}; use ${k}.workspace = true\""
                    rc=1
                    ;;
                *) return 2 ;;
            esac
        done
    done <<< "${members}"
    [ "${rc}" -eq 0 ] && printf 'cargo-workspace=clean version=absent\n'
    return "${rc}"
}

# What: the compose files of a dir, one per line, sorted.
# Why: one finder for the checks that read compose with yq.
# From: Issue #1683 | PR #1858
_ci_compose_dir_files() {
    local out
    out="$(_ci_capture 0 find "$1" -type f \( -name '*.yml' -o -name '*.yaml' \))" || return 2
    [ -z "${out}" ] || _ci_capture 0 sort <<< "${out}"
}

# What: an external deploy image must be a SOT base image.
# Why: one owner per external image; no copy elsewhere.
# From: Issue #1683
_ci_check_sot_external_images() {
    local -a dirs=("$@")
    local d img k allowed=" " dep
    if [ "${#dirs[@]}" -eq 0 ]; then
        dep="$(_ci_compose_path)" || return 2
        dirs=("${dep%/*}")
    fi
    local -a viol=()
    # What: the exact SOT base image values.
    # Why: compose must match them; other values are drift.
    # From: Issue #1683 | PR #1858
    local keys val
    keys="$(_ci_block_keys base_images all)" || return 2
    for k in ${keys}; do
        val="$(_ci_block_entry_field base_images "" "${k}")" || return 2
        allowed+="${val} "
    done
    for d in "${dirs[@]}"; do
        if [ ! -d "${d}" ]; then
            viol+=("${d}: compose dir missing")
            continue
        fi
        local files f produced
        files="$(_ci_compose_dir_files "${d}")" || return 2
        if [ -z "${files}" ]; then
            viol+=("${d}: compose dir holds no compose file")
            continue
        fi
        while IFS= read -r f; do
            # What: the image: of every service, read by yq.
            # Why: yq owns YAML quoting and comments.
            # From: Issue #1683 | PR #1858
            produced="$(_ci_run "[CI-ERROR-CHECK-0200]" "file=\"${f}\" reason=\"compose images not read\"" \
                yq --yaml-fix-merge-anchor-to-spec=true -r '.services[]?.image | select(tag == "!!str")' "${f}")" || return 2
            while IFS= read -r img; do
                # What: only ${LANCACHE_*} own images skip.
                # Why: any literal host (ghcr too) is SOT.
                # From: Issue #1683 | PR #1858
                case "${img}" in
                    *"\${LANCACHE"*|'') continue ;;
                esac
                case "${allowed}" in
                    *" ${img} "*) ;;
                    *) viol+=("${f}: external image is not a SOT base image: ${img}") ;;
                esac
            done <<<"${produced}"
        done <<<"${files}"
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0014]" "reason=\"external image not in SOT\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'sot-external-images=clean\n'
}

# What: add each text line to array $1 as "<$2>: <line>".
# Why: checks list findings per file the same way.
# From: Issue #1683 | PR #1912
_ci_viol_lines() {
    local -n _vl_viol="$1"
    local _vl_line
    while IFS= read -r _vl_line; do
        [ -z "${_vl_line}" ] || _vl_viol+=("$2: ${_vl_line}")
    done <<< "$3"
}

# What: container names share one prefix + service name.
# Why: operators find a container by its service name.
# From: Issue #1683 | PR #1858
_ci_check_naming_consistency() {
    local root="${1:-${CI_REPO_ROOT}}" dep
    dep="$(_ci_compose_path "${root}")" || return 2
    local -a compose_files=("${dep}")
    local -a viol=()
    local cf cfg line

    for cf in "${compose_files[@]}"; do
        if [ ! -f "${cf}" ]; then
            viol+=("${cf}: compose file missing")
            continue
        fi
        cfg="$(_ci_compose_json "${cf}")" || return 2
        # What: prefix is the project name in any case.
        # Why: compose name: owns the name; one spelling.
        # From: Issue #1683 | PR #1912
        line="$(_ci_capture 0 jq -r "$(cat <<'PROG'
.name as $p
            | [.services | to_entries[] | {s: .key, c: (.value.container_name // "")}] as $all
            | ($all | map(select(.c == "")) | map("service \(.s) has no container_name")[]),
              ($all | map(select(.c != "" and (.s as $s | .c | endswith("-" + $s) | not)))
                | map("container_name \(.c) does not end in -\(.s)")[]),
              ($all | map(select(.c != "") | .c[0:(.c | length) - (.s | length) - 1]) | unique
                | (select(length > 1) | "container prefixes differ: \(join(", "))"),
                  (.[] | select(ascii_downcase != ($p | ascii_downcase))
                    | "container prefix \(.) is not the project name \($p)"))
PROG
                    )" <<<"${cfg}")" || return 2
        _ci_viol_lines viol "${cf}" "${line}"
    done

    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0096]" "reason=\"naming-consistency drift (docs/policy/naming-conventions-policy.md)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'naming-consistency=clean\n'
}

# What: fail on compose service with no healthcheck.
# Why: every service needs a real healthcheck.
# From: Issue #1683 | PR #1858
_ci_check_compose_healthchecks() {
    local -a files=("$@")
    if [ "${#files[@]}" -eq 0 ]; then
        local f dep top
        dep="$(_ci_compose_path)" || return 2
        top="${dep%/*}"; top="${top%/*}"
        for f in "${top}"/*/"${dep##*/}"; do
            [ -f "${f}" ] && files+=("${f}")
        done
    fi
    if [ "${#files[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0020]" "reason=\"no stack compose files found\""
        return 2
    fi
    # What: exemptions are per service, never per file path.
    # Why: the SOT owns the list; a path key duplicated it.
    # From: Issue #1683 | PR #1858
    local -A excluded=()
    local file svc hc checked=0 ex raw
    raw="$(_ci_block_entry_list validation "" healthcheck_exempt)" || return 2
    while IFS= read -r ex; do
        [ -n "${ex}" ] && excluded["${ex}"]=1
    done <<< "${raw}"
    local -a viol=()
    for file in "${files[@]}"; do
        if [ ! -f "${file}" ]; then
            viol+=("${file}: compose file missing")
            continue
        fi
        # What: judge the rendered compose, not its text.
        # Why: anchors and merge keys give healthchecks too.
        # From: Issue #1683 | PR #1912
        local cfg produced
        cfg="$(_ci_compose_json "${file}")" || return 2
        produced="$(_ci_capture 0 jq -r '.services | to_entries[]
            | "\(.key)\t\(if .value.healthcheck then 1 else 0 end)"' <<<"${cfg}")" || return 2
        while IFS=$'\t' read -r svc hc; do
            [ -n "${svc}" ] || continue
            checked=$((checked + 1))
            [ "${hc}" = "1" ] && continue
            [ -n "${excluded[${svc}]:-}" ] && continue
            viol+=("${file}: service '${svc}' has no healthcheck:")
        done <<<"${produced}"
    done
    if [ "${checked}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0097]" "reason=\"no services found across deploy compose files\""
        return 2
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0021]" "reason=\"service missing a healthcheck\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'compose-healthchecks=clean checked=%s\n' "${checked}"
}

# What: Fail if a proxy CACHE_* default drifts from its doc.
# Why: a hand-copied doc default silently goes stale.
# From: Issue #1683 | PR #1858
_ci_check_proxy_cache_env_doc_drift() {
    local defaults="${1:-}"
    local arch_doc="${2:-}"
    if [ -z "${arch_doc}" ]; then arch_doc="$(_ci_repo_path CI_ARCH_DOC)" || return 2; fi
    if [ ! -f "${arch_doc}" ]; then
        ci_log "[CI-ERROR-CHECK-0098]" "path=\"${arch_doc}\" reason=\"architecture doc not found\""
        return 2
    fi
    local key value doc_row documented scanned=0 checked=0 rc
    local -a viol=()
    local produced produced_rc=0
    if [ -n "${defaults}" ]; then
        if [ ! -f "${defaults}" ]; then
            ci_log "[CI-ERROR-CHECK-0022]" "path=\"${defaults}\" reason=\"defaults file not found\""
            return 2
        fi
        produced="$(grep -E '^CACHE_[A-Z_]+=' "${defaults}")" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 1 || return 2
    else
        # What: values compose gives proxy, SOT fixture env
        # Why: an empty one falls back to runtime.defaults
        # From: Issue #1683 | PR #1912
        produced="$(_ci_service_compose_env proxy)" || return 2
    fi
    while IFS='=' read -r key value; do
        [[ "${key}" =~ ^CACHE_[A-Z_]+$ ]] || continue
        scanned=$((scanned + 1))
        doc_row="$(_ci_capture 1 grep -E "^\| \`${key}\` \|" "${arch_doc}")" || return 2
        [ -n "${doc_row}" ] || continue
        checked=$((checked + 1))
        if [ -z "${value}" ] && [ -z "${defaults}" ]; then value="$(_ci_runtime_default "${key}")" || return 2; fi
        documented="$(_ci_capture 0 sed -E "s/^\| \`[A-Z_]+\` \| \`([^\`]*)\` \|.*/\1/" <<<"${doc_row}")" || return 2
        if [ "${documented}" != "${value}" ]; then
            viol+=("${key}: default=${value} vs doc=${documented}")
        fi
    done <<<"${produced}"
    if [ "${scanned}" -eq 0 ]; then
        ci_log "[CI-ERROR-CHECK-0152]" "defaults=\"${defaults:-deploy compose}\" reason=\"no CACHE_* default found for proxy; vacuous scan\""
        return 2
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0023]" "reason=\"proxy CACHE_* default/doc drift\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'proxy-cache-env-doc-drift=clean scanned=%s checked=%s\n' "${scanned}" "${checked}"
}

# What: Fail unless prod install paths stay prebuilt-only.
# Why: release doc: prod runs prebuilt images.
# From: Issue #1683 | PR #1858
_ci_check_prebuilt_prod() {
    local repo_root="${1:-${CI_REPO_ROOT}}" dep
    local -a viol=()
    dep="$(_ci_compose_path "${repo_root}")" || return 2
    dep="${dep%/*}"
    local hit="" files f one
    files="$(_ci_compose_dir_files "${dep}")" || return 2
    if [ -z "${files}" ]; then
        viol+=("${dep}: compose dir holds no compose file")
    fi
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        # What: services with a build: key, read by yq.
        # Why: yq owns YAML; grep read text inside strings.
        # From: Issue #1683 | PR #1858
        one="$(_ci_run "[CI-ERROR-CHECK-0202]" "file=\"${f}\" reason=\"compose build: not read\"" \
            yq --yaml-fix-merge-anchor-to-spec=true -r '(.services // {}) | to_entries[] | select((.value | tag) == "!!map" and (.value | has("build"))) | .key + " (build: at line " + (.value.build | line | tostring) + ")"' "${f}")" || return 2
        if [ -n "${one}" ]; then hit+="${f}: ${one}"$'\n'; fi
    done <<<"${files}"
    hit="${hit%$'\n'}"
    if [ -n "${hit}" ]; then
        viol+=("a stack compose declares build:; prod must run prebuilt images only" "${hit}")
    fi
    local hit su readme
    su="$(_ci_installer "${repo_root}")" || return 2
    readme="$(_ci_repo_path CI_README "${repo_root}")" || return 2
    hit="$(_ci_capture 1 grep -RIn -- '--build' "${readme}" "${dep}" "${su}")" || return 2
    if [ -n "${hit}" ]; then
        viol+=("a user-facing install path instructs --build; prod must run from prebuilt images, not a local build" "${hit}")
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0042]" "reason=\"production install path is not prebuilt-only\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'prebuilt-prod=clean\n'
}

# What: Check prod state derives from LANCACHE_STATE_DIR.
# Why: AG-SETUP-001: LANCACHE_STATE_DIR is state root.
# From: Issue #1683 | PR #1858
_ci_check_prod_state_wiring() {
    local repo_root="${1:-${CI_REPO_ROOT}}" dep compose
    compose="$(_ci_compose_path "${repo_root}")" || return 2
    dep="${compose#"${repo_root}/"}"
    local doc doc_rel
    doc_rel="$(_ci_variable CI_BACKUP_RESTORE_DOC)" || return 2
    doc="${repo_root}/${doc_rel}"
    local -a viol=()
    local key f keys
    for f in "${compose}" "${doc}"; do
        [ -f "${f}" ] || { ci_log "[CI-ERROR-CHECK-0043]" "path=\"${f}\" reason=\"required prod-state-wiring input missing\""; return 2; }
    done
    keys="$(_ci_state_keys)" || return 2
    if [ -z "${keys}" ]; then
        ci_log "[CI-ERROR-CHECK-0174]" "reason=\"SOT runtime.state_dir_keys names no state key\""
        return 2
    fi
    # What: a key counts only as a whole word, not a prefix.
    # Why: PDNS_DIR_OLD must not satisfy PDNS_DIR.
    # From: Issue #1683 | PR #1912
    while IFS= read -r key; do
        _ci_file_match "[CI-ERROR-CHECK-0181]" "key=\"${key}\" reason=\"doc not searched\"" "${doc}" "${key}" -Fw \
            || { [ "$?" -eq 1 ] || return 2; viol+=("${doc_rel} does not mention ${key}"); }
    done <<<"${keys}"
    # What: compose mounts exactly the SOT state_dir_keys.
    # Why: the SOT list owns the keys; compose only mounts.
    # From: Issue #1683 | PR #1912
    local mounted="" want row key off=""
    row="$(_ci_run "[CI-ERROR-CHECK-0192]" "file=\"${compose}\" reason=\"state mounts not read\"" \
        yq --yaml-fix-merge-anchor-to-spec=true -r '(.services[].volumes[]?, .volumes[]?.driver_opts.device?) | select(tag == "!!str") | select(test("^\$\{[A-Z0-9_]+:[?-]"))' "${compose}")" || return 2
    # What: ":?" after the key is a mount, ":-" a default.
    # Why: a mount default in compose is a second owner.
    # From: Issue #1683 | PR #1912
    while IFS= read -r want; do
        [ -n "${want}" ] || continue
        key="${want#\$\{}"
        key="${key%%:*}"
        case "${want:$(( ${#key} + 2 )):2}" in
            ':?') mounted+="${key}"$'\n' ;;
            *) off+=$'\n'"${want}" ;;
        esac
    done <<< "${row}"
    mounted="$(_ci_capture 0 sort -u <<< "${mounted%$'\n'}")" || return 2
    want="$(_ci_capture 0 sort -u <<< "${keys}")" || return 2
    [ "${mounted}" = "${want}" ] \
        || viol+=("${dep} state mounts differ from SOT runtime.state_dir_keys: compose=[${mounted//$'\n'/ }] sot=[${want//$'\n'/ }]")
    [ -z "${off}" ] || viol+=("${dep} has a mount default in compose:${off}")
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0100]" "reason=\"prod state wiring differs from the SOT or undocumented\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'prod-state-wiring=clean\n'
}

# What: True if compose file/profile warning-free.
# Why: docker compose warnings hide real drift; fail closed.
# From: Issue #1683 | PR #1858
_ci_compose_config_ok() {
    local file="$1" profile="${2:-}" env_file="${3:-}" out
    local -a args=(-f "${file}")
    if [ -n "${profile}" ]; then
        args+=(--profile "${profile}")
    fi
    if ! out="$(_ci_compose_run "${env_file}" "${args[@]}" config --quiet 2>&1)"; then
        printf '%s\n' "${out}"
        return 1
    fi
    if _ci_text_has -i '(^|[[:space:]])(warn|warning|level=warning)' "${out}"; then
        printf 'warnings treated as errors:\n%s\n' "${out}"
        return 1
    fi
    return 0
}

# What: a compose file as JSON, all profiles, opt env file
# Why: a profiled service is checked like any other.
# From: Issue #1683 | PR #1858
_ci_compose_json() {
    local -a pf=()
    _ci_compose_profile_flags "$1" pf || return 2
    _ci_compose_query "$1" "${2:-}" "${pf[@]}" config --no-env-resolution --format json
}

# What: every stack compose renders clean in every profile.
# Why: profiles come from the file; none is skipped.
# From: Issue #1683 | PR #1858
_ci_check_compose_config() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local -a viol=() profiles=() files=()
    local rel cf raw p label render msg count=0
    _ci_stack_compose_files files || return $?
    for rel in "${files[@]}"; do
        cf="${repo_root}/${rel}"
        label="${rel}"
        if [ ! -f "${cf}" ]; then
            viol+=("${label}: compose target missing")
            continue
        fi
        if ! raw="$(_ci_compose_profiles "${cf}" "" 2>&1)"; then
            viol+=("${label}: profiles unreadable"$'\n'"${raw}")
            continue
        fi
        profiles=("")
        [ -z "${raw}" ] || mapfile -t -O 1 profiles <<< "${raw}"
        for p in "${profiles[@]}"; do
            count=$((count + 1))
            render="${label}"
            if [ -n "${p}" ]; then
                render="${label}:${p}"
            fi
            if ! msg="$(_ci_compose_config_ok "${cf}" "${p}" "")"; then
                viol+=("${render}: config invalid" "${msg}")
            fi
        done
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0101]" "reason=\"compose config invalid\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'compose-config=clean checks=%s\n' "${count}"
}

# What: the bootstrap repo address equals the SOT value.
# Why: setup.sh runs before the clone; the one text check.
# From: Issue #1683 | PR #1858
_ci_check_setup_update_safety() {
    local repo_root="${1:-${CI_REPO_ROOT}}" su
    local -a viol=()
    su="$(_ci_installer "${repo_root}")" || return 2
    local repo_url
    repo_url="$(_ci_runtime_default LANCACHE_REPO_URL)" || return 2
    _ci_file_match "[CI-ERROR-CHECK-0193]" "reason=\"repo address not searched\"" "${su}" "LANCACHE_REPO_URL=\"${repo_url}\"" -Fx \
        || { [ "$?" -eq 1 ] || return 2; viol+=("setup.sh LANCACHE_REPO_URL differs from SOT runtime.defaults LANCACHE_REPO_URL (${repo_url})"); }
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0103]" "reason=\"setup.sh update safety or bootstrap contract violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'setup-update-safety=clean\n'
}

# What: compose JSON on the fixture env, own IMAGE vars
# Why: only then do the images show which var they take
# From: Issue #1683 | PR #1912
_ci_compose_image_render() {
    local file="$1" out="$2" env body line kept=""
    shift 2
    env="$(_ci_mktemp "${CI_TMPDIR}/ci-image-env.XXXXXX")" || return 2
    body="$(_ci_validation_env)" || { rm -f "${env}"; return 2; }
    while IFS= read -r line; do
        case "${line}" in LANCACHE_IMAGE_*) ;; *) kept+="${line}"$'\n' ;; esac
    done <<< "${body}"
    body="${kept%$'\n'}"
    if ! printf '%s\n' "${body}" "$@" > "${env}"; then
        ci_log "[CI-ERROR-CHECK-0172]" "file=\"${env}\" reason=\"render env file not writable\""
        rm -f "${env}"
        return 2
    fi
    if ! _ci_compose_json "${file}" "${env}" > "${out}"; then
        rm -f "${env}"
        return 2
    fi
    rm -f "${env}"
}

# What: Fail unless channel/tag resolves from config.
# Why: one resolution across setup.sh/UI/compose.
# From: Issue #1683
_ci_check_image_channel_resolution() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local sec prod dep
    sec="$(_ci_service_path ui src/main.rs "${repo_root}")" || return 2
    prod="$(_ci_compose_path "${repo_root}")" || return 2
    dep="${prod#"${repo_root}/"}"
    local -a viol=()
    local f
    if [ ! -f "${sec}" ]; then
        viol+=("ui source missing: ${sec}")
    else
        for f in \
            '"image_registry": process_env("LANCACHE_IMAGE_REGISTRY")' \
            '"image_prefix": process_env("LANCACHE_IMAGE_PREFIX")' \
            '"image_channel": process_env("LANCACHE_IMAGE_CHANNEL")' \
            '"image_tag": process_env("LANCACHE_IMAGE_TAG")'; do
            _ci_file_match "[CI-ERROR-CHECK-0187]" "line=\"${f}\" reason=\"ui source not searched\"" "${sec}" "${f}" -F \
                || { [ "$?" -eq 1 ] || return 2; viol+=("ui main.rs must expose/use ${f}"); }
        done
    fi
    if [ ! -f "${prod}" ]; then
        viol+=("prod compose missing: ${prod}")
    else
        # What: each compose image has one ref var
        # Why: AG-CI-006: the SOT owns the image coordinates
        # From: Issue #1683 | PR #1912
        local tdir rep line sreg spre stag schan prog svc names refs hits
        hits="$(_ci_run -m 1 "[CI-ERROR-CHECK-0178]" "file=\"${prod}\" reason=\"image defaults not scanned\"" grep -nE 'LANCACHE_IMAGE_(REF_[A-Z_]+|REGISTRY|PREFIX|TAG):-[^}]' "${prod}")" || return 2
        while IFS= read -r line; do
            [ -z "${line}" ] || viol+=("compose gives an image coordinate a default: ${line}")
        done <<< "${hits}"
        names="$(ci_services)" || return 2
        sreg="r${SRANDOM}.test" spre="p${SRANDOM}/q${SRANDOM}" stag="t${SRANDOM}" schan="c${SRANDOM}"
        refs=()
        while IFS= read -r svc; do
            [ -z "${svc}" ] || refs+=("LANCACHE_IMAGE_REF_${svc^^}=${sreg}/${spre}/${svc}:${stag}")
        done <<< "${names}"
        prog="$(cat <<'PROG'
($s[0].services) as $S | ($sreg + "/" + $spre + "/") as $sp
            | [$names | split("\n")[] | select(. != "")] as $N
            | [$S | to_entries[] | select((.value.environment // {}) | type == "object" and has("LANCACHE_IMAGE_REGISTRY"))] as $ev
            | (if ($ev | length) == 0 then "no compose service receives LANCACHE_IMAGE_REGISTRY" else empty end),
              ($N[] | . as $k | ($S[$k].image // "") as $im
                | if $im == ($sp + $k + ":" + $stag) then empty
                  else "service \($k): image \($im) does not take LANCACHE_IMAGE_REF_\($k | ascii_upcase)" end),
              ($ev[] | .key as $k | $S[$k].environment as $se
                | (["LANCACHE_IMAGE_REGISTRY", $sreg], ["LANCACHE_IMAGE_PREFIX", $spre],
                   ["LANCACHE_IMAGE_CHANNEL", $schan], ["LANCACHE_IMAGE_TAG", $stag]) as [$n, $sv]
                | if ($se[$n] // null) == $sv then empty else "service \($k): \($n) is \($se[$n] // "unset") for env file value \($sv)" end)
PROG
                )"
        tdir="$(_ci_mktemp -d "${CI_TMPDIR}/ci-chanres.XXXXXX")" || return 2
        if ! _ci_compose_image_render "${prod}" "${tdir}/s.json" "LANCACHE_IMAGE_REGISTRY=${sreg}" \
                "LANCACHE_IMAGE_PREFIX=${spre}" "LANCACHE_IMAGE_TAG=${stag}" "LANCACHE_IMAGE_CHANNEL=${schan}" "${refs[@]}"; then
            rm -rf "${tdir}"
            return 2
        fi
        rep="$(_ci_run "[CI-ERROR-CHECK-0171]" "file=\"${dep}\" reason=\"image coordinate comparison failed\"" \
            jq -rn --slurpfile s "${tdir}/s.json" --arg names "${names}" \
            --arg sreg "${sreg}" --arg spre "${spre}" --arg stag "${stag}" --arg schan "${schan}" \
            "${prog}")" || { rm -rf "${tdir}"; return 2; }
        rm -rf "${tdir}"
        while IFS= read -r line; do
            [ -z "${line}" ] || viol+=("${line}")
        done <<< "${rep}"
    fi
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0105]" "reason=\"image channel/tag resolution contract violated\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'image-channel-resolution=clean\n'
}

# What: Fail unless the trivyignore yields full OpenVEX.
# Why: a broken entry must fail here, not at release time.
# From: Issue #1683 | PR #1858
_ci_check_vex_drift() {
    local repo_root="${1:-${CI_REPO_ROOT}}"
    local trivyignore
    trivyignore="$(_ci_repo_path CI_TRIVY_IGNORE "${repo_root}")" || return 2
    local out ids entry_count statement_count
    [ -f "${trivyignore}" ] || { ci_error "[CI-ERROR-CHECK-0050]" "path=\"${trivyignore}\" reason=\".trivyignore.yaml not found\"" "${trivyignore}"; return 2; }
    if ! out="$(_ci_generate_vex "${trivyignore}")"; then
        ci_log "[CI-ERROR-CHECK-0107]" "path=\"${trivyignore}\" reason=\"OpenVEX generation failed (raw above)\""
        return 1
    fi
    ids="$(_ci_trivyignore_ids "${trivyignore}")" || return 2
    entry_count="$(_ci_count_lines "${ids}")"
    statement_count="$(_ci_capture 0 jq '.statements | length' <<< "${out}")" || return 2
    if [ "${statement_count}" != "${entry_count}" ]; then
        ci_log "[CI-ERROR-CHECK-0109]" "entries=${entry_count} statements=${statement_count} reason=\"trivyignore entries and VEX statements differ\""
        return 1
    fi
    printf 'vex-drift=clean statements=%s\n' "${statement_count}"
}

# What: print each logging-matrix row's service, dupes kept.
# Why: the check finds missing, extra and double rows.
# From: Issue #1683 | PR #1912
_ci_logging_matrix_canonical() {
    local doc="$1" line name marked=0 in_table=0
    local head_re='^\|[[:space:]]*Service[[:space:]]*\|'
    local sep_re='^\|[[:space:]]*-+[[:space:]]*\|'
    local lead_re='^\|[[:space:]]*' tick_re=$'`[a-z0-9-]+`'
    # What: rows of the first table after the marker line.
    # Why: the first non-table line after a row ends it.
    while IFS= read -r line || [ -n "${line}" ]; do
        if [[ "${line}" == *'**Logging matrix**'* ]]; then
            marked=1
            continue
        fi
        [ "${marked}" -eq 1 ] || continue
        if [[ "${line}" != '|'* ]]; then
            [ "${in_table}" -eq 0 ] || break
            continue
        fi
        in_table=1
        if [[ "${line}" =~ ${head_re} || "${line}" =~ ${sep_re} ]]; then
            continue
        fi
        [[ "${line}" =~ ${lead_re} ]]
        name="${line:${#BASH_REMATCH[0]}}"
        name="${name%%|*}"
        name="${name%"${name##*[![:space:]]}"}"
        if [[ "${name}" =~ ${tick_re} ]]; then
            name="${BASH_REMATCH[0]:1:${#BASH_REMATCH[0]}-2}"
        fi
        printf 'row=%s\n' "${name}"
    done < "${doc}"
}

# What: Print one real Compose service name per line.
# Why: a profiled service needs `config --profiles` first.
# From: Issue #1683 | PR #1858
_ci_compose_service_names() {
    local file="$1"
    local -a profile_flags=()
    _ci_compose_profile_flags "${file}" profile_flags || return 2
    _ci_compose_query "${file}" "" "${profile_flags[@]}" config --services
}

# What: each Compose service has exactly one matrix row.
# Why: a new, renamed or doubled service must not hide.
# From: Issue #1683 | PR #1912
_ci_check_logging_matrix() {
    local repo_root="${1:-${CI_REPO_ROOT}}" doc rows cf raw_services n
    local -a canonical=() services=() viol=()
    local -A in_doc=() in_compose=()
    doc="$(_ci_repo_path CI_ARCH_DOC "${repo_root}")" || return 2
    if [ ! -f "${doc}" ]; then
        ci_log "[CI-ERROR-CHECK-0035]" "path=\"${doc}\" reason=\"architecture doc not found\""
        return 2
    fi
    rows="$(_ci_logging_matrix_canonical "${doc}")" || {
        ci_log "[CI-ERROR-CHECK-0120]" "path=\"${doc}\" reason=\"logging matrix not readable (raw above)\""; return 2; }
    if [ -z "${rows}" ]; then
        ci_log "[CI-ERROR-CHECK-0036]" "path=\"${doc}\" reason=\"no logging-matrix rows parsed\""
        return 2
    fi
    mapfile -t canonical <<< "${rows}"
    # What: drops the row= prefix of each parsed name.
    # Why: $(...) would eat a last row with an empty name.
    # From: Issue #1683 | PR #1912
    canonical=("${canonical[@]#row=}")
    # What: only the primary stack compose is matched.
    # Why: the secondary dns logs locally (driver: local).
    # From: Issue #1683 | PR #1912
    cf="$(_ci_compose_path "${repo_root}")" || return 2
    raw_services="$(_ci_compose_service_names "${cf}")" || {
        ci_log "[CI-ERROR-CHECK-0034]" "path=\"${cf}\" reason=\"compose service lookup failed (raw above)\""; return 2; }
    mapfile -t services <<< "${raw_services}"
    for n in "${canonical[@]}"; do
        [ -n "${n}" ] || { viol+=("${doc}: a row has no service name"); continue; }
        [ -z "${in_doc[${n}]:-}" ] || viol+=("${doc}: row '${n}' appears more than once")
        in_doc[${n}]=1
    done
    for n in "${services[@]}"; do
        [ -n "${n}" ] || continue
        in_compose[${n}]=1
        [ -n "${in_doc[${n}]:-}" ] || viol+=("${cf}: service '${n}' has no logging-matrix row")
    done
    for n in "${canonical[@]}"; do
        [ -z "${n}" ] || [ -n "${in_compose[${n}]:-}" ] || viol+=("${doc}: row '${n}' is not a real Compose service")
    done
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0038]" "reason=\"logging-matrix drift\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'logging-matrix=clean rows=%s services=%s\n' "${#canonical[@]}" "${#in_compose[@]}"
}

# What: every build target's Dockerfile, one pass each.
# Why: one owner for the rules a Dockerfile must meet.
# From: Issue #1683 | PR #1912
_ci_check_dockerfiles() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" targets t df rel type svars bvars allow raw tok missing bst bv
    local hits spec p id c ctxs srcs src ok n=0 rc=0 dline mnt_spec
    local cargo_re=$'cargo[ \t]+install[ \t]+' cmd_end_re='^[^&|;]*'
    local -a tl=() cl=() roots=() parts=() toks=() e_bt=() e_tune=() e_stage=() e_secret=() e_ctx=() e_src=()
    local -A kv=() is_pkg=()
    svars="$(_ci_block_entry_list stage_variables "" ci_sh)" || return 2
    [ -n "${svars}" ] || e_stage+=("SOT stage_variables.ci_sh lists no variable")
    bvars="$(_ci_block_entry_list build_variables "" rust)" || return 2
    allow="$(_ci_runtime_secret_ids)" || return 2
    raw="$(_ci_build_tools_packages)" || return 2
    while IFS= read -r tok; do [ -z "${tok}" ] || is_pkg["${tok}"]=1; done <<< "${raw}"
    targets="$(ci_build_targets)" || return 2
    [ -z "${targets}" ] || mapfile -t tl <<< "${targets}"
    for t in "${tl[@]}"; do
        df="$(_ci_service_path "${t}" Dockerfile "${repo_root}")" || return 2
        rel="${df#"${repo_root}/"}"
        if [ ! -f "${df}" ]; then
            e_secret+=("${t}: no Dockerfile at ${rel}"); continue
        fi
        n=$(( n + 1 ))
        type="$(_ci_required_field "${t}" build_type)" || return 2
        # What: ci.sh stages declare each SOT stage var.
        # Why: ARG scope is per stage; else no value.
        # From: Issue #1683 | PR #1858
        missing="$(_ci_dockerfile_stage_missing_args "${df}" "${svars}" 'ci[.]sh (apk-setup|rust-build)')" || return 2
        missing="$(_ci_capture 0 sort -u <<< "${missing}")" || return 2
        while read -r bst bv; do
            [ -z "${bv}" ] || e_stage+=("${t}: Dockerfile stage ${bst} runs ci.sh without ARG ${bv} (SOT stage_variables.ci_sh)")
        done <<< "${missing}"
        # What: each secret mount id is a central id.
        # Why: set-runtime writes only listed ids.
        # From: Issue #1683 | PR #1858
        hits=""
        while IFS= read -r dline || [ -n "${dline}" ]; do
            [[ ! "${dline}" =~ ^[[:space:]]*# ]] || continue
            while [[ "${dline}" =~ --mount=[^[:space:]]+ ]]; do
                mnt_spec="${BASH_REMATCH[0]}"
                hits+="${mnt_spec}"$'\n'
                dline="${dline#*"${mnt_spec}"}"
            done
        done < "${df}" || return 2
        while IFS= read -r spec; do
            [ -n "${spec}" ] || continue
            kv=()
            IFS=',' read -r -a parts <<< "${spec#--mount=}"
            for p in "${parts[@]}"; do kv["${p%%=*}"]="${p#*=}"; done
            [ "${kv[type]:-bind}" = secret ] || continue
            id="${kv[id]:-${kv[target]:-${kv[dst]:-${kv[destination]:-}}}}"
            [ -n "${kv[id]:-}" ] || id="${id##*/}"
            if [ -z "${id}" ]; then
                e_secret+=("${t}: ${rel}: '${spec}' has no id or target"); continue
            fi
            _ci_list_has "${id}" "${allow}" || e_secret+=("${t}: ${rel}: mount id '${id}' is not in the central list")
        done <<< "${hits}"
        # What: COPY sources: the context or an edge.
        # Why: else the image identity goes stale.
        # From: Issue #1683 | PR #1912
        c="$(_ci_required_field "${t}" context)" || return 2
        roots=("${c}")
        ctxs="$(ci_service_context_paths "${t}" "${repo_root}")" || return 2
        cl=()
        [ -z "${ctxs}" ] || mapfile -t cl <<< "${ctxs}"
        roots+=("${cl[@]}")
        srcs="$(_ci_dockerfile_copy_sources "$(< "${df}")")" || return 2
        while IFS= read -r src; do
            [ -n "${src}" ] || continue
            ok=""
            for p in "${roots[@]}"; do
                case "${src%/}" in "${p}" | "${p}"/*) ok=1; break ;; esac
            done
            [ -n "${ok}" ] || e_ctx+=("${t}: ${rel} copies ${src}, outside its context and SOT edges")
        done <<< "${srcs}"
        # What: cargo install tokens; rust: none at all.
        # Why: build-tools owns the toolchain (AG-REL-002).
        # From: Issue #1683 | PR #1912
        raw=""
        while IFS= read -r dline || [ -n "${dline}" ]; do
            [[ "${dline}" =~ ${cargo_re} ]] || continue
            dline="${dline#*"${BASH_REMATCH[0]}"}"
            [[ "${dline}" =~ ${cmd_end_re} ]]
            IFS=$' \t' read -r -a toks <<< "${BASH_REMATCH[0]}"
            for tok in "${toks[@]}"; do
                [[ "${tok}" == -* ]] || raw+="${tok}"$'\n'
            done
        done < "${df}" || return 2
        raw="${raw%$'\n'}"
        if [ "${type}" != rust ]; then
            while IFS= read -r tok; do
                [ -z "${tok}" ] || [ -z "${is_pkg[${tok}]:-}" ] || e_src+=("${rel}: cargo install ${tok}; SOT ships it prebuilt in build-tools")
            done <<< "${raw}"
            continue
        fi
        [ -z "${raw}" ] || e_bt+=("${t}: Dockerfile compiles a tool with cargo install; consume the build-tools image")
        # What: rust stages: build vars, build-tools image.
        # Why: one toolchain owner (AG-CI-008).
        # From: Issue #1683
        _ci_file_match "[CI-ERROR-CHECK-0188]" "target=\"${t}\" reason=\"toolchain ARG not searched\"" "${df}" "ARG ${CI_ARG_TOOLCHAIN_IMAGE}" -F \
            || { [ "$?" -eq 1 ] || return 2; e_bt+=("${t}: Dockerfile must declare ARG ${CI_ARG_TOOLCHAIN_IMAGE}"); }
        missing="$(_ci_dockerfile_stage_missing_args "${df}" "${bvars}" 'ci[.]sh rust-build')" || return 2
        missing="$(_ci_capture 0 sort -u <<< "${missing}")" || return 2
        while read -r bst bv; do
            [ -z "${bv}" ] || e_bt+=("${t}: Dockerfile stage ${bst} runs ci.sh rust-build without ARG ${bv} (SOT build_variables.rust)")
        done <<< "${missing}"
        _ci_file_match "[CI-ERROR-CHECK-0189]" "target=\"${t}\" reason=\"FROM line not searched\"" "${df}" "^FROM \\$\\{${CI_ARG_TOOLCHAIN_IMAGE}(:-scratch)?\\}([[:space:]]|$)" \
            || { [ "$?" -eq 1 ] || return 2; e_bt+=("${t}: Dockerfile must build FROM \${${CI_ARG_TOOLCHAIN_IMAGE}}"); }
        # What: forbid a mutable default on the ARG.
        # Why: ci.sh supplies the immutable ref (AG-CI-008).
        # From: Issue #1683
        if _ci_file_match "[CI-ERROR-CHECK-0190]" "target=\"${t}\" reason=\"ARG default not searched\"" "${df}" "^ARG ${CI_ARG_TOOLCHAIN_IMAGE}="; then
            e_bt+=("${t}: ARG ${CI_ARG_TOOLCHAIN_IMAGE} must carry no default; ci.sh supplies it")
        elif [ "$?" -ne 1 ]; then
            return 2
        fi
        # What: reject Cargo tuning hardcode; empty ARG ok.
        # Why: jobs/lto/codegen from CI vars (AG-CI-006).
        # From: Issue #1683
        if _ci_file_match "[CI-ERROR-CHECK-0191]" "target=\"${t}\" reason=\"Cargo tuning not searched\"" "${df}" '^[[:space:]]*(ARG[[:space:]]+SCCACHE_DIST_SCHEDULER_URL|ENV[[:space:]]+CARGO_BUILD_JOBS=|ARG[[:space:]]+PROJECT_CARGO_LTO=.+|ARG[[:space:]]+PROJECT_CARGO_CODEGENUNIT=.+|ENV[[:space:]]+PROJECT_CARGO_LTO=|ENV[[:space:]]+PROJECT_CARGO_CODEGENUNIT=)'; then
            e_tune+=("${t}: Dockerfile hardcodes a Cargo tuning value; source jobs/lto/codegen from CI vars")
        elif [ "$?" -ne 1 ]; then
            return 2
        fi
    done
    [ "${#e_stage[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0169]" "targets=${n} reason=\"a ci.sh build stage lacks an SOT stage variable ARG\"" "$(printf '%s\n' "${e_stage[@]}")"; rc=1; }
    [ "${#e_secret[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0156]" "targets=${n} reason=\"Dockerfile missing or mount id not central\"" "$(printf '%s\n' "${e_secret[@]}")"; rc=1; }
    [ "${#e_ctx[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0175]" "targets=${n} reason=\"a COPY source is outside the context paths\"" "$(printf '%s\n' "${e_ctx[@]}")"; rc=1; }
    [ "${#e_src[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0061]" "targets=${n} reason=\"Dockerfile source-compiles a prebuilt SOT tool; consume the build-tools image\"" "$(printf '%s\n' "${e_src[@]}")"; rc=1; }
    [ "${#e_bt[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0058]" "targets=${n} reason=\"rust Dockerfile does not consume the build-tools image (AG-CI-008/AG-REL-002)\"" "$(printf '%s\n' "${e_bt[@]}")"; rc=1; }
    [ "${#e_tune[@]}" -eq 0 ] || { ci_error "[CI-ERROR-CHECK-0060]" "targets=${n} reason=\"rust Dockerfile hardcodes a Cargo tuning value (AG-CI-006)\"" "$(printf '%s\n' "${e_tune[@]}")"; rc=1; }
    [ "${rc}" -ne 0 ] || printf 'dockerfiles=clean targets=%s\n' "${n}"
    return "${rc}"
}

# What: "stage name" per stage that runs <ere> sans ARG
# Why: ARG scope is per stage; else no value reaches it
# From: Issue #1683 | PR #1858
_ci_dockerfile_stage_missing_args() {
    local df="$1" runs="$3" sm_line sm_word sm_base sm_as sm_st=0
    local -a sm_need=() sm_fld=() sm_decl=("|")
    local -A sm_stage=()
    read -r -a sm_need <<< "${2//$'\n'/ }"
    while IFS= read -r sm_line || [ -n "${sm_line}" ]; do
        [[ ! "${sm_line}" =~ ^[[:space:]]*# ]] || continue
        # What: a stage inherits the ARGs of its base.
        # Why: FROM <alias> keeps the ARGs declared there.
        if _ci_dockerfile_from_parts "${sm_line}" sm_base sm_as; then
            sm_st=$((sm_st + 1))
            sm_decl[sm_st]="|"
            [ -z "${sm_stage["k${sm_base}"]+x}" ] || sm_decl[sm_st]="${sm_decl[${sm_stage["k${sm_base}"]}]}"
            [ -z "${sm_as}" ] || sm_stage["${sm_as}"]="${sm_st}"
            continue
        fi
        IFS=$' \t' read -r -a sm_fld <<< "${sm_line}"
        sm_word="${sm_fld[0]-}"
        if [ "${sm_word^^}" = ARG ]; then
            for sm_word in "${sm_fld[@]:1}"; do sm_decl[sm_st]+="${sm_word%%=*}|"; done
            continue
        fi
        [[ "${sm_line}" =~ ${runs} ]] || continue
        for sm_word in "${sm_need[@]}"; do
            [[ "${sm_decl[sm_st]}" == *"|${sm_word}|"* ]] || printf '%s %s\n' "${sm_st}" "${sm_word}"
        done
    done < "${df}" || return 2
}

# What: no workspace Cargo.toml set [profile].
# Why: sourced from CARGO env vars (AG-CI-006).
# From: Issue #1683
_ci_check_cargo_profile_tuning() {
    local repo_root="${1:-${CI_REPO_ROOT:-.}}" f line tomls
    local -a viol=()
    tomls="$(_ci_ls_files cargo-profile-tuning "${repo_root}" '*Cargo.toml')" || return 2
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        local produced produced_rc=0
        produced="$(grep -nE '^[[:space:]]*(lto|codegen-units)[[:space:]]*=' "${repo_root}/${f}")" || produced_rc=$?
        _ci_producer_ok "${produced_rc}" 1 || return 2
        while IFS= read -r line; do
            [ -n "${line}" ] && viol+=("${f}:${line}")
        done <<<"${produced}"
    done <<< "${tomls}"
    if [ "${#viol[@]}" -gt 0 ]; then
        ci_error "[CI-ERROR-CHECK-0059]" "reason=\"Cargo.toml hardcodes [profile] lto/codegen-units; source them from CARGO_PROFILE_RELEASE env (AG-CI-006)\"" "$(printf '%s\n' "${viol[@]}")"
        return 1
    fi
    printf 'cargo-profile-tuning=clean\n'
}

# What: every stack compose renders clean in every profile.
# Why: a compose error breaks every install.
# From: Issue #1683
@test "compose_config" {
    if [ "${compose_config_is_enabled:-true}" != "true" ]; then
        skip "compose_config_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_compose_config
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: no prod compose service has a build: key.
# Why: prod runs prebuilt images only.
# From: Issue #1683
@test "prebuilt_prod" {
    if [ "${prebuilt_prod_is_enabled:-true}" != "true" ]; then
        skip "prebuilt_prod_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_prebuilt_prod
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: each compose image comes from one ref variable.
# Why: a fixed tag would ignore the chosen channel.
# From: Issue #1683
@test "image_channel_resolution" {
    if [ "${image_channel_resolution_is_enabled:-true}" != "true" ]; then
        skip "image_channel_resolution_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_image_channel_resolution
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: every compose service has a healthcheck entry.
# Why: a hung container must show as unhealthy.
# From: Issue #1683
@test "compose_healthchecks" {
    if [ "${compose_healthchecks_is_enabled:-true}" != "true" ]; then
        skip "compose_healthchecks_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_compose_healthchecks
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: build target Dockerfiles follow the SOT rules.
# Why: stage args and secret ids have one owner.
# From: Issue #1683
@test "dockerfiles" {
    if [ "${dockerfiles_is_enabled:-false}" != "true" ]; then
        skip "dockerfiles_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_dockerfiles
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: each compose service has one logging doc row.
# Why: a new service must not miss its log row.
# From: Issue #1683
@test "logging_matrix" {
    if [ "${logging_matrix_is_enabled:-false}" != "true" ]; then
        skip "logging_matrix_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_logging_matrix
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: prod mounts the SOT state dirs under STATE_DIR.
# Why: AG-SETUP-001: one state root.
# From: Issue #1683
@test "prod_state_wiring" {
    if [ "${prod_state_wiring_is_enabled:-false}" != "true" ]; then
        skip "prod_state_wiring_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_prod_state_wiring
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: external deploy images equal the SOT base images.
# Why: one owner per external image.
# From: Issue #1683
@test "sot_external_images" {
    if [ "${sot_external_images_is_enabled:-false}" != "true" ]; then
        skip "sot_external_images_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_sot_external_images
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: the setup.sh bootstrap repo equals the SOT value.
# Why: setup.sh loads itself before the clone.
# From: Issue #1683
@test "setup_update_safety" {
    if [ "${setup_update_safety_is_enabled:-false}" != "true" ]; then
        skip "setup_update_safety_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_setup_update_safety
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: no Cargo.toml sets lto or codegen-units.
# Why: AG-CI-006: CARGO env vars own them.
# From: Issue #1683
@test "cargo_profile_tuning" {
    if [ "${cargo_profile_tuning_is_enabled:-false}" != "true" ]; then
        skip "cargo_profile_tuning_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_cargo_profile_tuning
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: the trivyignore yields a full OpenVEX document.
# Why: a broken entry must fail before release.
# From: Issue #1683
@test "vex_drift" {
    if [ "${vex_drift_is_enabled:-false}" != "true" ]; then
        skip "vex_drift_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_vex_drift
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: proxy CACHE_* compose defaults equal the doc.
# Why: a copied doc default goes stale.
# From: Issue #1683
@test "proxy_cache_env_doc_drift" {
    if [ "${proxy_cache_env_doc_drift_is_enabled:-false}" != "true" ]; then
        skip "proxy_cache_env_doc_drift_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_proxy_cache_env_doc_drift
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: container names are project prefix + service.
# Why: operators find a container by its service.
# From: Issue #1683
@test "naming_consistency" {
    if [ "${naming_consistency_is_enabled:-false}" != "true" ]; then
        skip "naming_consistency_is_enabled=false"
    fi
    ci_sh_load
    run _ci_check_naming_consistency
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}

# What: Cargo has no version; license, edition from SOT.
# Why: the SOT owns release version data.
# From: Issue #1683
@test "version_drift" {
    if [ "${version_drift_is_enabled:-false}" != "true" ]; then
        skip "version_drift_is_enabled=false"
    fi
    ci_sh_load
    run _ci_version_release
    printf '%s\n' "${output}" >&3
    [ "${status}" -eq 0 ]
}
