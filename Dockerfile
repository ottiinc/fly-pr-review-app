FROM alpine

RUN apk add --no-cache \
  bash \
  curl \
  jq

RUN curl -LSs https://fly.io/install.sh | FLYCTL_INSTALL=/usr/local sh

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
