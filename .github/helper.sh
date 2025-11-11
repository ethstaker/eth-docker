#!/usr/bin/env bash

set_value_in_env() {
    # Assumes that "var" has been set to the name of the variable to be changed
    if [[ "${!var+x}" ]]; then
        if ! grep -qF "${var}" .env 2>/dev/null ; then
            echo "${var}=${!var}" >> .env
        else
            sed -i'.original' -e "s~^\(${var}\s*=\s*\).*$~\1${!var}~" .env
        fi
    fi
}
