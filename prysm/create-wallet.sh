#!/bin/bash
set -Eeuo pipefail

__password=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)

echo "$__password" >/tmp/password.txt
echo "Wallet password created"
set +e
if [[ "${WEB3SIGNER}" = "true" ]]; then
    __kind=web3signer
    echo "No need to create a permanent wallet when using web3signer with Prysm. Aborting."
    exit 0
else
    __kind=imported
fi
__result=$(validator --datadir=/var/lib/prysm wallet create --"${NETWORK}" --wallet-dir=/var/lib/prysm --keymanager-kind=${__kind} --accept-terms-of-use --wallet-password-file=/tmp/password.txt 2>&1)
if echo "$__result" | grep -qi error; then
    echo "An error occurred while attempting to create a Prysm wallet"
    echo "$__result"
    exit 1
else
    echo "$__result"
fi
set -e
echo "Wallet has been created"
echo "$__password" >/var/lib/prysm/password.txt
chmod 600 /var/lib/prysm/password.txt
echo "Wallet password stored"
