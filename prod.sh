#!/bin/bash
# usage: ./prod.sh [docker-compose SUBCOMMAND: up, down, ...]

# make sure ARENA-core/conf folder exists
[ ! -d "ARENA-core/conf" ] && mkdir ARENA-core/conf

# copy arena client defaults
cp ./conf/arena-web-conf/arena-defaults.js ./conf/arena-web-conf/defaults.js
cp ./conf/arena-web-conf/arena-defaults.json ./conf/arena-web-conf/defaults.json
cat version.env > ./conf/arena-web-conf/versions.txt

# force static volumes to be created again on "up"
if [[ "$*" == *up* ]]
then
    #docker volume rm arena-services-docker_arts-static-content
    docker volume rm arena-services-docker_account-static-content
fi

docker-compose -f docker-compose.yaml -f docker-compose.prod.yaml --env-file version.env $@
