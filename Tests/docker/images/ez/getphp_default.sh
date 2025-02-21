#!/bin/sh

DEBIAN_VERSION=$(lsb_release -s -c)

if [ "${DEBIAN_VERSION}" = jessie ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        php5 \
        php5-cli \
        php5-curl \
        php5-gd \
        php5-intl \
        php5-json \
        php5-memcached \
        php5-mysql \
        php5-xsl
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        php \
        php-cli \
        php-curl \
        php-gd \
        php-intl \
        php-json \
        php-memcached \
        php-mbstring \
        php-mysql \
        php-xml
fi

php -v
