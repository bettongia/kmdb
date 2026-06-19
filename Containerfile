# Stage 1: build addlicense (Go tool used by the license_check target)
FROM docker.io/library/golang:latest AS addlicense-builder
RUN CGO_ENABLED=0 go install github.com/google/addlicense@latest

# Stage 2: Dart runtime with tooling
FROM docker.io/library/dart:stable

COPY --from=addlicense-builder /go/bin/addlicense /usr/local/bin/addlicense

RUN apt-get update && apt-get install -y --no-install-recommends \
    make \
    clang \
    lcov \
    libicu-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/sh runner

ENV HOME=/home/runner

# dart pub global activate installs binaries here (e.g. melos, coverage)
ENV PATH="/home/runner/.pub-cache/bin:${PATH}"

USER runner
WORKDIR /home/runner/app

COPY --chown=runner:runner . .

CMD ["make", "cicd_linux_base"]
