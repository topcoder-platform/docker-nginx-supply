#!/bin/bash
IMAGE_NAME="nginx-www:latest"
CONTAINER_ID=`docker ps | grep "$IMAGE_NAME" | awk '{ print $1 }'`

# Executes $1 on the container and if $2 is passed, the result is stored in that variable
function docker_exec {
  print "Executing on $CONTAINER_ID: $1"

  EXECUTION_STRING="docker exec $CONTAINER_ID $1"
  eval result="\`${EXECUTION_STRING}\`"

  if [ -n "$2" ]
  then
    eval "$2=\$result"
  fi
}

function print { # This is better than echo because it doesn't eat tabs or condense spaces in various circumstances
  printf '%s\n' "$1"
}

docker_exec "ps -ef | grep nginx | grep master | awk '{print \$2}'" NGINX_MASTER_PID

docker_exec "kill -HUP $NGINX_MASTER_PID"