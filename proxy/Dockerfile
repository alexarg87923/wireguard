FROM alpine:latest

RUN apk add --no-cache \
    redsocks \
    iptables \
    bash \
    curl

RUN mkdir -p /etc/redsocks

COPY redsocks.conf /etc/redsocks/redsocks.conf

COPY proxy-entrypoint.sh /proxy-entrypoint.sh

RUN chmod +x /proxy-entrypoint.sh

ENTRYPOINT ["/bin/bash"]

CMD ["/proxy-entrypoint.sh"]