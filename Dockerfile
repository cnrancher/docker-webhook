FROM    golang:alpine3.11 AS build
WORKDIR /go/src/github.com/adnanh/webhook
ENV     WEBHOOK_VERSION 2.7.0

RUN     apk add --update -t build-deps curl libc-dev gcc libgcc
RUN     curl -L --silent -o webhook.tar.gz https://github.com/adnanh/webhook/archive/${WEBHOOK_VERSION}.tar.gz \
    &&  tar -xzf webhook.tar.gz --strip 1 \
    &&  go get -d \
    &&  go build -o /usr/local/bin/webhook \
    &&  apk del --purge build-deps \
    &&  rm -rf /var/cache/apk/* \
    &&  rm -rf /go

FROM    alpine:3.11

COPY    --from=build /usr/local/bin/webhook /usr/local/bin/webhook
COPY    start.sh monitoring.sh webhooks.sh /

RUN     apk add --no-cache curl wget vim bash jq inotify-tools net-tools tzdata \
    &&  chmod +x /start.sh /monitoring.sh /webhooks.sh \
    &&  mkdir -p /etc/webhook/source \
    &&  touch /etc/webhook/hooks.json \
    &&  cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    &&  apk del tzdata \
    &&  rm -rf /var/cache/apk/*

RUN     curl -LsS https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl -o /usr/local/bin/kubectl \
    &&  chmod +x /usr/local/bin/kubectl

VOLUME  /etc/webhook
WORKDIR /etc/webhook

EXPOSE  9000

ENTRYPOINT  ["/start.sh"]
