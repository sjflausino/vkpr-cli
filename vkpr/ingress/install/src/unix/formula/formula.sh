#!/bin/sh


runFormula() {
  local VKPR_INGRESS_VALUES=$(dirname "$0")/utils/ingress.yaml
  
  checkGlobalConfig $LB_TYPE "ingress.loadBalancerType" "Classic" "LB_TYPE"
  checkGlobalConfig "false" "false" "ingress.metrics" "METRICS"
  
  startInfos
  configureRepository
  installIngress
}

startInfos() {
  echo "=============================="
  echoColor "bold" "$(echoColor "green" "VKPR Ingress Install Routine")"
  echo "=============================="
}

configureRepository() {
  registerHelmRepository nginx-stable https://helm.nginx.com/stable
}

installIngress() {
  echoColor "bold" "$(echoColor "green" "Installing ngnix ingress...")"
  settingIngress
  $VKPR_YQ eval "$YQ_VALUES" "$VKPR_INGRESS_VALUES" \
  | $VKPR_HELM upgrade -i --version "$VKPR_INGRESS_NGINX_VERSION" \
      --namespace $VKPR_K8S_NAMESPACE --create-namespace \
      --wait --timeout 5m0s -f - ingress-nginx nginx-stable/nginx-ingress
}

settingIngress() {
  if [[ $VKPR_ENV_LB_TYPE == "NLB" ]]; then
    YQ_VALUES='
      .controller.service.annotations.["'service.beta.kubernetes.io/aws-load-balancer-backend-protocol'"] = "tcp" |
      .controller.service.annotations.["'service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled'"] = "'true'" |
      .controller.service.annotations.["'service.beta.kubernetes.io/aws-load-balancer-type'"] = "nlb"
    '
  fi

  if [[ $VKPR_ENV_METRICS = "true" ]]; then
    YQ_VALUES=''$YQ_VALUES' |      
      .controller.enableLatencyMetrics = "true" |
      .prometheus.create = "true"
    ' 
  fi

  mergeVkprValuesHelmArgs "ingress" $VKPR_INGRESS_VALUES
}