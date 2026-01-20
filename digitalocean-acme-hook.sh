#!/usr/bin/env bash
#
# Digital Ocean hook for Dehydrated - derived from https://github.com/silkeh/pdns_api.sh
# John ORourke for getconnect.net 2026

# Copyright 2016-2021 - Silke Hofstra and contributors
#
# Licensed under the EUPL
#
# You may not use this work except in compliance with the Licence.
# You may obtain a copy of the Licence at:
#
# https://joinup.ec.europa.eu/collection/eupl
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the Licence is distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied.
# See the Licence for the specific language governing
# permissions and limitations under the Licence.
#

set -e
set -u
set -o pipefail

# Local directory
DIR="$(dirname "$0")"

# Config directories
CONFIG_DIRS="/etc/dehydrated /usr/local/etc/dehydrated"

# Show an error/warning
error() { echo "Error: $*" >&2; }
warn() { echo "Warning: $*" >&2; }
fatalerror() { error "$*"; exit 1; }

# Debug message
debug() { [[ -z "${DEBUG:-}" ]] || echo "$@"; }

# Join an array with a character
join() { local IFS="$1"; shift; echo "$*"; }

# Reverse a string
rev() {
  local str rev
  str="$(cat)"
  rev=""
  for (( i=${#str}-1; i>=0; i-- )); do rev="${rev}${str:$i:1}"; done
  echo "${rev}"
}

# Load the configuration and set default values
load_config() {
  # Check for config in various locations
  # From letsencrypt.sh
  if [[ -z "${CONFIG:-}" ]]; then
    for check_config in ${CONFIG_DIRS} "${PWD}" "${DIR}"; do
      if [[ -f "${check_config}/config" ]]; then
        CONFIG="${check_config}/config"
        break
      fi
    done
  fi

  # Check if config was set
  if [[ -z "${CONFIG:-}" ]]; then
    # Warn about missing config
    warn "No config file found, using default config!"
  elif [[ -f "${CONFIG}" ]]; then
    # shellcheck disable=SC1090
    . "${CONFIG}"
  fi

  if [[ -n "${CONFIG_D:-}" ]]; then
    if [[ ! -d "${CONFIG_D}" ]]; then
      fatalerror "The path ${CONFIG_D} specified for CONFIG_D does not point to a directory."
    fi

    # Allow globbing
    if [[ -n "${ZSH_VERSION:-}" ]]
    then
      set +o noglob
    else
      set +f
    fi

    for check_config_d in "${CONFIG_D}"/*.sh; do
      if [[ -f "${check_config_d}" ]] && [[ -r "${check_config_d}" ]]; then
        echo "# INFO: Using additional config file ${check_config_d}"
        # shellcheck disable=SC1090
        . "${check_config_d}"
      else
        fatalerror "Specified additional config ${check_config_d} is not readable or not a file at all."
      fi
    done

    # Disable globbing
    if [[ -n "${ZSH_VERSION:-}" ]]
    then
      set -o noglob
    else
      set -f
    fi
  fi

  # Check required settings
  [[ -n "${DIGITALOCEAN_TOKEN:-}" ]]  || fatalerror "DIGITALOCEAN_TOKEN setting is required."

}

# Load the zones from file
load_zones() {
  # Check for zones.txt in various locations
  if [[ -z "${PDNS_ZONES_TXT:-}" ]]; then
    for check_zones in ${CONFIG_DIRS} "${PWD}" "${DIR}"; do
      if [[ -f "${check_zones}/zones.txt" ]]; then
        PDNS_ZONES_TXT="${check_zones}/zones.txt"
        break
      fi
    done
  fi

  # Load zones
  all_zones=()
  if [[ -n "${PDNS_ZONES_TXT:-}" ]] && [[ -f "${PDNS_ZONES_TXT}" ]]; then
    mapfile -t all_zones < "${PDNS_ZONES_TXT}"
  fi
}

# API request
request() {
  # Request parameters
  local method url data
  method="$1"
  url="$2"
  data="$3"
  error=false

  # Perform the request
  # This is wrappend in an if to avoid the exit on error
  # shellcheck disable=SC2086
  if ! res="$(curl ${PDNS_CURL_OPTS:-} -sSfL --stderr - --request "${method}" --header "${content_header}" --header "${api_header}" --data "${data}" "${url}")"; then
    error=true
  fi

  # Debug output
  debug "# Request"
  debug "Method: ${method}"
  debug "URL: ${url}"
  debug "Data: ${data}"
  debug "Response: ${res}"

  # Abort on failed request
  if [[ "${res}" = *"error"* ]] || [[ "${error}" = true ]]; then
    fatalerror "API error: ${res}"
  fi
}

# Setup of connection settings
setup() {
  # Header values
  api_header="Authorization: Bearer ${DIGITALOCEAN_TOKEN}"
  content_header="Content-Type: application/json"
  url="https://api.digitalocean.com/v2/domains"

  # Get a zone list from the API if none was set
  if [[ ${#all_zones[@]} -eq 0 ]]; then
    request "GET" "${url}" ""
    mapfile -t all_zones < <(<<< "${res}" jq -r ".domains[].name")
  fi

  # Strip trailing dots from zones
  all_zones=("${all_zones[@]//$'.\n'/ }")
  all_zones=("${all_zones[@]%.}")

  # Sort zones to list most specific first
  mapfile -t all_zones < <(printf '%s\n' "${all_zones[@]}" | rev | sort | rev)

  # Set suffix in case of CNAME redirection
  if [[ -n "${PDNS_SUFFIX:-}" ]]; then
      suffix=".${PDNS_SUFFIX}"
  else
      suffix=""
  fi

  # Debug setup result
  debug "# Setup"
  debug "Zones: $(printf '%s ' "${all_zones[@]}")"
  debug "Suffix: \"${suffix}\""
}

setup_domain() {
  # Domain and token from arguments
  domain="$1"
  token="$2"
  zone=""

  # Record name
  name="_acme-challenge.${domain}${suffix}"

  # Read name parts into array
  IFS='.' read -ra name_array <<< "${name}"

  # Find zone name, cut off subdomains until match
  for check_zone in "${all_zones[@]}"; do
    for (( j=${#name_array[@]}-1; j>=0; j-- )); do
      if [[ "${check_zone}" = "$(join . "${name_array[@]:j}")" ]]; then
        zone="${check_zone}"
	name=$(join . "${name_array[@]:0:j}");
        break 2
      fi
    done
  done

  # Fallback to creating zone from arguments
  if [[ -z "${zone}" ]]; then
    zone="${name_array[*]: -2:1}.${name_array[*]: -1:1}"
    name="${name_array[*]:0:${#name_array[@]}-1}"
    warn "zone not found, using '${zone}' and name '${name}'"
  fi

}

get_tokens() {
  IFS=" " read -ra tokens <<< "${token}"

  for i in "${!tokens[@]}"; do
    [[ $i -ne 0 ]] && echo -n " "
    echo -n ${tokens[$i]}
  done
}

# https://docs.digitalocean.com/reference/api/digitalocean/#tag/Domain-Records/operation/domains_create_record
# TTL must be over 30, and don't send null values
deploy_record() {
  echo -n '{
    "type": "TXT",
    "name": "'"${name}"'",
    "data": "'"${deploy_token}"'",
    "ttl": 300
  }'
}

clean_record() {
  depth_count=1
  next_page="${url}/${zone}/records"
  debug "Fetching ${next_page}"
  while [ -n "$next_page" ]; do
    request GET "${next_page}" ""
    mapfile -t _deletion_ids < <(<<< "${res}" jq -r '.domain_records[] | select(.name|startswith("'${name}'")) | .id')
    mapfile -t _deletion_names < <(<<< "${res}" jq -r '.domain_records[] | select(.name|startswith("'${name}'")) | .name')
    if [[ -n "${_deletion_ids:-}" ]]; then
      debug "Deleting records with IDs ${_deletion_ids:-} for names ${_deletion_names:-}"
      for _id in $_deletion_ids; do
        request DELETE "${url}/${zone}/records/${_id}" ""
      done
    fi
    let depth_count++
    next_page=$(<<< "${res}" jq -r '.links.pages.next|select(.!=null)')
    if [[ -n "$next_page" ]] ; then
      debug "Next page of records at ${next_page}"
    fi
  done
}

exit_hook() {
  if [[ -n "${PDNS_EXIT_HOOK:-}" ]]; then
    exec ${PDNS_EXIT_HOOK}
  fi
}

deploy_cert() {
  if [[ -n "${PDNS_DEPLOY_CERT_HOOK:-}" ]]; then
    exec ${PDNS_DEPLOY_CERT_HOOK}
  fi
}

main() {
  # Set hook
  hook="$1"

  # Ignore unknown hooks
  if [[ ! "${hook}" =~ ^(deploy_challenge|clean_challenge|exit_hook|deploy_cert)$ ]]; then
    exit 0
  fi

  # Main setup
  load_config
  load_zones
  setup
  declare -A requests

  # Debug output
  debug "# Main"
  debug "Bash: ${BASH_VERSION}"
  debug "Args: $*"
  debug "Hook: ${hook}"

  # Interface for exit_hook
  if [[ "${hook}" = "exit_hook" ]]; then
    shift
    exit_hook "$@"
    exit 0
  fi

  # Interface for deploy_cert
  if [[ "${hook}" = "deploy_cert" ]]; then
    deploy_cert "$@"
    exit 0
  fi

  declare -A domains
  # Loop through arguments per 3
  for ((i=2; i<=$#; i=i+3)); do
    t=$((i + 2))
    _domain="${!i}"
    _token="${!t}"

    if [[ "${_domain}" == "*."* ]]; then
      debug "Domain ${_domain} is a wildcard domain, ACME challenge will be for domain apex (${_domain:2})"
      _domain="${_domain:2}"
    fi

    domains[${_domain}]="${_token} ${domains[${_domain}]:-}"
  done

  # Loop through unique domains
  for domain in "${!domains[@]}"; do
    # Setup for this domain
    req=""
    t=${domains[${domain}]}
    setup_domain "${domain}" "${t}"

    # Debug output
    debug "# Domain"
    debug "Name:  ${name}"
    debug "Token: ${token}"
    debug "Zone:  ${zone}"

    # Deploy tokens
    if [[ "${hook}" = "deploy_challenge" ]]; then
      for deploy_token in $(get_tokens); do
        request "POST" "${url}/${zone}/records" "$(deploy_record)"
        #if [[ -z "${PDNS_NO_NOTIFY:-}" ]]; then
          # request "PUT" "${url}/${zone}/notify" ''
        #fi
      done
    fi

    # Remove tokens
    if [[ "${hook}" = "clean_challenge" ]]; then
      clean_record
      #if [[ -z "${PDNS_NO_NOTIFY:-}" ]]; then
        # request "PUT" "${url}/${zone}/notify" ''
      #fi
    fi

    # Other actions are not implemented but will not cause an error
  done

  # Wait the requested amount of seconds when deployed
  if [[ "${hook}" = "deploy_challenge" ]] && [[ -n "${DO_WAIT:=10}" ]]; then
    debug "Waiting for ${DO_WAIT} seconds"

    sleep "${DO_WAIT}"
  fi
}

main "$@"
