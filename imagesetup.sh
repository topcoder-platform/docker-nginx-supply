#!/bin/bash
adduser --system --no-create-home --group nginx
mkdir -p /data/nginx
cd /data
apt-get update
apt-get -y install wget git gcc zlib1g-dev libpcre3 libpcre3-dev make openssl libssl1.0.0 libssl-dev chkconfig
wget http://nginx.org/download/nginx-1.9.7.tar.gz
tar xzvf nginx-1.9.7.tar.gz
git clone https://github.com/yaoweibin/nginx_ajp_module.git
cd nginx-1.9.7
./configure --user=nginx --group=nginx --prefix=/etc/nginx --sbin-path=/usr/sbin/nginx --conf-path=/etc/nginx/nginx.conf --pid-path=/var/run/nginx.pid --lock-path=/var/run/nginx.lock --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log --with-http_gzip_static_module --with-http_stub_status_module --with-http_ssl_module --with-pcre --with-file-aio --with-http_realip_module --without-http_scgi_module --without-http_uwsgi_module --without-http_fastcgi_module --add-module=/data/nginx_ajp_module
make
make install
nginx -V

