# Rust via rustup, installed system-wide (minimal profile). The cargo/rustc
# binaries live in /usr/local/cargo (read-only rootfs at runtime). At RUN time
# the harness sets CARGO_HOME=/home/claude/.cargo backed by the polysbx-cargo
# volume (see backend-docker.sh) so dependency fetches + `cargo install` have a
# writable registry/cache; both bin dirs are on PATH below.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/home/claude/.cargo/bin:/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --profile minimal \
    && chmod -R a+rwX "$RUSTUP_HOME" "$CARGO_HOME"
