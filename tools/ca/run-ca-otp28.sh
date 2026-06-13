#!/usr/bin/env bash
set -eo pipefail

OTP28_HOME="${OTP28_HOME:-$HOME/28.0.2}"
CA_HOME="${CA_HOME:-$HOME/ca}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.18.4-otp-28}"

if [ ! -f "$OTP28_HOME/activate" ]; then
  echo "OTP 28 activation script was not found: $OTP28_HOME/activate" >&2
  echo "Set OTP28_HOME to the kerl installation path." >&2
  exit 1
fi

# kerl activation scripts may read unset internal variables, so this script
# intentionally does not use `set -u`.
# shellcheck disable=SC1090
source "$OTP28_HOME/activate"

if [ -f "$HOME/.asdf/asdf.sh" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.asdf/asdf.sh"
fi

cd "$CA_HOME"

if command -v asdf >/dev/null 2>&1; then
  export ASDF_ELIXIR_VERSION="$ELIXIR_VERSION"
fi

exec iex -S mix
