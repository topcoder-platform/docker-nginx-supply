FROM nginx:1.9.6

COPY nginx.conf /etc/nginx/nginx.conf
COPY sites-enabled /etc/nginx/sites-enabled
COPY includes /etc/nginx/includes
RUN  mkdir -p /usr/local/nginx/cache && chown -Rf nginx:nginx /usr/local/nginx
RUN  mkdir -p /var/log/nginx/logs && chown -Rf nginx:nginx /var/log/nginx