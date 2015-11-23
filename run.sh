#!/bin/bash -x
git pull && git checkout $ENV && git pull

cp -r /data/docker-nginx-supply/src/nginx.conf /data/nginx/
cp -r /data/docker-nginx-supply/src/limits.conf /data/nginx/
cp -r /data/docker-nginx-supply/src/sites-enabled /data/nginx/
cp -r /data/docker-nginx-supply/src/includes /data/nginx/

ln -s /data/nginx/nginx.conf /etc/nginx/nginx.conf
ln -s /data/nginx/limits.conf /etc/nginx/limits.conf
ln -s /data/nginx/sites-enabled /etc/nginx/sites-enabled
ln -s /data/nginx/includes /etc/nginx/includes

./build.sh

chown -Rf nginx:nginx /data/nginx

nginx -t && nginx && tail -f /dev/null