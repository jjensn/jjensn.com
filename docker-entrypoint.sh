#!/bin/sh

git clone https://github.com/jjensn/jjensn.com.git -b master /usr/src/site || echo "git failed" ;
if [[ ! -z "${DEPLOY_ENV}" ]]; then
cp -prvf /development/_posts/*.md /usr/src/site/_posts/; cp -prvf /development/assets.css /usr/src/site/; cp -prvf /development/assets.js /usr/src/site/
fi
bundle install;
exec "$@"