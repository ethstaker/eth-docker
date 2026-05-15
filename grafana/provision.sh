#!/bin/bash
# Provision dashboards for chosen client. This may not work too well if clients are changed
# without deleting the grafana docker volume
# Expects a full grafana command with parameters as argument(s)
set -o pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R grafana:root /var/lib/grafana
  chown -R grafana:root /etc/grafana
  exec su-exec grafana "$0" "$@"
fi


handle_replacement() {
  local exitstatus="$1"
  local tmp_file="$2"
  local target="$3"
  local new_sum
  local old_sum

  # 1. Check if the pipeline failed
  if [[ "${exitstatus}" -ne 0 ]]; then
    echo "Error: Download or JSON change failed for ${target}. Skipping."
    [[ -f "${tmp_file}" ]] && rm -f "${tmp_file}"
    return 1
  fi

  # 2. Check if the file is empty (wget might return 0 but no data)
  if [[ ! -s "${tmp_file}" ]]; then
    echo "Error: Output file is empty for ${target}. Skipping."
    rm -f "${tmp_file}"
    return 1
  fi

  new_sum=$(sha1sum "${tmp_file}" | awk '{print $1}')
  # 3. SHA1 Comparison
  if [[ -f "${target}.sha1sum" ]]; then
    old_sum=$(cat "${target}.sha1sum")

    if [[ "${new_sum}" == "${old_sum}" ]]; then
        echo "No changes for $(basename "${target}")."
        rm -f "${tmp_file}"
        return 0
    fi
  fi

  # 4. Success - Replace file
  if mv "${tmp_file}" "${target}"; then
    sha1sum "${target}" | awk '{print $1}' > "${target}".sha1sum
    chmod 644 "${target}"
    echo "Successfully updated ${target}"
  else
    echo "Error: Failed to move temporary file ${tmp_file} to ${target}"
    return 1
  fi
}


cp /tmp/grafana/provisioning/alerting/* /etc/grafana/provisioning/alerting/

shopt -s extglob
# Provision CL dashboards
# Assumed to be mutually exclusive
case "${CLIENT}" in
  *prysm* )
    #  prysm_small
    url='https://www.offchainlabs.com/prysm/docs/assets/files/small_amount_validators-372a4e8caa631260e6c951d4d81c3283.json/'
    file='/etc/grafana/provisioning/dashboards/prysm_small.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Prysm Dashboard"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    #  prysm_more_10
    url='https://www.offchainlabs.com/prysm/docs/assets/files/big_amount_validators-0ed1a1ead364ced51d5d92ddc19db229.json/'
    file='/etc/grafana/provisioning/dashboards/prysm_big.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Prysm Dashboard Many Validators"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *lighthouse.yml* )
    #  lighthouse_summary
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/Summary.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_summary.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Summary"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    #  lighthouse_validator_client
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/ValidatorClient.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_validator_client.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Validator Client"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    # lighthouse_validator_monitor
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/ValidatorMonitor.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_validator_monitor.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Validator Monitor"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *lighthouse-cl-only* )
    #  lighthouse_summary
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/Summary.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_summary.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Summary"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    # lighthouse_validator_monitor
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/ValidatorMonitor.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_validator_monitor.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Validator Monitor"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *teku* )
    #  teku_overview
    id=12199
    status=0
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq -r .revision) || status=1
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/teku_overview.json'
    if [[ "${status}" -eq 0 ]]; then
      tmp=$(mktemp)
      wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Teku Overview"' \
        | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    fi
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *nimbus* )
    #  nimbus_dashboard
    url='https://raw.githubusercontent.com/status-im/nimbus-eth2/master/grafana/beacon_nodes_Grafana_dashboard.json'
    file='/etc/grafana/provisioning/dashboards/nimbus_dashboard.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Nimbus Dashboard"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' \
      | jq 'walk(if . == "${DS_PROMETHEUS-PROXY}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *lodestar* )
    #  lodestar summary
    url='https://raw.githubusercontent.com/ChainSafe/lodestar/stable/dashboards/lodestar_summary.json'
    file='/etc/grafana/provisioning/dashboards/lodestar_summary.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lodestar Dashboard"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' \
      | jq '.templating.list[3].query |= "consensus" | .templating.list[4].query |= "validator"' \
      | jq 'walk(if . == "prometheus_local" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *grandine* )
    #  grandine overview
    url='https://raw.githubusercontent.com/grandinetech/grandine/refs/heads/master/prometheus_metrics/dashboards/overview.json'
    file='/etc/grafana/provisioning/dashboards/grandine_dashboard.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq '.title = "Grandine Dashboard"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' \
      >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
esac

# Provision VC dashboards
# Assumed to be mutually exclusive
case "${CLIENT}" in
  *vero* )
    #  vero detailed
    url='https://raw.githubusercontent.com/serenita-org/vero/refs/heads/master/grafana/vero-detailed.json'
    file='/etc/grafana/provisioning/dashboards/vero-detailed.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${datasource}" then "Prometheus" else . end)' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    #  vero simple
    url='https://raw.githubusercontent.com/serenita-org/vero/refs/heads/master/grafana/vero-simple.json'
    file='/etc/grafana/provisioning/dashboards/vero-simple.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${datasource}" then "Prometheus" else . end)' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *lighthouse-vc-only* )
    #  lighthouse_validator_client
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/ValidatorClient.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_validator_client.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Validator Client"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
esac

# Provision EL dashboards
# Assumed to be mutually exclusive
case "${CLIENT}" in
  *geth* )
    # geth_dashboard
    url='https://gist.githubusercontent.com/karalabe/e7ca79abdec54755ceae09c08bd090cd/raw/3a400ab90f9402f2233280afd086cb9d6aac2111/dashboard.json'
    file='/etc/grafana/provisioning/dashboards/geth_dashboard.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Geth Dashboard"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *erigon* )
    # erigon_dashboard
    url='https://raw.githubusercontent.com/ledgerwatch/erigon/devel/cmd/prometheus/dashboards/erigon.json'
    file='/etc/grafana/provisioning/dashboards/erigon_dashboard.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Erigon Dashboard"' | jq '.uid = "YbLNLr6Mz"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *besu* )
    # besu_dashboard
    id=10273
    status=0
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq -r .revision) || status=1
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/besu_dashboard.json'
    if [[ "${status}" -eq 0 ]]; then
      tmp=$(mktemp)
      wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Besu Dashboard"' \
        | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    fi
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *reth* )
    # reth_dashboard
    url='https://raw.githubusercontent.com/paradigmxyz/reth/main/etc/grafana/dashboards/overview.json'
    file='/etc/grafana/provisioning/dashboards/reth_dashboard.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Reth Dashboard"' \
      | jq 'walk(
          if . == "${DS_PROMETHEUS}" then "Prometheus"
          elif . == "${VAR_INSTANCE_LABEL}" then "execution"
          else .
          end
        )' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *nethermind* )
    # nethermind_dashboard
    url='https://raw.githubusercontent.com/NethermindEth/metrics-infrastructure/master/grafana/provisioning/dashboards/nethermind.json'
    file='/etc/grafana/provisioning/dashboards/nethermind_dashboardv2.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *ethrex* )
    # ethrex_dashboard
    url='https://raw.githubusercontent.com/lambdaclass/ethrex/refs/heads/main/metrics/provisioning/grafana/dashboards/common_dashboards/ethrex_l1_perf.json'
    file='/etc/grafana/provisioning/dashboards/ethrex_l1_perf.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
esac

# Provision remote signer dashboards
case "${CLIENT}" in
  *web3signer* )
    # web3signer_dashboard
    id=13687
    status=0
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq -r .revision) || status=1
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/web3signer.json'
    if [[ "${status}" -eq 0 ]]; then
      tmp=$(mktemp)
      wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    fi
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
esac

# Provision DVT dashboards
# Assumed to be mutually exclusive
case "${CLIENT}" in
  *ssv.yml* )
    # SSV Operational Dashboard
    url='https://docs.ssv.network/files/SSV-Operational-dashboard.json'
    file='/etc/grafana/provisioning/dashboards/ssv_operational_dashboard.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
  *lido-obol.yml* )
    # Lido Obol Dashboard
    url='https://raw.githubusercontent.com/ObolNetwork/lido-charon-distributed-validator-node/main/grafana/dashboards/dash_charon_overview.json'
    file='/etc/grafana/provisioning/dashboards/charon.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(
          if (type == "object" and .datasource? and .datasource.uid? == "prometheus")
          then .datasource.uid = "Prometheus"
          else .
          end
        )' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    url='https://raw.githubusercontent.com/ObolNetwork/lido-charon-distributed-validator-node/main/grafana/dashboards/single_node_dashboard.json'
    file='/etc/grafana/provisioning/dashboards/single_node_dashboard.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(
          if (type == "object" and .datasource? and .datasource.uid? == "prometheus")
          then .datasource.uid = "Prometheus"
          else .
          end
        )' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    url='https://raw.githubusercontent.com/ObolNetwork/lido-charon-distributed-validator-node/main/grafana/dashboards/validator_ejector_overview.json'
    file='/etc/grafana/provisioning/dashboards/validator_ejector_overview.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(
          if (type == "object" and .datasource? and .datasource.uid? == "prometheus")
          then .datasource.uid = "Prometheus"
          else .
          end
        )' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    url='https://raw.githubusercontent.com/ObolNetwork/lido-charon-distributed-validator-node/main/grafana/dashboards/logs_dashboard.json'
    file='/etc/grafana/provisioning/dashboards/logs_dashboard.json'
    tmp=$(mktemp)
    status=0
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(
          if (type == "object" and .datasource? and .datasource.uid? == "loki")
          then .datasource.uid = "Loki"
          else .
          end
        )' \
      | jq 'walk(if . == "${DS_LOKI}" then "Loki" else . end)' >"${tmp}" || status=1
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
esac

# Provision cadvisor and node exporter dashboards
case "${CLIENT}" in
  !(*grafana-rootless*) )
    # cadvisor and node exporter dashboard
    id=19724
    status=0
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq -r .revision) || status=1
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/docker-host-container-overview.json'
    if [[ "${status}" -eq 0 ]]; then
      tmp=$(mktemp)
      wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    fi
    handle_replacement "${status}" "${tmp}" "${file}"
    # Another cadvisor and node exporter dashboard
    id=15120
    status=0
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq -r .revision) || status=1
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/host-docker-monitoring.json'
    if [[ "${status}" -eq 0 ]]; then
      tmp=$(mktemp)
      wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Host & Docker Monitoring"' \
        | jq '.panels |= map(if .title == "Temp" then .targets[0] |= (.legendFormat = "{{type}}" | .expr = "node_thermal_zone_temp")| .options.orientation = "vertical" elif .title == "Temperature" then .targets[0].expr = "node_thermal_zone_temp" else . end)' \
        | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
    fi
    handle_replacement "${status}" "${tmp}" "${file}"
    ;;
esac

# Always provision a few basics
# Log file dashboard (via loki)
id=20223
status=0
revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq -r .revision) || status=1
url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
file='/etc/grafana/provisioning/dashboards/eth-docker-logs.json'
if [[ "${status}" -eq 0 ]]; then
  tmp=$(mktemp)
  wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_LOKI}" then "Loki" else . end)' >"${tmp}" || status=1
fi
handle_replacement "${status}" "${tmp}" "${file}"

# Home staking dashboard
id=17846
status=0
revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq -r .revision) || status=1
url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
file='/etc/grafana/provisioning/dashboards/homestaking-dashboard.json'
if [[ "${status}" -eq 0 ]]; then
  tmp=$(mktemp)
  wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
fi
handle_replacement "${status}" "${tmp}" "${file}"

# Ethereum Metrics Exporter Dashboard
id=16277
status=0
revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq -r .revision) || status=1
url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
file='/etc/grafana/provisioning/dashboards/ethereum-metrics-exporter-single.json'
if [[ "${status}" -eq 0 ]]; then
  tmp=$(mktemp)
  wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${tmp}" || status=1
fi
handle_replacement "${status}" "${tmp}" "${file}"

tree /etc/grafana/provisioning/

exec "$@"
