FROM 811668436784.dkr.ecr.us-east-1.amazonaws.com/nginx-supply:base

LABEL app="nginx-supply" version="1.0"

RUN rm -rf /var/log/nginx/*.log && rm -rf /etc/nginx/nginx.conf && rm -rf /etc/nginx/sites-enabled && rm -rf /etc/nginx/includes && rm -rf /data/nginx/dist && rm -rf /data/nginx/*
RUN mkdir -p /usr/local/nginx/cache && chown -Rf nginx:nginx /usr/local/nginx
RUN mkdir -p /var/log/nginx/logs && chown -Rf nginx:nginx /var/log/nginx

COPY dist /data/nginx/dist
COPY run /data/nginx/

RUN ln -s /data/nginx/dist/nginx.conf /etc/nginx/nginx.conf
RUN ln -s /data/nginx/dist/limits.conf /etc/nginx/limits.conf
RUN ln -s /data/nginx/dist/sites-enabled /etc/nginx/sites-enabled
RUN ln -s /data/nginx/dist/includes /etc/nginx/includes

RUN chown -Rf nginx:nginx /data/nginx/dist

WORKDIR /data/nginx

CMD ./run

