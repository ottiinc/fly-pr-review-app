#!/bin/bash

set -eu

set_outputs() {
  fly status --json --app="${INPUT_NAME}" > status.json

  echo "url=https://$(jq -r '.Hostname' status.json)" >> "${GITHUB_OUTPUT}"
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
  if is_existing_app; then
    return
  fi

  fly apps create --name="${INPUT_NAME}" --org="${INPUT_ORG}"
}

is_existing_app() {
  fly apps list --json --org="${INPUT_ORG}" \
    | jq --exit-status --arg name "${INPUT_NAME}" 'any(.Name == $name)' > /dev/null
}

delete_app() {
  if ! is_existing_app; then
    return
  fi

  fly apps destroy --yes --name="${INPUT_NAME}" --org="${INPUT_ORG}"
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
  deploy
  set_outputs
}

main
