FROM alpine:3.22.2 AS build

# Setup Zig
ARG ZIG_VER=0.15.2
RUN apk add --no-cache curl xz
RUN curl https://ziglang.org/download/${ZIG_VER}/zig-$(uname -m)-linux-${ZIG_VER}.tar.xz -o zig.tar.xz && \
tar xf zig.tar.xz && \
mv zig-$(uname -m)-linux-${ZIG_VER}/ /opt/zig

# Build the app
WORKDIR /build

COPY site/ ./site
COPY src/ ./src

COPY build.zig.zon ./build.zig.zon
COPY build.zig ./build.zig

COPY bundle/public ./public
COPY bundle/assets ./assets

RUN /opt/zig/zig build $BUILD_ARGS -Doptimize=ReleaseFast -Dcpu=baseline

# Run the app
FROM alpine:3.22.2

COPY --from=build /build/zig-out/bin/$BIN_NAME /app/$BIN_NAME

COPY --from=build /build/public /app/public
COPY --from=build /build/assets /app/assets

ENTRYPOINT ["/app/$BIN_NAME", "--rootdir", "./app"]

