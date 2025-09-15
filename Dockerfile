FROM lscr.io/linuxserver/wireguard:latest

ENV PUID=1000
ENV PGID=1000
ENV PEER_ID=1000
ENV SERVERURL=1.1.1.1
ENV SERVERPORT=51821
ENV INTERNAL_SUBNET=10.0.2.1
ENV LOG_CONFS=true

COPY ./wireguard-entrypoint.sh /config/wireguard-entrypoint.sh
COPY ./templates /config/templates

EXPOSE 51821:51821/udp

ENTRYPOINT ["/bin/bash"]

CMD ["/config/wireguard-entrypoint.sh"]