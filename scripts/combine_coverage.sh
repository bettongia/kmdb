#!/usr/bin/env bash

# Acknowledgement:
#   https://medium.com/flutter-community/managing-multi-package-flutter-projects-with-melos-c8ce96fa7c82

escapedPath="$(echo `pwd` | sed 's/\//\\\//g')"

if [ -d "coverage" ]; then
    sed "s/^SF:lib/SF:$escapedPath\/lib/g" coverage/lcov.info >> "$MELOS_ROOT_PATH/site/coverage/lcov.info"
fi
