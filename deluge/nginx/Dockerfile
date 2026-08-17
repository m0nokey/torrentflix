FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# renovate: datasource=repology depName=alpine_3_23/nginx versioning=loose
ARG NGINX_PACKAGE_VERSION=1.31.3-r1
# renovate: datasource=repology depName=alpine_3_23/nginx-module-acme versioning=loose
ARG NGINX_ACME_PACKAGE_VERSION=1.31.3.0.4.1-r1

RUN apk add --no-cache openssl curl ca-certificates \
    && echo '@nginx https://nginx.org/packages/mainline/alpine/v3.23/main' >> /etc/apk/repositories \
    && curl -fsSL https://nginx.org/keys/nginx_signing.rsa.pub \
       -o /etc/apk/keys/nginx_signing.rsa.pub \
    && echo 'ff7cf138acc09f2a5029300ab713fe6a1440605fca72e2bab76a4da9206fec87  /etc/apk/keys/nginx_signing.rsa.pub' | sha256sum -c - \
    && apk add --no-cache \
       nginx@nginx=${NGINX_PACKAGE_VERSION} \
       nginx-module-acme@nginx=${NGINX_ACME_PACKAGE_VERSION}

COPY nginx.conf /etc/nginx/nginx.conf

RUN mkdir -p /var/cache/nginx/acme/state /www /etc/nginx/conf.d \
    && chown -R 101:101 /var/cache/nginx/acme \
    && chmod 700 /var/cache/nginx/acme/state \
    && rm -f /etc/nginx/conf.d/default.conf

STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
