FROM lscr.io/linuxserver/wireguard:latest

ENV PUID=1000
ENV PGID=1000
ENV PEERS=0
ENV INTERNAL_SUBNET=10.0.2.1
ENV LOG_CONFS=false
ENV ALLOWEDIPS=10.0.2.2/32

COPY ./wireguard-entrypoint.sh /config/wireguard-entrypoint.sh
COPY ./server.conf /config/templates/server.conf

EXPOSE 51821:51821/udp

ENTRYPOINT ["/bin/bash"]

CMD ["/config/wireguard-entrypoint.sh"]