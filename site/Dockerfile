FROM alpine:3.22.2 AS build

# Setup Zig
ARG ZIG_VER=0.15.2
RUN apk add --no-cache curl xz
RUN curl https://ziglang.org/download/${ZIG_VER}/zig-$(uname -m)-linux-${ZIG_VER}.tar.xz -o zig.tar.xz && \
tar xf zig.tar.xz && \
mv zig-$(uname -m)-linux-${ZIG_VER}/ /opt/zig

# Build the app
WORKDIR /build
COPY . .

RUN /opt/zig/zig build -Doptimize=ReleaseFast -Dcpu=baseline

# Run the app
FROM alpine:3.22.2
COPY --from=build /build/zig-out/bin/zx_site /zx_site

ENTRYPOINT ["/zx_site"]

