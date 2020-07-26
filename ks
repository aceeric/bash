#!/usr/bin/env bash

#
# Prints usage instructions
#
function usage() {
  echo Displays secret key values with less typing
  while IFS= read -r line; do
    echo "${line:4}"
  done <<< '
    Usage: ks [-n,--namespace] [-d,--hdr] [-w,--write] [-f,--first] [-h,--help] [secret] [key] [key...]
    
    Options:
      -n,--namespace  Namespace
      -d,--hdr        Prints the key name too. Ignored if --write
      -w,--write      Writes the value to a file named by the key. Ignores --hdr
      -f,--first      If the secret param matches multiple secrets, selects the first
      -h,--help       Displays this help

    Positional params:
      secret  The first positional param is the secret name. In shorthand form, this is a subset of
              letters from a desired secret name. The script turns that into a regex to find a secret.
              A full name is also supported.

      key     The keys within the secret to display, separated by whitespace. If omitted, then just does
              "kubectl describe secret". Supports key name or ordinal position.

    Examples:
      ks                                -- kubectl get secret
      ks -nfoo                          -- kubectl get secret -nfoo
      ks gz7                            -- kubectl describe secret default-token-gz7mc
      ks gz7 ca.crt                     -- Decodes and displays the contents of ca.crt
      ks gz7 0                          -- "
      ks gz7 0 -w                       -- Creates ca.crt the working directory
      ks cl-a-c-do                      -- kubectl describe secret clusterrole-aggregation-controller-dockercfg-sb9h7
      ks cluca- ca.p12 > truststore.p12 -- Extracts the P12 truststore from strimzi-cluster-ca-cert to file
                                           truststore.p12 in the current working directory
    '
}

# The secret to work with. Could be a full secret name or a shorthand name. If empty, then list secrets
secret=""

# The result of converting a shorthand secret name to a full secret name via regex match
parsed_secret=""

# Key(s). If empty, then kubectl describe
keys=()

# --namespace. Intentionally ref'd un-quoted in the script so if empty it disappears
namespace=

# --hdr. Display the key name above the key value
headers=0

# --write. Write each key value to the current working directory to a file named with the key name
write=0

# --first. If the shorthand name finds >1 secret then take the first, otherwise err
first=0

# Populated by parse_args. All secrets that match the secret on the command line
found_secrets=()

#
# Supports a short-form option like -f=value
#
function opt_val() {
  opt="$1"
  if [[ "$opt" == =* ]]; then
    echo "${opt:1}"
  else
    echo "$opt"
  fi
}

#
# Parses the command line and sets all script-level vars
#
short_opts=dwfhn:
long_opts=hdr,write,first,help,namespace:
script_name=$(basename "$0")
function parse_args() {
  local parsed
  parsed=$(getopt --options "$short_opts" --longoptions "$long_opts" -n "$script_name" -- "$@") || exit 1
  eval set -- "$parsed"
  while true; do
    case "$1" in
      -h|--help)
        usage
        exit 1
        ;;
      -n|--namespace)
        namespace="-n$(opt_val $2)"
        shift 2
        ;;
      -d|--hdr)
        headers=1
        shift 1
        ;;
      -w|--write)
        write=1
        shift 1
        ;;
      -f|--first)
        first=1
        shift 1
        ;;
      --)
        shift
        break
        ;;
      *)
        shift
        ;;
    esac
  done

  for opt in "$@"; do
    # first positional param is the secret name, everything else is a key
    if [[ "$secret" == "" ]]; then
      secret="$opt"
    else
      keys+=("$opt")
    fi
  done

  if [[ "$secret" != "" ]]; then
    if kubectl get secret "$secret" $namespace &>/dev/null; then
      # the user supplied an exact secret name
      parsed_secret="$secret"
      return
    fi
    # passing found_secrets unadorned passes the array by ref, to be filled in by the function
    find_matches found_secrets

    if [[ "${#found_secrets[@]}" -eq 0 ]]; then
      echo "$script_name: '$secret' does not match any secrets"
      exit 1
    elif [[ "${#found_secrets[@]}" -gt 1 ]]; then
      echo "$script_name: '$secret' has multiple matches:"
      printf '  %s\n' "${found_secrets[@]}" | sort -n
      exit 1
    else
      parsed_secret="${found_secrets[0]}"
    fi
  fi
}

#
# The script can display a secret value by ordinal key position: ks foo 0. Each time you describe a secret
# the order of the 'Data' section can change. So this sorts the keys.
#
function kubectl_describe() {
  local secret="$1"
  local namespace="$2"
  local secrets=()
  local in_data=0
  while read -r line; do
    if [[ $in_data -eq 1 ]]; then
      secrets+=("$line")
    else
      echo "$line"
      if [[ "$line" == "====" ]]; then
        in_data=1
      fi
    fi
  done < <(kubectl describe secret "$secret" $namespace)
  printf '%s\n' "${secrets[@]}" | sort -n
}

#
# Uses script-level 'secret' var as a regex and finds all matches in the cluster. Matches are inserted into
# the array passed by ref in arg one. If no matches, then the array is unmodified.
#
function find_matches() {
  # -n declares a ref
  local -n arr=$1
  local re=""
  # secret into regex
  for (( i=0; i<"${#secret}"; i++ )); do
    re="${re}.*${secret:$i:1}+"
  done
  while read -r s; do
    if [[ "$s" =~ $re ]]; then
      arr+=("$s")
      if [[ $first -eq 1 ]]; then
        # --first says stop on the first match
        break
      fi
    fi
  done < <(kubectl get secret -o custom-columns="NAME:metadata.name" --no-headers $namespace)
}

#
# Main function
#
function main() {
  if [[ "$secret" == "" ]]; then
    kubectl get secret $namespace
    exit
  fi

  if [[ "${#keys[@]}" -eq 0 ]]; then
    kubectl_describe "$parsed_secret" "$namespace"
    exit
  fi

  # get all the keys to support displaying a key value by ordinal position
  local all_keys=()
  while read -r key; do
    all_keys+=("$key")
  done < <(kubectl get secret "$parsed_secret" $namespace\
   --template='{{ range $key, $value := .data }}{{ $key }}{{ "\n" }}{{ end }}' | sort)

  local re='^[0-9]+$'
  for key in "${keys[@]}"; do
    if [[ "$key" =~ $re ]]; then
      # key ordinal position
      if [[ $key -ge "${#all_keys[@]}" ]]; then
        echo "$script_name: bad ordinal position: $key (secret has ${#all_keys[@]} keys)"
        exit 1
      fi
      key="${all_keys[$key]}"
    fi
    if [[ $headers -eq 1 ]] && [[ $write -eq 0 ]]; then
      key_len="${#key}"
      underline=$(printf "%0.s=" $(seq 1 "$key_len"))
      printf "%s\n%s\n" "$key" "$underline"
    fi
    # escape any periods in the key name
    escaped="${key/\./\\\.}"
    if [[ $write -eq 1 ]]; then
      kubectl get secret "$parsed_secret" $namespace -o "jsonpath={.data['$escaped']}" | base64 --decode > "$key"
      echo "wrote $key"
    else
      kubectl get secret "$parsed_secret" $namespace -o "jsonpath={.data['$escaped']}" | base64 --decode
      # If a header was requested then outdent the prompt since many key values aren't newline-terminated
      if [[ $headers -eq 1 ]] ; then
        echo
      fi
    fi
  done
  exit
}

# entry point
parse_args "$@"
main
