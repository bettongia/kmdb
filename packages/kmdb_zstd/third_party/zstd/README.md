# Zstandard

Please refer to the official Github project for more information:
https://github.com/facebook/zstd

This package is based on
[Zstandard v1.5.7](https://github.com/facebook/zstd/releases/tag/v1.5.7).

The file
[packages/kmdb_zstd/third_party/zstd/src/zstd.c](packages/kmdb_zstd/third_party/zstd/src/zstd.c)
was built using the `create_single_file_library.sh` script in the Zstandard
project (see the
[README](https://github.com/facebook/zstd/blob/dev/build/single_file_libs/README.md)).

```sh
cd build/single_file_libs
python3 combine.py -r ../../lib -k zstd.h -o zstd.c zstd-in.c
```
