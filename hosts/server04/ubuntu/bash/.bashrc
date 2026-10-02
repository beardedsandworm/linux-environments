#
# ~/.bashrc
#

export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
export PATH=$PATH:$ANDROID_HOME/platform-tools

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

# activate starship in terminal
eval "$(starship init bash)"

# enable fzf in terminal
source /usr/share/fzf/key-bindings.bash
source /usr/share/fzf/completion.bash

# add Dracula theme to fzf
export FZF_DEFAULT_OPTS='--color=fg:#f8f8f2,bg:#282a36,hl:#bd93f9 --color=fg+:#f8f8f2,bg+:#44475a,hl+:#bd93f9 --color=info:#ffb86c,prompt:#50fa7b,pointer:#ff79c6 --color=marker:#ff79c6,spinner:#ffb86c,header:#6272a4'

# branding
wormlogo() {
  printf "\e[38;2;242;195;95m{\e[0m\e[38;2;143;212;106m~\e[0m\e[38;2;242;195;95m}\e[0m \e[38;2;143;212;106mworm\e[0m\e[38;2;242;195;95mlogic\e[0m\n"
}
