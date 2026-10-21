# Minimal assertion helpers. Source, call `check`, end with `finish`.

_pass=0
_fail=0

# check <description> <shell condition>
check() {
  if eval "$2"; then
    _pass=$((_pass + 1))
    echo "  PASS $1"
  else
    _fail=$((_fail + 1))
    echo "  FAIL $1"
  fi
}

finish() {
  echo "  ${_pass} passed, ${_fail} failed"
  [ "${_fail}" -eq 0 ]
}
