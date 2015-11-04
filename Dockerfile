FROM appiriodevops/nginx:latest

RUN  rm -rf /var/log/nginx/*.log
RUN  mkdir -p /usr/local/nginx/cache && chown -Rf nginx:nginx /usr/local/nginx
RUN  mkdir -p /var/log/nginx/logs && chown -Rf nginx:nginx /var/log/nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY sites-enabled /etc/nginx/sites-enabled
COPY includes /etc/nginx/includes
