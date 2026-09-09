FROM redis:7.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY ./configs/ha/entrypoint.sh /usr/local/bin/reluster-entrypoint.sh
COPY ./configs/ha/replica/slave.conf /etc/redis/redis.conf.template

RUN chmod +x /usr/local/bin/reluster-entrypoint.sh

ENV REDIS_CONFIG_TEMPLATE=/etc/redis/redis.conf.template \
    REDIS_CONFIG_FILE=/etc/redis/redis.conf

ENTRYPOINT ["/usr/local/bin/reluster-entrypoint.sh"]
CMD ["redis-server", "/etc/redis/redis.conf"]
