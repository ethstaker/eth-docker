#!/bin/bash
set -Eeu

# Permissions
mkdir -p /var/lib/web3signer/keys && chown -R 10000:10000 /var/lib/web3signer

# Configuration
db_url="postgresql://postgres:postgres@${PG_ALIAS}:5432/web3signer"
check_query="SELECT 1 FROM pg_database WHERE datname = current_database() AND datcollversion <> (SELECT collversion FROM pg_collation WHERE collname = 'en_US.utf8' LIMIT 1);"

# Check if a fix is needed
needs_fix=$(psql "${db_url}" -Atc "${check_query}")

if [ "${needs_fix}" = "1" ]; then
    echo "Collation mismatch detected (glibc upgrade). Starting repair..."

    # 1. Reindex the only character-based table in Web3signer
    psql "${db_url}" -c "REINDEX TABLE flyway_schema_history;"

    # 2. Update the version stamp for the main database
    psql "${db_url}" -c "ALTER DATABASE web3signer REFRESH COLLATION VERSION;"

    # 3. Clear the warnings for system databases (no reindex needed as they are empty)
    # We swap the DB name in the URL to connect to 'postgres'
    psql "${db_url/web3signer/postgres}" -c "ALTER DATABASE postgres REFRESH COLLATION VERSION;"
    psql "${db_url/web3signer/template1}" -c "ALTER DATABASE template1 REFRESH COLLATION VERSION;"

    echo "Repair complete. Collation versions are now in sync with container's glibc."
else
    echo "Collation versions are already in sync. No action required."
fi

data_dir=/var/lib/postgres-data
upgrade_marker="${data_dir}/upgrade_in_progress.lock"
echo "Checking database state at ${data_dir} ..."
# A failed PostgreSQL version upgrade should fail postgres, so this never runs. Belt and suspenders.
if [[ -f "${upgrade_marker}" ]]; then
  echo "ERROR: Upgrade marker found! A previous PostgreSQL upgrade attempt failed or was interrupted."
  echo "Manual intervention required to prevent slashing."
  sleep 30
  exit 1
fi
if [[ -f "${data_dir}/PG_VERSION" ]]; then
  version=$(cat "${data_dir}/PG_VERSION")
# A mismatch should fail postgres, so this never runs. Belt and suspenders.
  if [[ "${version}" != "${PG_DOCKER_TAG%%[^0-9]*}" ]]; then
    echo "ERROR: The slashing protection database is version ${version}, but the image is ${PG_DOCKER_TAG}."
    echo "Aborting, PostgreSQL may have created a blank database."
    echo "Manual intervention required to prevent slashing."
    sleep 30
    exit 1
  fi
fi

if [[ -f /var/lib/web3signer/.migration_fatal_error ]]; then
    echo "An error occurred during \"ethd update\" and slashing protection database migration, that makes it unsafe to start Web3signer."
    echo "Until this is manually remedied, Web3signer will refuse to start up."
    echo "Aborting."
    echo
    echo "If this issue has since been resolved, you can remove the \".migration_fatal_error\" marker file in Web3signer's"
    echo "Docker volume."
    echo
    echo "ONLY remove the marker file if the issue has been resolved. You risk slashing otherwise."
    sleep 30
    exit 1
fi

if [[ -f /var/lib/web3signer/.migration_error ]]; then
    echo "An error occurred during \"ethd update\", while switching to a new version of PostgreSQL."
    echo "Web3signer will start, but won't work until PostgreSQL's version matches the slashing protection database"
    echo "version."
    echo
    echo "If this issue has since been resolved, you can remove the \".migration_error\" marker file in Web3signer's"
    echo "Docker volume."
fi

exec "$@"
