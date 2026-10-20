FROM alpine:3.24
RUN apk add --no-cache iperf3 busybox-extras fio git build-base zlib-dev inotify-tools
