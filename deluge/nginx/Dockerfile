FROM alpine:3.23

RUN apk add --no-cache openssl curl ca-certificates \
    && echo '@nginx https://nginx.org/packages/mainline/alpine/v3.23/main' >> /etc/apk/repositories \
    && curl -fsSL https://nginx.org/keys/nginx_signing.rsa.pub \
       -o /etc/apk/keys/nginx_signing.rsa.pub \
    && apk add --no-cache nginx@nginx nginx-module-acme@nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d /etc/nginx/conf.d

RUN mkdir -p /var/cache/nginx/acme/state /www \
    && chown -R 101:101 /var/cache/nginx/acme \
    && chmod 700 /var/cache/nginx/acme/state \
    && rm -f /etc/nginx/conf.d/default.conf

STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
