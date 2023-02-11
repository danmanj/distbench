#!/bin/bash
################################################################################
# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################
# A script to automate setting up distbench experiments in cloudlab.
#
# To start, visit the following URL to startup a cluster in cloudlab:
# https://tinyurl.com/yeyuxs6y
# (hint: add this to your bookmarks)
#
# You can use another experiment profile, but the machines must be
# named nodeN with N starting at 0.
#
# After the cluster is up and running, execute this script to download,
# build, deploy, and run distbench on the experimental cluster.
# The logs for the most recent run of all the instances of distbench
# will be collected on node0.
#
# The distbench node managers and test sequencer will be bound to the
# cluster's private IP address, making them unreachable over the public
# internet. However the test sequencer RPC interface will be reachable
# from the machine that this script is running on via ssh port forwarding
# as localhost:11000. E.g.
# test_builder client_server -s localhost:11000 -o my_data_dir
#
# If this script is run multiple times it will kill previous instances
# and build/deploy an up-to-date distbench binary from the selected
# branch on github. Do not attempt to manually work with the git
# repository in the distench_source/ directory, as it will likely be
# deleted and re-downloaded by a subsequent run of this script, making
# you very sad. Please submit your changes to a github branch instead.
#
# This script takes 4 optional arguments
# 1) The DNS domain name (not hostname) of the experimental cluster.
# 2) The git repository to fetch from
# 3) The git branch to use
# 4) Optionally the number of nodes to use within the cluster.
#    If the forth argument is omitted DNS is queried to find out
#    the number of nodes to use.
#
# For convenience feel free to edit the following 3 lines.
DEFAULT_CLUSTER_DOMAINNAME=distbench.uic-dcs-pg0.utah.cloudlab.us
DEFAULT_GIT_REPO=https://github.com/google/distbench.git
DEFAULT_GIT_BRANCH=main

################################################################################
# GIANT WARNING! GIANT WARNING! GIANT WARNING! GIANT WARNING! GIANT WARNING!
# DO NOT MAKE CHANGES BELOW THIS LINE, UNLESS YOU PLAN TO UPSTREAM THEM.
################################################################################
set -uEeo pipefail
shopt -s inherit_errexit

function slowcat() { while read -N1 c; do sleep 0.003; echo -n "$c"; done; }
function echo_green() { echo -e $(tput setaf 2)"$*"$(tput sgr0) | slowcat;}
function echo_red() { echo -e $(tput setaf 1)"$*"$(tput sgr0) | slowcat;}
function clssh() { ssh -o 'StrictHostKeyChecking no' "${@}"; }

CLUSTER_DOMAINNAME=${1:-${DEFAULT_CLUSTER_DOMAINNAME}}
GIT_REPO=${2:-${DEFAULT_GIT_REPO}}
GIT_BRANCH=${3:-${DEFAULT_GIT_BRANCH}}
declare -i NUM_NODES=${4:-0}

echo_green "Setting up experimental cluster ${CLUSTER_DOMAINNAME} ..."
echo_green "  Using git repo: ${GIT_REPO} branch: ${GIT_BRANCH}"

if [[ ${NUM_NODES} -le 0 ]]
then
  echo_green "\\nCounting nodes in experimental cluster..."
  NUM_NODES=0
  while nslookup node${NUM_NODES}.${CLUSTER_DOMAINNAME} >/dev/null 2>&1
  do
    NUM_NODES+=1
  done
  echo_green "  Counted $NUM_NODES nodes in experimental cluster."
  if [[ "${NUM_NODES}" == "0" ]]
  then
    echo_red "  Experimental cluster may not be ready yet, or nonexistent."
    exit 1
  fi
else
  echo_green "\\nUsing $NUM_NODES nodes in experimental cluster."
fi

echo_green "\\nPicking private netdev to use..."
NODE0=node0.${CLUSTER_DOMAINNAME}
PUBLIC_HOSTNAME=$(clssh ${NODE0} hostname -f)
PUBLIC_IP=$(host ${PUBLIC_HOSTNAME} | cut -f 4 -d" ")
netdev_list=($(clssh ${NODE0} ip -br link list |
                 grep LOWER_UP |
                 grep -v lo |
                 cut -f1 -d " "))
if [[ ${#netdev_list[@]} -eq 0 ]]
then
  echo_red "\\nNo netdevs returned"
  exit 1
fi
for netdev in "${netdev_list[@]}"
do
  echo_green "  Trying netdev $netdev..."
  if clssh ${NODE0} ip address show dev $netdev | grep $PUBLIC_IP &> /dev/null
  then
    echo_green "    Netdev ${netdev} is the public interface."
    PUBLIC_NETDEV=${netdev}
  else
    echo_green "    Netdev ${netdev} is a private interface."
    PRIVATE_NETDEV=${netdev}
    break
  fi
done

CONTROL_NETDEV=${PRIVATE_NETDEV}
TRAFFIC_NETDEV=${PRIVATE_NETDEV}

CONTROL_IP4=$(
    clssh ${NODE0} ip -br -4 address show dev ${CONTROL_NETDEV} |
      (IFS=" /" ;read a b c d; echo $c)
)

CONTROL_IP6=$(
    clssh ${NODE0} ip -br -6 address show dev ${CONTROL_NETDEV} |
      (IFS=" /" ;read a b c d; echo $c)
)

if [[ "${CONTROL_IP6:0:4}" == "fe80" || -z "$CONTROL_IP6" ]]
then
  SEQUENCER_IP=${CONTROL_IP4}
else
  SEQUENCER_IP=${CONTROL_IP6}
fi

echo_green "\\nUsing ${SEQUENCER_IP} for sequencer IP"

SEQUENCER_PORT=10000

echo_green "\\nExecuting bootstrap script on main node..."
sleep 3

# For debugability change the clsh command to be
# "export TERM=$TERM; tee debug.sh | bash /dev/stdin"
# (include the quotes)
# The double -t sends SIGHUP to the remote processes when the local ssh client
# is killed by e.g. SIGTERM.
clssh -t -t -L 11000:${SEQUENCER_IP}:${SEQUENCER_PORT} ${NODE0} \
  env TERM=$TERM bash /dev/stdin \
  "${NUM_NODES}" \
  "${GIT_REPO}" \
  "${GIT_BRANCH}" \
  "${SEQUENCER_IP}" \
  "${SEQUENCER_PORT}" \
  "${CONTROL_NETDEV}" \
  "${TRAFFIC_NETDEV}" \
   << 'EOF'
######################## REMOTE SCRIPT BEGINS HERE #############################
# We must enclose the contents in () to force bash to read the entire script
# before execution starts. Otherwise commands reading from stdin may steal the
# text of the script.
(
set -uEeo pipefail
shopt -s inherit_errexit

declare -i NUM_NODES="${1}"
GIT_REPO="${2}"
GIT_BRANCH="${3}"
SEQUENCER_IP="${4}"
SEQUENCER_PORT="${5}"
CONTROL_NETDEV="${6}"
TRAFFIC_NETDEV="${7}"

[[ $# == 7 ]]

function slowcat() { while read -N1 c; do sleep 0.003; echo -n "$c"; done; }
function echo_red() { echo -e $(tput setaf 1)"$*"$(tput sgr0) | slowcat;}
function echo_purple() { echo -e $(tput setaf 5)"$*"$(tput sgr0) | slowcat;}
function echo_yellow() { echo -e $(tput setaf 3)"$*"$(tput sgr0) | slowcat;}
function echo_green() { echo -e $(tput setaf 2)"$*"$(tput sgr0) | slowcat;}
function echo_blue() { echo -e $(tput setaf 6)"$*"$(tput sgr0) | slowcat;}

function cloudlab_ssh() { sudo ssh -o 'StrictHostKeyChecking no' "${@}"; }

function cloudlab_scp() { sudo scp -o 'StrictHostKeyChecking no' "${@}"; }

function verify_repo_is_unmodified() {
  # Must be a sequence of commands with && because set -e is broken by design,
  # and nested traps are crazy to implement.
  echo_purple "\\nChecking if distbench git worktree is unmodified..." &&
  git status -u no &&
  git branch &&
  if [[ "$(git branch | wc -l)" != "1" ]]
  then
    echo_red "There seem to be extra branches in cloudlab git repo."
    return 1
  else
    REMOTE_BRANCH=$(git branch -r --contains HEAD --format='%(refname:short)' |
                    grep -v "origin/HEAD" | head -n 1) &&
    [[ -n "${REMOTE_BRANCH}" ]] &&
    git diff --color=always HEAD &&
    git diff --color=always HEAD --name-status &&
    git diff-index --quiet HEAD &&
    git diff --color=always ${REMOTE_BRANCH} &&
    git diff --color=always ${REMOTE_BRANCH} --name-status &&
    git diff-index --quiet ${REMOTE_BRANCH} &&
    echo_purple "  git worktree is unmodified, and safe to update/replace..." &&
    return 0
  fi
}

function fetch_git_repo() {
  cd "${HOME}"
  if [[ -d distbench_source ]]
  then
    echo_purple "  Moving existing git repo out of the way..."
    mv distbench_source distbench_source.prev
    echo_purple "  The old distbench_source is now in distbench_source.prev"
    sleep 5
  fi
  echo_purple "  Grabbing everything from ${GIT_REPO} ..."
  git clone -b ${GIT_BRANCH} ${GIT_REPO} distbench_source
}

function inner_fetch_or_update_git_repo() {
  # If an error occurs call fetch_git_repo and return:
  trap "fetch_git_repo; return 0" ERR

  cd distbench_source
  verify_repo_is_unmodified
  git remote show origin | grep "${GIT_REPO}"
  echo_purple "  distbench upstream repo name matches; safe to fetch..."
  git fetch --all
  OLD_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [[ "${OLD_BRANCH}" == "HEAD" ]]
  then
    git checkout -b ${GIT_BRANCH} origin/${GIT_BRANCH}
  else
    if [[ "${GIT_BRANCH}" != "${OLD_BRANCH}" ]]
    then
      echo_purple "  Switch from branch ${OLD_BRANCH} to ${GIT_BRANCH}"
      git checkout --detach
      git branch -d ${OLD_BRANCH}
      git checkout -b ${GIT_BRANCH} origin/${GIT_BRANCH}
    else
      git reset --hard origin/${GIT_BRANCH}
    fi
  fi
  echo_purple "  distbench git repo is now up-to-date..."
  return 0
}

function fetch_or_update_git_repo() {
  (
    # Runs in a subshell to restore trap automatically.
    inner_fetch_or_update_git_repo
  )
}

function unknown_error_shutdown() {
  echo_red "\\nError, unknown_error_shutdown invoked status = $?"
  echo_red "\\n$BASH_COMMAND"
  jobs
  ${HOME}/distbench_exe run_tests --test_sequencer=${SEQUENCER} --infile \
    <(echo "tests_setting: { shutdown_after_tests: true }")
  #set
  ! killall distbench_exe
  exit 1
}

trap unknown_error_shutdown ERR

echo_purple "\\nRemote bootstrap script executing..."
SEQUENCER=${SEQUENCER_IP}:${SEQUENCER_PORT}
HOSTNAME=$(hostname)
CLUSTER_DOMAINNAME=${HOSTNAME#node[0-9].}
NODE0=node0.${CLUSTER_DOMAINNAME}
if [[ "${HOSTNAME}" != "${NODE0}" ]]
then
  echo_red "Hostname '${HOSTNAME}' does not follow expected format." \
           "\\nshould be ${NODE0}"
  exit 1
fi

echo_purple "\\nFetching distbench source code..."
fetch_or_update_git_repo

echo_purple "\\nChecking for working copy of bazel..."
pushd distbench_source
bazel-5.4.0 version 2> /dev/null || (
  curl -fsSL https://bazel.build/bazel-release.pub.gpg |
    gpg --dearmor > bazel.gpg
  sudo mv bazel.gpg /etc/apt/trusted.gpg.d/
  dsrc="deb [arch=amd64] https://storage.googleapis.com/bazel-apt stable jdk1.8"
  echo "$dsrc" | sudo tee /etc/apt/sources.list.d/bazel.list
  sudo apt-get update
  sudo apt-get install bazel bazel-5.4.0 -y
)

echo_purple "\\nChecking for working copy of libfabric/libmercury ..."
LIBFABRIC_VERSION=1.17.0
MERCURY_VERSION=2.2.0
LF_LINK=$(readlink -sf external_repos/opt/libfabric || true)
HG_LINK=$(readlink -sf external_repos/opt/mercury || true)
if [[ "${LF_LINK:10}" != "${LIBFABRIC_VERSION}" ||
      "${HG_LINK:8}" != "${MERCURY_VERSION}" ]]
then
  sudo apt-get install cmake libhwloc-dev uuid-dev -y &&
  time ./setup_mercury.sh ${LIBFABRIC_VERSION} ${MERCURY_VERSION}
fi

echo_purple "\\nBuilding distbench binary..."
bazel build -c opt :distbench \
  --//:with-mercury=true \
  --//:with-homa=true \
  --//:with-homa-grpc=true
popd

echo_purple "\\nKilling any previous distbench processes..."
for i in $(seq 0 $((NUM_NODES-1)))
do
  ping -c 1 node${i}.${CLUSTER_DOMAINNAME} > /dev/null
  ! cloudlab_ssh node${i}.${CLUSTER_DOMAINNAME} \
    "killall -9 distbench_exe ; rm -f ${HOME}/distbench_exe" &
done
wait

echo_purple "\\nDeploying newest distbench binary as ${HOME}/distbench_exe ..."
cp distbench_source/bazel-bin/distbench ${HOME}/distbench_exe
for i in $(seq 1 $((NUM_NODES-1)))
do
  cloudlab_scp distbench_exe node${i}.${CLUSTER_DOMAINNAME}:${HOME} &
done
wait

COMMON_ARGS=(
  --prefer_ipv4=true
  --control_plane_device=${CONTROL_NETDEV}
)
TEST_SEQUENCER_ARGS=(
  ${COMMON_ARGS[@]}
  --port=${SEQUENCER_PORT}
)
NODE_MANAGER_ARGS=(
  ${COMMON_ARGS[@]}
  --test_sequencer=${SEQUENCER}
  --default_data_plane_device=${TRAFFIC_NETDEV}
)

echo_purple "\\nStarting Test Sequencer on ${SEQUENCER} ..."
echo_purple "  Debug logs can be found in test_sequencer.log"
GLOG_logtostderr=1 ${HOME}/distbench_exe test_sequencer \
  ${TEST_SEQUENCER_ARGS[@]} \
  2>&1 | tee distbench_test_sequencer.log &
sleep 5

# This is the starting port for node managers. For debuggability this will be
# incremented so that each instance runs on a unique port.
declare -i NODE_MANAGER_PORT=9000

for i in $(seq 0 $((NUM_NODES-1)))
do
  echo_purple "\\nStarting node${i} Node Manager..."
  echo_purple "  Debug logs can be found in node${i}.log"
  # The double -t propgates SIGHUP to all node managers.
  cloudlab_ssh -t -t node${i}.${CLUSTER_DOMAINNAME} \
    env GLOG_logtostderr=1 sudo -u $USER ${HOME}/distbench_exe node_manager \
        node${i} \
        --port=${NODE_MANAGER_PORT} \
        ${NODE_MANAGER_ARGS[@]} 2>&1 | tee distbench_node_manager${i}.log &
  NODE_MANAGER_PORT+=1
  sleep 0.5
done

echo
echo_green "The test sequencer and node managers should now be up and running."
echo_yellow "You should now be able to send tests to localhost:11000 E.g."
echo_blue "  'test_builder client_server -s localhost:11000 -o my_data_dir'"
echo_yellow "Debug logs can be fetched via"
echo_blue "  'scp ${NODE0}:distbench*.log my_log_dir'"

wait
) < /dev/null | tee cloudlab_distbench.log
EOF
