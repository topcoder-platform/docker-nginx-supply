FROM appiriodevops/nginx:latest

RUN  rm -rf /var/log/nginx/*.log && rm -rf /etc/nginx/nginx.conf && rm -rf /etc/nginx/sites-enabled && rm -rf /etc/nginx/includes
RUN  mkdir -p /usr/local/nginx/cache && chown -Rf nginx:nginx /usr/local/nginx
RUN  mkdir -p /var/log/nginx/logs && chown -Rf nginx:nginx /var/log/nginx
RUN  mkdir -p /data/nginx

COPY nginx.conf /data/nginx/nginx.conf
COPY sites-enabled /data/nginx/sites-enabled
COPY includes /data/nginx/includes

RUN ln -s /data/nginx/nginx.conf /etc/nginx/nginx.conf
RUN ln -s /data/nginx/sites-enabled /etc/nginx/sites-enabled
RUN ln -s /data/nginx/includes /etc/nginx/includes

CMD nginx -t && nginx && tail -f /dev/null
