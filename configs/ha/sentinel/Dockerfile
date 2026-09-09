FROM redis:7.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY ./configs/ha/entrypoint.sh /usr/local/bin/reluster-entrypoint.sh
COPY ./configs/ha/sentinel/sentinel.conf /etc/redis/sentinel.conf.template

RUN chmod +x /usr/local/bin/reluster-entrypoint.sh

ENV REDIS_CONFIG_TEMPLATE=/etc/redis/sentinel.conf.template \
    REDIS_CONFIG_FILE=/data/sentinel.conf

ENTRYPOINT ["/usr/local/bin/reluster-entrypoint.sh"]
CMD ["redis-server", "/data/sentinel.conf", "--sentinel"]
