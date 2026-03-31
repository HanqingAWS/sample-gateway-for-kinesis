FROM openresty/openresty:1.25.3.2-alpine

# Install lua-resty-http v0.17.2 (stable release, all files)
RUN apk add --no-cache curl && \
    mkdir -p /usr/local/openresty/site/lualib/resty && \
    cd /tmp && \
    curl -fSL https://github.com/ledgetech/lua-resty-http/archive/refs/tags/v0.17.2.tar.gz -o lua-resty-http.tar.gz && \
    tar xzf lua-resty-http.tar.gz && \
    cp lua-resty-http-0.17.2/lib/resty/*.lua /usr/local/openresty/site/lualib/resty/ && \
    rm -rf /tmp/lua-resty-http* && \
    apk del curl

# Copy configuration
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# Create lua directory and copy Lua scripts
RUN mkdir -p /etc/nginx/lua
COPY collect.lua /etc/nginx/lua/collect.lua

EXPOSE 8080

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
