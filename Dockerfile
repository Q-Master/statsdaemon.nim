# builder img
FROM debian:stable-slim as statsd-builder
RUN apt update && \
    apt install --no-install-recommends -y curl xz-utils gcc g++ openssl ca-certificates git && \
    curl https://nim-lang.org/choosenim/init.sh -sSf | bash -s -- -y && \
    apt -y autoremove && apt -y clean && rm -r /tmp/*
WORKDIR /projects/
ENV PATH="/root/.nimble/bin:$PATH"
COPY statsdaemon.* ./
COPY src ./src
WORKDIR /projects/
RUN nimble build -d:release -l:"-flto" -t:"-flto" --opt:size --threads:on
RUN objcopy --strip-all -R .comment -R .comments  statsdaemon


# main img
FROM debian:stable-slim as release
WORKDIR /opt
COPY --from=statsd-builder /projects/statsdaemon ./
COPY statsd.ini ./
VOLUME ["/opt/statsd.ini"]
ENTRYPOINT ["./statsdaemon"]
