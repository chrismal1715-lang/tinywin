# tinywin shell conveniences
[ -n "$PS1" ] || return 0
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$PATH:$HOME/.local/bin";; esac
export PATH
