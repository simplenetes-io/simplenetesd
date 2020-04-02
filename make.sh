#!/usr/bin/env sh

set -e

mkdir -p release

space /cmdline/ -e SPACE_MUTE_EXIT_MESSAGE=1 -d >./release/sntd
chmod +x ./release/sntd

