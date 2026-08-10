#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
"""One-shot guarded patcher for the CI 1.1 artifact-identity refactor.

This file is intentionally temporary. Every rewrite is assertion-counted and
fails closed when the expected current_dev source shape is not present.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    raise SystemExit(f"ci-1.1 patcher: {message}")


def replace_exact(text: str, old: str, new: str, *, count: int = 1, label: str) -> str:
    actual = text.count(old)
    if actual != count:
        fail(f"{label}: expected {count} exact match(es), found {actual}")
    return text.replace(old, new)


def replace_regex(text: str, pattern: str, replacement: str, *, count: int = 1, label: str, flags: int = re.M | re.S) -> str:
    new_text, actual = re.subn(pattern, replacement, text, count=count, flags=flags)
    if actual != count:
        fail(f"{label}: expected {count} regex match(es), found {actual}")
    return new_text


def get_job(text: str, job: str) -> tuple[int, int, str]:
    match = re.search(rf"(?m)^  {re.escape(job)}:\n", text)
    if not match:
        fail(f"job {job!r} not found")
    next_job = re.search(r"(?m)^  [A-Za-z0-9_-]+:\n", text[match.end():])
    end = match.end() + next_job.start() if next_job else len(text)
    return match.start(), end, text[match.start():end]


def set_job(text: str, job: str, transform) -> str:
    start, end, block = get_job(text, job)
    new_block = transform(block)
    return text[:start] + new_block + text[end:]


def get_step(block: str, name: str) -> tuple[int, int, str]:
    match = re.search(rf"(?m)^      - name: {re.escape(name)}\n", block)
    if not match:
        fail(f"step {name!r} not found")
    next_step = re.search(r"(?m)^      - name: |^      - uses: ", block[match.end():])
    end = match.end() + next_step.start() if next_step else len(block)
    return match.start(), end, block[match.start():end]


def replace_step(block: str, name: str, new_step: str) -> str:
    start, end, _ = get_step(block, name)
    return block[:start] + new_step.rstrip() + "\n\n" + block[end:]


def insert_after_step(block: str, name: str, addition: str) -> str:
    _, end, _ = get_step(block, name)
    return block[:end] + "\n" + addition.rstrip() + "\n" + block[end:]


def trusted_candidate_condition() -> str:
    return """${{
            steps.build.outcome == 'success' &&
            (
              github.event_name != 'pull_request' ||
              (
                github.actor != 'dependabot[bot]' &&
                github.event.pull_request.head.repo.id == github.event.repository.id
              )
            )
          }}"""


def patch_build_job(block: str, *, platform: str, persistent_cache: bool) -> str:
    condition = trusted_candidate_condition()
    if persistent_cache:
        _, _, prep = get_step(block, "Prepare pushed service Trivy cache")
        prep = replace_regex(
            prep,
            r"if: >-\n\s+\$\{\{\n\s+github\.event_name != 'pull_request' &&\n\s+steps\.build\.outcome == 'success'\n\s+\}\}",
            "if: >-\n          " + condition.replace("\n", "\n          "),
            label="amd64 candidate Trivy cache condition",
        )
        block = replace_step(block, "Prepare pushed service Trivy cache", prep)
        cache_dir = "${{ steps.trivy-cache.outputs.dir }}"
        cleanup = "${{ steps.trivy-cache.outputs.ephemeral == 'true' && 'true' || 'false' }}"
    else:
        cache_dir = "${{ runner.temp }}/trivy-${{ matrix.service }}-arm64-${{ github.run_id }}-${{ github.run_attempt }}"
        cleanup = '"true"'

    scan = f"""      - name: Scan pushed service digest with Trivy
        # CI 1.1: this scan consumes the immutable digest emitted by the one
        # candidate build. Same-repo PR candidates are scanned too; fork and
        # Dependabot PRs remain read-only and therefore have no pushed digest.
        if: >-
          {condition}
        timeout-minutes: 20
        uses: ./.github/actions/trivy-scan-exact-digest
        with:
          image-ref: ghcr.io/${{{{ github.repository }}}}/${{{{ matrix.service }}}}@${{{{ steps.build.outputs.digest }}}}
          cache-dir: {cache_dir}
          cleanup-cache: {cleanup}
"""
    block = replace_step(block, "Scan pushed service digest with Trivy", scan)

    smoke = f"""      - name: Smoke-test exact build-tools candidate
        if: >-
          ${{{{
            matrix.service == 'build-tools' &&
            steps.build.outcome == 'success' &&
            (
              github.event_name != 'pull_request' ||
              (
                github.actor != 'dependabot[bot]' &&
                github.event.pull_request.head.repo.id == github.event.repository.id
              )
            )
          }}}}
        uses: ./.github/actions/build-tools-candidate-smoke
        with:
          image-ref: ghcr.io/${{{{ github.repository }}}}/build-tools@${{{{ steps.build.outputs.digest }}}}
          platform: {platform}
          run-fixtures: {'"true"' if platform == 'linux/amd64' else '"false"'}
"""
    block = insert_after_step(block, "Scan pushed service digest with Trivy", smoke)
    return block


def patch_merge_job(block: str) -> str:
    outputs = """    outputs:
      proxy_digest: ${{ steps.create-trusted-manifests.outputs.proxy_digest || steps.create-pr-staging-manifests.outputs.proxy_digest }}
      dns_digest: ${{ steps.create-trusted-manifests.outputs.dns_digest || steps.create-pr-staging-manifests.outputs.dns_digest }}
      watchdog_digest: ${{ steps.create-trusted-manifests.outputs.watchdog_digest || steps.create-pr-staging-manifests.outputs.watchdog_digest }}
      dhcp_digest: ${{ steps.create-trusted-manifests.outputs.dhcp_digest || steps.create-pr-staging-manifests.outputs.dhcp_digest }}
      dhcp_proxy_digest: ${{ steps.create-trusted-manifests.outputs.dhcp_proxy_digest || steps.create-pr-staging-manifests.outputs.dhcp_proxy_digest }}
      ntp_digest: ${{ steps.create-trusted-manifests.outputs.ntp_digest || steps.create-pr-staging-manifests.outputs.ntp_digest }}
      syslog_digest: ${{ steps.create-trusted-manifests.outputs.syslog_digest || steps.create-pr-staging-manifests.outputs.syslog_digest }}
      ui_digest: ${{ steps.create-trusted-manifests.outputs.ui_digest || steps.create-pr-staging-manifests.outputs.ui_digest }}
      build_tools_digest: ${{ steps.create-trusted-manifests.outputs.build_tools_digest || steps.create-pr-staging-manifests.outputs.build_tools_digest }}
      stack_digest: ${{ steps.create-trusted-manifests.outputs.stack_digest }}
"""
    block = replace_exact(
        block,
        "      artifact-metadata: write\n    steps:\n",
        "      artifact-metadata: write\n" + outputs + "    steps:\n",
        label="merge-manifests job outputs",
    )

    def exact_children(step: str, *, trusted: bool) -> str:
        step = replace_exact(
            step,
            '          source_tag="sha-${short_sha}"\n' if trusted else '          source_tag="pr-${PR_NUMBER}-sha-${short_sha}"\n',
            ('          source_tag="sha-${short_sha}"\n          declare -A merged_digests=()\n' if trusted
             else '          source_tag="pr-${PR_NUMBER}-sha-${short_sha}"\n'),
            label="merge digest map initialization" if trusted else "PR merge source tag",
        )
        old = """            ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \\
              docker buildx imagetools create -t "$target_image" "$amd64_image" "$arm64_image" \\
"""
        new = """            amd64_digest="$(digest_for_image "$amd64_image")"
            arm64_digest="$(digest_for_image "$arm64_image")"
            [[ "$amd64_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { echo "::error::Invalid amd64 digest for $service: $amd64_digest"; exit 1; }
            [[ "$arm64_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { echo "::error::Invalid arm64 digest for $service: $arm64_digest"; exit 1; }
            amd64_ref="ghcr.io/${REPOSITORY}/${service}@${amd64_digest}"
            arm64_ref="ghcr.io/${REPOSITORY}/${service}@${arm64_digest}"

            ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \\
              docker buildx imagetools create -t "$target_image" "$amd64_ref" "$arm64_ref" \\
"""
        step = replace_exact(step, old, new, label="merge exact child digests")
        if trusted:
            step = replace_exact(
                step,
                """            merged_digest="$(digest_for_image "$target_image")"
            printf '%s_digest=%s\\n' "${service//-/_}" "$merged_digest" >> "$GITHUB_OUTPUT"
""",
                """            merged_digest="$(digest_for_image "$target_image")"
            [[ "$merged_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { echo "::error::Invalid merged digest for $service: $merged_digest"; exit 1; }
            merged_digests["$service"]="$merged_digest"
            printf '%s_digest=%s\\n' "${service//-/_}" "$merged_digest" >> "$GITHUB_OUTPUT"
""",
                label="record trusted merged digests",
            )
            marker = "          done\n"
            idx = step.rfind(marker)
            if idx < 0:
                fail("trusted merge loop terminator not found")
            stack = r'''

          # Build the immutable stack BOM before any public channel is moved.
          # Every recorded service digest is the exact merged manifest digest
          # produced above from the already-checked platform children.
          for service in "${services[@]}"; do
            digest="${merged_digests[$service]:-}"
            [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || {
              echo "::error::Cannot create stack BOM: missing exact digest for $service."
              exit 1
            }
          done

          pointer_context="$(mktemp -d)"
          cleanup_pointer_context() { rm -rf "$pointer_context"; }
          trap cleanup_pointer_context EXIT

          {
            printf 'LANCACHE_IMAGE_TAG=%s\n' "$source_tag"
            printf 'LANCACHE_IMAGE_COMMIT=%s\n' "$COMMIT_SHA"
            printf 'LANCACHE_IMAGE_SERVICES=%s\n' "${services[*]}"
            for service in "${services[@]}"; do
              env_key="$(printf '%s' "$service" | tr '[:lower:]-' '[:upper:]_')"
              printf 'LANCACHE_IMAGE_DIGEST_%s=%s\n' "$env_key" "${merged_digests[$service]}"
            done
          } > "$pointer_context/stack.env"

          cat > "$pointer_context/stack-bom.json" <<BOM
          {
            "schema": 1,
            "commit": "${COMMIT_SHA}",
            "source_tag": "${source_tag}",
            "services": {
              "proxy": "${merged_digests[proxy]}",
              "dns": "${merged_digests[dns]}",
              "watchdog": "${merged_digests[watchdog]}",
              "dhcp": "${merged_digests[dhcp]}",
              "dhcp-proxy": "${merged_digests[dhcp-proxy]}",
              "ntp": "${merged_digests[ntp]}",
              "syslog": "${merged_digests[syslog]}",
              "ui": "${merged_digests[ui]}",
              "build-tools": "${merged_digests[build-tools]}"
            }
          }
          BOM

          stack_pointer_description="Resolves a lancache-ng stack channel to one immutable, digest-recorded service image set."
          cat > "$pointer_context/Dockerfile" <<DOCKERFILE
          FROM busybox:stable-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213
          LABEL org.opencontainers.image.title="lancache-ng stack bill of materials"
          LABEL org.opencontainers.image.description="${stack_pointer_description}"
          COPY stack.env /stack.env
          COPY stack-bom.json /stack-bom.json
          CMD ["true"]
          DOCKERFILE

          stack_pointer_image="ghcr.io/${REPOSITORY}/stack:${source_tag}"
          ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \
            docker buildx build \
            --platform "$REQUIRED_PLATFORMS" \
            --push \
            -t "$stack_pointer_image" \
            --annotation "index:org.opencontainers.image.description=${stack_pointer_description}" \
            "$pointer_context"
          GHCR_RETRY_USERNAME="$GHCR_RETRY_USERNAME" GHCR_RETRY_PASSWORD="$GHCR_RETRY_PASSWORD" \
            bash scripts/require-image-platforms.sh "$stack_pointer_image" "$REQUIRED_PLATFORMS"
          stack_digest="$(digest_for_image "$stack_pointer_image")"
          [[ "$stack_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { echo "::error::Invalid stack BOM digest: $stack_digest"; exit 1; }
          printf 'stack_digest=%s\n' "$stack_digest" >> "$GITHUB_OUTPUT"
          cleanup_pointer_context
          trap - EXIT
'''
            step = step[:idx + len(marker)] + stack + step[idx + len(marker):]
        return step

    _, _, trusted_step = get_step(block, "Create multi-platform manifests")
    block = replace_step(block, "Create multi-platform manifests", exact_children(trusted_step, trusted=True))
    _, _, pr_step = get_step(block, "Create PR staging multi-platform manifest")
    block = replace_step(block, "Create PR staging multi-platform manifest", exact_children(pr_step, trusted=False))

    stack_attest = """      - name: Attest immutable stack BOM provenance
        if: steps.create-trusted-manifests.outputs.stack_digest != ''
        uses: ./.github/actions/ghcr-attest-with-cache
        with:
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
          subject-name: ghcr.io/${{ github.repository }}/stack
          subject-digest: ${{ steps.create-trusted-manifests.outputs.stack_digest }}
"""
    remove_idx = re.search(r"(?m)^      - name: Remove buildx builder\n", block)
    if not remove_idx:
        fail("merge-manifests Remove buildx builder step not found")
    block = block[:remove_idx.start()] + stack_attest + "\n" + block[remove_idx.start():]
    return block


def patch_full_setup_job(block: str) -> str:
    block = replace_exact(
        block,
        "    needs: [detect-changes, merge-manifests, promote, compute-validation-network]\n",
        "    needs: [detect-changes, merge-manifests, compute-validation-network]\n",
        label="full-setup dependency before promotion",
    )
    block = replace_exact(
        block,
        "          (github.event_name != 'pull_request' && needs.promote.result == 'success')\n",
        "          (github.event_name != 'pull_request' && needs['merge-manifests'].result == 'success')\n",
        label="full-setup push gate before promotion",
    )

    _, _, channel_step = get_step(block, "Determine validation image channel")
    channel_step = replace_regex(
        channel_step,
        r'(          tag="\$\(vit_resolve_tag .*?\)"\n)',
        r'''\1
          # CI 1.1: a trusted push validates the immutable commit candidate
          # before public promotion. PRs keep their unique staging tag and
          # immediately pin every service behind it to a digest below.
          if [[ "$EVENT_NAME" != "pull_request" ]]; then
            tag="sha-${BUILD_SHA::7}"
            echo "Validating pre-promotion candidate set '$tag'."
          fi
''',
        label="full-setup pre-promotion sha tag",
    )
    block = replace_step(block, "Determine validation image channel", channel_step)

    _, backfill_end, _ = get_step(block, "Ensure PR staging tags exist for full-setup services")
    pin_step = """      - name: Pin full-setup service identities to immutable digests
        id: pin-full-setup-digests
        env:
          REPOSITORY: ${{ github.repository }}
          IMAGE_TAG: ${{ steps.channel.outputs.tag }}
          PROXY_DIGEST: ${{ needs['merge-manifests'].outputs.proxy_digest }}
          DNS_DIGEST: ${{ needs['merge-manifests'].outputs.dns_digest }}
          WATCHDOG_DIGEST: ${{ needs['merge-manifests'].outputs.watchdog_digest }}
          UI_DIGEST: ${{ needs['merge-manifests'].outputs.ui_digest }}
          BUILD_TOOLS_DIGEST: ${{ needs['merge-manifests'].outputs.build_tools_digest }}
          GHCR_RETRY_USERNAME: ${{ github.actor }}
          GHCR_RETRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          override_file=".ci-exact-digests.yml"
          client_tools_ref="$(bash scripts/render-full-setup-digest-override.sh "deploy/full-setup/${override_file}")"
          printf 'FULL_SETUP_COMPOSE_OVERRIDE=%s\n' "$override_file" >> "$GITHUB_ENV"
          printf 'FULL_SETUP_CLIENT_TOOLS_IMAGE=%s\n' "$client_tools_ref" >> "$GITHUB_ENV"
"""
    block = block[:backfill_end] + "\n" + pin_step + block[backfill_end:]

    _, _, compose_step = get_step(block, "Validate compose configuration")
    compose_step = replace_exact(
        compose_step,
        "            docker compose -f docker-compose.yml config >/dev/null\n",
        "            docker compose -f docker-compose.yml -f \"${FULL_SETUP_COMPOSE_OVERRIDE:?FULL_SETUP_COMPOSE_OVERRIDE is required}\" config >/dev/null\n",
        label="full-setup exact compose config",
    )
    compose_step = replace_exact(
        compose_step,
        "          LANCACHE_IMAGE_TAG: ${{ steps.channel.outputs.tag }}\n",
        "          LANCACHE_IMAGE_TAG: ${{ steps.channel.outputs.tag }}\n          FULL_SETUP_COMPOSE_OVERRIDE: ${{ env.FULL_SETUP_COMPOSE_OVERRIDE }}\n",
        label="full-setup compose override env",
    )
    block = replace_step(block, "Validate compose configuration", compose_step)

    _, _, reserve_step = get_step(block, "Reserve a validation subnet and start the stack (locked, retries on collision)")
    reserve_step = replace_exact(
        reserve_step,
        "          image-tag: ${{ steps.channel.outputs.tag }}\n",
        "          image-tag: ${{ steps.channel.outputs.tag }}\n          compose-override-file: ${{ env.FULL_SETUP_COMPOSE_OVERRIDE }}\n",
        label="full-setup reserve exact override",
    )
    block = replace_step(block, "Reserve a validation subnet and start the stack (locked, retries on collision)", reserve_step)

    _, _, sim_step = get_step(block, "Run client simulation against the full-setup stack")
    sim_step = replace_regex(
        sim_step,
        r"        env:\n          FULL_SETUP_CLIENT_TOOLS_IMAGE: .*?\n",
        "",
        label="full-setup exact build-tools env",
    )
    block = replace_step(block, "Run client simulation against the full-setup stack", sim_step)

    _, _, cleanup_step = get_step(block, "Clean up image")
    cleanup_step = replace_exact(
        cleanup_step,
        "          docker rmi lancache-ng-full-setup:validation || true\n",
        "          docker rmi lancache-ng-full-setup:validation || true\n          rm -f deploy/full-setup/.ci-exact-digests.yml\n",
        label="full-setup override cleanup",
    )
    block = replace_step(block, "Clean up image", cleanup_step)
    return block


def patch_promote_job(block: str) -> str:
    block = replace_exact(
        block,
        "    needs: merge-manifests\n",
        "    needs: [merge-manifests, full-setup-validate]\n",
        label="promotion depends on validation",
    )
    block = replace_exact(
        block,
        "    if: \"!cancelled() && needs['merge-manifests'].result == 'success' && github.event_name != 'pull_request'\"\n",
        "    if: \"!cancelled() && needs['merge-manifests'].result == 'success' && needs['full-setup-validate'].result == 'success' && github.event_name != 'pull_request'\"\n",
        label="promotion full-setup gate",
    )

    _, _, promote_step = get_step(block, "Promote coherent stack tags")
    promote_step = replace_exact(
        promote_step,
        "          GHCR_RETRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}\n",
        """          GHCR_RETRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
          PROXY_DIGEST: ${{ needs['merge-manifests'].outputs.proxy_digest }}
          DNS_DIGEST: ${{ needs['merge-manifests'].outputs.dns_digest }}
          WATCHDOG_DIGEST: ${{ needs['merge-manifests'].outputs.watchdog_digest }}
          DHCP_DIGEST: ${{ needs['merge-manifests'].outputs.dhcp_digest }}
          DHCP_PROXY_DIGEST: ${{ needs['merge-manifests'].outputs.dhcp_proxy_digest }}
          NTP_DIGEST: ${{ needs['merge-manifests'].outputs.ntp_digest }}
          SYSLOG_DIGEST: ${{ needs['merge-manifests'].outputs.syslog_digest }}
          UI_DIGEST: ${{ needs['merge-manifests'].outputs.ui_digest }}
          BUILD_TOOLS_DIGEST: ${{ needs['merge-manifests'].outputs.build_tools_digest }}
          STACK_DIGEST: ${{ needs['merge-manifests'].outputs.stack_digest }}
""",
        label="promotion exact digest env",
    )
    promote_step = replace_exact(
        promote_step,
        """          stack_pointer_image="ghcr.io/${REPOSITORY}/stack:${source_tag}"
          channel_tags=()
          pointer_context=""
          declare -A previous_refs=()
""",
        """          stack_pointer_image="ghcr.io/${REPOSITORY}/stack@${STACK_DIGEST}"
          channel_tags=()
          declare -A candidate_digests=(
            [proxy]="$PROXY_DIGEST"
            [dns]="$DNS_DIGEST"
            [watchdog]="$WATCHDOG_DIGEST"
            [dhcp]="$DHCP_DIGEST"
            [dhcp-proxy]="$DHCP_PROXY_DIGEST"
            [ntp]="$NTP_DIGEST"
            [syslog]="$SYSLOG_DIGEST"
            [ui]="$UI_DIGEST"
            [build-tools]="$BUILD_TOOLS_DIGEST"
          )
          declare -A previous_refs=()
""",
        label="promotion immutable candidate map",
    )
    promote_step = replace_exact(
        promote_step,
        """            if [[ -n "$pointer_context" ]]; then
              rm -rf "$pointer_context"
            fi

""",
        "",
        label="remove promotion stack build cleanup",
    )

    promote_step = replace_regex(
        promote_step,
        r"          # Wrapped in ghcr_retry: unlike merge-manifests' per-arch checks,.*?          # Neither loop below passes --annotation\.",
        r'''          # Validate the exact candidate identities handed off by merge-manifests.
          # The sha-* names are checked only as immutable-record pointers; promotion
          # itself consumes repository@sha256 references from the job outputs.
          for service in "${services[@]}"; do
            expected_digest="${candidate_digests[$service]:-}"
            [[ "$expected_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || {
              echo "::error::Missing or malformed candidate digest for $service: '$expected_digest'."
              exit 1
            }
            source_tag_image="ghcr.io/${REPOSITORY}/${service}:${source_tag}"
            source_tag_digest="$(digest_for_image "$source_tag_image")"
            [[ "$source_tag_digest" = "$expected_digest" ]] || {
              echo "::error::$source_tag_image moved away from the merge-manifests digest; refusing promotion."
              exit 1
            }
            GHCR_RETRY_USERNAME="$GHCR_RETRY_USERNAME" GHCR_RETRY_PASSWORD="$GHCR_RETRY_PASSWORD" \
              bash scripts/require-image-platforms.sh "ghcr.io/${REPOSITORY}/${service}@${expected_digest}" "$REQUIRED_PLATFORMS"
          done

          [[ "$STACK_DIGEST" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { echo "::error::Missing or malformed stack BOM digest '$STACK_DIGEST'."; exit 1; }
          stack_tag_image="ghcr.io/${REPOSITORY}/stack:${source_tag}"
          [[ "$(digest_for_image "$stack_tag_image")" = "$STACK_DIGEST" ]] || {
            echo "::error::$stack_tag_image moved away from the merge-manifests stack BOM digest; refusing promotion."
            exit 1
          }
          GHCR_RETRY_USERNAME="$GHCR_RETRY_USERNAME" GHCR_RETRY_PASSWORD="$GHCR_RETRY_PASSWORD" \
            bash scripts/require-image-platforms.sh "$stack_pointer_image" "$REQUIRED_PLATFORMS"

          # Neither loop below passes --annotation.''',
        label="remove promotion rebuild and validate exact inputs",
    )
    promote_step = replace_exact(
        promote_step,
        '            source_image="ghcr.io/${REPOSITORY}/${service}:${source_tag}"\n',
        '            source_image="ghcr.io/${REPOSITORY}/${service}@${candidate_digests[$service]}"\n',
        label="promote exact service digest",
    )
    block = replace_step(block, "Promote coherent stack tags", promote_step)

    # Stack provenance belongs to artifact creation in merge-manifests, not promotion.
    try:
        start, end, _ = get_step(block, "Attest stack pointer provenance")
        block = block[:start] + block[end:]
    except SystemExit:
        raise
    return block


def patch_release_job(block: str) -> str:
    # Once the release step resolves build-tools, all later uses in that step
    # consume the immutable digest rather than resolving the release tag again.
    pattern = r'(          build_tools_digest="\$\(digest_for_image "\$build_tools_image"\)"\n)'
    if re.search(pattern, block):
        block = replace_regex(
            block,
            pattern,
            r'''\1          build_tools_image="ghcr.io/${REPOSITORY}/build-tools@${build_tools_digest}"
''',
            label="release exact build-tools reference",
        )
    return block


def patch_main_workflow() -> None:
    path = ROOT / ".github/workflows/build-push.yml"
    text = path.read_text()
    text = set_job(text, "build", lambda block: patch_build_job(block, platform="linux/amd64", persistent_cache=True))
    text = set_job(text, "build-arm64", lambda block: patch_build_job(block, platform="linux/arm64", persistent_cache=False))
    text = set_job(text, "merge-manifests", patch_merge_job)
    text = set_job(text, "full-setup-validate", patch_full_setup_job)
    text = set_job(text, "promote", patch_promote_job)
    text = set_job(text, "release", patch_release_job)

    text = replace_exact(
        text,
        "          matrix:\n            service: [proxy, dns, watchdog, dhcp, dhcp-proxy, ntp, ui, build-tools]\n",
        "          matrix:\n            service: [proxy, dns, watchdog, dhcp, dhcp-proxy, ntp, syslog, ui, build-tools]\n",
        label="release SBOM syslog coverage",
    )

    # Update the self-guard to recognize the shared build-tools smoke action.
    text = replace_exact(
        text,
        """          grep -F 'Build local arm64 scan image' .github/workflows/build-tools.yml >/dev/null \\
            && grep -F 'BUILD_TOOLS_SCAN_IMAGE_ARM64' .github/workflows/build-tools.yml >/dev/null \\
            && grep -F 'docker run --rm --platform linux/arm64 \"${BUILD_TOOLS_SCAN_IMAGE_ARM64:?BUILD_TOOLS_SCAN_IMAGE_ARM64 is required}\"' .github/workflows/build-tools.yml >/dev/null \\
            && grep -F 'Scan local build-tools arm64 image with Trivy' .github/workflows/build-tools.yml >/dev/null \\
            || { echo \"::error::The build-tools workflow must build, smoke-test, and Trivy-scan the local arm64 scan image before publishing.\"; exit 1; }
""",
        """          grep -F 'Build local arm64 scan image' .github/workflows/build-tools.yml >/dev/null \\
            && grep -F 'BUILD_TOOLS_SCAN_IMAGE_ARM64' .github/workflows/build-tools.yml >/dev/null \\
            && grep -F 'uses: ./.github/actions/build-tools-candidate-smoke' .github/workflows/build-tools.yml >/dev/null \\
            && grep -F 'Scan local build-tools arm64 image with Trivy' .github/workflows/build-tools.yml >/dev/null \\
            || { echo \"::error::The build-tools workflow must build, smoke-test, and Trivy-scan the local arm64 candidate before publishing.\"; exit 1; }
""",
        label="build-tools smoke guard",
    )
    path.write_text(text)


def patch_reserve_action() -> None:
    path = ROOT / ".github/actions/reserve-validation-subnet-stack/action.yml"
    text = path.read_text()
    text = replace_exact(
        text,
        """  working-directory:
    description: Directory holding the full-setup docker-compose.yml.
    required: false
    default: deploy/full-setup
""",
        """  working-directory:
    description: Directory holding the full-setup docker-compose.yml.
    required: false
    default: deploy/full-setup
  compose-override-file:
    description: Optional compose override file, relative to working-directory, containing immutable digest-qualified image references.
    required: false
    default: ""
""",
        label="reserve compose override input",
    )
    text = replace_exact(
        text,
        """        RESERVE_LOCK_ROOT: ${{ inputs.lock-root }}
        GHCR_RETRY_USERNAME: ${{ inputs.ghcr-retry-username }}
""",
        """        RESERVE_LOCK_ROOT: ${{ inputs.lock-root }}
        COMPOSE_OVERRIDE_FILE: ${{ inputs.compose-override-file }}
        GHCR_RETRY_USERNAME: ${{ inputs.ghcr-retry-username }}
""",
        label="reserve compose override env",
    )
    marker = '        # Pull the validation images before reserving a slot. build-push.yml\'s\n'
    compose_args = """        compose_args=(-f docker-compose.yml)
        if [[ -n "$COMPOSE_OVERRIDE_FILE" ]]; then
          [[ -f "$COMPOSE_OVERRIDE_FILE" ]] || { echo "::error::Compose override '$COMPOSE_OVERRIDE_FILE' does not exist in $(pwd)."; exit 1; }
          compose_args+=(-f "$COMPOSE_OVERRIDE_FILE")
        fi

"""
    text = replace_exact(text, marker, compose_args + marker, label="reserve compose args")
    text = replace_exact(text, "docker compose pull --quiet", 'docker compose "${compose_args[@]}" pull --quiet', count=2, label="reserve exact pull")
    text = replace_exact(text, "docker compose up -d 2>&1", 'docker compose "${compose_args[@]}" up -d 2>&1', label="reserve exact up")
    path.write_text(text)


def patch_build_tools_workflow() -> None:
    path = ROOT / ".github/workflows/build-tools.yml"
    text = path.read_text()
    push_block = """  push:
    branches: [master, current_dev, v0.2.0]
    paths:
      - "tools/build-tools/**"
      - ".github/workflows/build-tools.yml"
      - ".github/actions/build-tools-candidate-smoke/**"
      - ".github/actions/trivy-scan-exact-digest/**"
"""
    text = replace_exact(text, push_block, "", label="remove duplicate build-tools push workflow")
    text = replace_exact(
        text,
        """  determine-publish-scope:
    name: determine build-tools publish scope
""",
        """  determine-publish-scope:
    name: determine build-tools publish scope
    # Same-repo PRs are built by build-push.yml exactly once. This standalone
    # PR path remains only for fork PRs, which cannot publish a candidate from
    # the main workflow but still need a local build-tools validation.
    if: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.id != github.event.repository.id }}
""",
        label="build-tools same-repo PR de-duplication",
    )
    path.write_text(text)


def patch_validate_stack_images() -> None:
    path = ROOT / "scripts/validate-stack-images.sh"
    text = path.read_text()
    text = replace_exact(
        text,
        "runtime_images=(proxy dns watchdog dhcp dhcp-proxy ui syslog)",
        "runtime_images=(proxy dns watchdog dhcp dhcp-proxy ntp ui syslog)",
        label="canonical runtime ntp coverage",
    )
    path.write_text(text)


def write_digest_override_helper() -> None:
    path = ROOT / "scripts/render-full-setup-digest-override.sh"
    if path.exists():
        fail(f"{path.relative_to(ROOT)} already exists")
    path.write_text(r'''#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# Render the full-setup compose override from immutable OCI digests. Digests
# already handed off by merge-manifests are consumed directly; only a service
# without a producer output (for example an untouched PR backfill) is resolved
# once from its event-unique staging tag and immediately pinned.
set -euo pipefail

output_file=${1:?output compose override path is required}
: "${REPOSITORY:?REPOSITORY is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"

# shellcheck source=scripts/lib/ghcr-retry.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ghcr-retry.sh"

resolve_digest() {
  local service=$1 supplied=$2 image digest
  if [[ "$supplied" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
    printf '%s\n' "$supplied"
    return 0
  fi
  image="ghcr.io/${REPOSITORY}/${service}:${IMAGE_TAG}"
  echo "::notice::No producer digest was exported for $service; resolving $image once and pinning the result for this validation run." >&2
  digest="$(ghcr_retry ghcr.io "${GHCR_RETRY_USERNAME:-}" "${GHCR_RETRY_PASSWORD:-}" -- docker buildx imagetools inspect "$image" --format '{{json .Manifest.Digest}}')"
  digest="${digest%\"}"; digest="${digest#\"}"
  [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { echo "::error::Could not resolve immutable digest for $image: '$digest'." >&2; exit 1; }
  printf '%s\n' "$digest"
}

proxy_digest="$(resolve_digest proxy "${PROXY_DIGEST:-}")"
dns_digest="$(resolve_digest dns "${DNS_DIGEST:-}")"
watchdog_digest="$(resolve_digest watchdog "${WATCHDOG_DIGEST:-}")"
ui_digest="$(resolve_digest ui "${UI_DIGEST:-}")"
build_tools_digest="$(resolve_digest build-tools "${BUILD_TOOLS_DIGEST:-}")"

mkdir -p "$(dirname "$output_file")"
cat > "$output_file" <<YAML
# Generated by scripts/render-full-setup-digest-override.sh for one CI run.
services:
  proxy:
    image: "ghcr.io/${REPOSITORY}/proxy@${proxy_digest}"
  dns-standard:
    image: "ghcr.io/${REPOSITORY}/dns@${dns_digest}"
  dns-ssl:
    image: "ghcr.io/${REPOSITORY}/dns@${dns_digest}"
  watchdog:
    image: "ghcr.io/${REPOSITORY}/watchdog@${watchdog_digest}"
  retention:
    image: "ghcr.io/${REPOSITORY}/watchdog@${watchdog_digest}"
  ui:
    image: "ghcr.io/${REPOSITORY}/ui@${ui_digest}"
YAML

printf 'ghcr.io/%s/build-tools@%s\n' "$REPOSITORY" "$build_tools_digest"
''')
    path.chmod(0o755)


def main() -> None:
    patch_build_tools_workflow()
    patch_validate_stack_images()
    patch_reserve_action()
    write_digest_override_helper()
    patch_main_workflow()
    print("ci-1.1 patcher: all guarded rewrites applied successfully")


if __name__ == "__main__":
    main()
