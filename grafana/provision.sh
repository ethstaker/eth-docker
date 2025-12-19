#!/bin/bash
# Provision dashboards for chosen client. This may not work too well if clients are changed
# without deleting the grafana docker volume
# Expects a full grafana command with parameters as argument(s)

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R grafana:root /var/lib/grafana
  chown -R grafana:root /etc/grafana
  exec su-exec grafana "$0" "$@"
fi

cp /tmp/grafana/provisioning/alerting/* /etc/grafana/provisioning/alerting/

shopt -s extglob
# Provision CL dashboards
# Assumed to be mutually exclusive
case "${CLIENT}" in
  *prysm* )
    #  prysm_small
    url='https://www.offchainlabs.com/prysm/docs/assets/files/small_amount_validators-372a4e8caa631260e6c951d4d81c3283.json/'
    file='/etc/grafana/provisioning/dashboards/prysm_small.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Prysm Dashboard"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    #  prysm_more_10
    url='https://www.offchainlabs.com/prysm/docs/assets/files/big_amount_validators-0ed1a1ead364ced51d5d92ddc19db229.json/'
    file='/etc/grafana/provisioning/dashboards/prysm_big.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Prysm Dashboard Many Validators"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
  *lighthouse.yml* )
    #  lighthouse_summary
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/Summary.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_summary.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Summary"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    #  lighthouse_validator_client
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/ValidatorClient.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_validator_client.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Validator Client"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    # lighthouse_validator_monitor
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/ValidatorMonitor.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_validator_monitor.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Validator Monitor"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
  *lighthouse-cl-only* )
    #  lighthouse_summary
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/Summary.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_summary.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Summary"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    # lighthouse_validator_monitor
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/ValidatorMonitor.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_validator_monitor.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Validator Monitor"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
  *teku* )
    #  teku_overview
    id=12199
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq .revision)
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/teku_overview.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Teku Overview"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
  *nimbus* )
    #  nimbus_dashboard
    url='https://raw.githubusercontent.com/status-im/nimbus-eth2/master/grafana/beacon_nodes_Grafana_dashboard.json'
    file='/etc/grafana/provisioning/dashboards/nimbus_dashboard.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Nimbus Dashboard"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' \
      | jq 'walk(if . == "${DS_PROMETHEUS-PROXY}" then "Prometheus" else . end)' >"${file}"
    ;;
  *lodestar* )
    #  lodestar summary
    url='https://raw.githubusercontent.com/ChainSafe/lodestar/stable/dashboards/lodestar_summary.json'
    file='/etc/grafana/provisioning/dashboards/lodestar_summary.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lodestar Dashboard"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' \
      | jq '.templating.list[3].query |= "consensus" | .templating.list[4].query |= "validator"' \
      | jq 'walk(if . == "prometheus_local" then "Prometheus" else . end)' >"${file}"
    ;;
  *grandine* )
    #  grandine overview
    url='https://raw.githubusercontent.com/grandinetech/grandine/refs/heads/master/prometheus_metrics/dashboards/overview.json'
    file='/etc/grafana/provisioning/dashboards/grandine_dashboard.json'
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' \
      >"${file}"
    ;;
esac

# Provision VC dashboards
# Assumed to be mutually exclusive
case "${CLIENT}" in
  *vero* )
    #  vero detailed
    url='https://raw.githubusercontent.com/serenita-org/vero/refs/heads/master/grafana/vero-detailed.json'
    file='/etc/grafana/provisioning/dashboards/vero-detailed.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${datasource}" then "Prometheus" else . end)' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    #  vero simple
    url='https://raw.githubusercontent.com/serenita-org/vero/refs/heads/master/grafana/vero-simple.json'
    file='/etc/grafana/provisioning/dashboards/vero-simple.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${datasource}" then "Prometheus" else . end)' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
  *lighthouse-vc-only* )
    #  lighthouse_validator_client
    url='https://raw.githubusercontent.com/sigp/lighthouse-metrics/master/dashboards/ValidatorClient.json'
    file='/etc/grafana/provisioning/dashboards/lighthouse_validator_client.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Lighthouse Validator Client"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
esac

# Provision EL dashboards
# Assumed to be mutually exclusive
case "${CLIENT}" in
  *geth* )
    # geth_dashboard
    url='https://gist.githubusercontent.com/karalabe/e7ca79abdec54755ceae09c08bd090cd/raw/3a400ab90f9402f2233280afd086cb9d6aac2111/dashboard.json'
    file='/etc/grafana/provisioning/dashboards/geth_dashboard.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Geth Dashboard"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
  *erigon* )
    # erigon_dashboard
    url='https://raw.githubusercontent.com/ledgerwatch/erigon/devel/cmd/prometheus/dashboards/erigon.json'
    file='/etc/grafana/provisioning/dashboards/erigon_dashboard.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Erigon Dashboard"' | jq '.uid = "YbLNLr6Mz"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
  *besu* )
    # besu_dashboard
    id=10273
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq .revision)
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/besu_dashboard.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Besu Dashboard"' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
  *reth* )
    # reth_dashboard
    url='https://raw.githubusercontent.com/paradigmxyz/reth/main/etc/grafana/dashboards/overview.json'
    file='/etc/grafana/provisioning/dashboards/reth_dashboard.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Reth Dashboard"' \
      | jq 'walk(
          if . == "${DS_PROMETHEUS}" then "Prometheus"
          elif . == "${VAR_INSTANCE_LABEL}" then "execution"
          else .
          end
        )' >"${file}"
    ;;
  *nethermind* )
    # nethermind_dashboard
    url='https://raw.githubusercontent.com/NethermindEth/metrics-infrastructure/master/grafana/provisioning/dashboards/nethermind.json'
    file='/etc/grafana/provisioning/dashboards/nethermind_dashboardv2.json'
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    # uid changed, removing this may undo the damage
    if [[ -f /etc/grafana/provisioning/dashboards/nethermind_dashboard.json ]]; then
      rm /etc/grafana/provisioning/dashboards/nethermind_dashboard.json
    fi
    ;;
  *ethrex* )
    # ethrex_dashboard
    url='https://raw.githubusercontent.com/lambdaclass/ethrex/refs/heads/main/metrics/provisioning/grafana/dashboards/common_dashboards/ethrex_l1_perf.json'
    file='/etc/grafana/provisioning/dashboards/ethrex_l1_perf.json'
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
esac

# Provision remote signer dashboards
case "${CLIENT}" in
  *web3signer* )
    # web3signer_dashboard
    id=13687
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq .revision)
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/web3signer.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
esac

# Provision DVT dashboards
# Assumed to be mutually exclusive
case "${CLIENT}" in
  *ssv.yml* )
    # SSV Operational Dashboard
    url='https://docs.ssv.network/files/SSV-Operational-dashboard.json'
    file='/etc/grafana/provisioning/dashboards/ssv_operational_dashboard.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    ;;
  *lido-obol.yml* )
    # Lido Obol Dashboard
    url='https://raw.githubusercontent.com/ObolNetwork/lido-charon-distributed-validator-node/main/grafana/dashboards/dash_charon_overview.json'
    file='/etc/grafana/provisioning/dashboards/charon.json'
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(
          if (type == "object" and .datasource? and .datasource.uid? == "prometheus")
          then .datasource.uid = "Prometheus"
          else .
          end
        )' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    url='https://raw.githubusercontent.com/ObolNetwork/lido-charon-distributed-validator-node/main/grafana/dashboards/single_node_dashboard.json'
    file='/etc/grafana/provisioning/dashboards/single_node_dashboard.json'
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(
          if (type == "object" and .datasource? and .datasource.uid? == "prometheus")
          then .datasource.uid = "Prometheus"
          else .
          end
        )' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    url='https://raw.githubusercontent.com/ObolNetwork/lido-charon-distributed-validator-node/main/grafana/dashboards/validator_ejector_overview.json'
    file='/etc/grafana/provisioning/dashboards/validator_ejector_overview.json'
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(
          if (type == "object" and .datasource? and .datasource.uid? == "prometheus")
          then .datasource.uid = "Prometheus"
          else .
          end
        )' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    url='https://raw.githubusercontent.com/ObolNetwork/lido-charon-distributed-validator-node/main/grafana/dashboards/logs_dashboard.json'
    file='/etc/grafana/provisioning/dashboards/logs_dashboard.json'
    wget -t 3 -T 10 -qcO - "${url}" \
      | jq 'walk(
          if (type == "object" and .datasource? and .datasource.uid? == "loki")
          then .datasource.uid = "Loki"
          else .
          end
        )' \
      | jq 'walk(if . == "${DS_LOKI}" then "Loki" else . end)' >"${file}"
    ;;
esac

# Provision cadvisor and node exporter dashboards
case "${CLIENT}" in
  !(*grafana-rootless*) )
    # cadvisor and node exporter dashboard
    id=19724
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq .revision)
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/docker-host-container-overview.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    # Another cadvisor and node exporter dashboard
    id=15120
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq .revision)
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/host-docker-monitoring.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq '.title = "Host & Docker Monitoring"' \
      | jq '.panels |= map(if .title == "Temp" then .targets[0] |= (.legendFormat = "{{type}}" | .expr = "node_thermal_zone_temp")| .options.orientation = "vertical" elif .title == "Temperature" then .targets[0].expr = "node_thermal_zone_temp" else . end)' \
      | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
    # Log file dashboard (via loki)
    id=20223
    revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq .revision)
    url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
    file='/etc/grafana/provisioning/dashboards/eth-docker-logs.json'
    wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_LOKI}" then "Loki" else . end)' >"${file}"
    ;;
esac

# Always provision a few basics
# Home staking dashboard
id=17846
revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq .revision)
url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
file='/etc/grafana/provisioning/dashboards/homestaking-dashboard.json'
wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"
# Ethereum Metrics Exporter Dashboard
id=16277
revision=$(wget -t 3 -T 10 -qO - https://grafana.com/api/dashboards/${id} | jq .revision)
url="https://grafana.com/api/dashboards/${id}/revisions/${revision}/download"
file='/etc/grafana/provisioning/dashboards/ethereum-metrics-exporter-single.json'
wget -t 3 -T 10 -qcO - "${url}" | jq 'walk(if . == "${DS_PROMETHEUS}" then "Prometheus" else . end)' >"${file}"

# Remove empty files, so a download error doesn't kill Grafana
find /etc/grafana/provisioning -type f -empty -delete

tree /etc/grafana/provisioning/

exec "$@"
