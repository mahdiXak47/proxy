# syntax=docker/dockerfile:1
#
# x-ui panel image for this relay.
#
# WHY A CUSTOM IMAGE AT ALL:
# upstream alireza7/x-ui:1.10.2 ships WITHOUT sqlite3, but every config-management
# script in this repo talks to the panel's SQLite database through
# `docker exec x-ui sqlite3 ...` (apply-xray-template.sh, backup-db.sh). Without
# sqlite3 in the image there is no way to install a reviewed Xray template or take
# a consistent backup, so the whole git-controlled workflow collapses.
#
# Pinned by digest, not just tag: a tag can be repointed at new content, a digest
# cannot. Verify/refresh with:
#   docker buildx imagetools inspect alireza7/x-ui:1.10.2
#
# NOTE: upstream publishes linux/amd64 ONLY. On an arm64 host you must build and
# run with --platform linux/amd64 (qemu). Production edge hosts are amd64.
FROM alireza7/x-ui:1.10.2@sha256:a01742aa2f74768fb35599634b1c2afe4bc1b3a9645bde1899cf591eda32c385

# Upstream base is Alpine 3.23.
# sqlite  -> required: config apply + DB snapshots/backups
# tzdata  -> required: correct timestamps for traffic accounting and client expiry
# curl    -> in-container health/debug probes without installing anything live
# jq      -> validate/inspect the rendered Xray template in place
# tini    -> real PID 1: reaps zombies and forwards SIGTERM so restarts are clean
RUN apk add --no-cache \
      sqlite \
      tzdata \
      curl \
      jq \
      tini \
 && rm -rf /var/cache/apk/* \
 && sqlite3 --version \
 && echo "sqlite3 available in image"

WORKDIR /app

# The panel keeps x-ui.db plus the certs it is pointed at here.
VOLUME ["/etc/x-ui"]

ENV TZ=Asia/Tehran \
    XUI_ENABLE_FAIL2BAN=true

# Panel + inbound ports are published via host networking in docker-compose.yml;
# EXPOSE is documentation only.
EXPOSE 443/tcp 2053/tcp

# Fail the container when either process dies, so Docker restarts it instead of
# leaving a half-dead panel that accepts connections but proxies nothing.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD pgrep x-ui >/dev/null && pgrep xray >/dev/null || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["./x-ui"]
