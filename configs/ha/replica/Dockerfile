FROM redis:7.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY ./configs/ha/entrypoint.sh /usr/local/bin/reluster-entrypoint.sh
COPY ./configs/ha/role-discovery.sh /usr/local/lib/reluster/role-discovery.sh
COPY ./configs/ha/replica/redis.conf /etc/redis/redis.conf.template

RUN chmod +x /usr/local/bin/reluster-entrypoint.sh \
    && chmod 0644 /usr/local/lib/reluster/role-discovery.sh

ENV REDIS_CONFIG_TEMPLATE=/etc/redis/redis.conf.template \
    REDIS_CONFIG_FILE=/data/redis.conf

ENTRYPOINT ["/usr/local/bin/reluster-entrypoint.sh"]
CMD ["redis-server", "/data/redis.conf"]
