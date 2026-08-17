FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

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
