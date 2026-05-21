## color codes
C_RESET="\033[0m"
C_RESET_UNDERLINE="\033[24m"
C_RESET_REVERSE="\033[27m"
C_DEFAULT="\033[39m"
C_DEFAULTB="\033[49m"
C_BOLD="\033[1m"
C_BRIGHT="\033[2m"
C_UNDERSCORE="\033[4m"
C_REVERSE="\033[7m"
C_BLACK="\033[30m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_BROWN="\033[33m"
C_BLUE="\033[34m"
C_MAGENTA="\033[35m"
C_CYAN="\033[36m"
C_WHITE="\033[37m"

c_red() {
   printf "${C_RED}${1}${C_RESET}"
}

c_blue() {
   printf "${C_BLUE}${1}${C_RESET}"
}

c_brown() {
   printf "${C_BROWN}${1}${C_RESET}"
}

c_green() {
   printf "${C_GREEN}${1}${C_RESET}"
}

c_red_bold() {
   printf "${C_RED}${C_BOLD}${1}${C_RESET}"
}

c_blue_bold() {
   printf "${C_BLUE}${C_BOLD}${1}${C_RESET}"
}

c_brown_bold() {
   printf "${C_BROWN}${C_BOLD}${1}${C_RESET}"
}

c_green_bold() {
   printf "${C_GREEN}${C_BOLD}${1}${C_RESET}"
}

now() {
  date +'[%Y-%m-%d %H:%M:%S]'
}

log_error() {
   printf "❌  ${C_MAGENTA}${C_BOLD}$(now)${C_RESET} ${C_RED}${C_BOLD}${1}${C_RESET}\n"
   exit 1
}

log_notice() {
   printf "🔔 ${C_MAGENTA}${C_BOLD}$(now)${C_RESET} ${C_BLUE}${C_BOLD}${1}${C_RESET}\n"
}

log_warn() {
   printf "⚠️ ${C_MAGENTA}${C_BOLD}$(now)${C_RESET} ${C_BROWN}${C_BOLD}${1}${C_RESET}\n"
}

log_info() {
   printf "✅ ${C_MAGENTA}${C_BOLD}$(now)${C_RESET} ${C_GREEN}${C_BOLD}${1}${C_RESET}\n"
}

print_cmd() {
   printf "${C_CYAN}${C_BOLD}>${C_RESET} ${C_GREEN}${C_BOLD}${1}${C_RESET}\n"
}

forge_script() {
  log_info "forge script"
  local -a forge_opts
  forge_opts=(--ffi --rpc-url "$F_RPC_URL" --sender "$F_SENDER" --slow)

  if [[ "$F_VERBOSE" == "true" ]]; then 
    forge_opts+=(-vvvv)
  fi

  # wallet type
  if [[ "$F_NO_WALLET" != "true" ]]; then
    if [[ "$F_WALLET_TYPE" == "PRIVATE_KEY" ]]; then 
      log_info "Use $F_WALLET_TYPE wallet"
      forge_opts+=(--private-key "$F_PRIVATE_KEY")
    elif [[ "$F_WALLET_TYPE" == "LEDGER" ]]; then
      log_info "Use $F_WALLET_TYPE wallet"
      forge_opts+=(--ledger --mnemonic-indexes "${F_MNEMONIC_INDEX:-0}")
      if [[ -n "$F_HARDWARE_DERIVATION_PATH" ]]; then
        forge_opts+=(--mnemonic-derivation-paths "$F_HARDWARE_DERIVATION_PATH")
      fi
    elif [[ "$F_WALLET_TYPE" == "TREZOR" ]]; then
      log_info "Use $F_WALLET_TYPE wallet"
      forge_opts+=(--trezor --mnemonic-indexes "${F_MNEMONIC_INDEX:-0}")
      if [[ -n "$F_HARDWARE_DERIVATION_PATH" ]]; then
        forge_opts+=(--mnemonic-derivation-paths "$F_HARDWARE_DERIVATION_PATH")
      fi
    elif [[ "$F_WALLET_TYPE" == "MNEMONIC" ]]; then
      log_info "Use $F_WALLET_TYPE wallet"
      if [[ -z "$F_MNEMONIC_INDEX" ]]; then
        log_error "MNEMONIC_INDEX must be set for MNEMONIC wallet, exit."
        exit 1
      fi
      forge_opts+=(--mnemonics "$F_MNEMONIC" --mnemonic-indexes "$F_MNEMONIC_INDEX")
    elif [[ "$F_WALLET_TYPE" == "AWS_KMS" ]]; then
      log_info "Use $F_WALLET_TYPE wallet"
      if [[ -z "$AWS_KMS_KEY_ID" && -z "$F_AWS_KMS_KEY_ID" ]]; then
        log_error "AWS_KMS_KEY_ID or F_AWS_KMS_KEY_ID must be set for AWS_KMS wallet, exit."
        exit 1
      fi
      export AWS_KMS_KEY_ID="${AWS_KMS_KEY_ID:-$F_AWS_KMS_KEY_ID}"
      forge_opts+=(--aws)
    else
      log_error "Unknown wallet type. Options: AWS_KMS, PRIVATE_KEY, LEDGER, TREZOR, MNEMONIC"
    fi
  fi

  # verifier options
  if [[ "$F_VERIFY" == "true" ]]; then
    forge_opts+=(--verify)
    log_info "Verification enabled (etherscan config from foundry.toml)"
  fi

  log_info "forge script $(_redacted_cmd "${forge_opts[@]}" "$@")"

  forge script "${forge_opts[@]}" "$@"
}

_redacted_cmd() {
  local -a out
  local redact_next="false"
  local arg
  for arg in "$@"; do
    if [[ "$redact_next" == "true" ]]; then
      out+=("<redacted>")
      redact_next="false"
      continue
    fi

    out+=("$arg")
    case "$arg" in
      --private-key|--private-keys|--mnemonics|--mnemonic-passphrases)
        redact_next="true"
        ;;
    esac
  done

  printf "%s " "${out[@]}"
}

sender_impersonate_safe_signer_on_forked_network() {
  ## $1 is the safe config items
  for safeConfigItem in ${@}; do
    log_info "Processing safe .config.${safeConfigItem}"
    local safeAddr=$(yq .config.${safeConfigItem} $CONFIG_YAML)
    log_info "Safe ${safeConfigItem} address is ${safeAddr}"
    if [[ "${safeAddr}" == "" ]]; then 
      log_error ".config.${safeConfigItem} is empty, exit."
      exit 1
    fi
    isSenderOwner=$(cast call --rpc-url ${F_RPC_URL} ${safeAddr} "isOwner(address)(bool)" ${F_SENDER})
    if [[ "${isSenderOwner}" == "true" ]]; then
      log_info "Sender ${F_SENDER} is already owner of safe ${safeConfigItem}(${safeAddr}), skip."
      continue
    fi
    log_info "Impersonate ${safeAddr} and add owner ${F_SENDER} with threshold 1 to safe ${safeAddr}"
    cmd="cast rpc anvil_impersonateAccount ${safeAddr} -r ${F_RPC_URL}"
    log_info "> ${cmd}"; eval ${cmd}
    cmd="cast send --unlocked --from ${safeAddr} ${safeAddr} \"addOwnerWithThreshold(address,uint256)\" ${F_SENDER} 1"
    log_info "> ${cmd}"; eval ${cmd}
    cmd="cast rpc anvil_stopImpersonatingAccount ${safeAddr} -r ${F_RPC_URL}"
    log_info "> ${cmd}"; eval ${cmd}
  done
}

forge_test() {
  log_info "forge test"
  log_info "forge test ${FORGE_OPTS} ${@}"
  forge test ${FORGE_OPTS} "${@}"
}
