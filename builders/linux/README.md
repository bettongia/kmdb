# Build image for Linux

These instructions assume that you've
[installed Podman](https://podman-desktop.io/docs/installation).

On a Mac, using a podman machine with 15Gb storage should be fine - the default
machine is likely to have this (at least) but the following can be used to set
the size (to 15Gb or something else):

```sh
podman machine init --disk-size 15
podman machine start
```

Build the image as below - it takes a while as
[TeX Live](https://www.tug.org/texlive/) is installed for use in generating the
documentation:

```sh
podman build -t kmdb-builder-base -f Containerfile.base .
```

```sh
podman image rm kmdb-builder

podman build -t kmdb-builder \
    --build-context=PROJECT_DIR=$(realpath ../..) \
    --build-context=KMESH_PACKAGES_DIR=$(realpath ../../../kmesh/packages) .
```

You can now run the command below to kick off the default Makefile tasks:

```sh
podman run --rm -it kmdb-builder
```

```sh
podman run --rm -it --entrypoint bash kmdb-builder
```
