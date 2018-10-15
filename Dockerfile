FROM ruby:2.5-alpine

ARG repo
ARG branch
ARG PORT=80

ENV JEKYLL_REPO=https://github.com/jjensn/jjensn.com.git
ENV JEKYLL_BRANCH=master
ENV PORT=80

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
CMD ["sh", "-c", "bundle exec jekyll serve -H 0.0.0.0 -P 80" ]