FROM ruby:2.5-alpine

ARG repo
ARG branch
ARG PORT=80

ENV JEKYLL_REPO=${repo}
ENV JEKYLL_BRANCH=${branch}
ENV PORT=${PORT}

RUN apk update && apk upgrade && \
    apk add --no-cache git openssh build-base gcc bash cmake

RUN gem install jekyll

EXPOSE ${PORT}

RUN git --version

COPY ./docker-entrypoint.sh /usr/local/bin
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
RUN mkdir /usr/src/site
WORKDIR /usr/src/site
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["sh", "-c", "bundle exec jekyll serve -H 0.0.0.0 -P ${PORT}" ]