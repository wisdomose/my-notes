# Hey Notes API. Build context: apps/api
FROM rust:1.97-slim AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
# Cache dependencies separately from the source.
RUN mkdir src && echo "fn main() {}" > src/main.rs && touch src/lib.rs \
    && cargo build --release && rm -rf src
COPY src ./src
RUN touch src/main.rs src/lib.rs && cargo build --release

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* && useradd --system --uid 10001 app
COPY --from=build /app/target/release/hey-notes-api /usr/local/bin/hey-notes-api
USER app
ENV PORT=8080 TRUST_PROXY=true RUST_LOG=hey_notes_api=info,tower_http=info
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD curl -fs http://localhost:8080/health || exit 1
CMD ["hey-notes-api"]
