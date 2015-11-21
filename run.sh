#!/bin/bash -x
git pull && git checkout $ENV && git pull

cp -r dist/nginx.conf /data/nginx/nginx.conf
cp -r dist/limits.conf /data/nginx/limits.conf
cp -r dist/sites-enabled /data/nginx/sites-enabled
cp -r dist/includes /data/nginx/includes
ln -s /data/nginx/nginx.conf /etc/nginx/nginx.conf
ln -s /data/nginx/limits.conf /etc/nginx/limits.conf
ln -s /data/nginx/sites-enabled /etc/nginx/sites-enabled
ln -s /data/nginx/includes /etc/nginx/includes

sh build.sh

nginx -t && nginx && tail -f /dev/null