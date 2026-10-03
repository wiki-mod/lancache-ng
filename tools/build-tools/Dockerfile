
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# What: Alpine CI and developer validation toolchain.
# Why: One musl toolchain image builds the whole stack.
# From: Issue #1683

# What: Base image pin, consumed from the version SOT.
# Why: build-manifest.yml is the sole owner of the pin.
# From: Issue #1683
ARG ALPINE_IMAGE

# What: Reused ISC dhclient pin, from the version SOT.
# Why: Version, branch and per-arch digests owned centrally.
# From: Issue #1683
ARG DHCLIENT_VERSION
ARG DHCLIENT_ALPINE_BRANCH
ARG DHCLIENT_URL
ARG DHCLIENT_ARCH
ARG DHCLIENT_SHA256

# What: Alpine toolchain stage; scratch if no image arg.
# Why: no baked image; a missing arg fails the build.
# From: Issue #1683 | PR #1858
FROM ${ALPINE_IMAGE:-scratch}

LABEL org.opencontainers.image.description="Prebuilt lancache-ng CI and developer validation toolchain image (Alpine)."

# What: re-declare SOT build-args for use in this stage.
# Why: pre-FROM ARGs are not visible after FROM in Docker.
# From: Issue #1683
ARG DHCLIENT_VERSION
ARG DHCLIENT_ALPINE_BRANCH
ARG DHCLIENT_URL
ARG DHCLIENT_ARCH
ARG DHCLIENT_SHA256

# What: uses plain /bin/sh for the apk-install step only.
# Why: the alpine base has no bash until apk installs it.
# From: Issue #1095
SHELL ["/bin/sh", "-c"]

ENV PATH="/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    RUST_BACKTRACE=1

# What: build identity keys the cache of later layers.
# Why: a new package set must not reuse a stale apk layer.
# From: Issue #1683 | PR #1858
ARG BUILD_IDENTITY

# What: the apk package list, supplied from the SOT.
# Why: the SOT owns the list; this stage only consumes it.
# From: Issue #1683
ARG APK_PACKAGES

# What: tagged apk repos and repo keys from the SOT.
# Why: the SOT owns URL and key pin; this stage adds them.
# From: Issue #1683 | PR #1858
ARG APK_TAGGED_REPOS
ARG APK_KEYS

# What: bootstrap bash for ci.sh apk-setup.
# Why: the alpine base has no bash; ci.sh needs it.
# From: Issue #1683 | PR #1858
RUN apk add --no-cache bash

# What: shared package setup via ci.sh.
# Why: ci.sh owns repos, proxy CA, update+upgrade, add.
# From: Issue #1683 | PR #1858
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    --mount=type=secret,id=project_selfhosted_proxy_ca \
    bash /usr/local/bin/ci.sh apk-setup ${APK_PACKAGES}

# What: install the SOT-pinned ISC dhclient apk via ci.sh.
# Why: newer Alpine dropped it; ci.sh owns fetch + verify.
# From: Issue #1683 | PR #1858
RUN --mount=type=bind,from=ci-scripts,source=ci.sh,target=/usr/local/bin/ci.sh \
    bash /usr/local/bin/ci.sh apk-pin-install "${DHCLIENT_URL}" "${DHCLIENT_VERSION}" \
      "${DHCLIENT_ALPINE_BRANCH}" "${DHCLIENT_ARCH}" "${DHCLIENT_SHA256}"

WORKDIR /workspace

CMD ["bash"]
