FROM appiriodevops/nginx-supply:latest

MAINTAINER Selva Umapathy "tumapathy@appirio.com"

RUN rm -rf /var/log/nginx/*.log && rm -rf /etc/nginx/nginx.conf && rm -rf /etc/nginx/sites-enabled && rm -rf /etc/nginx/includes
RUN mkdir -p /usr/local/nginx/cache && chown -Rf nginx:nginx /usr/local/nginx
RUN mkdir -p /var/log/nginx/logs && chown -Rf nginx:nginx /var/log/nginx
RUN mkdir -p /data/nginx

WORKDIR /data/docker-nginx-supply
RUN git pull
RUN chmod +x *.sh

CMD ./run.sh
