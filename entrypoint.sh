#!/bin/bash

set -eu

set_outputs() {
  fly status --json --app="${INPUT_NAME}" > status.json

  echo "url=https://$(jq -r '.Hostname' status.json)" >> "${GITHUB_OUTPUT}"
}

ensure_postgres() {
  local -a args

  if [[ -z "${INPUT_POSTGRES_NAME:-}" ]]; then
    return
  fi

  if is_existing_app "${INPUT_POSTGRES_NAME}"; then
    attach_if_required
    return
  fi

  args+=(--name="${INPUT_POSTGRES_NAME}")
  args+=(--org="${INPUT_ORG}")
  args+=(--region="${INPUT_POSTGRES_REGION}")
  args+=(--vm-size="${INPUT_POSTGRES_VM_SIZE}")
  args+=(--volume-size="${INPUT_POSTGRES_VOLUME_SIZE}")

  if [[ -n "${INPUT_POSTGRES_VM_MEMORY:-}" ]]; then
    args+=(--vm-memory="${INPUT_POSTGRES_VM_MEMORY}")
  fi

  fly postgres create --initial-cluster-size=1 "${args[@]}"

  attach_if_required
}

destroy_release_machine() {
  # Work around a Fly bug that causes release_command machines to be left behind,
  # which in turn causes the app to fail to deploy.

  if ! grep -qE '^release_command' "${INPUT_CONFIG}"; then
    return
  fi

  fly machines list --json --app="${INPUT_NAME}" \
    | jq -r '.[] | select (
        .config.metadata.fly_process_group == "fly_app_release_command" and
        (.state == "stopped" or .state == "failed")
      ) | .id' \
    | xargs -r -n 1 fly machine destroy --force --app="${INPUT_NAME}"
}

deploy() {
  local -a args

  args+=(--app="${INPUT_NAME}")
  args+=(--config="${INPUT_CONFIG}")
  args+=(--ha="${INPUT_HA}")

  if [[ -n "${INPUT_IMAGE:-}" ]]; then
    args+=(--image="${INPUT_IMAGE}")
  fi

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

  fly secrets import --app="${INPUT_NAME}" <<< "${INPUT_SECRETS}"
}

ensure_app() {
  if is_existing_app "${INPUT_NAME}"; then
    return
  fi

  fly apps create --name="${INPUT_NAME}" --org="${INPUT_ORG}"
}

attach_if_required() {
  # Check if the Postgres instance is already attached
  if fly postgres users list --app "${INPUT_POSTGRES_NAME}" | grep -q "${INPUT_NAME//-/_}"; then
    echo "Postgres instance '${INPUT_POSTGRES_NAME}' is already attached to app '${INPUT_NAME}', skipping..."
  else
    echo "Attaching Postgres instance '${INPUT_POSTGRES_NAME}' to app '${INPUT_NAME}'..."
    fly secrets unset DATABASE_URL --app "${INPUT_NAME}" # In case DATABASE_URL _was_ set but the postgres app was destroyed
    fly postgres attach "${INPUT_POSTGRES_NAME}" --app="${INPUT_NAME}" --yes
  fi
}

is_existing_app() {
  local name
  name="$1"

  fly apps list --json --org="${INPUT_ORG}" \
    | jq --exit-status --arg name "${name}" 'any(.Name == $name)' > /dev/null
}

delete_app() {
  if ! is_existing_app "${INPUT_NAME}"; then
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

  if [[ "$action" = "synchronize" && "${INPUT_SYNC}" = "false" ]]; then
    if is_existing_app "${INPUT_NAME}"; then
      set_outputs
      exit 0
    fi
  fi

  ensure_app
  set_secrets
  ensure_postgres
  destroy_release_machine
  deploy
  set_outputs
}

main
