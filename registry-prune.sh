#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Container cleanup for GHCR + Docker Hub (each optional)
# ------------------------------------------------------------
# Keeps:
#   - tag: latest
#   - the NEWEST release-like version (x.y.z or x.y.z-<anything>)
# Deletes:
#   - Release tags older than --max-release-days
#   - Dev tags older than --max-dev-days
#
# Runs only on registries with complete settings provided.
# DRY RUN by default; add --execute to perform deletions.
#
# Dependencies: curl, jq, GNU date (or gdate on macOS)
# GHCR auth: GitHub PAT with read:packages, delete:packages
# Docker Hub auth: username/password (JWT)
# ------------------------------------------------------------

PROTECTED_TAGS=("latest")  # dynamic newest release is determined at runtime

# Defaults
DRY_RUN=1

# --- GHCR (optional) -----------------------------------------
GHCR_OWNER_TYPE="users"    # "users" or "orgs"
GHCR_OWNER=""
GHCR_USER=""               # optional; not used for auth, kept for symmetry
GHCR_TOKEN=""
GHCR_PACKAGE=""

# --- Docker Hub (optional) -----------------------------------
DOCKER_USER=""
DOCKER_PASS=""
DOCKER_NAMESPACE=""
DOCKER_REPO=""

# --- thresholds (required only if at least one registry is enabled)
MAX_RELEASE_DAYS=""
MAX_DEV_DAYS=""

# --- utilities ------------------------------------------------
die() { echo "Error: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Pick a GNU-compatible date (needs -d)
DATE_BIN="date"
if ! date -u -d "1970-01-01T00:00:00Z" +%s >/dev/null 2>&1; then
  if have_cmd gdate; then
    DATE_BIN="gdate"
  else
    die "GNU date required (install coreutils for 'gdate' on macOS)."
  fi
fi
iso_to_epoch() { $DATE_BIN -u -d "$1" +%s; }
now_epoch()    { $DATE_BIN -u +%s; }

contains_protected() {
  local t="$1"
  for p in "${PROTECTED_TAGS[@]}"; do
    [[ "$t" == "$p" ]] && return 0
  done
  return 1
}

# Release: x.y.z or x.y.z-<anything> (letters/digits/dot/hyphen)
is_release_tag() {
  local t="$1"
  [[ "$t" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9\.-]*)?$ ]]
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0")
    [--ghcr-owner-type users|orgs]
    [--ghcr-owner OWNER]
    [--ghcr-user USER] [--ghcr-token TOKEN] [--ghcr-package PACKAGE]
    [--docker-user USER] [--docker-pass PASS] [--docker-namespace NS] [--docker-repo REPO]
    [--max-release-days N] [--max-dev-days M]
    [--execute] [--protect extraTag]...

Notes:
  * You can configure GHCR, Docker Hub, or both. Missing configs => that registry is skipped.
  * If at least one registry is configured, --max-release-days and --max-dev-days are required.
  * Always keeps "latest" and the newest release-like version. Add more with --protect.

Examples:
  # GHCR only (dry-run)
  $(basename "$0") \\
    --ghcr-owner-type users --ghcr-owner ghuser \\
    --ghcr-token ghp_xxx --ghcr-package myimage \\
    --max-release-days 90 --max-dev-days 14

  # Docker Hub only (execute)
  $(basename "$0") \\
    --docker-user dhuser --docker-pass 'secret' \\
    --docker-namespace team --docker-repo myimage \\
    --max-release-days 90 --max-dev-days 14 --execute
EOF
}

# --- arg parsing ----------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ghcr-owner-type) GHCR_OWNER_TYPE="$2"; shift 2;;
    --ghcr-owner) GHCR_OWNER="$2"; shift 2;;
    --ghcr-user) GHCR_USER="$2"; shift 2;;
    --ghcr-token) GHCR_TOKEN="$2"; shift 2;;
    --ghcr-package) GHCR_PACKAGE="$2"; shift 2;;

    --docker-user) DOCKER_USER="$2"; shift 2;;
    --docker-pass) DOCKER_PASS="$2"; shift 2;;
    --docker-namespace) DOCKER_NAMESPACE="$2"; shift 2;;
    --docker-repo) DOCKER_REPO="$2"; shift 2;;

    --max-release-days) MAX_RELEASE_DAYS="$2"; shift 2;;
    --max-dev-days) MAX_DEV_DAYS="$2"; shift 2;;

    --protect) PROTECTED_TAGS+=("$2"); shift 2;;
    --execute) DRY_RUN=0; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1 (see --help)";;
  esac
done

have_cmd curl || die "curl is required"
have_cmd jq   || die "jq is required"

# Determine which registries are enabled (complete config only)
GHCR_ENABLED=0
if [[ -n "$GHCR_OWNER" && -n "$GHCR_TOKEN" && -n "$GHCR_PACKAGE" && ( "$GHCR_OWNER_TYPE" == "users" || "$GHCR_OWNER_TYPE" == "orgs" ) ]]; then
  GHCR_ENABLED=1
fi

DOCKER_ENABLED=0
if [[ -n "$DOCKER_USER" && -n "$DOCKER_PASS" && -n "$DOCKER_NAMESPACE" && -n "$DOCKER_REPO" ]]; then
  DOCKER_ENABLED=1
fi

if (( GHCR_ENABLED == 0 && DOCKER_ENABLED == 0 )); then
  echo "No registry settings provided. Nothing to do."
  exit 0
fi

# Thresholds required only if something will run
if [[ -z "$MAX_RELEASE_DAYS" || -z "$MAX_DEV_DAYS" ]]; then
  die "--max-release-days and --max-dev-days are required when a registry is configured"
fi

echo "Protected tags: ${PROTECTED_TAGS[*]}"
echo "Mode: $([[ $DRY_RUN -eq 1 ]] && echo DRY RUN || echo EXECUTE)"
echo "Enabled: GHCR=$GHCR_ENABLED, DockerHub=$DOCKER_ENABLED"
echo

# --- GHCR ------------------------------------------------------
ghcr_find_newest_release_version_id() {
  local page=1 newest_epoch=-1 newest_id="" newest_tag=""
  while :; do
    local url="https://api.github.com/${GHCR_OWNER_TYPE}/${GHCR_OWNER}/packages/container/${GHCR_PACKAGE}/versions?per_page=100&page=${page}"
    local resp
    if ! resp=$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GHCR_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"); then
      break
    fi
    local count; count=$(echo "$resp" | jq 'length')
    [[ "$count" -gt 0 ]] || break

    while IFS= read -r row; do
      local created_at created_epoch vid has_release=0 tag_found=""
      vid=$(echo "$row" | jq -r '.id')
      created_at=$(echo "$row" | jq -r '.created_at')
      created_epoch=$(iso_to_epoch "$created_at")

      if echo "$row" | jq -e '.metadata.container.tags // [] | length > 0' >/dev/null; then
        while IFS= read -r t; do
          if is_release_tag "$t"; then has_release=1; tag_found="$t"; break; fi
        done < <(echo "$row" | jq -r '.metadata.container.tags[]')
      fi

      if (( has_release )) && (( created_epoch > newest_epoch )); then
        newest_epoch=$created_epoch
        newest_id="$vid"
        newest_tag="$tag_found"
      fi
    done < <(echo "$resp" | jq -c '.[]')
    page=$((page+1))
  done

  echo "$newest_id|$newest_tag"
}

ghcr_cleanup() {
  if (( GHCR_ENABLED == 0 )); then
    echo "==> GHCR: skipping (missing settings)"; echo; return
  fi

  echo "==> GHCR: owner_type=$GHCR_OWNER_TYPE owner=$GHCR_OWNER package=$GHCR_PACKAGE"
  local PROTECTED_NEWEST_GHCR_VERSION_ID PROTECTED_NEWEST_GHCR_VERSION_TAG
  local _result
  _result=$(ghcr_find_newest_release_version_id || true)
  PROTECTED_NEWEST_GHCR_VERSION_ID="${_result%%|*}"
  PROTECTED_NEWEST_GHCR_VERSION_TAG="${_result#*|}"
  if [[ -n "$PROTECTED_NEWEST_GHCR_VERSION_ID" && -n "$PROTECTED_NEWEST_GHCR_VERSION_TAG" && "$PROTECTED_NEWEST_GHCR_VERSION_ID" != "$PROTECTED_NEWEST_GHCR_VERSION_TAG" ]]; then
    echo "GHCR protected newest release-like: tag='$PROTECTED_NEWEST_GHCR_VERSION_TAG' (version_id=$PROTECTED_NEWEST_GHCR_VERSION_ID)"
  elif [[ -n "$PROTECTED_NEWEST_GHCR_VERSION_ID" ]]; then
    echo "GHCR protected newest release-like version_id: $PROTECTED_NEWEST_GHCR_VERSION_ID"
  else
    echo "GHCR: no release-like versions found to protect."
  fi

  local page=1 now; now=$(now_epoch)
  local deleted=0 considered=0 kept=0

  while :; do
    local url="https://api.github.com/${GHCR_OWNER_TYPE}/${GHCR_OWNER}/packages/container/${GHCR_PACKAGE}/versions?per_page=100&page=${page}"
    local resp
    resp=$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GHCR_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url") || break

    local count; count=$(echo "$resp" | jq 'length')
    [[ "$count" -gt 0 ]] || break

    for row in $(echo "$resp" | jq -cr '.[] | @base64'); do
      _jq() { echo "$row" | base64 --decode | jq -r "$1"; }
      local version_id created_at created_epoch age_days
      version_id=$(_jq '.id')
      created_at=$(_jq '.created_at')
      created_epoch=$(iso_to_epoch "$created_at")
      age_days=$(( (now - created_epoch) / 86400 ))

      local tags_json; tags_json=$(_jq '.metadata.container.tags // []')
      readarray -t tags < <(echo "$tags_json" | jq -r '.[]')

      if [[ -n "$PROTECTED_NEWEST_GHCR_VERSION_ID" && "$version_id" == "$PROTECTED_NEWEST_GHCR_VERSION_ID" ]]; then
        kept=$((kept+1))
        echo "GHCR keep (newest release-like version): version_id=$version_id tags=[${tags[*]}] age=${age_days}d"
        continue
      fi

      local has_protected=0
      for t in "${tags[@]}"; do
        if contains_protected "$t"; then has_protected=1; break; fi
      done
      if (( has_protected )); then
        kept=$((kept+1))
        echo "GHCR keep (protected tag): version_id=$version_id tags=[${tags[*]}] age=${age_days}d"
        continue
      fi

      local is_release=0
      for t in "${tags[@]}"; do
        if is_release_tag "$t"; then is_release=1; break; fi
      done
      local threshold=$([[ $is_release -eq 1 ]] && echo "$MAX_RELEASE_DAYS" || echo "$MAX_DEV_DAYS")

      considered=$((considered+1))
      if (( age_days > threshold )); then
        if (( DRY_RUN )); then
          echo "GHCR would DELETE: version_id=$version_id tags=[${tags[*]}] age=${age_days}d (> ${threshold}d, $([[ $is_release -eq 1 ]] && echo release || echo dev))"
        else
          echo "GHCR DELETE: version_id=$version_id tags=[${tags[*]}] age=${age_days}d (> ${threshold}d, $([[ $is_release -eq 1 ]] && echo release || echo dev))"
          curl -fsSL -X DELETE \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GHCR_TOKEN}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/${GHCR_OWNER_TYPE}/${GHCR_OWNER}/packages/container/${GHCR_PACKAGE}/versions/${version_id}" >/dev/null
          deleted=$((deleted+1))
        fi
      else
        kept=$((kept+1))
        echo "GHCR keep: version_id=$version_id tags=[${tags[*]}] age=${age_days}d (<= ${threshold}d)"
      fi
    done

    page=$((page+1))
  done

  echo "GHCR summary: considered=$considered kept=$kept deleted=$deleted (final deletions only with --execute)"
  echo
}

# --- Docker Hub ------------------------------------------------
docker_login() {
  curl -fsSL -H "Content-Type: application/json" \
    -X POST https://hub.docker.com/v2/users/login \
    -d "{\"username\":\"${DOCKER_USER}\",\"password\":\"${DOCKER_PASS}\"}" | jq -r '.token'
}

docker_find_newest_release_tag() {
  local token="$1" url newest_epoch=-1 newest_tag=""
  url="https://hub.docker.com/v2/repositories/${DOCKER_NAMESPACE}/${DOCKER_REPO}/tags?page_size=100&ordering=last_updated"
  while [[ -n "$url" && "$url" != "null" ]]; do
    local resp; resp=$(curl -fsSL -H "Authorization: JWT ${token}" "$url")
    local results_len; results_len=$(echo "$resp" | jq '.results | length')
    [[ "$results_len" -gt 0 ]] || break

    while IFS= read -r row; do
      local tag last_updated epoch
      tag=$(echo "$row" | jq -r '.name')
      last_updated=$(echo "$row" | jq -r '.last_updated')
      if is_release_tag "$tag"; then
        epoch=$(iso_to_epoch "$last_updated")
        if (( epoch > newest_epoch )); then
          newest_epoch=$epoch; newest_tag="$tag"
        fi
      fi
    done < <(echo "$resp" | jq -c '.results[]')

    url=$(echo "$resp" | jq -r '.next')
  done

  echo "$newest_tag"
}

docker_cleanup() {
  if (( DOCKER_ENABLED == 0 )); then
    echo "==> Docker Hub: skipping (missing settings)"; echo; return
  fi

  echo "==> Docker Hub: namespace=$DOCKER_NAMESPACE repo=$DOCKER_REPO"
  local token; token=$(docker_login) || die "Docker Hub login failed"

  local PROTECTED_NEWEST_RELEASE_TAG
  PROTECTED_NEWEST_RELEASE_TAG=$(docker_find_newest_release_tag "$token" || true)
  if [[ -n "$PROTECTED_NEWEST_RELEASE_TAG" ]]; then
    echo "Docker protected newest release-like tag: ${PROTECTED_NEWEST_RELEASE_TAG}"
  else
    echo "Docker: no release-like tags found to protect."
  fi

  local now; now=$(now_epoch)
  local url="https://hub.docker.com/v2/repositories/${DOCKER_NAMESPACE}/${DOCKER_REPO}/tags?page_size=100&ordering=last_updated"
  local deleted=0 considered=0 kept=0

  while [[ -n "$url" && "$url" != "null" ]]; do
    local resp; resp=$(curl -fsSL -H "Authorization: JWT ${token}" "$url")
    local results_len; results_len=$(echo "$resp" | jq '.results | length')
    [[ "$results_len" -eq 0 ]] && break

    for row in $(echo "$resp" | jq -cr '.results[] | @base64'); do
      _jq() { echo "$row" | base64 --decode | jq -r "$1"; }
      local tag last_updated last_epoch age_days
      tag=$(_jq '.name')
      last_updated=$(_jq '.last_updated')
      last_epoch=$(iso_to_epoch "$last_updated")
      age_days=$(( (now - last_epoch) / 86400 ))

      if contains_protected "$tag" || [[ -n "$PROTECTED_NEWEST_RELEASE_TAG" && "$tag" == "$PROTECTED_NEWEST_RELEASE_TAG" ]]; then
        kept=$((kept+1))
        echo "Docker keep (protected): $tag age=${age_days}d"
        continue
      fi

      local is_release=0
      if is_release_tag "$tag"; then is_release=1; fi
      local threshold=$([[ $is_release -eq 1 ]] && echo "$MAX_RELEASE_DAYS" || echo "$MAX_DEV_DAYS")

      considered=$((considered+1))
      if (( age_days > threshold )); then
        if (( DRY_RUN )); then
          echo "Docker would DELETE: $tag age=${age_days}d (> ${threshold}d, $([[ $is_release -eq 1 ]] && echo release || echo dev))"
        else
          echo "Docker DELETE: $tag age=${age_days}d (> ${threshold}d, $([[ $is_release -eq 1 ]] && echo release || echo dev))"
          curl -fsSL -X DELETE -H "Authorization: JWT ${token}" \
            "https://hub.docker.com/v2/repositories/${DOCKER_NAMESPACE}/${DOCKER_REPO}/tags/${tag}/" >/dev/null
          deleted=$((deleted+1))
        fi
      else
        kept=$((kept+1))
        echo "Docker keep: $tag age=${age_days}d (<= ${threshold}d)"
      fi
    done

    url=$(echo "$resp" | jq -r '.next')
  done

  echo "Docker summary: considered=$considered kept=$kept deleted=$deleted (final deletions only with --execute)"
  echo
}

# --- run -------------------------------------------------------
ghcr_cleanup
docker_cleanup

echo "All done."
