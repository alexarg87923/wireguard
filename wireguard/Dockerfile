FROM lscr.io/linuxserver/wireguard:latest

COPY ./wireguard-entrypoint.sh /config/wireguard-entrypoint.sh
COPY ./templates /config/templates

ENTRYPOINT ["/bin/bash"]

CMD ["/config/wireguard-entrypoint.sh"]