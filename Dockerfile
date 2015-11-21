FROM appiriodevops/nginx-supply:latest

MAINTAINER Selva Umapathy "tumapathy@appirio.com"

RUN rm -rf /var/log/nginx/*.log && rm -rf /etc/nginx/nginx.conf && rm -rf /etc/nginx/sites-enabled && rm -rf /etc/nginx/includes
RUN mkdir -p /usr/local/nginx/cache && chown -Rf nginx:nginx /usr/local/nginx
RUN mkdir -p /var/log/nginx/logs && chown -Rf nginx:nginx /var/log/nginx
RUN mkdir -p /data/nginx

WORKDIR /data/docker-nginx-supply

RUN git pull && git checkout $ENV && git pull

COPY dist/nginx.conf /data/nginx/nginx.conf
COPY dist/limits.conf /data/nginx/limits.conf
COPY dist/sites-enabled /data/nginx/sites-enabled
COPY dist/includes /data/nginx/includes

RUN ln -s /data/nginx/nginx.conf /etc/nginx/nginx.conf
RUN ln -s /data/nginx/limits.conf /etc/nginx/limits.conf
RUN ln -s /data/nginx/sites-enabled /etc/nginx/sites-enabled
RUN ln -s /data/nginx/includes /etc/nginx/includes
RUN chmod +x *.sh

CMD ./run.sh
