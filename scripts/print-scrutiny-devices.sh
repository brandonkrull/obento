#!/usr/bin/env bash
# Prints the `devices:` lines to paste into the scrutiny service in compose/docker-compose.yml
for d in /dev/sd? /dev/nvme?; do [[ -e $d ]] && echo "      - $d:$d"; done
