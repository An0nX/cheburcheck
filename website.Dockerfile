# syntax=docker/dockerfile:1

################################################################################
# Build Stage - Компиляция Rust приложения на Alpine
################################################################################
FROM dhi.io/alpine-base:3.23-dev AS build

WORKDIR /build

# Установка переменных окружения для оптимизации сборки Rust
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true \
    CARGO_TERM_COLOR=always \
    CARGO_PROFILE_RELEASE_LTO=true \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_DEBUG=false \
    CARGO_PROFILE_RELEASE_STRIP=true \
    CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=false \
    CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS=false \
    CARGO_PROFILE_RELEASE_PANIC=abort \
    OPENSSL_STATIC=1 \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

# Установка необходимых зависимостей для сборки (одна команда для оптимизации слоев)
RUN apk add --no-cache \
    curl \
    openssl-static \
    openssl-dev \
    pkg-config \
    musl-dev \
    && rm -rf /var/cache/apk/*

# Установка Rust с поддержкой архитектуры через специальный скрипт
RUN set -eux; \
    case "$(apk --print-arch)" in \
      x86_64)  ARCH=x86_64  ;; \
      aarch64) ARCH=aarch64 ;; \
      *) echo "unsupported arch: $(apk --print-arch)"; exit 1 ;; \
    esac; \
    curl -fsSL "https://static.rust-lang.org/rustup/dist/${ARCH}-unknown-linux-musl/rustup-init" -o /tmp/rustup-init; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --default-toolchain stable --profile minimal; \
    rm /tmp/rustup-init; \
    rustup --version; \
    cargo --version; \
    rustc --version

# Копирование файлов манифеста ПЕРВЫМИ для оптимизации кеша
COPY Cargo.toml Cargo.lock ./

# Создание минимального проекта для предварительной загрузки зависимостей
RUN set -eux; \
    mkdir -p src/bin website/src; \
    echo "fn main() {}" > src/main.rs; \
    touch website/src/lib.rs

# Загрузка и кеширование зависимостей Cargo
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=cache,target=/build/target \
    cargo fetch

# Копирование исходного кода ПОСЛЕ кеширования зависимостей
COPY . .

# Компиляция приложения с использованием кешей BuildKit
# Секреты используются через environment переменные или файлы
RUN --mount=type=cache,target=/build/target \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=secret,id=DATABASE_URL,env=DATABASE_URL \
    set -eux; \
    cargo build \
      --release \
      --package website \
      --locked; \
    objcopy --compress-debug-sections target/release/website /tmp/main; \
    file /tmp/main

# Экспортирование бинарного файла для финального образа
RUN cp /tmp/main /build/main

################################################################################
# Runtime Stage - Минимальный образ distroless для продакшена
################################################################################
FROM gcr.io/distroless/static:nonroot

# Метаданные образа
LABEL org.opencontainers.image.title="Website" \
      org.opencontainers.image.description="Rocket-based website application" \
      org.opencontainers.image.version="1.0"

WORKDIR /app

# Копирование скомпилированного бинарника из build-этапа
COPY --from=build --chown=nonroot:nonroot /build/main ./

# Копирование конфигурации
COPY --from=build --chown=nonroot:nonroot /build/website/Rocket.toml ./

# Копирование статических активов и шаблонов
COPY --from=build --chown=nonroot:nonroot /build/website/static ./static
COPY --from=build --chown=nonroot:nonroot /build/website/templates ./templates

# Переменные окружения для Rocket приложения
ENV ROCKET_ADDRESS=::
ENV ROCKET_PORT=8080

EXPOSE 8080

# Distroless уже запускается с непривилегированным пользователем (nonroot)
ENTRYPOINT ["/app/main"]
