#!/bin/bash
set -uEeo pipefail
shopt -s inherit_errexit
LIBFABRIC_VERSION=${1:-1.17.0}
MERCURY_VERSION=${2:-2.2.0}

mkdir -p external_repos/opt
cd external_repos
DST_LIBFABRIC=$(pwd)/opt/libfabric-${LIBFABRIC_VERSION}
DST_MERCURY=$(pwd)/opt/mercury-${MERCURY_VERSION}

function echo_purple() { echo -e $(tput setaf 5)"$*"$(tput sgr0); }

function update_clone() {
  set -x
  if [[ $# != "4" ]]
  then
    echo_purple "update_clone needs exactly 4 arguments to proceed"
   return 1
  fi
  REMOTE_REPO="${1}"
  TAGBRANCH="${2}"
  GITDIR="${3}"
  WORKTREE="${4}"
  if [[ "$(git -C "${GITDIR}" remote get-url origin)" != "$REMOTE_REPO" ]]
  then
    if [[ -d "${GITDIR}" ]]
    then
      echo_purple "\\nLocal git repo may be corrupted!!!"
      echo_purple "Refusing to overwrite anything..."
      echo_purple "You might try running"
      echo_purple "rm -rf $GITDIR"
      echo_purple "and trying again if you are sure that this is safe."
      return 1
    fi
    rm -rf "${GITDIR}"
    mkdir -p "${GITDIR}"
    git -C "${GITDIR}" init # --bare
    git -C "${GITDIR}" remote add origin "${1}"
    git -C "${GITDIR}" fetch --all --tags
    git -C "${GITDIR}" worktree add "${WORKTREE}" "${TAGBRANCH}"
    #git clone -n "${REMOTE_REPO}" "${GITDIR}"
    #git -C "${GITDIR}" checkout --detach
  fi
  if [[ ! -d "${WORKTREE}" ]]
  then
    git -C "${GITDIR}" worktree add "${WORKTREE}" "${TAGBRANCH}"
  fi
  pushd "${WORKTREE}"
  # Make sure worktree does not contain uncommited modifications.
  git diff --exit-code HEAD || (
      echo_purple "There may be modifications to your worktree files."
      echo_purple "Refusing to overwrite anything..."
      return 2
    )
  # Make sure worktree is a commit that exists in a remote branch
  if [[ -z "$(git branch -r --contains HEAD ; git tag --contains HEAD)" ]]
  then
    echo_purple "The local git worktree no longer matches anything upstream."
    echo_purple "This probably means you made local changes and commited them."
    echo_purple "Refusing to overwrite anything..."
    return 3
  fi
  git fetch --all --tags
  git reset --hard ${TAGBRANCH}
  popd
}

(
  VERSION_TAG=v${LIBFABRIC_VERSION}
  LIBFABRIC_REPO_DIR=${PWD}/libfabric_repo
  LIBFABRIC_BUILD_DIR=${LIBFABRIC_REPO_DIR}/${LIBFABRIC_VERSION}
  update_clone \
    https://github.com/ofiwg/libfabric.git \
    ${VERSION_TAG} \
    ${PWD}/libfabric_repo \
    ${LIBFABRIC_BUILD_DIR}
  rm -rf ${DST_LIBFABRIC} opt/libfabric
  (
    cd ${LIBFABRIC_BUILD_DIR}
    if [[ ! -f ./configure ]]
    then
      ./autogen.sh
    fi
    if [[ ! -f config.status ]]
    then
      ./configure \
      --prefix $DST_LIBFABRIC \
      --enable-verbs=no \
      --enable-efa=no \
      --disable-usnic \
      --enable-psm3-verbs=no || rm config.status
    fi
    echo_purple building libfabric:
    nice make -j $(nproc)
    echo_purple installing libfabric:
    make install
  )
  ln -sf ${DST_LIBFABRIC} opt/libfabric
)

(
  if [[ -v LD_LIBRARY_PATH && -n "${LD_LIBRARY_PATH}" ]]
  then
    LD_LIBRARY_PATH=$DST_MERCURY/lib:$LD_LIBRARY_PATH
  else
    LD_LIBRARY_PATH=$DST_MERCURY/lib
  fi

  VERSION_TAG=v${MERCURY_VERSION}
  MERCURY_REPO_DIR=${PWD}/mercury_repo
  MERCURY_BUILD_DIR=${MERCURY_REPO_DIR}/${MERCURY_VERSION}
  update_clone \
    https://github.com/mercury-hpc/mercury.git \
    ${VERSION_TAG} \
    ${PWD}/mercury_repo \
    ${MERCURY_BUILD_DIR}
  rm -rf ${DST_MERCURY} opt/mercury
  (
    cd ${MERCURY_BUILD_DIR}
    if [[ ! -f build/Makefile ]]
    then
      rm -rf build
    fi
    if ! cd build
    then
      mkdir -p build
      cd build
      cmake \
        DCMAKE_-BUILD_TYPE=Debug \
        -DNA_USE_SM=OFF \
        -DNA_USE_OFI=ON \
        -DOFI_INCLUDE_DIR=$DST_LIBFABRIC/include \
        -DOFI_LIBRARY=$DST_LIBFABRIC/lib \
        -DCMAKE_INSTALL_PREFIX=$DST_MERCURY \
        ..
    fi
    echo_purple building mercury:
    nice make -j $(nproc)
    echo_purple installing mercury:
    make install
  )
  ln -sf ${DST_MERCURY} opt/mercury
)
