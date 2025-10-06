# syntax=docker/dockerfile:1
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl socat \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/hiddify

COPY HiddifyCli ./HiddifyCli
COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

EXPOSE 12334

ENTRYPOINT ["/opt/hiddify/entrypoint.sh"]
CMD ["run"]
