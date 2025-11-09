#!/usr/bin/env bash

set_value_in_env() {
    # Assumes that "var" has been set to the name of the variable to be changed
    if [ "${!var+x}" ]; then
        # Quote the value to handle spaces and special characters
        local quoted_val
        quoted_val=$(printf '%q' "${!var}")
        if ! grep -qF "${var}" .env 2>/dev/null ; then
            echo "${var}=${quoted_val}" >> .env
        else
            sed -i'.original' -e "s~^\(${var}\s*=\s*\).*$~\1${quoted_val}~" .env
        fi
    fi
}
