FROM appiriodevops/nginx:latest
RUN  rm -rf /var/log/nginx/*.log
RUN  chown -Rf nginx:nginx /var/cache/nginx
RUN  mkdir -p /usr/local/nginx/cache && chown -Rf nginx:nginx /usr/local/nginx
RUN  mkdir -p /var/log/nginx/logs && chown -Rf nginx:nginx /var/log/nginx
RUN  mkdir -p /var/cache/nginx && chown -RF nginx:nginx /var/cache/nginx

USER nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY sites-enabled /etc/nginx/sites-enabled
COPY includes /etc/nginx/includes
