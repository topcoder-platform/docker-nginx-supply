#!/bin/bash
kill -HUP `ps -ef | grep nginx | grep master | awk '{print $2}'`