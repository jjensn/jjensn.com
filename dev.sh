#/bin/bash

docker-compose build && DEPLOY_ENV=1 docker-compose up