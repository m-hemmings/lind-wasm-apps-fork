FROM securesystemslab/lind-wasm-dev:latest AS src

COPY --chown=lind:lind . /home/lind/lind-wasm/lind-wasm-apps
WORKDIR /home/lind/lind-wasm/lind-wasm-apps

# Stage 1: shared setup that multiple app builds depend on.
FROM src AS shared
RUN make -j"$(nproc)" -Otarget preflight merge-base-sysroot libtirpc

# Stage 2: apps that only need the base merged sysroot.
FROM shared AS base-apps
RUN make -j"$(nproc)" -Otarget bash nginx coreutils

# Stage 3: lmbench mutates merged libc.a, so run it after other apps.
FROM base-apps AS lmbench-app
RUN make -Otarget lmbench

# Final image: include full workspace and staged build outputs.
FROM securesystemslab/lind-wasm-dev:latest
COPY --from=lmbench-app --chown=lind:lind /home/lind/lind-wasm/lind-wasm-apps /home/lind/lind-wasm/lind-wasm-apps
WORKDIR /home/lind/lind-wasm/lind-wasm-apps
