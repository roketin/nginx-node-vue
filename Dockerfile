FROM node:8.11.3-alpine

# ensure local python is preferred over distribution python
ENV PATH /usr/local/bin:$PATH

# http://bugs.python.org/issue19846
# > At the moment, setting "LANG=C" on a Linux system *fundamentally breaks Python 3*, and that's not OK.
ENV LANG C.UTF-8

ENV NGINX_VERSION 1.13.1

RUN GPG_KEYS=B0F4253373F8F6F510D42178520A9993A1C052F8
RUN CONFIG="\
		--prefix=/etc/nginx \
		--sbin-path=/usr/sbin/nginx \
		--modules-path=/usr/lib/nginx/modules \
		--conf-path=/etc/nginx/nginx.conf \
		--error-log-path=/var/log/nginx/error.log \
		--http-log-path=/var/log/nginx/access.log \
		--pid-path=/var/run/nginx.pid \
		--lock-path=/var/run/nginx.lock \
		--http-client-body-temp-path=/var/cache/nginx/client_temp \
		--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
		--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
		--http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
		--http-scgi-temp-path=/var/cache/nginx/scgi_temp \
		--user=nginx \
		--group=nginx \
		--with-http_ssl_module \
		--with-http_realip_module \
		--with-http_addition_module \
		--with-http_sub_module \
		--with-http_dav_module \
		--with-http_flv_module \
		--with-http_mp4_module \
		--with-http_gunzip_module \
		--with-http_gzip_static_module \
		--with-http_random_index_module \
		--with-http_secure_link_module \
		--with-http_stub_status_module \
		--with-http_auth_request_module \
		--with-http_xslt_module=dynamic \
		--with-http_image_filter_module=dynamic \
		--with-http_geoip_module=dynamic \
		--with-threads \
		--with-stream \
		--with-stream_ssl_module \
		--with-stream_ssl_preread_module \
		--with-stream_realip_module \
		--with-stream_geoip_module=dynamic \
		--with-http_slice_module \
		--with-mail \
		--with-mail_ssl_module \
		--with-compat \
		--with-file-aio \
		--with-http_v2_module \
	" 
RUN addgroup -S nginx
RUN adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx
RUN apk add --no-cache --virtual .build-deps \
		gcc \
		libc-dev \
		make \
		openssl-dev \
		pcre-dev \
		zlib-dev \
		linux-headers \
		curl \
		gnupg \
		libxslt-dev \
		gd-dev \
		geoip-dev
RUN curl -fSL http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz -o nginx.tar.gz \
RUN curl -fSL http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz.asc  -o nginx.tar.gz.asc \
RUN export GNUPGHOME="$(mktemp -d)" \
RUN found=''; \
	for server in \
		ha.pool.sks-keyservers.net \
		hkp://keyserver.ubuntu.com:80 \
		hkp://p80.pool.sks-keyservers.net:80 \
		pgp.mit.edu \
	; do \
		echo "Fetching GPG key $GPG_KEYS from $server"; \
		gpg --keyserver "$server" --keyserver-options timeout=10 --recv-keys "$GPG_KEYS" && found=yes && break; \
	done; \
	test -z "$found" && echo >&2 "error: failed to fetch GPG key $GPG_KEYS" && exit 1; \
	gpg --batch --verify nginx.tar.gz.asc nginx.tar.gz
RUN rm -r "$GNUPGHOME" nginx.tar.gz.asc
RUN mkdir -p /usr/src
RUN tar -zxC /usr/src -f nginx.tar.gz
RUN rm nginx.tar.gz
RUN cd /usr/src/nginx-$NGINX_VERSION
RUN ./configure $CONFIG --with-debug
RUN make -j$(getconf _NPROCESSORS_ONLN)
RUN mv objs/nginx objs/nginx-debug
RUN mv objs/ngx_http_xslt_filter_module.so objs/ngx_http_xslt_filter_module-debug.so
RUN mv objs/ngx_http_image_filter_module.so objs/ngx_http_image_filter_module-debug.so
RUN mv objs/ngx_http_geoip_module.so objs/ngx_http_geoip_module-debug.so
RUN mv objs/ngx_stream_geoip_module.so objs/ngx_stream_geoip_module-debug.so
RUN ./configure $CONFIG
RUN make -j$(getconf _NPROCESSORS_ONLN)
RUN make install
RUN rm -rf /etc/nginx/html/
RUN mkdir /etc/nginx/conf.d/
RUN mkdir -p /usr/share/nginx/html/
RUN mkdir -p /var/log/supervisor
RUN install -m644 html/index.html /usr/share/nginx/html/
RUN install -m644 html/50x.html /usr/share/nginx/html/
RUN install -m755 objs/nginx-debug /usr/sbin/nginx-debug
RUN install -m755 objs/ngx_http_xslt_filter_module-debug.so /usr/lib/nginx/modules/ngx_http_xslt_filter_module-debug.so
RUN install -m755 objs/ngx_http_image_filter_module-debug.so /usr/lib/nginx/modules/ngx_http_image_filter_module-debug.so
RUN install -m755 objs/ngx_http_geoip_module-debug.so /usr/lib/nginx/modules/ngx_http_geoip_module-debug.so
RUN install -m755 objs/ngx_stream_geoip_module-debug.so /usr/lib/nginx/modules/ngx_stream_geoip_module-debug.so
RUN ln -s ../../usr/lib/nginx/modules /etc/nginx/modules
RUN strip /usr/sbin/nginx*
RUN strip /usr/lib/nginx/modules/*.so
RUN rm -rf /usr/src/nginx-$NGINX_VERSION

	# Bring in gettext so we can get `envsubst`, then throw
	# the rest away. To do this, we need to install `gettext`
	# then move `envsubst` out of the way so `gettext` can
	# be deleted completely, then move `envsubst` back.
RUN apk add --no-cache --virtual .gettext gettext
RUN mv /usr/bin/envsubst /tmp/

RUN runDeps="$( \
		scanelf --needed --nobanner /usr/sbin/nginx /usr/lib/nginx/modules/*.so /tmp/envsubst \
			| awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
			| sort -u \
			| xargs -r apk info --installed \
			| sort -u \
	)"
RUN apk add --no-cache --virtual .nginx-rundeps $runDeps
RUN apk del .build-deps
RUN apk del .gettext
RUN mv /tmp/envsubst /usr/local/bin/

	# forward request and error logs to docker log collector
RUN ln -sf /dev/stdout /var/log/nginx/access.log
RUN ln -sf /dev/stderr /var/log/nginx/error.log
RUN mkdir -p /etc/letsencrypt/webrootauth 

# install ca-certificates so that HTTPS works consistently
# the other runtime dependencies for Python are installed later
RUN echo @testing http://nl.alpinelinux.org/alpine/edge/testing >> /etc/apk/repositories && \
    echo /etc/apk/respositories && \
    apk update && apk upgrade && \
    apk add --no-cache \
    bash \
    openssh-client \
    wget \
    supervisor \
    curl \
    libcurl \
    git \
    python \
    python-dev \
    py-pip \
    ca-certificates \
    dialog \
    autoconf \
    make \
    gcc 

# Add Scripts
ADD scripts/start.sh /start.sh
ADD scripts/pull /usr/bin/pull
ADD scripts/push /usr/bin/push
ADD scripts/letsencrypt-setup /usr/bin/letsencrypt-setup
ADD scripts/letsencrypt-renew /usr/bin/letsencrypt-renew
RUN chmod 755 /usr/bin/pull && chmod 755 /usr/bin/push && chmod 755 /usr/bin/letsencrypt-setup && chmod 755 /usr/bin/letsencrypt-renew && chmod 755 /start.sh

ADD conf/supervisord.conf /etc/supervisord.conf

COPY conf/nginx.conf /etc/nginx/nginx.conf
# COPY conf/nginx.vh.default.conf /etc/nginx/conf.d/default.conf
COPY conf/nginx.vh.default.template /etc/nginx/conf.d/default.template

# copy in code
ADD src/ /var/www/html/
ADD errors/ /var/www/errors

EXPOSE 80

STOPSIGNAL SIGTERM

# install global dependencies
RUN npm i -g flow-bin flow-typed

WORKDIR "/var/www/html"

CMD ["/start.sh"]