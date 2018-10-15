#!/bin/sh

git clone $JEKYLL_REPO -b $JEKYLL_BRANCH /usr/src/site || echo "git failed" ;
bundle install;
exec "$@"