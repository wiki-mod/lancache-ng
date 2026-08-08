# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Immutable metadata carrier for an accepted stack lock and its final gate record.
FROM scratch

ARG SOURCE_SHA
LABEL org.opencontainers.image.title="lancache-ng accepted stack lock" \
      org.opencontainers.image.revision="${SOURCE_SHA}" \
      io.lancache-ng.stack.accepted="true"

COPY stack-lock.json /stack-lock.json
COPY acceptance.json /acceptance.json

# A command is present so `docker create` can materialize the image for
# `docker cp`; the file is metadata and is never executed.
CMD ["/stack-lock.json"]
