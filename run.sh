#!/bin/bash -x
git pull && git checkout $ENV && git pull

cp -r /data/docker-nginx-supply/nginx.conf /data/nginx/nginx.conf
cp -r /data/docker-nginx-supply/nginx.conf /data/nginx/limits.conf
cp -r /data/docker-nginx-supply/nginx.conf /data/nginx/sites-enabled
cp -r /data/docker-nginx-supply/nginx.conf /data/nginx/includes
ln -s /data/nginx/nginx.conf /etc/nginx/nginx.conf
ln -s /data/nginx/limits.conf /etc/nginx/limits.conf
ln -s /data/nginx/sites-enabled /etc/nginx/sites-enabled
ln -s /data/nginx/includes /etc/nginx/includes

./build.sh

nginx -t && nginx && tail -f /dev/null