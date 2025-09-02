#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Container cleanup for GHCR + Docker Hub (each optional)
# ------------------------------------------------------------
# Keeps:
#   - "latest" and any tags passed via --protect
#   - Highest release-like tag overall (A.B.C / vA.B.C / A.B.C.D / vA.B.C.D, with optional -suffix)
#   - (opt) --protect-latest-per <minor|patch>:
#       minor => for each A.B, protect ONE tag with highest (C, D, suffix); tie → youngest
#       patch => for each A.B.C, protect ONE tag with highest (D, suffix); tie → youngest
#       if flag provided without a value -> defaults to patch
#   - (opt) youngest N release/dev via --keep-release-count / --keep-dev-count
# Deletes:
#   - Release tags older than --max-release-days (unless protected/forced-keep)
#   - Dev tags older than --max-dev-days (unless protected/forced-keep)
#   - (opt, GHCR) untagged versions older than --max-untagged-days when --include-untagged
#
# DRY RUN by default; add --execute (and optionally --yes) to perform deletions.
# ------------------------------------------------------------

PROTECTED_TAGS=("latest")

# Modes & knobs
DRY_RUN=1
ASSUME_YES=0
DELETE_LIMIT=0
OUT_DIR=""
QUIET=0
VERBOSE=0

# Protection policies
PROTECT_LATEST_PER=0         # 0/1
PROTECT_SCOPE=""             # "minor" or "patch" (default "patch" if PROTECT_LATEST_PER=1 and empty)
KEEP_RELEASE_COUNT=0
KEEP_DEV_COUNT=0

# Untagged handling (GHCR only)
INCLUDE_UNTAGGED=0
MAX_UNTAGGED_DAYS=""

# --- GHCR (optional) -----------------------------------------
GHCR_OWNER_TYPE="users"    # "users" or "orgs"
GHCR_OWNER=""
GHCR_USER=""
GHCR_TOKEN=""
GHCR_PACKAGE=""

# --- Docker Hub (optional) -----------------------------------
DOCKER_USER=""
DOCKER_PASS=""
DOCKER_NAMESPACE=""
DOCKER_REPO=""
DOCKER_JWT=""

# --- thresholds ----------------------------------------------
MAX_RELEASE_DAYS=""
MAX_DEV_DAYS=""

# --- utilities ------------------------------------------------
die() { echo "Error: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
log_info()   { (( QUIET )) || echo "$@"; }
log_debug()  { (( VERBOSE )) && echo "[debug] $@"; }
log_error()  { echo "$@" >&2; }

DATE_BIN="date"
if ! date -u -d "1970-01-01T00:00:00Z" +%s >/dev/null 2>&1; then
  if have_cmd gdate; then DATE_BIN="gdate"; else die "GNU date required (install coreutils for 'gdate' on macOS)."; fi
fi
iso_to_epoch() { $DATE_BIN -u -d "$1" +%s; }
now_epoch()    { $DATE_BIN -u +%s; }

curl_retry_json() {
  local max=5 delay=1 out rc
  while :; do
    if out=$(curl -fsS "$@"); then printf '%s' "$out"; return 0; fi
    rc=$?; ((max--)) || return "$rc"; sleep "$delay"; delay=$((delay*2))
  done
}

curl_delete_with_retry() {
  local url="$1"; shift
  local tries=5 delay=1 status
  while :; do
    status=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$@" "$url")
    if [[ "$status" =~ ^2 ]]; then return 0; fi
    if [[ "$status" == "429" || "$status" =~ ^5 ]]; then
      ((tries--)) || break; sleep "$delay"; delay=$((delay*2)); continue
    fi
    break
  done
  return 1
}

confirm_execute_once() {
  local pending_delete_count="$1"
  if (( DRY_RUN )) || (( ASSUME_YES )); then return 0; fi
  if [[ ! -t 0 ]]; then return 0; fi
  read -r -p "About to DELETE ${pending_delete_count} item(s). Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted."
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0")
    [--ghcr-owner-type users|orgs] [--ghcr-owner OWNER] [--ghcr-user USER] [--ghcr-token TOKEN] [--ghcr-package PACKAGE]
    [--docker-user USER] [--docker-pass PASS] [--docker-namespace NS] [--docker-repo REPO]
    [--max-release-days N] [--max-dev-days M]
    [--keep-release-count N] [--keep-dev-count M]
    [--protect-latest-per <minor|patch>]      # default 'patch' if provided without value
    [--protect TAG]... [--output-dir DIR]
    [--include-untagged] [--max-untagged-days K]   # GHCR only
    [--execute] [--yes] [--delete-limit N]
    [--quiet] [--verbose]
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
    --max-dev-days)     MAX_DEV_DAYS="$2"; shift 2;;

    --keep-release-count) KEEP_RELEASE_COUNT="$2"; shift 2;;
    --keep-dev-count)     KEEP_DEV_COUNT="$2"; shift 2;;

    --protect-latest-per)
      PROTECT_LATEST_PER=1
      if [[ $# -ge 2 && ! "${2:-}" =~ ^-- ]]; then
        PROTECT_SCOPE="$2"
        [[ "$PROTECT_SCOPE" =~ ^(minor|patch)$ ]] || die "--protect-latest-per must be 'minor' or 'patch'"
        shift 2
      else
        PROTECT_SCOPE="patch"
        shift 1
      fi
      ;;

    --protect) PROTECTED_TAGS+=("$2"); shift 2;;
    --output-dir) OUT_DIR="$2"; shift 2;;

    --include-untagged) INCLUDE_UNTAGGED=1; shift;;
    --max-untagged-days) MAX_UNTAGGED_DAYS="$2"; shift 2;;

    --execute) DRY_RUN=0; shift;;
    --yes) ASSUME_YES=1; shift;;
    --delete-limit) DELETE_LIMIT="$2"; shift 2;;

    --quiet) QUIET=1; shift;;
    --verbose) VERBOSE=1; shift;;

    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1 (see --help)";;
  esac
done

have_cmd curl || die "curl is required"
have_cmd jq   || die "jq is required"

# Validate switches
[[ "$GHCR_OWNER_TYPE" =~ ^(users|orgs)$ ]] || { [[ -z "$GHCR_OWNER" ]] || die "--ghcr-owner-type must be 'users' or 'orgs'"; }
[[ -z "$MAX_RELEASE_DAYS"   || "$MAX_RELEASE_DAYS"   =~ ^[0-9]+$ ]] || die "--max-release-days must be an integer"
[[ -z "$MAX_DEV_DAYS"       || "$MAX_DEV_DAYS"       =~ ^[0-9]+$ ]] || die "--max-dev-days must be an integer"
[[ -z "$MAX_UNTAGGED_DAYS"  || "$MAX_UNTAGGED_DAYS"  =~ ^[0-9]+$ ]] || die "--max-untagged-days must be an integer"
[[ "$KEEP_RELEASE_COUNT" =~ ^[0-9]+$ ]] || die "--keep-release-count must be an integer"
[[ "$KEEP_DEV_COUNT"     =~ ^[0-9]+$ ]] || die "--keep-dev-count must be an integer"
[[ "$DELETE_LIMIT"       =~ ^[0-9]+$ ]] || die "--delete-limit must be an integer"

# Determine which registries are enabled
GHCR_ENABLED=0
if [[ -n "$GHCR_OWNER" && -n "$GHCR_TOKEN" && -n "$GHCR_PACKAGE" && ( "$GHCR_OWNER_TYPE" == "users" || "$GHCR_OWNER_TYPE" == "orgs" ) ]]; then
  GHCR_ENABLED=1
fi
DOCKER_ENABLED=0
if [[ -n "$DOCKER_USER" && -n "$DOCKER_PASS" && -n "$DOCKER_NAMESPACE" && -n "$DOCKER_REPO" ]]; then
  DOCKER_ENABLED=1
fi

if (( GHCR_ENABLED == 0 && DOCKER_ENABLED == 0 )); then
  log_info "No registry settings provided. Nothing to do."
  exit 0
fi

# Thresholds required when something will run
if [[ -z "$MAX_RELEASE_DAYS" || -z "$MAX_DEV_DAYS" ]]; then
  die "--max-release-days and --max-dev-days are required when a registry is configured"
fi
if (( INCLUDE_UNTAGGED )) && (( GHCR_ENABLED )); then
  [[ -n "$MAX_UNTAGGED_DAYS" ]] || die "--max-untagged-days is required when --include-untagged is used for GHCR"
fi
if (( INCLUDE_UNTAGGED )) && (( DOCKER_ENABLED )); then
  log_info "Docker Hub: --include-untagged has no effect (API doesn't list them)."
fi

# Default protect scope if feature enabled but unset
if (( PROTECT_LATEST_PER == 1 )) && [[ -z "$PROTECT_SCOPE" ]]; then
  PROTECT_SCOPE="patch"
fi

JQ_PROTECTED=$(printf '%s\n' "${PROTECTED_TAGS[@]}" | jq -R . | jq -cs 'unique')

log_info "Protected tags: ${PROTECTED_TAGS[*]}"
log_info "Mode: $([[ $DRY_RUN -eq 1 ]] && echo DRY RUN || echo EXECUTE)"
log_info "Enabled: GHCR=$GHCR_ENABLED, DockerHub=$DOCKER_ENABLED"
echo

# Release recognition regex (8 patterns)
RELEASE_RE='^v?[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[A-Za-z0-9][A-Za-z0-9\.-]*)?$'

ANY_DELETE_FAILED=0
trap 'ret=$?; if (( ANY_DELETE_FAILED != 0 )); then exit 1; else exit $ret; fi' EXIT

# ---------- printers ----------
print_tag_rows() {
  local json="$1"
  printf "%-8s %-10s %8s   %s\n" ACTION TYPE AGE TAG
  echo "----------------------------------------------------------"
  local had=0 act
  while IFS=$'\t' read -r action type age tag; do
    [[ -z "${action:-}" ]] && continue
    had=1
    if [[ "$action" == "keep" ]]; then act="KEEP"; else if (( DRY_RUN )); then act="DRY-RUN"; else act="DELETE"; fi; fi
    printf "%-8s %-10s %8s   %s\n" "$act" "$type" "$age" "$tag"
  done < <(jq -r '.[] | [.action, .type_out, ("\(.age_days)d"), ( .tag // .name // "" )] | @tsv' <<< "$json" || true)
  (( had )) || echo "(none)"
  echo
}

print_untagged_rows() {
  local json="$1"
  printf "%-8s %-10s %8s   %s\n" ACTION TYPE AGE VERSION_ID
  echo "----------------------------------------------------------"
  local had=0 act
  while IFS=$'\t' read -r action type age vid; do
    [[ -z "${action:-}" ]] && continue
    had=1
    if [[ "$action" == "keep" ]]; then act="KEEP"; else if (( DRY_RUN )); then act="DRY-RUN"; else act="DELETE"; fi; fi
    printf "%-8s %-10s %8s   %s\n" "$act" "$type" "$age" "$vid"
  done < <(jq -r '.[] | [.action, .type_out, ("\(.age_days)d"), (.id|tostring)] | @tsv' <<< "$json" || true)
  (( had )) || echo "(none)"
  echo
}

# ==============================================================
# GHCR
# ==============================================================
GHCR_VERSIONS_CACHE=""
GHCR_TAGS_CACHE=""
GHCR_UNTAGGED_CACHE=""

ghcr_cache_versions() {
  local base_protected_json="$1" max_release="$2" max_dev="$3" protect_flag="$4" protect_scope="$5" keep_release_count="$6" keep_dev_count="$7" include_untagged="$8" max_untagged="$9"

  local page=1 all_json='[]'
  while :; do
    local url="https://api.github.com/${GHCR_OWNER_TYPE}/${GHCR_OWNER}/packages/container/${GHCR_PACKAGE}/versions?per_page=100&page=${page}"
    local resp
    if ! resp=$(curl_retry_json -H "Accept: application/vnd.github+json" \
                                -H "Authorization: Bearer ${GHCR_TOKEN}" \
                                -H "X-GitHub-Api-Version: 2022-11-28" \
                                "$url"); then
      log_error "GHCR: fetch failed (page=$page)"; break
    fi
    local count; count=$(echo "$resp" | jq 'length')
    [[ "$count" -gt 0 ]] || break
    all_json=$(jq -s 'add' <(echo "$all_json") <(echo "$resp"))
    page=$((page+1))
  done
  log_debug "GHCR fetched versions: $(echo "$all_json" | jq 'length')"
  local now; now=$(now_epoch)

  local _tmp
  if ! _tmp=$(
    jq -c --argjson now "$now" --arg re "$RELEASE_RE" --argjson incl "$include_untagged" '
      [ .[] | {id: .id, created_at: .created_at, tags: (.metadata.container.tags // [])} ]
      | (if $incl==1 then . else map(select(.tags | length > 0)) end)
      | map(.age_days = (( $now - (.created_at | fromdateiso8601) ) / 86400 | floor))
      | map(.type = (if (.tags|length)==0 then "untagged"
                     else if (.tags | map(test($re)) | any) then "release" else "dev" end end))
    ' <<< "$all_json"
  ); then
    log_error "GHCR: failed to process versions JSON"
    GHCR_VERSIONS_CACHE='[]'
  else
    GHCR_VERSIONS_CACHE="$_tmp"
  fi

  if ! _tmp=$(
    jq -c \
      --arg re "$RELEASE_RE" \
      --argjson base_protected "$base_protected_json" \
      --argjson max_release "$max_release" \
      --argjson max_dev "$max_dev" \
      --argjson protect_flag "$protect_flag" \
      --arg protect_scope "$protect_scope" \
      --argjson keep_release_count "$keep_release_count" \
      --argjson keep_dev_count "$keep_dev_count" '
      def stripv(t): t|sub("^v";"");
      def parse(t):
        (stripv(t) | capture("^(?<maj>[0-9]+)\\.(?<min>[0-9]+)\\.(?<c>[0-9]+)(?:\\.(?<d>[0-9]+))?(?:-(?<suf>[A-Za-z0-9][A-Za-z0-9\\.-]*))?$"));
      def rel_obj(name; age):
        (parse(name) // empty) as $m
        | {name: name, age_days: age,
           maj: ($m.maj|tonumber), min: ($m.min|tonumber),
           c: ($m.c|tonumber), d: (($m.d // -1)|tonumber),
           suf: ($m.suf // ""), key_minor: "\($m.maj).\($m.min)", key_patch: "\($m.maj).\($m.min).\($m.c)"};
      def vkey(t):
        (parse(t) as $m
         | if $m then [($m.maj|tonumber),($m.min|tonumber),($m.c|tonumber),((($m.d // -1)|tonumber)),($m.suf // "")]
           else null end);

      [ .[] | select((.tags|length)>0) | . as $v | ($v.tags[] | {tag: ., age_days: $v.age_days}) ]
      | sort_by(.tag) | group_by(.tag)
      | map({ tag: (.[0].tag), age_days: (map(.age_days) | min),
              type: (if (.[0].tag | test($re)) then "release" else "dev" end) }) as $tags

      | ( $tags | map(select(.type=="release") | rel_obj(.tag; .age_days)) ) as $rel

      | ( if ($rel|length)==0 then "" else
            ( $rel | sort_by([.maj,.min,.c,.d,.suf,(0-.age_days)]) | last | .name )
        end ) as $highest

      | ( if ($protect_flag==1 and ($rel|length)>0) then
            ( $rel
              | map(.group = (if $protect_scope=="minor" then .key_minor else .key_patch end))
              | sort_by(.group) | group_by(.group)
              | map( sort_by([.c,.d,.suf,(0-.age_days)]) | last | .name ) )
          else [] end
        ) as $scope_heads

      | ( $base_protected + (if $highest=="" then [] else [$highest] end) + $scope_heads | unique ) as $protected

      | ( $tags | map(select(.type=="release" and ((.tag as $t | $protected | index($t)) == null))) | sort_by(.age_days) | ( .[0: ($keep_release_count)] // [] ) | map(.tag) ) as $force_keep_release
      | ( $tags | map(select(.type=="dev"     and ((.tag as $t | $protected | index($t)) == null))) | sort_by(.age_days) | ( .[0: ($keep_dev_count    )] // [] ) | map(.tag) ) as $force_keep_dev

      | $tags
      | map(
          .is_protected = ((.tag as $t | $protected | index($t)) != null)
        | .forced_keep  = ((.tag as $t | ( ($force_keep_release + $force_keep_dev) // [] ) | index($t)) != null)
        | .action = (if (.is_protected or .forced_keep) then "keep"
                     elif (.type=="release") then (if .age_days <= $max_release then "keep" else "delete" end)
                     elif (.type=="dev")     then (if .age_days <= $max_dev    then "keep" else "delete" end)
                     else "keep" end)
        | .type_out = (if .is_protected then "protected" else .type end)
      ) as $full

      # --------- Final ordering (sections) ----------
      | (
          # KEEP protected: latest first, then release-like by version, then others by name
          ( [ $full[] | select(.action=="keep" and .is_protected and .tag=="latest") ] +
            ( [ $full[] | select(.action=="keep" and .is_protected and .tag!="latest" and (.tag|test($re))) ]
              | sort_by( vkey(.tag) ) | reverse ) +
            ( [ $full[] | select(.action=="keep" and .is_protected and .tag!="latest" and ((.tag|test($re)) == false)) ]
              | sort_by(.tag) )
          ) +

          # KEEP release (non-protected), version-desc
          ( [ $full[] | select(.action=="keep" and (.is_protected|not) and .type=="release") ]
            | sort_by( vkey(.tag) ) | reverse ) +

          # KEEP dev (non-protected), newest→oldest by age
          ( [ $full[] | select(.action=="keep" and (.is_protected|not) and .type=="dev") ]
            | sort_by(.age_days) ) +

          # DELETE release, version-desc
          ( [ $full[] | select(.action=="delete" and .type=="release") ]
            | sort_by( vkey(.tag) ) | reverse ) +

          # DELETE dev, newest→oldest by age
          ( [ $full[] | select(.action=="delete" and .type=="dev") ]
            | sort_by(.age_days) )
        )
      | map({action, type_out, age_days, tag})
    ' <<< "$GHCR_VERSIONS_CACHE"
  ); then
    log_error "GHCR: failed to reduce to per-tag set"
    GHCR_TAGS_CACHE='[]'
  else
    GHCR_TAGS_CACHE="$_tmp"
  fi

  if (( include_untagged )); then
    if ! _tmp=$(
      jq -c --argjson maxu "$max_untagged" '
        [ .[] | select((.tags|length)==0) |
          . + { is_protected:false, forced_keep:false,
                action: (if .age_days <= $maxu then "keep" else "delete" end),
                type_out:"untagged" } ]
      ' <<< "$GHCR_VERSIONS_CACHE"
    ); then
      log_error "GHCR: failed to select untagged"
      GHCR_UNTAGGED_CACHE='[]'
    else
      GHCR_UNTAGGED_CACHE="$_tmp"
    fi
  else
    GHCR_UNTAGGED_CACHE='[]'
  fi

  if [[ -n "$OUT_DIR" ]]; then
    mkdir -p "$OUT_DIR"
    printf '%s\n' "${GHCR_VERSIONS_CACHE:-[]}" | jq -S '.' > "$OUT_DIR/ghcr_versions_cache.json" || true
    printf '%s\n' "${GHCR_TAGS_CACHE:-[]}"     | jq -S '.' > "$OUT_DIR/ghcr_tags_cache.json"     || true
    jq -r '.[] | [.action,.type_out,("\(.age_days)d"),.tag] | @tsv' <<< "${GHCR_TAGS_CACHE:-[]}" > "$OUT_DIR/ghcr_plan.tsv" || true
    printf '%s\n' "${GHCR_UNTAGGED_CACHE:-[]}" | jq -S '.' > "$OUT_DIR/ghcr_untagged_cache.json" || true
    jq -r '.[] | [.action,.type_out,("\(.age_days)d"),(.id|tostring)] | @tsv' <<< "${GHCR_UNTAGGED_CACHE:-[]}" > "$OUT_DIR/ghcr_untagged_plan.tsv" || true
  fi

  local highest
  highest=$(jq -r '
    def stripv(t): t|sub("^v";"");
    def parse(t):
      (stripv(t) | capture("^(?<maj>[0-9]+)\\.(?<min>[0-9]+)\\.(?<c>[0-9]+)(?:\\.(?<d>[0-9]+))?(?:-(?<suf>[A-Za-z0-9][A-Za-z0-9\\.-]*))?$"));
    [ .[] | select(.type_out=="protected" or .type_out=="release") | .tag ] | unique
    | if length==0 then "" else
        sort_by( (parse(.) | [(.maj|tonumber),(.min|tonumber),(.c|tonumber),((.d // -1)|tonumber),((.suf // "")),(0)]) ) | last
      end
  ' <<< "${GHCR_TAGS_CACHE:-[]}")
  if [[ -n "$highest" ]]; then log_info "GHCR protected highest release-like tag: ${highest}"; else log_info "GHCR: no release-like tags found to protect."; fi

  return 0
}

ghcr_cleanup() {
  (( GHCR_ENABLED )) || { log_info "==> GHCR: skipping (missing settings)"; echo; return 0; }
  log_info "==> GHCR: owner_type=$GHCR_OWNER_TYPE owner=$GHCR_OWNER package=$GHCR_PACKAGE"

  if ! ghcr_cache_versions "$JQ_PROTECTED" "$MAX_RELEASE_DAYS" "$MAX_DEV_DAYS" "$PROTECT_LATEST_PER" "$PROTECT_SCOPE" "$KEEP_RELEASE_COUNT" "$KEEP_DEV_COUNT" "$INCLUDE_UNTAGGED" "${MAX_UNTAGGED_DAYS:-0}"; then
    log_error "GHCR: caching failed; continuing with empty sets"
    GHCR_TAGS_CACHE='[]'; GHCR_UNTAGGED_CACHE='[]'
  fi

  print_tag_rows "$GHCR_TAGS_CACHE"
  if (( INCLUDE_UNTAGGED )); then print_untagged_rows "$GHCR_UNTAGGED_CACHE"; fi

  local pending; pending=$(jq '[ .[] | select(.action=="delete") ] | length' <<< "${GHCR_TAGS_CACHE:-[]}")
  local pending_u; pending_u=$(jq '[ .[] | select(.action=="delete") ] | length' <<< "${GHCR_UNTAGGED_CACHE:-[]}")
  local total=$(( pending + pending_u ))

  if (( total > 0 && DRY_RUN == 0 )); then
    confirm_execute_once "$total"
    local remaining="$DELETE_LIMIT"

    while IFS= read -r tag; do
      [[ -z "${tag:-}" ]] && continue
      while IFS= read -r vid; do
        if (( DELETE_LIMIT>0 && remaining==0 )); then break; fi
        if curl_delete_with_retry "https://api.github.com/${GHCR_OWNER_TYPE}/${GHCR_OWNER}/packages/container/${GHCR_PACKAGE}/versions/${vid}" \
             -H "Accept: application/vnd.github+json" \
             -H "Authorization: Bearer ${GHCR_TOKEN}" \
             -H "X-GitHub-Api-Version: 2022-11-28"
        then (( DELETE_LIMIT>0 )) && remaining=$((remaining-1))
        else log_error "  failed to delete GHCR version_id=$vid (tag=$tag)"; ANY_DELETE_FAILED=1; fi
      done < <(jq -r --arg t "$tag" '.[] | select(any(.tags[]?; . == $t)) | .id' <<< "${GHCR_VERSIONS_CACHE:-[]}" || true)
    done < <(jq -r '.[] | select(.action=="delete") | .tag' <<< "${GHCR_TAGS_CACHE:-[]}" || true)

    if (( INCLUDE_UNTAGGED )); then
      while IFS= read -r vid; do
        if (( DELETE_LIMIT>0 && remaining==0 )); then break; fi
        if curl_delete_with_retry "https://api.github.com/${GHCR_OWNER_TYPE}/${GHCR_OWNER}/packages/container/${GHCR_PACKAGE}/versions/${vid}" \
             -H "Accept: application/vnd.github+json" \
             -H "Authorization: Bearer ${GHCR_TOKEN}" \
             -H "X-GitHub-Api-Version: 2022-11-28"
        then (( DELETE_LIMIT>0 )) && remaining=$((remaining-1))
        else log_error "  failed to delete GHCR untagged version_id=$vid"; ANY_DELETE_FAILED=1; fi
      done < <(jq -r '.[] | select(.action=="delete") | .id' <<< "${GHCR_UNTAGGED_CACHE:-[]}" || true)
    fi
  fi

  local kept del kept_u del_u
  kept=$(jq '[ .[] | select(.action=="keep") ] | length' <<< "${GHCR_TAGS_CACHE:-[]}")
  del=$(jq  '[ .[] | select(.action=="delete") ] | length' <<< "${GHCR_TAGS_CACHE:-[]}")
  if (( INCLUDE_UNTAGGED )); then
    kept_u=$(jq '[ .[] | select(.action=="keep") ] | length' <<< "${GHCR_UNTAGGED_CACHE:-[]}")
    del_u=$(jq  '[ .[] | select(.action=="delete") ] | length' <<< "${GHCR_UNTAGGED_CACHE:-[]}")
    log_info "GHCR summary: tags keep=$kept delete=$del; untagged keep=$kept_u delete=$del_u $([[ $DRY_RUN -eq 1 ]] && echo '(dry run)' || echo '')"
  else
    log_info "GHCR summary: keep=$kept delete=$del $([[ $DRY_RUN -eq 1 ]] && echo '(dry run)' || echo '')"
  fi
  echo
  return 0
}

# ==============================================================
# Docker Hub
# ==============================================================
DOCKER_TAGS_CACHE=""

docker_login() {
  local resp token
  if ! resp=$(curl_retry_json -H "Content-Type: application/json" \
                               -X POST https://hub.docker.com/v2/users/login \
                               -d "{\"username\":\"${DOCKER_USER}\",\"password\":\"${DOCKER_PASS}\"}"); then
    log_error "Docker Hub login request failed (network/HTTP error)"
    return 1
  fi
  token=$(printf '%s' "$resp" | jq -r '.token // empty') || token=""
  if [[ -z "$token" ]]; then
    log_error "Docker Hub login returned no token"
    return 1
  fi
  printf '%s' "$token"
  return 0
}

docker_cache_tags() {
  local token="$1" base_protected_json="$2" max_release="$3" max_dev="$4" protect_flag="$5" protect_scope="$6" keep_release_count="$7" keep_dev_count="$8"

  local url="https://hub.docker.com/v2/repositories/${DOCKER_NAMESPACE}/${DOCKER_REPO}/tags?page_size=100&ordering=last_updated"
  local all_json='[]'
  while [[ -n "$url" && "$url" != "null" ]]; do
    local resp
    if ! resp=$(curl_retry_json -H "Authorization: JWT ${token}" "$url"); then
      log_error "Docker: fetch failed"
      break
    fi
    local results_len; results_len=$(echo "$resp" | jq '.results | length')
    [[ "$results_len" -gt 0 ]] || break
    all_json=$(jq -s 'add' <(echo "$all_json") <(echo "$resp" | jq '.results'))
    url=$(echo "$resp" | jq -r '.next')
  done
  log_debug "Docker fetched tags: $(echo "$all_json" | jq 'length')"

  local now; now=$(now_epoch)
  local _tmp
  if ! _tmp=$(
    jq -c \
      --argjson now "$now" \
      --arg re "$RELEASE_RE" \
      --argjson base_protected "$base_protected_json" \
      --argjson max_release "$max_release" \
      --argjson max_dev "$max_dev" \
      --argjson protect_flag "$protect_flag" \
      --arg protect_scope "$protect_scope" \
      --argjson keep_release_count "$keep_release_count" \
      --argjson keep_dev_count "$keep_dev_count" '
      def stripv(t): t|sub("^v";"");
      def parse(t):
        (stripv(t) | capture("^(?<maj>[0-9]+)\\.(?<min>[0-9]+)\\.(?<c>[0-9]+)(?:\\.(?<d>[0-9]+))?(?:-(?<suf>[A-Za-z0-9][A-Za-z0-9\\.-]*))?$"));
      def rel_obj(name; age):
        (parse(name) // empty) as $m
        | {name: name, age_days: age,
           maj: ($m.maj|tonumber), min: ($m.min|tonumber),
           c: ($m.c|tonumber), d: (($m.d // -1)|tonumber),
           suf: ($m.suf // ""), key_minor: "\($m.maj).\($m.min)", key_patch: "\($m.maj).\($m.min).\($m.c)"};
      def vkey(t):
        (parse(t) as $m
         | if $m then [($m.maj|tonumber),($m.min|tonumber),($m.c|tonumber),((($m.d // -1)|tonumber)),($m.suf // "")]
           else null end);

      [ .[] |
        { name: .name,
          last_updated: .last_updated,
          age_days: (( $now - (.last_updated | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) ) / 86400 | floor),
          type: (if (.name | test($re)) then "release" else "dev" end)
        }
      ] as $tags

      | ( $tags | map(select(.type=="release") | rel_obj(.name; .age_days)) ) as $rel

      | ( if ($rel|length)==0 then "" else
            ( $rel | sort_by([.maj,.min,.c,.d,.suf,(0-.age_days)]) | last | .name )
        end ) as $highest

      | ( if ($protect_flag==1 and ($rel|length)>0) then
            ( $rel
              | map(.group = (if $protect_scope=="minor" then .key_minor else .key_patch end))
              | sort_by(.group) | group_by(.group)
              | map( sort_by([.c,.d,.suf,(0-.age_days)]) | last | .name ) )
          else [] end
        ) as $scope_heads

      | ( $base_protected + (if $highest=="" then [] else [$highest] end) + $scope_heads | unique ) as $protected

      | ( $tags | map(select(.type=="release" and ((.name as $n | $protected | index($n)) == null))) | sort_by(.age_days) | ( .[0: ($keep_release_count)] // [] ) | map(.name) ) as $force_keep_release
      | ( $tags | map(select(.type=="dev"     and ((.name as $n | $protected | index($n)) == null))) | sort_by(.age_days) | ( .[0: ($keep_dev_count    )] // [] ) | map(.name) ) as $force_keep_dev

      | $tags
      | map(
          .is_protected = ((.name as $n | $protected | index($n)) != null)
        | .forced_keep  = ((.name as $n | ( ($force_keep_release + $force_keep_dev) // [] ) | index($n)) != null)
        | .action = (if (.is_protected or .forced_keep) then "keep"
                     elif (.type=="release") then (if .age_days <= $max_release then "keep" else "delete" end)
                     elif (.type=="dev")     then (if .age_days <= $max_dev    then "keep" else "delete" end)
                     else "keep" end)
        | .type_out = (if .is_protected then "protected" else .type end)
      ) as $full

      # --------- Final ordering (sections) ----------
      | (
          # KEEP protected: latest first, then release-like by version, then others by name
          ( [ $full[] | select(.action=="keep" and .is_protected and .name=="latest") ] +
            ( [ $full[] | select(.action=="keep" and .is_protected and .name!="latest" and (.name|test($re))) ]
              | sort_by( vkey(.name) ) | reverse ) +
            ( [ $full[] | select(.action=="keep" and .is_protected and .name!="latest" and ((.name|test($re)) == false)) ]
              | sort_by(.name) )
          ) +

          # KEEP release (non-protected), version-desc
          ( [ $full[] | select(.action=="keep" and (.is_protected|not) and .type=="release") ]
            | sort_by( vkey(.name) ) | reverse ) +

          # KEEP dev (non-protected), newest→oldest by age
          ( [ $full[] | select(.action=="keep" and (.is_protected|not) and .type=="dev") ]
            | sort_by(.age_days) ) +

          # DELETE release, version-desc
          ( [ $full[] | select(.action=="delete" and .type=="release") ]
            | sort_by( vkey(.name) ) | reverse ) +

          # DELETE dev, newest→oldest by age
          ( [ $full[] | select(.action=="delete" and .type=="dev") ]
            | sort_by(.age_days) )
        )
      | map({action, type_out, age_days, name})
    ' <<< "$all_json"
  ); then
    log_error "Docker: failed to process tags JSON"
    DOCKER_TAGS_CACHE='[]'
  else
    DOCKER_TAGS_CACHE="$_tmp"
  fi

  if [[ -n "$OUT_DIR" ]]; then
    mkdir -p "$OUT_DIR"
    printf '%s\n' "${DOCKER_TAGS_CACHE:-[]}" | jq -S '.' > "$OUT_DIR/docker_tags_cache.json" || true
    jq -r '.[] | [.action,.type_out,("\(.age_days)d"),.name] | @tsv' <<< "${DOCKER_TAGS_CACHE:-[]}" > "$OUT_DIR/docker_plan.tsv" || true
  fi
}

docker_login_wrap_and_cache() {
  local token=""
  if ! token="$(docker_login)"; then
    log_error "Docker Hub: login failed; continuing with empty set"
    DOCKER_TAGS_CACHE='[]'
  else
    DOCKER_JWT="$token"
    docker_cache_tags "$token" "$JQ_PROTECTED" "$MAX_RELEASE_DAYS" "$MAX_DEV_DAYS" "$PROTECT_LATEST_PER" "$PROTECT_SCOPE" "$KEEP_RELEASE_COUNT" "$KEEP_DEV_COUNT" || {
      log_error "Docker Hub: caching failed; continuing with empty set"
      DOCKER_TAGS_CACHE='[]'
    }
  fi
}

docker_cleanup() {
  (( DOCKER_ENABLED )) || { log_info "==> Docker Hub: skipping (missing settings)"; echo; return 0; }
  log_info "==> Docker Hub: namespace=$DOCKER_NAMESPACE repo=$DOCKER_REPO"

  docker_login_wrap_and_cache
  print_tag_rows "$DOCKER_TAGS_CACHE"

  local pending; pending=$(jq '[ .[] | select(.action=="delete") ] | length' <<< "${DOCKER_TAGS_CACHE:-[]}")
  if (( pending > 0 && DRY_RUN == 0 )); then
    confirm_execute_once "$pending"
    local remaining="$DELETE_LIMIT"
    while IFS= read -r tag; do
      [[ -z "${tag:-}" ]] && continue
      if (( DELETE_LIMIT>0 && remaining==0 )); then break; fi
      if curl_delete_with_retry "https://hub.docker.com/v2/repositories/${DOCKER_NAMESPACE}/${DOCKER_REPO}/tags/${tag}/" \
           -H "Authorization: JWT ${DOCKER_JWT}"; then
        (( DELETE_LIMIT>0 )) && remaining=$((remaining-1))
      else
        log_error "  failed to delete Docker tag=$tag"; ANY_DELETE_FAILED=1
      fi
    done < <(jq -r '.[] | select(.action=="delete") | .name' <<< "${DOCKER_TAGS_CACHE:-[]}" || true)
  fi

  local kept del
  kept=$(jq '[ .[] | select(.action=="keep") ] | length' <<< "${DOCKER_TAGS_CACHE:-[]}")
  del=$(jq  '[ .[] | select(.action=="delete") ] | length' <<< "${DOCKER_TAGS_CACHE:-[]}")
  log_info "Docker summary: keep=$kept delete=$del $([[ $DRY_RUN -eq 1 ]] && echo '(dry run)' || echo '')"
  echo
}

# --- run -------------------------------------------------------
ghcr_cleanup
docker_cleanup
log_info "All done."
