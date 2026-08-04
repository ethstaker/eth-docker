# hadolint global ignore=DL3002,DL3007,DL3008,DL3018,DL3059,DL3066
FROM grafana/grafana:latest

USER root
RUN apk update && apk --no-cache add wget tree jq sed su-exec && rm -rf /var/cache/apk/*

RUN mkdir -p /etc/grafana/provisioning/dashboards/
RUN mkdir -p /etc/grafana/provisioning/datasources/
RUN mkdir -p /etc/grafana/provisioning/alerting/
RUN mkdir -p /tmp/grafana/provisioning/alerting/
RUN chown -R grafana:root /etc/grafana/
RUN chown -R grafana:root /tmp/grafana/
COPY --chown=grafana:root ./dashboard.yml /etc/grafana/provisioning/dashboards/
COPY --chown=grafana:root ./datasource.yml /etc/grafana/provisioning/datasources/
COPY --chown=grafana:root ./default-alerts/*.yml /tmp/grafana/provisioning/alerting/
COPY --chown=grafana:root ./provision.sh /usr/local/bin/
# Belt and suspenders
RUN chmod -R 755 /usr/local/bin/*

ENTRYPOINT [ "/run.sh" ]
