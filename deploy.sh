#!/bin/bash
#
# Copyright 2019 The Cloud Robotics Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Manage a deployment

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${DIR}/scripts/common.sh"

set -o pipefail -o errexit

PROJECT_NAME="cloud-robotics"

if [[ -e "${DIR}/INSTALL_FROM_BINARY" ]]; then
  TERRAFORM="${DIR}/bin/terraform"
  HELM_COMMAND="${DIR}/bin/helm"
else
  TERRAFORM="${DIR}/bazel-out/../../../external/hashicorp_terraform/terraform"
  HELM_COMMAND="${DIR}/bazel-out/../../../external/kubernetes_helm/helm"
fi

TERRAFORM_DIR="${DIR}/src/bootstrap/cloud/terraform"
TERRAFORM_APPLY_FLAGS=${TERRAFORM_APPLY_FLAGS:- -auto-approve}

APP_MANAGEMENT=${APP_MANAGEMENT:-false}

# utility functions

function include_config {
  source "${DIR}/scripts/include-config.sh"

  PROJECT_DOMAIN=${CLOUD_ROBOTICS_DOMAIN:-"www.endpoints.${GCP_PROJECT_ID}.cloud.goog"}
  PROJECT_OWNER_EMAIL=${CLOUD_ROBOTICS_OWNER_EMAIL:-$(gcloud config get-value account)}
  KUBE_CONTEXT="gke_${GCP_PROJECT_ID}_${GCP_ZONE}_${PROJECT_NAME}"

  HELM="${HELM_COMMAND} --kube-context ${KUBE_CONTEXT}"
}

function prepare_source_install {
  bazel build "@hashicorp_terraform//:terraform" \
      "@kubernetes_helm//:helm" \
      //src/app_charts/base:base-cloud \
      //src/app_charts/platform-apps:platform-apps-cloud \
      //src/app_charts:push \
      //src/bootstrap/robot:setup-robot-image-reference-txt \
      //src/go/cmd/cr-adapter:cr-adapter.push \
      //src/go/cmd/setup-robot:setup-robot.push \
      //src/proto/map:proto_descriptor \

  # `setup-robot.push` is the first container push to avoid a GCR bug with parallel pushes on newly
  # created projects (see b/123625511).
  ${DIR}/bazel-bin/src/go/cmd/setup-robot/setup-robot.push

  # The cr-adapter isn't packaged as a GCR app and hence pushed separately.
  ${DIR}/bazel-bin/src/go/cmd/cr-adapter/cr-adapter.push
  # Running :push outside the build system shaves ~3 seconds off an incremental build.
  ${DIR}/bazel-bin/src/app_charts/push
}

function check_project_resources {
  # TODO(rodrigoq): if cleanup-services.sh is adjusted to allow specifying the
  # project, adjust this message too.
  echo "Project resource status:"
  "${DIR}"/scripts/show-resource-usage.sh ${GCP_PROJECT_ID} \
    || die "ERROR: Quota reached, consider running scripts/cleanup-services.sh"
}

function clear_iot_devices {
  local iot_registry_name="$1"
  local devices
  devices=$(gcloud beta iot devices list \
    --project "${GCP_PROJECT_ID}" \
    --region "${GCP_REGION}" \
    --registry "${iot_registry_name}" \
    --format='value(id)')
  if [[ -n "${devices}" ]] ; then
    echo "Clearing IoT devices from ${iot_registry_name}" 1>&2
    for dev in ${devices}; do
      gcloud beta iot devices delete \
        --quiet \
        --project "${GCP_PROJECT_ID}" \
        --region "${GCP_REGION}" \
        --registry "${iot_registry_name}" \
        ${dev}
    done
  fi
}

function terraform_exec {
  ( cd "${TERRAFORM_DIR}" && ${TERRAFORM} "$@" )
}

function terraform_init {
  local IMAGE_PROJECT_ID
  IMAGE_PROJECT_ID="$(echo ${CLOUD_ROBOTICS_CONTAINER_REGISTRY} | sed -n -e 's:^.*gcr.io/::p')"

  # Pass CLOUD_ROBOTICS_DOMAIN here and not PROJECT_DOMAIN, as we only create dns resources if a custom
  # domain is used.
  cat > "${TERRAFORM_DIR}/terraform.tfvars" <<EOF
# autogenerated by deploy.sh, do not edit!
name = "${GCP_PROJECT_ID}"
id = "${GCP_PROJECT_ID}"
domain = "${CLOUD_ROBOTICS_DOMAIN}"
zone = "${GCP_ZONE}"
region = "${GCP_REGION}"
shared_owner_group = "${CLOUD_ROBOTICS_SHARED_OWNER_GROUP}"
EOF

  if [[ -n "${IMAGE_PROJECT_ID}" ]] && [[ "${IMAGE_PROJECT_ID}" != "${GCP_PROJECT_ID}" ]]; then
    cat >> "${TERRAFORM_DIR}/terraform.tfvars" <<EOF
private_image_repositories = ["${IMAGE_PROJECT_ID}"]
EOF
  fi

  if [[ -n "${TERRAFORM_GCS_BUCKET:-}" ]]; then
    cat > "${TERRAFORM_DIR}/backend.tf" <<EOF
# autogenerated by deploy.sh, do not edit!
terraform {
  backend "gcs" {
    bucket = "${TERRAFORM_GCS_BUCKET}"
    prefix = "${TERRAFORM_GCS_PREFIX}"
  }
}
EOF
  else
    rm -f "${TERRAFORM_DIR}/backend.tf"
  fi

  terraform_exec init -upgrade -reconfigure \
    || die "terraform init failed"
}

function terraform_apply {
  terraform_init

  # Workaround for https://github.com/terraform-providers/terraform-provider-google/issues/2118
  terraform_exec import google_app_engine_application.app ${GCP_PROJECT_ID} 2>/dev/null || true
  # We've stopped managing Google Cloud projects in Terraform, make sure they
  # aren't deleted.
  terraform_exec state rm google_project.project 2>/dev/null || true

  terraform_exec apply ${TERRAFORM_APPLY_FLAGS} \
    || die "terraform apply failed"
}

function terraform_delete {
  terraform_exec destroy -auto-approve || die "terraform destroy failed"
}

function helm_charts {
  local GCP_PROJECT_NUMBER
  GCP_PROJECT_NUMBER=$(terraform_exec output project-number)
  local INGRESS_IP
  INGRESS_IP=$(terraform_exec output ingress-ip)

  gcloud container clusters get-credentials "${PROJECT_NAME}" \
    --zone ${GCP_ZONE} \
    --project ${GCP_PROJECT_ID} \
    || die "create: failed to get cluster credentials"

  ${HELM} init --history-max=10 --upgrade --force-upgrade --wait

  # Transitionary helper:
  # Delete the obsolete robot-cluster app. It has been merged back into base.
  ${HELM} delete --purge robot-cluster-cloud 2>/dev/null || true
  if ${HELM} get cloud-base | grep -q "kind: Apps"; then
    # Delete the old cloud-base release, since an immutable field changed in
    # 1d3dfc8.
    ${HELM} delete --purge cloud-base 2>/dev/null || true
  fi

  ${HELM} repo update
  # TODO(ensonic): we'd like to use this as part of 'base-cloud', but have no means of
  # enforcing dependencies. The cert-manager chart introduces new CRDs that we are using in
  # base-cloud.
  # TODO(rodrigoq): when upgrading to v0.6, make sure the CRDs are manually
  # installed beforehand: https://github.com/jetstack/cert-manager/pull/1138
  helmout=$(${HELM} upgrade --install cert-manager --set rbac.create=false stable/cert-manager --version v0.5.2) \
    || die "Helm failed for jetstack-cert-manager: $helmout"

  values=$(cat <<EOF
    --set-string domain=${PROJECT_DOMAIN}
    --set-string ingress_ip=${INGRESS_IP}
    --set-string project=${GCP_PROJECT_ID}
    --set-string project_number=${GCP_PROJECT_NUMBER}
    --set-string region=${GCP_REGION}
    --set-string owner_email=${PROJECT_OWNER_EMAIL}
    --set-string app_management=${APP_MANAGEMENT}
    --set-string deploy_environment=${CLOUD_ROBOTICS_DEPLOY_ENVIRONMENT}
    --set-string oauth2_proxy.client_id=${CLOUD_ROBOTICS_OAUTH2_CLIENT_ID}
    --set-string oauth2_proxy.client_secret=${CLOUD_ROBOTICS_OAUTH2_CLIENT_SECRET}
    --set-string oauth2_proxy.cookie_secret=${CLOUD_ROBOTICS_COOKIE_SECRET}
EOF
)

  # TODO(rodrigoq): during the repo reorg, make sure that the release name
  # matches the chart name. Right now one is "cloud-base" and the other is
  # "base-cloud", which is confusing.
  helmout=$(${HELM} upgrade --install cloud-base ./bazel-bin/src/app_charts/base/base-cloud-0.0.1.tgz $values) \
    || die "Helm failed for base-cloud: $helmout"
  echo "helm installed base-cloud to ${KUBE_CONTEXT}: $helmout"

  helmout=$(${HELM} upgrade --install platform-apps ./bazel-genfiles/src/app_charts/platform-apps/platform-apps-cloud-0.0.1.tgz) \
    || die "Helm failed for platform-apps-cloud: $helmout"
  echo "helm installed platform-apps-cloud to ${KUBE_CONTEXT}"
}

# commands

# shellcheck disable=2120
# Parameters are not passed in this script, but may be passed by the user.
function set-project {
  [[ ! -e "${DIR}/config.sh" ]] || [[ ! -e "${DIR}/config.bzl" ]] || \
    die "ERROR: config.sh and config.bzl already exist"
  [[ ! -e "${DIR}/config.sh" ]] || die "ERROR: config.sh already exists but config.bzl does not."
  [[ ! -e "${DIR}/config.bzl" ]] || die "ERROR: config.bzl already exists but config.sh does not."

  local project_id=$1
  if [[ -z ${project_id} ]]; then
    echo "Enter the id of your Google Cloud project:"
    read project_id
  fi

  # Check that the project exists and that we have access.
  gcloud projects describe "${project_id}" >/dev/null \
    || die "ERROR: unable to access Google Cloud project: ${project_id}"

  # Create config files based on templates.
  sed "s/my-project/${project_id}/" "${DIR}/config.bzl.tmpl" > "${DIR}/config.bzl"
  echo "Created config.bzl for ${project_id}."

  sed -e "s/my-project/${project_id}/" "${DIR}/config.sh.tmpl"  > "${DIR}/config.sh"
  echo "Created config.sh for ${project_id}."

  echo "Project successfully set to ${project_id}."
}

function create {
  if [[ ! -e "${DIR}/config.sh" && ! -e "${DIR}/config.bzl" ]]; then
    set-project
  fi
  include_config
  if [[ ! -e "${DIR}/INSTALL_FROM_BINARY" ]]; then
    prepare_source_install
  fi
  terraform_apply
  helm_charts
  check_project_resources
}

function delete {
  include_config
  if [[ ! -e "${DIR}/INSTALL_FROM_BINARY" ]]; then
    bazel build "@hashicorp_terraform//:terraform"
  fi
  clear_iot_devices "cloud-robotics"
  terraform_delete
}

# Alias for create.
function update {
  create
}

# This is a shortcut for skipping Terrafrom configs checks if you know the config has not changed.
function fast_push {
  include_config
  if [[ ! -e "${DIR}/INSTALL_FROM_BINARY" ]]; then
    prepare_source_install
  fi
  helm_charts
}

# main
if [[ ! "$1" =~ ^(set-project|create|delete|update|fast_push)$ ]]; then
  die "Usage: $0 {set-project|create|delete|update|fast_push}"
fi

# call arguments verbatim:
"$@"
