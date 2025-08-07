#!/bin/sh
set -e

# Exit early if CNAME_LIST is empty or not set
if [ -z "$CNAME_LIST" ]; then
  echo "[route53-ddns] CNAME_LIST not set — exiting"
  exit 0
fi

echo "[route53-ddns] Generating Route53 CNAME records config..."

cat <<EOF > /ddns-route53.yml
credentials:
  accessKeyID: "$AWS_ACCESS_KEY_ID"
  secretAccessKey: "$AWS_SECRET_ACCESS_KEY"

route53:
  hostedZoneID: "$ROUTE53_ZONE_ID"
  recordsSet:
EOF

IFS=',' read -r -a HOSTNAMES <<< "$CNAME_LIST"
for cname in "${HOSTNAMES[@]}"; do
  cat <<EOF >> /ddns-route53.yml
    - name: "${cname}."
      type: "CNAME"
      ttl: 300
      records:
        - "${CNAME_TARGET}."
EOF
done

echo "[route53-ddns] Config created successfully."
