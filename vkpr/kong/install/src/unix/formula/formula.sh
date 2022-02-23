#!/bin/bash

runFormula() {
  checkGlobalConfig "$DOMAIN" "localhost" "domain" "DOMAIN"
  checkGlobalConfig "$SECURE" "false" "secure" "SECURE"
  checkGlobalConfig "$HA" "false" "kong.HA" "KONG_HA"
  checkGlobalConfig "false" "false" "kong.metrics" "KONG_METRICS"
  checkGlobalConfig "$KONG_MODE" "dbless" "kong.mode" "KONG_DEPLOY"
  checkGlobalConfig "$RBAC_PASSWORD" "vkpr123" "kong.rbac.adminPassword" "KONG_RBAC"
  checkGlobalConfig "$VKPR_K8S_NAMESPACE" "vkpr" "kong.namespace" "KONG_NAMESPACE"

  # External apps values
  checkGlobalConfig "$VKPR_K8S_NAMESPACE" "vkpr" "postgresql.namespace" "POSTGRESQL_NAMESPACE"

  local VKPR_KONG_VALUES; VKPR_KONG_VALUES="$(dirname "$0")"/utils/kong.yaml

  startInfos
  addRepoKong
  addDependencies
  [[ "$VKPR_ENV_KONG_DEPLOY" != "dbless" ]] && installDB
  [[ "$ENTERPRISE" == true ]] && createKongSecrets
  installKong
}

startInfos() {
  echo "=============================="
  echoColor "bold" "$(echoColor "green" "VKPR Kong Install Routine")"
  echoColor "bold" "$(echoColor "blue" "Kong HTTPS:") ${VKPR_ENV_SECURE}"
  echoColor "bold" "$(echoColor "blue" "Kong Domain:") ${VKPR_ENV_DOMAIN}"
  echoColor "bold" "$(echoColor "blue" "Kong HA:") ${VKPR_ENV_KONG_HA}"
  echoColor "bold" "$(echoColor "blue" "Kong Mode:") ${VKPR_ENV_KONG_DEPLOY}"
  echo "=============================="
}

addRepoKong(){
  registerHelmRepository kong https://charts.konghq.com
}

addDependencies(){
  mkdir -p config/
  printf "{
  \"cookie_name\": \"admin_session\",
  \"cookie_samesite\": \"Strict\",
  \"secret\": \"$(openssl rand -base64 32)\",
  \"cookie_secure\": false,
  \"storage\": \"kong\",
  \"cookie_domain\": \"manager.%s\"
}" "$VKPR_ENV_DOMAIN" > config/admin_gui_session_conf

  printf "{
  \"cookie_name\": \"portal_session\",
  \"cookie_samesite\": \"Strict\",
  \"secret\": \"$(openssl rand -base64 32)\",
  \"cookie_secure\": false,
  \"storage\": \"kong\",
  \"cookie_domain\": \"portal.%s\"
}" "$VKPR_ENV_DOMAIN" > config/portal_session_conf

  if [[ "$VKPR_ENV_KONG_DEPLOY" == "hybrid" ]]; then
    openssl req -new -x509 -nodes -newkey ec:<(openssl ecparam -name secp384r1) \
                -keyout config/cluster.key -out config/cluster.crt \
                -days 1095 -subj "/CN=kong_clustering"
  fi
}

createKongSecrets() {
  echoColor "green" "Creating the Kong Secrets..."
  $VKPR_KUBECTL create ns "$VKPR_ENV_KONG_NAMESPACE" 2> /dev/null

  [[ "$LICENSE" == " " ]] && LICENSE="license"
  local LICENSE_CONTENT; LICENSE_CONTENT=$(cat "$LICENSE" 2> /dev/null)
  $VKPR_KUBECTL create secret generic kong-enterprise-license --from-literal="license=$LICENSE_CONTENT" -n "$VKPR_ENV_KONG_NAMESPACE" && \
  $VKPR_KUBECTL label secret kong-enterprise-license vkpr=true app.kubernetes.io/instance=kong -n "$VKPR_ENV_KONG_NAMESPACE"

  if [[ "$VKPR_ENV_KONG_DEPLOY" != "dbless" ]]; then
    $VKPR_KUBECTL create secret generic kong-session-config \
      --from-file=config/admin_gui_session_conf \
      --from-file=config/portal_session_conf -n "$VKPR_ENV_KONG_NAMESPACE" && \
    $VKPR_KUBECTL label secret kong-session-config vkpr=true app.kubernetes.io/instance=kong -n "$VKPR_ENV_KONG_NAMESPACE"
  fi

  if [[ "$VKPR_ENV_KONG_DEPLOY" = "hybrid" ]]; then
    $VKPR_KUBECTL create ns kong

    $VKPR_KUBECTL create secret tls kong-cluster-cert --cert=config/cluster.crt --key=config/cluster.key -n "$VKPR_ENV_KONG_NAMESPACE" && \
      $VKPR_KUBECTL label secret kong-cluster-cert vkpr=true app.kubernetes.io/instance=kong -n "$VKPR_ENV_KONG_NAMESPACE"

    $VKPR_KUBECTL create secret tls kong-cluster-cert --cert=config/cluster.crt --key=config/cluster.key -n kong && \
      $VKPR_KUBECTL label secret kong-cluster-cert vkpr=true app.kubernetes.io/instance=kong -n kong

    $VKPR_KUBECTL create secret generic kong-enterprise-license --from-file=$LICENSE -n kong && \
      $VKPR_KUBECTL label secret kong-enterprise-license vkpr=true app.kubernetes.io/instance=kong -n kong
  fi

  rm -rf "$(dirname "$0")"/config/
}

installDB(){
  local PG_HA="false"
  [[ $VKPR_ENV_KONG_HA == true ]] && PG_HA="true"

  if [[ $(checkPodName "$VKPR_ENV_POSTGRESQL_NAMESPACE" "postgres-postgresql") != "true" ]]; then
    echoColor "green" "Initializing postgresql to Kong"
    [[ -f $CURRENT_PWD/vkpr.yaml ]] && cp "$CURRENT_PWD"/vkpr.yaml "$(dirname "$0")"
    rit vkpr postgres install --HA=$PG_HA --default
  else
    echoColor "green" "Initializing Kong with Postgres already created"
  fi
}

installKong(){
  local YQ_VALUES=".proxy.enabled = true"
  settingKongEnterprise

  case "$VKPR_ENV_KONG_DEPLOY" in
    hybrid)
      installKongDP
      VKPR_KONG_VALUES="$(dirname "$0")"/utils/kong-cp.yaml
    ;;
    dbless)
      VKPR_KONG_VALUES="$(dirname "$0")"/utils/kong-dbless.yaml
    ;;
  esac

  echoColor "bold" "$(echoColor "green" "Installing Kong...")"
  settingKongDefaults

  $VKPR_YQ eval "$YQ_VALUES" "$VKPR_KONG_VALUES" \
  | $VKPR_HELM upgrade -i --version "$VKPR_KONG_VERSION" \
    --namespace "$VKPR_ENV_KONG_NAMESPACE" --create-namespace \
    --wait -f - kong kong/kong

  if [[ "$VKPR_ENV_KONG_METRICS" == true ]]; then
    $VKPR_KUBECTL apply -f "$(dirname "$0")"/utils/prometheus-plugin.yaml
  fi
}

installKongDP() {
  echoColor "bold" "$(echoColor "green" "Installing Kong DP in cluster...")"
  local VKPR_KONG_DP_VALUES; VKPR_KONG_DP_VALUES="$(dirname "$0")"/utils/kong-dp.yaml

  $VKPR_YQ eval "$YQ_VALUES" "$VKPR_KONG_DP_VALUES" \
  | $VKPR_HELM upgrade -i --version "$VKPR_KONG_VERSION" \
    --namespace kong --create-namespace \
    --wait -f - kong-dp kong/kong
}

settingKongDefaults() {
  local PG_HOST="postgres-postgresql.${VKPR_ENV_POSTGRESQL_NAMESPACE}"
  local PG_SECRET="postgres-postgresql"

  if $VKPR_KUBECTL get pod -n "$VKPR_ENV_POSTGRESQL_NAMESPACE" | grep -q pgpool; then
    PG_HOST="postgres-postgresql-pgpool.${VKPR_ENV_POSTGRESQL_NAMESPACE}"
    PG_SECRET="postgres-postgresql-postgresql"
    YQ_VALUES="$YQ_VALUES |
     .env.pg_password.valueFrom.secretKeyRef.name = \"$PG_SECRET\"
    "
  fi

  if ! $VKPR_KUBECTL get secret -n "$VKPR_ENV_KONG_NAMESPACE" | grep -q "$PG_SECRET"; then
    PG_PASSWORD=$($VKPR_KUBECTL get secret "$PG_SECRET" -o yaml -n "$VKPR_ENV_POSTGRESQL_NAMESPACE" |\
    $VKPR_YQ e ".data.postgresql-password" -)
    $VKPR_KUBECTL create secret generic "$PG_SECRET" --from-literal="postgresql-password=$PG_PASSWORD" -n "$VKPR_ENV_KONG_NAMESPACE"
    $VKPR_KUBECTL label secret "$PG_SECRET" vkpr=true app.kubernetes.io/instance=kong -n "$VKPR_ENV_KONG_NAMESPACE"
  fi

  YQ_VALUES="$YQ_VALUES |
    .env.pg_host = \"$PG_HOST\"
  "

  if [[ "$VKPR_ENV_DOMAIN" != "localhost" ]]; then
    YQ_VALUES="$YQ_VALUES |
      .admin.ingress.hostname = \"api.manager.$VKPR_ENV_DOMAIN\" |
      .manager.ingress.hostname = \"manager.$VKPR_ENV_DOMAIN\" |
      .portal.ingress.hostname = \"portal.$VKPR_ENV_DOMAIN\" |
      .portalapi.ingress.hostname = \"api.portal.$VKPR_ENV_DOMAIN\" |
      .env.admin_gui_url = \"http://manager.$VKPR_ENV_DOMAIN\" |
      .env.admin_api_uri = \"http://api.manager.$VKPR_ENV_DOMAIN\"|
      .env.portal_gui_host = \"http://portal.$VKPR_ENV_DOMAIN\" |
      .env.portal_api_url = \"http://api.portal.$VKPR_ENV_DOMAIN\"
    "

    if [[ "$VKPR_ENV_SECURE" == true ]]; then
      YQ_VALUES="$YQ_VALUES |
        .admin.ingress.annotations.[\"kubernetes.io/tls-acme\"] = \"true\" |
        .admin.ingress.tls = \"admin-kong-cert\" |
        .manager.ingress.annotations.[\"kubernetes.io/tls-acme\"] = \"true\" |
        .manager.ingress.tls = \"manager-kong-cert\" |
        .env.portal_gui_protocol = \"https\" |
        .env.admin_gui_url = \"https://manager.$VKPR_ENV_DOMAIN\" |
        .env.admin_api_uri = \"https://api.manager.$VKPR_ENV_DOMAIN\"|
        .env.portal_gui_host = \"https://portal.$VKPR_ENV_DOMAIN\" |
        .env.portal_api_url = \"https://api.portal.$VKPR_ENV_DOMAIN\"
      "
    fi
  fi

  if [[ "$VKPR_ENV_KONG_DEPLOY" != "dbless" ]]; then
    YQ_VALUES="$YQ_VALUES |
      .portal.ingress.annotations.[\"kubernetes.io/tls-acme\"] = \"true\" |
      .portal.ingress.tls = \"portal-kong-cert\" |
      .portalapi.ingress.annotations.[\"kubernetes.io/tls-acme\"] = \"true\" |
      .portalapi.ingress.tls = \"portalapi-kong-cert\"
    "
  fi

  if [[ "$VKPR_ENV_KONG_METRICS" == "true" ]]; then
    YQ_VALUES="$YQ_VALUES |
      .serviceMonitor.enabled = \"true\" |
      .serviceMonitor.namespace = \"$VKPR_ENV_KONG_NAMESPACE\" |
      .serviceMonitor.interval = \"30s\" |
      .serviceMonitor.scrapeTimeout = \"30s\" |
      .serviceMonitor.labels.release = \"prometheus-stack\" |
      .serviceMonitor.targetLabels[0] = \"prometheus-stack\"
    "
  fi

  if [[ "$VKPR_ENV_KONG_HA" == "true" ]]; then
    YQ_VALUES="$YQ_VALUES |
      .replicaCount = \"3\" |
      .ingressController.env.leader_elect = \"true\"
    "
  fi

  if [[ "$ENTERPRISE" == true ]] && [[ "$VKPR_ENV_KONG_DEPLOY" != "dbless" ]]; then
    YQ_VALUES="$YQ_VALUES |
      .env.password.valueFrom.secretKeyRef.name = \"kong-enterprise-superuser-password\" |
      .env.password.valueFrom.secretKeyRef.key = \"password\" |
      .ingressController.env.kong_admin_token.valueFrom.secretKeyRef.name = \"kong-enterprise-superuser-password\" |
      .ingressController.env.kong_admin_token.valueFrom.secretKeyRef.key = \"password\" |
      .enterprise.rbac.enabled = \"true\" |
      .enterprise.rbac.admin_gui_auth = \"basic-auth\" |
      .enterprise.rbac.session_conf_secret = \"kong-session-config\" |
      .env.enforce_rbac = \"on\" |
      .env.enforce_rbac style=\"double\"
    "
  fi

  mergeVkprValuesHelmArgs "kong" "$VKPR_KONG_VALUES"
}

settingKongEnterprise() {
  $VKPR_KUBECTL create secret generic kong-enterprise-superuser-password --from-literal="password=$VKPR_ENV_KONG_RBAC" -n "$VKPR_ENV_KONG_NAMESPACE" && \
    $VKPR_KUBECTL label secret kong-enterprise-superuser-password vkpr=true app.kubernetes.io/instance=kong -n "$VKPR_ENV_KONG_NAMESPACE"

  if [[ "$ENTERPRISE" == true ]]; then
    YQ_VALUES="$YQ_VALUES |
      .image.repository = \"kong/kong-gateway\" |
      .image.tag = \"2.7.1.2-alpine\" |
      .enterprise.enabled = \"true\" |
      .enterprise.vitals.enabled = \"true\" |
      .enterprise.portal.enabled = \"true\"
    "
  fi
}
