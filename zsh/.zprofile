eval "$(/opt/homebrew/bin/brew shellenv)"

# Optional: Python.org installer adds this via its post-install script.
if [[ -d "/Library/Frameworks/Python.framework/Versions/3.14/bin" ]]; then
  PATH="/Library/Frameworks/Python.framework/Versions/3.14/bin:${PATH}"
  export PATH
fi
