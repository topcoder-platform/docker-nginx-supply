#!/bin/bash

mkdir /var/log/nginx
mkdir /var/log/nginx/logs
touch /var/log/nginx/logs/access.log
touch /var/log/nginx/logs/error.log

mkdir /etc/le
cp logentries.config /etc/le/config
sed -i "s/{{user-key}}/`cat /tmp/logentries.key`/g" /etc/le/config

le follow /var/log/nginx/logs/access.log
le follow /var/log/nginx/logs/error.log
service logentries restart
