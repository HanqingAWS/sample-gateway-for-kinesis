FROM timberio/vector:0.43.1-alpine

COPY vector.toml /etc/vector/vector.toml

VOLUME /var/lib/vector

EXPOSE 8686

ENTRYPOINT ["vector"]
CMD ["--config", "/etc/vector/vector.toml"]
