#!/bin/sh

pwd && git clone https://github.com/jjensn/jjensn.com.git -b master /usr/src/site || echo "git failed" ;
bundle install;
exec "$@"