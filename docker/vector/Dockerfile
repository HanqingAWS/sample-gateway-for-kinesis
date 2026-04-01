FROM timberio/vector:0.43.1-alpine

COPY vector.toml /etc/vector/vector.toml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME /var/lib/vector

EXPOSE 8686

ENTRYPOINT ["/entrypoint.sh"]
