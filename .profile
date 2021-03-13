# ~/.profile: executed by the command interpreter for login shells.
# This file is not read by bash(1), if ~/.bash_profile or ~/.bash_login
# exists.
# see /usr/share/doc/bash/examples/startup-files for examples.
# the files are located in the bash-doc package.

# the default umask is set in /etc/profile; for setting the umask
# for ssh logins, install and configure the libpam-umask package.
#umask 022

# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
	. "$HOME/.bashrc"
    fi
fi

# set PATH so it includes user's private bin if it exists
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi

alias prod="IGGY_ENDPOINT="https://cloud.igneous.io" AWS_PROFILE="production" IGGY_ENV="production" ; source ~/.profile"
alias cust-prod="IGGY_ENDPOINT="https://cloud.igneous.io" AWS_PROFILE="cust-prod" IGGY_ENV="cust-prod" ; source ~/.profile"
alias dev="IGGY_ENDPOINT="https://dev.iggy.bz" AWS_PROFILE="default" IGGY_ENV="dev" ; source ~/.profile"
alias sim="IGGY_ENDPOINT="http://192.168.1.31:5000"  AWS_PROFILE="local" IGGY_ENV="sim" ; source ~/.profile"
alias topo12="export IGGY_ENDPOINT="" AWS_PROFILE="default" IGGY_ENV="topo12" ; source ~/.profile"
alias startcs="export IGGY_ENDPOINT="" AWS_PROFILE="local" IGGY_ENV="startcs" ; source ~/.profile"

alias piggy="IGGY_ENDPOINT="https://cloud.igneous.io" AWS_PROFILE="production" /home/$(whoami)/mesa/go/bin/linux_amd64/iggy"

export IGGY_ENDPOINT AWS_PROFILE IGGY_ENV
echo "IGGY_ENDPOINT :  $IGGY_ENDPOINT "
echo "AWS_PROFILE :  $AWS_PROFILE "

export PS1="\u@\h:\w : $IGGY_ENV $ "

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/$(whoami)/mesa/go/bin/linux_amd64:/usr/local/go/bin:/usr/src/go1.15.2/go/bin"

export GOPATH="/root/mesa/go"
