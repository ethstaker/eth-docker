#!/usr/bin/env bash
# shellcheck disable=SC2174
set -Eeuo pipefail

ts=$(date +%s)
base_dir=/var/lib/web3signer
mkdir -p -m 700 "${base_dir}"/converted-keys

if ! find "${base_dir}"/keys -type f -name '*.password' -print -quit 2>/dev/null | grep -q .; then
  echo "No key files found in ${base_dir}/keys. Aborting."
  exit 1
fi

if [[ "${NETWORK}" =~ ^(mainnet|gnosis)$ ]]; then
  echo "Reducing key security on ${NETWORK} is not recommended. If you need to do so, please do so manually."
  echo "Aborting"
  exit 1
fi

if find "${base_dir}"/converted-keys -type f -name '*.json' -print -quit | grep -q .; then
  while true; do
    echo "Keys have previously been converted."
    read -rp "Do you want to run conversion again, maybe because you added keys? (N/y) " yn
    case "${yn}" in
      [Yy]) echo; rm -f "${base_dir}"/converted-keys/*; break;;
      *) echo "Aborting, no changes made"; exit 0;;
    esac
  done
fi

while true; do
  echo "WARNING: This function will reduce the security of validator keys loaded into Web3signer."
  echo "Web3signer startup time for thousands of keys will reduce to seconds."
  echo "Conversion can take 30 minutes for 15,000 keys. Running in screen or tmux is recommended."
  read -rp "Are you sure you want to convert keystores to lower security? (No/yes) " yn
  case "${yn}" in
    [Yy][Ee][Ss]) echo; break;;
    *) echo "Aborting, no changes made"; exit 0;;
  esac
done

mkdir -p -m 700 "${base_dir}"/keys-backup."${ts}"
cp -rp "${base_dir}"/keys/* "${base_dir}"/keys-backup."${ts}"/

for file in "${base_dir}"/keys-backup."${ts}"/*.password; do
  [ -e "$file" ] || continue
  cp -- "$file" "${file%.password}.txt"
done

/opt/converter/bin/converter --src="${base_dir}"/keys-backup."${ts}" --password-src="${base_dir}"/keys-backup."${ts}" --dest="${base_dir}"/converted-keys
cp "${base_dir}"/converted-keys/*.json "${base_dir}"/keys/

echo
echo "Original keys have been backed up to keys-backup.${ts}, inside the \"web3signer-keys\" Docker volume"
echo "Converted keys have been copied to the Web3signer key store"
echo "Restart web3signer to use the converted keys"
