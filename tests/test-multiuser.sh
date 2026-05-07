#!/usr/bin/env bash
set -Eeuo pipefail

__users='{
  "alice": {
    "groups": ["sudo", "docker", "test-ethd-admins"]
  },
  "bob": {
    "groups": ["docker", "test-ethd-admins"]
  },
  "charlie": {
    "groups": ["sudo", "docker"]
  },
  "eve": {
    "groups": ["docker", "test-ethd-admins"]
  }
}'
__admin_group="test-ethd-admins"

declare -a __config_files=(
  "prometheus/prometheus.yml"
  "alloy/loki-write.alloy"
  "alloy/prometheus-write.alloy"
  "alloy/alloy-logs.alloy"
  "ssv-config/config.yaml"
  "ssv-config/dkg-config.yaml"
  "commit-boost/cb-config.toml"
  "tempo/tempo.yaml"
  "tempo/overrides.yaml"
)

__initial_owner=""
__error_count=0
__temp_dir="/tmp/ethd_test_dir"

# This hard-codes the user and group names.
__test_parameters='[
  {
    "owner": "alice:alice",
    "user": "alice",
    "umask": "022",
    "runfirst": "",
    "file_permissions": "u=rw,go=r",
    "exec_file_permissions": "u=rwx,go=rx",
    "dir_permissions": "u=rwx,go=rx",
    "setgid": "g-s",
    "expected_file_owner": "alice:alice",
    "expected_env_owner": "alice:alice",
    "expected_config_permissions": "644",
    "expected_env_permissions": "644",
    "should_succeed": "true"
  },
  {
    "owner": "alice:alice",
    "user": "alice",
    "umask": "077",
    "runfirst": "",
    "file_permissions": "u=rw,go=",
    "exec_file_permissions": "u=rwx,go=",
    "dir_permissions": "u=rwx,go=",
    "setgid": "g-s",
    "expected_file_owner": "alice:alice",
    "expected_env_owner": "alice:alice",
    "expected_config_permissions": "604",
    "expected_env_permissions": "600",
    "should_succeed": "true"
  },
  {
    "owner": "alice:alice",
    "user": "root",
    "umask": "022",
    "runfirst": "",
    "file_permissions": "u=rw,go=r",
    "exec_file_permissions": "u=rwx,go=rx",
    "dir_permissions": "u=rwx,go=rx",
    "setgid": "g-s",
    "expected_file_owner": "alice:alice",
    "expected_env_owner": "alice:alice",
    "expected_config_permissions": "644",
    "expected_env_permissions": "644",
    "should_succeed": "true"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "alice",
    "umask": "022",
    "runfirst": "",
    "file_permissions": "u=rw,g=rw,o=r",
    "exec_file_permissions": "u=rwx,g=rwx,o=rx",
    "dir_permissions": "u=rwx,g=rwx,o=rx",
    "setgid": "g-s",
    "expected_file_owner": "alice:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "664",
    "should_succeed": "true"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "alice",
    "umask": "022",
    "runfirst": "",
    "file_permissions": "u=rw,g=rw,o=r",
    "exec_file_permissions": "u=rwx,g=rwx,o=rx",
    "dir_permissions": "u=rwx,g=rwx,o=rx",
    "setgid": "g+s",
    "expected_file_owner": "alice:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "664",
    "should_succeed": "true"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "alice",
    "umask": "077",
    "runfirst": "",
    "file_permissions": "u=rw,g=rw,o=",
    "exec_file_permissions": "u=rwx,g=rwx,o=",
    "dir_permissions": "u=rwx,g=rwx,o=",
    "setgid": "g-s",
    "expected_file_owner": "alice:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "660",
    "should_succeed": "true"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "alice",
    "umask": "077",
    "runfirst": "",
    "file_permissions": "u=rw,g=rw,o=",
    "exec_file_permissions": "u=rwx,g=rwx,o=",
    "dir_permissions": "u=rwx,g=rwx,o=",
    "setgid": "g+s",
    "expected_file_owner": "alice:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "660",
    "should_succeed": "true"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "bob",
    "umask": "022",
    "runfirst": "",
    "file_permissions": "u=rw,g=rw,o=r",
    "exec_file_permissions": "u=rwx,g=rwx,o=rx",
    "dir_permissions": "u=rwx,g=rwx,o=rx",
    "setgid": "g-s",
    "expected_file_owner": "bob:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "664",
    "should_succeed": "true"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "bob",
    "umask": "022",
    "runfirst": "",
    "file_permissions": "u=rw,g=rw,o=r",
    "exec_file_permissions": "u=rwx,g=rwx,o=rx",
    "dir_permissions": "u=rwx,g=rwx,o=rx",
    "setgid": "g+s",
    "expected_file_owner": "bob:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "664",
    "should_succeed": "true"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "bob",
    "umask": "077",
    "runfirst": "alice",
    "file_permissions": "u=rw,g=rw,o=",
    "exec_file_permissions": "u=rwx,g=rwx,o=",
    "dir_permissions": "u=rwx,g=rwx,o=",
    "setgid": "g-s",
    "expected_file_owner": "alice:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "660",
    "should_succeed": "true"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "bob",
    "umask": "077",
    "runfirst": "alice",
    "file_permissions": "u=rw,g=rw,o=",
    "exec_file_permissions": "u=rwx,g=rwx,o=",
    "dir_permissions": "u=rwx,g=rwx,o=",
    "setgid": "g+s",
    "expected_file_owner": "alice:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "660",
    "should_succeed": "true"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "root",
    "umask": "022",
    "runfirst": "",
    "file_permissions": "u=rw,g=rw,o=r",
    "exec_file_permissions": "u=rwx,g=rwx,o=rx",
    "dir_permissions": "u=rwx,g=rwx,o=rx",
    "setgid": "g-s",
    "expected_file_owner": "eve:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "664",
    "should_succeed": "true"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "bob",
    "umask": "077",
    "runfirst": "",
    "file_permissions": "u=rw,g=rw,o=",
    "exec_file_permissions": "u=rwx,g=rwx,o=",
    "dir_permissions": "u=rwx,g=rwx,o=",
    "setgid": "g-s",
    "expected_file_owner": "bob:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "660",
    "should_succeed": "false"
  },
  {
    "owner": "eve:test-ethd-admins",
    "user": "charlie",
    "umask": "022",
    "runfirst": "",
    "file_permissions": "u=rw,g=rw,o=r",
    "exec_file_permissions": "u=rwx,g=rwx,o=rx",
    "dir_permissions": "u=rwx,g=rwx,o=r",
    "setgid": "g-s",
    "expected_file_owner": "alice:test-ethd-admins",
    "expected_env_owner": "eve:test-ethd-admins",
    "expected_config_permissions": "664",
    "expected_env_permissions": "664",
    "should_succeed": "false"
  }
]'


__handle_error() {
  local exitstatus=$1
  local lineno=$2

  if [[ ! $- =~ e ]]; then
# set +e, do nothing
    return 0
  fi

  echo
  echo "Test script terminated with exit code $exitstatus on line $lineno"
}


__create_users() {
  local user
  local group
  local sudoers_file

  if ! getent group "$__admin_group" >/dev/null; then
    echo "Creating $__admin_group group"
    sudo groupadd "$__admin_group"
  fi

  for user in $(jq -r 'keys[]' <<< "$__users"); do
    # Create user if it doesn't exist
    if ! id -u "$user" >/dev/null 2>&1; then
      echo "Creating user $user"
      sudo useradd -m -s /bin/bash "$user"
      for group in $(jq -r --arg u "$user" '.[$u].groups[]' <<< "$__users"); do
        sudo usermod -aG "$group" "$user"
        if [[ "$group" == "sudo" ]]; then
          # Passwordless sudo via sudoers.d
          sudoers_file="/etc/sudoers.d/$user"
          echo "$user ALL=(ALL) NOPASSWD:ALL" | sudo tee "$sudoers_file" >/dev/null
          sudo chmod 0440 "$sudoers_file"
        fi
      done
    fi
  done
}


__delete_users() {
  local user
  local group
  local sudoers_file

  echo
  for user in $(jq -r 'keys[]' <<< "$__users"); do
    # Only act if the user exists
    if id -u "$user" >/dev/null 2>&1; then
      echo "Deleting user $user"
      for group in $(jq -r --arg u "$user" '.[$u].groups[]' <<< "$__users"); do
        sudo gpasswd -d "$user" "$group" >/dev/null 2>&1 || true
        if [[ "$group" == "sudo" ]]; then
          # Remove sudoers file if present
          sudoers_file="/etc/sudoers.d/$user"
          [[ -f "$sudoers_file" ]] && sudo rm -f "$sudoers_file"
        fi
      done
      # Delete user (and home directory)
      sudo userdel -r "$user" 2>/dev/null || sudo userdel "$user"
    fi
  done

  if getent group "$__admin_group" >/dev/null; then
    echo "Deleting $__admin_group group"
    sudo groupdel "$__admin_group"
  fi
}


__check_os() {
  if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: This script is designed to be run on Linux, but /etc/os-release doesn't exist"
    echo "Aborting"
    exit 0
  fi
  . /etc/os-release
  if [[ ! "$ID" =~ (debian|ubuntu) ]]; then
    echo "ERROR: This script is designed to be run on Debian or Ubuntu, and you don't appear to be running either."
    echo "You are on $ID"
    echo "Aborting"
    exit 0
  fi
}


__check_workdir() {
  if [[ ! -f "ethd" ]]; then
    echo "ERROR: This script is designed to be run while inside the top-level Eth Docker directory"
    echo "\"ethd\" not found, the script was called from $(pwd)"
    echo "Aborting"
    exit 0
  fi
}


__check_prereqs() {
  for arg in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$arg" 2>/dev/null | grep -q "ok installed"; then
      echo "Installing $arg"
      sudo apt-get update && sudo apt-get -y install "$arg"
    fi
  done
}


__check_test_accounts_absent() {
  local user
  local found=0

  if getent group "$__admin_group" >/dev/null; then
    echo "ERROR: Test group $__admin_group already exists"
    found=1
  fi

  for user in $(jq -r 'keys[]' <<< "$__users"); do
    if id -u "$user" >/dev/null 2>&1; then
      echo "ERROR: Test user $user already exists"
      found=1
    fi
  done

  if [[ "$found" -eq 1 ]]; then
    echo
    echo "Refusing to continue so this script does not modify or delete pre-existing users/groups"
    echo "Run this test in a fresh container/VM, or remove/rename the conflicting test accounts first"
    echo "If the users were left over from a previous run of this script, you can force deletion with \"--cleanup\""
    exit 1
  fi
}


__warn_creation() {
  local yn

  echo "This test script will first create, then at the end delete, these users"
  jq -r 'keys[]' <<< "$__users"
  echo "It will also create and delete a $__admin_group group"
  echo
  read -rp "Are you sure you wish to continue? (y/N)" yn

  case $yn in
    [Yy]) return;;
    *) echo "Aborting"; exit 0;;
  esac
}


__delete_config_files() {
  local file

  for file in "${__config_files[@]}"; do
    if sudo test -f "$__temp_dir/$file"; then
      sudo rm -f "$__temp_dir/$file"
    fi
  done
}


# Set ownership and permissions for the test
__prep_temp_directory() {
  local owner="$1"
  local file_permissions="$2"
  local exec_file_permissions="$3"
  local dir_permissions="$4"
  local setgid="$5"

  echo
  echo "Preparing temporary directory for test"
  sudo mkdir -p "$__temp_dir"
  sudo cp -a . "$__temp_dir"/
  sudo chown -R "$owner" "$__temp_dir"
  sudo chmod "$setgid" "$__temp_dir"
  sudo find "$__temp_dir" -type d -exec chmod "$dir_permissions" {} +
  sudo find "$__temp_dir" -type f -perm /111 -exec chmod "$exec_file_permissions" {} +
  sudo find "$__temp_dir" -type f ! -perm /111 -exec chmod "$file_permissions" {} +
  sudo test -f "$__temp_dir/.env" && sudo chmod "$file_permissions" "$__temp_dir/.env"
}


__delete_temp_directory() {
  sudo rm -rf "$__temp_dir"
}


__check_config_files() {
  local file
  local expected_owner="$1"
  local expected_permissions="$2"

  for file in "${__config_files[@]}"; do
    if sudo test -f "$__temp_dir/$file"; then
      actual_owner=$(sudo stat -c '%U:%G' "$__temp_dir/$file")
      actual_permissions=$(sudo stat -c '%a' "$__temp_dir/$file")

      if [[ "$actual_owner" != "$expected_owner" ]]; then
        echo "ERROR: $__temp_dir/$file has owner $actual_owner but expected $expected_owner"
        __error_count=$((__error_count + 1))
      fi
        if [[ "$actual_permissions" != "$expected_permissions" ]]; then
        echo "ERROR: $__temp_dir/$file has permissions $actual_permissions but expected $expected_permissions"
        __error_count=$((__error_count + 1))
      fi
    else
      echo "ERROR: Expected config file $__temp_dir/$file does not exist"
      __error_count=$((__error_count + 1))
    fi
  done
}


__check_other_read_perms() {
  local -A read_perm_files=(
    [prometheus]="*.yml"
    [alloy]="*.alloy"
    [alloy-obol]="*.alloy"
    [ssv-config]="*.yaml"
    [.eth/dkg_output]="*"
    [commit-boost]="cb-config.toml"
    [tempo]="*.yaml"
    [loki]="*.yml"
    [siren]="*.sh"
  )
  local dir

  for dir in "${!read_perm_files[@]}"; do
    if sudo find "$__temp_dir/$dir" -type d \! -perm -o+rx -print -quit | grep -q .; then
      echo "ERROR: There are directories in $__temp_dir/$dir that do not have \"other\" read and execute permissions but should"
      __error_count=$((__error_count + 1))
    fi
    if sudo find "$__temp_dir/$dir" -type f -name "${read_perm_files[${dir}]}" \! -perm -o+r -print -quit | grep -q .; then
      echo "ERROR: There are files in $__temp_dir/$dir that do not have \"other\" read permissions but should"
      __error_count=$((__error_count + 1))
    fi
  done
}


__check_env_file() {
  local env_file=".env"
  local expected_owner="$1"
  local expected_permissions="$2"

  if sudo test -f "$__temp_dir/$env_file"; then
    actual_owner=$(sudo stat -c '%U:%G' "$__temp_dir/$env_file")
    actual_permissions=$(sudo stat -c '%a' "$__temp_dir/$env_file")

    if [[ "$actual_owner" != "$expected_owner" ]]; then
      echo "ERROR: $__temp_dir/$env_file has owner $actual_owner but expected $expected_owner"
      __error_count=$((__error_count + 1))
    fi
    if [[ "$actual_permissions" != "$expected_permissions" ]]; then
      echo "ERROR: $__temp_dir/$env_file has permissions $actual_permissions but expected $expected_permissions"
      __error_count=$((__error_count + 1))
    fi
  else
    echo "ERROR: Expected env file $__temp_dir/$env_file does not exist"
    __error_count=$((__error_count + 1))
  fi
}


__run_tests() {
  local user
  local owner
  local umask_val
  local runfirst
  local file_permissions
  local exec_file_permissions
  local dir_permissions
  local setgid
  local expected_file_owner
  local expected_env_owner
  local expected_config_permissions
  local expected_env_permissions
  local should_succeed
  local result
  local output

  while IFS= read -r obj; do  # From jq after "done"
    user=$(jq -r '.user' <<< "$obj")
    owner=$(jq -r '.owner' <<< "$obj")
    umask_val=$(jq -r '.umask' <<< "$obj")
    runfirst=$(jq -r '.runfirst' <<< "$obj")
    file_permissions=$(jq -r '.file_permissions' <<< "$obj")
    exec_file_permissions=$(jq -r '.exec_file_permissions' <<< "$obj")
    dir_permissions=$(jq -r '.dir_permissions' <<< "$obj")
    setgid=$(jq -r '.setgid' <<< "$obj")
    expected_file_owner=$(jq -r '.expected_file_owner' <<< "$obj")
    expected_config_permissions=$(jq -r '.expected_config_permissions' <<< "$obj")
    expected_env_owner=$(jq -r '.expected_env_owner' <<< "$obj")
    expected_env_permissions=$(jq -r '.expected_env_permissions' <<< "$obj")
    should_succeed=$(jq -r '.should_succeed' <<< "$obj")

    __error_count=0
    echo
    echo "Running test with these parameters"
    cat <<EOF
user=$user
owner=$owner
umask=$umask_val
file permissions=$file_permissions
executable file permissions=$exec_file_permissions
directory permissions=$dir_permissions
setgid=$setgid
EOF

    __prep_temp_directory "$owner" "$file_permissions" "$exec_file_permissions" "$dir_permissions" "$setgid"
    __delete_config_files

    set +e
    if [[ -n "$runfirst" ]]; then
      echo "Running \"ethd space\" first with user $runfirst to fix permissions before running with user $user"
      output=$(sudo -u "$runfirst" bash -c "cd $__temp_dir && umask $umask_val && ./ethd space 2>&1")
      result=$?
      if [[ "$result" -ne 0 ]]; then
        echo "ERROR: \"ethd space\" failed to run with user $runfirst"
        echo "Output was:"
        echo "$output"
        echo "Stopping here so this can be investigated. Note users have not been deleted yet, so you can investigate the temp directory at $__temp_dir"
        exit 1
      fi
    fi
    output=$(sudo -u "$user" bash -c "cd $__temp_dir && umask $umask_val && ./ethd space 2>&1")
    result=$?
    set -e
    if [[ "$result" -ne 0 && "$should_succeed" == "true" ]]; then
      echo "ERROR: \"ethd space\" failed to run with user $user"
      echo "Output was:"
      echo "$output"
      echo "Stopping here so this can be investigated. Note users have not been deleted yet, so you can investigate the temp directory at $__temp_dir"
      exit 1
    elif [[ "$result" -eq 0 && "$should_succeed" == "false" ]]; then
      echo "ERROR: \"ethd space\" ran successfully with user $user, but was expected to fail"
      echo "Output was:"
      echo "$output"
      echo "Stopping here so this can be investigated. Note users have not been deleted yet, so you can investigate the temp directory at $__temp_dir"
      exit 1
    elif [[ "$result" -ne 0 && "$should_succeed" == "false" ]]; then
      echo "Success: \"ethd space\" failed to run with user $user, as expected"
    elif [[ "$result" -eq 0 && "$should_succeed" == "true" ]]; then
      echo "Success: \"ethd space\" ran successfully with user $user"
      __check_config_files "$expected_file_owner" "$expected_config_permissions"
      __check_other_read_perms
      __check_env_file "$expected_env_owner" "$expected_env_permissions"
      if [[ "$__error_count" -eq 0 ]]; then
        echo "Success: All permissions are correct for user $user on the config files and .env file"
      else
        echo "ERROR: There were $__error_count permission errors for user $user on the config files and/or .env file"
        echo "Stopping here so this can be investigated. Note users have not been deleted yet, so you can investigate the temp directory at $__temp_dir"
        exit 1
      fi
      set +e
      output=$(sudo -u "$user" bash -c "cd $__temp_dir && umask $umask_val && ./ethd space 2>&1")
      result=$?
      set -e
      if [[ "$output" == *"Fixing ownership of .env"* ]]; then
        echo "ERROR: \"ethd space\" output contains \"Fixing ownership of .env\" for user $user"
        echo "Output was:"
        echo "$output"
        echo "Stopping here so this can be investigated. Note users have not been deleted yet, so you can investigate the temp directory at $__temp_dir"
        exit 1
      fi
      if [[ "$result" -ne 0 ]]; then
        echo "ERROR: \"ethd space\" failed to run when checking for idempotence with user $user"
        echo "Output was:"
        echo "$output"
        echo "Stopping here so this can be investigated. Note users have not been deleted yet, so you can investigate the temp directory at $__temp_dir"
        exit 1
      else
        echo "Success: \"ethd space\" ran successfully when checking for idempotence with user $user"
      fi
    fi

    __delete_temp_directory
  done < <(jq -c '.[]' <<< "$__test_parameters")
}

trap '__handle_error $? ${BASH_LINENO[0]}' ERR

if [[ "${1:-}" = "--cleanup" ]]; then
  __delete_users
  sudo rm -rf $__temp_dir
fi
__check_os
__check_workdir
__check_prereqs jq
__check_test_accounts_absent
__warn_creation
__create_users
__run_tests
__delete_users
