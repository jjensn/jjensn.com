FROM ruby:2.5-alpine

RUN apk update && apk upgrade && \
    apk add --no-cache git openssh build-base gcc bash cmake

RUN gem install jekyll

EXPOSE 80

RUN git --version

COPY ./docker-entrypoint.sh /usr/local/bin
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
RUN mkdir /usr/src/site
WORKDIR /usr/src/site
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["sh", "-c", "JEKYLL_ENV=production bundle exec jekyll build && cp -prvf /usr/src/site/_site/*.html /export/; cp -prvf /usr/src/site/_site/*.md /export/; cp -prvf /usr/src/site/_site/*.css /export/; cp -prvf /usr/src/site/_site/*.js /export/; cp -prvf assets /export/; rm -rf /usr/src/site" ]