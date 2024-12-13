#!/bin/bash

set -eu

set_outputs() {
  fly status --json --app="${INPUT_NAME}" > status.json

  echo "url=https://$(jq -r '.Hostname' status.json)" >> "${GITHUB_OUTPUT}"
}

ensure_postgres() {
  if [[ -z "${INPUT_POSTGRES_NAME:-}" ]]; then
    return
  fi

  if is_existing_app "${INPUT_POSTGRES_NAME}"; then
    return
  fi

  fly postgres create \
    --name "${INPUT_POSTGRES_NAME}" \
    --org="${INPUT_ORG}" \
    --region="${INPUT_POSTGRES_REGION}"\
    --initial-cluster-size="${INPUT_POSTGRES_INITIAL_CLUSTER_SIZE}" \
    --vm-size="${INPUT_POSTGRES_VM_SIZE}" \
    --volume-size="${INPUT_POSTGRES_VOLUME_SIZE}"

  fly postgres attach "${INPUT_POSTGRES_NAME}" --app="${INPUT_NAME}"
}

deploy() {
  local -a args

  args+=(--app="${INPUT_NAME}")
  args+=(--config="${INPUT_CONFIG}")
  args+=(--ha="${INPUT_HA}")

  while IFS= read -r build_arg; do
    if [[ -n "${build_arg}" ]]; then
      args+=(--build-arg="${build_arg}")
    fi
  done <<< "${INPUT_BUILD_ARGS:-}"

  while IFS= read -r build_secret; do
    if [[ -n "${build_secret}" ]]; then
      args+=(--build-secret="${build_secret}")
    fi
  done <<< "${INPUT_BUILD_SECRETS:-}"

  while IFS= read -r env; do
    if [[ -n "${env}" ]]; then
      args+=(--env="${env}")
    fi
  done <<< "${INPUT_ENV:-}"

  fly deploy --strategy=immediate "${args[@]}"
}

set_secrets() {
  if [[ -z "${INPUT_SECRETS:-}" ]]; then
    return
  fi

  printf "%s" "${INPUT_SECRETS}" | fly secrets import --app="${INPUT_NAME}"
}

ensure_app() {
  if is_existing_app "${INPUT_NAME}"; then
    return
  fi

  fly apps create --name="${INPUT_NAME}" --org="${INPUT_ORG}"
}

is_existing_app() {
  local name
  name="$1"

  fly apps list --json --org="${INPUT_ORG}" \
    | jq --exit-status --arg name "${name}" 'any(.Name == $name)' > /dev/null
}

delete_app() {
  if ! is_existing_app; then
    return
  fi

  fly apps destroy "${INPUT_NAME}" --yes

  if [[ -n "${INPUT_POSTGRES_NAME:-}" ]]; then
    fly apps destroy "${INPUT_POSTGRES_NAME}" --yes
  fi
}

main() {
  local action

  action=$(jq -r .action "${GITHUB_EVENT_PATH}")

  if [[ "$action" = "closed" ]]; then
    delete_app
    exit 0
  fi

  ensure_app
  set_secrets
  ensure_postgres
  deploy
  set_outputs
}

main
